# http2stream
HTTP2 Stream Muxer to support the LibP2P API

Work In Progress.

TODO List:
- All the partial functions in Sender are pretty smelly. Especially the errors that I give out if we try to encode a closed stream. We should be able to mark the Output type with a tag like we mark Streams (i.e. Output 'Closed and Output 'Open).

Future Work:
- I hate how imperative this thing is. I want to refactor all the connection code in the frame receiver into an ADT that we execute over.
- We tag the stream type with whether it is Open or Closed, i.e. Stream 'Open or Stream 'Closed. This eliminates some partial functions in the Receiver. But introduces some problems over how streams of different states are stored. Probably best figured out after we refactor the Receiver and Sender into an ADT.
