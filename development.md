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

> | closeStream closes both directions of the stream represented by the pair
> of (Input, Output)
> TODO: Suppose you acquire two different streams like this:
>  (is1, os1) <- acceptStream ctx
>  (is2, os2) <- acceptStream ctx
>  then you could try to close the input stream of strm1 and the output
>  stream of strm2 like so:

>  closeStream ctx (is1, os2)

>  which doesn't make a lot of sense
>  We should produce a type FullStream where we can extract the Input and Output
>  streams, but are not allowed to recombine them into a FullStream once extracted
>  or only allow the construction of valid FullStream pairs
>  (as in Input and Output are from the same stream)
>  Hide the constructor? 
>  alternatively, we should provide streams with a registered identifier at the top level
>  (Wrap Input and Output again so we have multicodec based addresses for streams)
>  The problem is http2stream muxing library. Why should it have another preregistered identifier
>  just to close the stream? Is it necessary to introduce another layer of indirection?
>  It would look nicer at the top level (but no raw access to the Input and Output types), just a
>  token identifier for that stream.

> -- Why do you need stream names?
> -- Because you want to provide some way for the user of the library
> -- to conveniently address streams that they are using
> -- Is it really a convenient way of addressing a stream?
> -- No it is a bad way of addressing a stream because we could acquire
> -- a streamname that doesn't exist
> -- for example
> -- writeStream "nosuchstream" "some payload"
> -- in fact we want to disallow at compile time writing to streams that don't exist
> -- if they w

we need to be able to close a stream
and handle the following 2 cases properly

case 1:
strm <- accept ctx
writeStream strm "http2 test"
closeStream ctx strm
-- END_STREAM flag is set on DATA

case 2:
strm <- accept ctx
closeStream ctx strm
-- ENDSTREAM flag is set on HEADERS

I think we should be able to do this because sending on the stream is lazily evaluated (i.e. if we accept a stream but don't write to it no headers frame is sent yet). Or rather we should make this a capability ( the tradeoff is that we might timeout the client on the other end, because they are expecting a headers frame in response to their request (it's a weird case)

OHeader is constructed by requestHeader and responsHeader with no flags specified

What enqueues the OHeader
The OHeader isn't enqueued
it's embedded into the output stream of the stream constructor
So w

So the problem is that OEndStream is treated as a frame in our output model when really it's a flag that is set on a particu lar frame

And we automatically represent OEndStream as a DataFrame
How do we represent OEndStream as a flag

The problem is that the mkFramePayload isn't context dependent
It operates on individual frames when we need it to have a different value depending on the state of the stream
In particular we want something like

mkPayload (OHeader mkHdr OEndStream) = 
