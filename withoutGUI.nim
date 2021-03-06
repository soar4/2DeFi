import chronos, nimcrypto, strutils
import libp2p/daemon/daemonapi

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

const
  ServerProtocols = @["/test-chat-stream"]

type
  CustomData = ref object
    api: DaemonAPI
    remotes: seq[StreamTransport]
    consoleFd: AsyncFD
    serveFut: Future[void]

proc threadMain(wfd: AsyncFD) {.thread.} =
  var transp = fromPipe(wfd)
 
  while true:
    var line = stdin.readLine()
    let res = waitFor transp.write(line & "\r\n")

proc serveThread(udata: CustomData) {.async.} =
  var transp = fromPipe(udata.consoleFd)

  proc remoteReader(transp: StreamTransport) {.async.} =
    while true:
      var line = await transp.readLine()
      if len(line) == 0:
        break
      echo ">> ", line

  while true:
    try:
      var line = await transp.readLine()
      if line.startsWith("/connect"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerID.init(parts[1]).value
          var address = MultiAddress.init(multiCodec("p2p-circuit")).value
          address &= MultiAddress.init(multiCodec("p2p"), peerId).value
          echo "= Searching for peer ", peerId.pretty()
          var id = await udata.api.dhtFindPeer(peerId)
          echo "= Peer " & parts[1] & " found at addresses:"
          for item in id.addresses:
            echo $item
          echo "= Connecting to peer ", $address
          await udata.api.connect(peerId, @[address], 30)
          echo "= Opening stream to peer chat ", parts[1]
          var stream = await udata.api.openStream(peerId, ServerProtocols)
          udata.remotes.add(stream.transp)
          echo "= Connected to peer chat ", parts[1]
          asyncCheck remoteReader(stream.transp)
      elif line.startsWith("/search"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerID.init(parts[1]).value
          echo "= Searching for peer ", peerId.pretty()
          var id = await udata.api.dhtFindPeer(peerId)
          echo "= Peer " & parts[1] & " found at addresses:"
          for item in id.addresses:
            echo $item
      elif line.startsWith("/consearch"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var peerId = PeerID.init(parts[1]).value
          echo "= Searching for peers connected to peer ", parts[1]
          var peers = await udata.api.dhtFindPeersConnectedToPeer(peerId)
          echo "= Found ", len(peers), " connected to peer ", parts[1]
          for item in peers:
            var peer = item.peer
            var addresses = newSeq[string]()
            var relay = false
            for a in item.addresses:
              addresses.add($a)
              if a.protoName().value == "/p2p-circuit":
                relay = true
                break
            if relay:
              echo peer.pretty(), " * ",  " [", addresses.join(", "), "]"
            else:
              echo peer.pretty(), " [", addresses.join(", "), "]"
      elif line.startsWith("/pub"):
        var parts = line.split(" ")
        if len(parts) == 3:
          var topic = parts[1]
          var message = parts[2]
          discard udata.api.pubsubPublish(topic, message)
      elif line.startsWith("/listpeers"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var topic = parts[1]
          var peers = await udata.api.pubsubListPeers(topic)
          echo peers
      elif line.startsWith("/gettopics"):
          var topics = await udata.api.pubsubGetTopics()
          echo topics
      elif line.startsWith("/sub"):
        var parts = line.split(" ")
        if len(parts) == 2:
          var topic = parts[1]
          proc callback(api: DaemonAPI,ticket: PubsubTicket,message: PubSubMessage): Future[bool] = 
            result = newFuture[bool]()
            echo "message.data: ",message.data
            result.complete true
          var ticket = await udata.api.pubsubSubscribe(topic, callback)
          echo "subscribed: ", ticket.topic
      elif line.startsWith("/exit"):
        break
      else:
        var msg = line & "\r\n"
        echo "<< ", line
        var pending = newSeq[Future[int]]()
        for item in udata.remotes:
          pending.add(item.write(msg))
        if len(pending) > 0:
          var results = await all(pending)
    except:
      echo getCurrentException().msg

var bootstrapNodes = @["/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
  "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
  "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
  "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
  "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
  "/ip4/104.131.131.82/udp/4001/quic/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ"]

proc main() {.async.} =
  {.gcsafe.}:
    var data = new CustomData
    data.remotes = newSeq[StreamTransport]()

    var (rfd, wfd) = createAsyncPipe()
    if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
        raise newException(ValueError, "Could not initialize pipe!")

    data.consoleFd = rfd

    data.serveFut = serveThread(data)
    data.api = await newDaemonApi({DHTFull, Bootstrap,PSGossipSub},id="", bootstrapNodes = bootstrapNodes, daemon="./p2pd")

    var thread: Thread[AsyncFD]
    thread.createThread(threadMain, wfd)

    echo "= Starting P2P node"

    var id = await data.api.identity()

    proc streamHandler(api: DaemonAPI, stream: P2PStream) {.async.} =
        echo "= Peer ", stream.peer.pretty(), " joined chat"
        data.remotes.add(stream.transp)
        while true:
            var line = await stream.transp.readLine()
            if len(line) == 0:
                break
            echo ">> ", line

    await data.api.addHandler(ServerProtocols, streamHandler)
    echo "= Your PeerID is ", id.peer.pretty()
    await data.serveFut

when isMainModule:
  waitFor(main())
