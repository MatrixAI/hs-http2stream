{-# LANGUAGE BangPatterns #-} 
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Multiplexer where

import qualified Control.Exception as E
import Data.IORef
import Control.Concurrent.STM
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder.Extra as B
import Network.HPACK
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.Types
import Network.Stream.HTTP2.EncodeFrame
import Control.Monad


-- | Read and decode a frame from the connection.
receiveFrame :: (Int -> IO BS.ByteString) -> IO (Int, Frame)
receiveFrame recvN = do    
    fhdrBytes <- recvN frameHeaderLength
    let (tid, hdr@FrameHeader{payloadLength}) = decodeFrameHeader fhdrBytes
    pl <- recvN payloadLength
    case decodeFramePayload tid hdr pl of
        Left h2error -> E.throwIO h2error
        Right pl'    -> return (frameHeaderLength + payloadLength, Frame hdr pl')
 

-- | Given a function that sends on the connection, encode the frame and send.
--   TODO: replace with ByteString Builder implementation as this uses
--   BS.concat which is quite slow.
sendOutput :: (BS.ByteString -> IO ()) -> Output -> IO ()
sendOutput send out@(OHeaders sid flags ohdrs@HeadersFrame{}) = do
    send $ encodeFrame (EncodeInfo flags sid Nothing) ohdrs
sendOutput send out@(OData sid flags odata@DataFrame{}) = do 
    send $ encodeFrame (EncodeInfo flags sid Nothing) odata


-- | For a given connection and connection context, receive and process an 
-- incoming frame. Only 1 of these should be run per connection, as some of
-- the stored data in the context (IORef stuff) is not thread safe. 
-- TODO: whatever calls this needs to catch stream and connection errors that
-- this throws
frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} connReceive = do
    (frameLen, inframe@Frame{..}) <- receiveFrame connReceive
    let FrameHeader{..} = frameHeader
    -- Update connection window size by bytes read
    atomically $ modifyTVar' connectionWindow (frameLen-) 
    -- TODO: Update stream window size by bytes read
    case framePayload of
        -- Receiving a data frame
        -- Pass it to the correct stream
        DataFrame pl -> do
            mstrm <- search streamTable streamId
            case mstrm of
                Nothing -> do
                    -- The stream is not open or half closed, so cannot receive
                    -- data.
                    E.throwIO $ StreamError StreamClosed streamId
                Just strm@(Stream{streamState}) -> do
                    state <- readIORef streamState
                    case state of
                        Open (Body q clen blen) -> atomically $ writeTQueue q pl
                        -- First frame of the stream after stream headers
                        Open JustOpened -> undefined
        HeadersFrame mpri hdrblk -> do
            -- Need to read the stream headers and make a new stream
            csid <- readIORef clientStreamId
            when (csid > streamId) $ do
                E.throwIO $ ConnectionError ProtocolError
                          $ "New client stream identifier must not decrease"
            Settings{initialWindowSize} <- readIORef http2settings 
            strm <- newStream streamId initialWindowSize
            insert streamTable streamId strm
            opened ctx strm
     
        PriorityFrame pri -> undefined
        RSTStreamFrame eid -> undefined
        SettingsFrame sl -> undefined
        PushPromiseFrame sid hdrblk -> undefined
        PingFrame bs -> undefined
        GoAwayFrame lastStreamId eid bs -> undefined
        WindowUpdateFrame ws -> undefined
        ContinuationFrame hdrblk -> undefined
        UnknownFrame tid bs -> undefined


-- | read an output frame from the connection context, and then send the frame
-- using the connection sender
frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender ctx@Context{outputQ} connSender = do
    (sid, pre, out) <- dequeue outputQ
    sendOutput connSender out
