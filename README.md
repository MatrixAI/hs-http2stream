# http2stream
HTTP2 Stream Muxer to support the LibP2P API

Work In Progress.

TODO List:
- All the partial functions in Sender are pretty smelly. Especially the errors that I give out if we try to encode a closed stream. We should be able to mark the Output type with a tag like we mark Streams (i.e. Output 'Closed and Output 'Open).
Future Work:
- Refactor the frameReceiver code to use an ADT for the control flow.
- We tag the stream type with whether it is Open or Closed, i.e. Stream 'Open or Stream 'Closed. This eliminates some partial functions in the Receiver. But introduces some problems over how streams of different states are stored. Probably best figured out after we refactor the Receiver and Sender into an ADT.

---

-# Dialing a Peer HTTP2	
-- The main thread is passed a StreamPair for communication with the peer	
-- The main thread writes the client connection preface, and a settings frame	
-  that is default, or configured using an m Config variable	
-- The main thread opens a channel for communication, and forks a thread that	
-  runs a stream handler to receive incoming data	
-- The main thread can then immediately begin writing data for whatever	
-  service is using the Stream, but should terminate on a signal from the forked	
-  thread (streamHandler thread)	
-- The stream handler should expect to receive an empty or updated settings	
-  frame from the remote peer as	
-	
-- Is there a way to tag a function that takes an initial Stream to one that i	
-  s:

```
  ghc-options:         -threaded -rtsopts -with-rtsopts=-N -fprof-auto
                       -fprof-auto-calls -fbreak-on-exception
```

---

Restart

Time to figure out what's going on here.

Exposed modules is `Network.Stream.HTTP2` which exposes `HTTP2` functions. Also `Network.Stream.Types` which exposes some of the types required.

The swarm system requires it?
We should also check the swarm.
