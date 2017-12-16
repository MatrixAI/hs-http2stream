
Stream ::= A record that stores stream information such as StreamId,
Open/HalfClosed/Closed, the window size of the stream, and the stream
precedence

# Stream States
- Half Closed means Read-Only
  -e.g. Half CLosed (Remote) Means that the remote is read only on the stream
  - Half closed (Local) Means that we are read only on the stream

# getStream
-- | Return either a stream saved in the context, or a newly created stream, or
nothing if the stream was innitiated by the server
getStream :: IO (Maybe Stream)
- If the stream exists in the context
  - If the frame type is 'FrameHeader'
    - If the existing stream is half closed, throw error
    - Otherwise set stream state to 'Opened' from 'Idle' in the context
  - return just the stream

- Else
  - If the streamID is a response (even number means server initiated-stream), then return 'Nothing'
  - Else (The stream was initiated by the client,  but no state associated with
    the stream in the context)
    - If the frame type  is 'FrameHeader'
      - check context, fail if too many streams multiplexed already
      - save the latest streamID from the client to clientStreamID in the
        context 
    
    - Now create a new stream, and save it in the context, returning just the
      new stream with 'JustOpened' state

Warp Server doesn't handle incoming pushpromise frames
