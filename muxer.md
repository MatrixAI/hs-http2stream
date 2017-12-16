# Dialing a Peer HTTP2
- The main thread is passed a StreamPair for communication with the peer
- The main thread writes the client connection preface, and a settings frame
  that is default, or configured using an m Config variable
- The main thread opens a channel for communication, and forks a thread that
  runs a stream handler to receive incoming data
- The main thread can then immediately begin writing data for whatever
  service is using the Stream, but should terminate on a signal from the forked
  thread (streamHandler thread)
- The stream handler should expect to receive an empty or updated settings
  frame from the remote peer as

- Is there a way to tag a function that takes an initial Stream to one that i
  s:
