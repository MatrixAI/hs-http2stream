# http2stream
HTTP2 Stream Muxer based on Warp server types

Currently a Work In Progress.

TODO List:
- QuickCheck tests
- FrameSender and FrameReceiver
- accept and dialStream
- Catch Stream and Connection errors in frame sender and frame receiver, and
  send the relevant rst_stream/ goaway frames to the peer.

Future Work:
- I think it is possible to lift the state of the stream to the type level
  using an extension like -XTypeFamilies. the type could look something like
  data Stream (a :: StreamState)  = ...
  Not yet sure what problems I'd run into, but worth trying later. Maybe this
  was how the original functional implementation of Warp worked, as they have
  an OpenState that has access to all the queues that you actually need to
  write into (with instance Monad Stream).
