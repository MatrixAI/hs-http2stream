# http2stream
HTTP2 Stream Muxer based on Warp server types

Currently a Work In Progress.

TODO List:
- QuickCheck tests
- FrameSender and FrameReceiver
- accept and dialStream
- Catch Stream and Connection errors in frame sender and frame receiver, and
  send the relevant rst_stream/ goaway frames to the peer.
