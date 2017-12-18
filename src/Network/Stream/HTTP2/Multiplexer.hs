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


-- | Read a frame from a function returning bytes representing a read from the
-- connection.
receiveInput :: (Int -> IO BS.ByteString) -> IO (Int, Input)
receiveInput recvN = do    
    (tid, hdr@FrameHeader{payloadLength, streamId, flags}) <- decodeFrameHeader <$> recvN frameHeaderLength
    pl <- recvN payloadLength
    case decodeFramePayload tid hdr pl of
         Left h2error -> E.throwIO h2error
         Right pl'    -> return (frameHeaderLength + payloadLength, mkInput tid streamId pl')
  where
    mkInput tid sid pl'
        | isControl sid       = mkControl pl'
        | FrameHeaders <- tid = mkHeaders sid pl'
        | FrameData    <- tid = mkData pl'
    -- mkControl (SettingsFrame sl) = CSettings bs??? sl
    -- mkControl (PingFrame bs) = CFrame (pingFrameAck bs)
    -- mkControl (GoAwayFrame lastProcessedId eid bs) = CFinish
    -- mkControl (WindowUpdateFrame ws)
    mkControl = undefined
    mkHeaders = undefined
    mkData = undefined

-- | Given a function that sends on the connection, encode the frame and send.
--   TODO: replace with ByteString Builder implementation as this uses
--   BS.concat which is quite slow.
sendOutput :: (BS.ByteString -> IO ()) -> Output -> IO ()
sendOutput send out@(OHeaders sid flags ohdrs@HeadersFrame{}) = do
    send $ encodeFrame (EncodeInfo flags sid Nothing) ohdrs
sendOutput send out@(OData sid flags odata@DataFrame{}) = do 
    send $ encodeFrame (EncodeInfo flags sid Nothing) odata

-- | For a given connection and connection context, receive an incoming frame
-- on that connection. Only 1 of these should be run per connection, as some of
-- the stored data (IORef stuff) is not thread safe. 
frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} connReceive = do
    (readlen, inframe) <- receiveInput connReceive
    -- Update connection window size by bytes read
    atomically $ modifyTVar' connectionWindow (readlen-) 
    case inframe of
        frameControl@(IControl ctl) -> control ctl
        frameHeaders@(IHeaders sid hdrblk) -> headers sid hdrblk
        frameData@(IData sid pl) -> stream sid pl
  where
    control = undefined
    headers = undefined
    stream = undefined
    -- headers sid hdrblk= do
    --     -- Need to read the stream headers and make a new stream
    --     readIORef clientStreamId
    --     when (sid <= clientStreamId) $ do
    --         E.throwIO $ ConnectionError ProtocolError
    --                   $ "New client stream identifier must not decrease"
    --     Settings{initialWindowSize} <- readIORef http2settings 
    --     strm <- newStream sid initialWindowSize
    --     insert streamTable sid strm
    --     opened ctx strm
    -- stream sid pl= do
    --     mstrm <- search streamTable sid
    --     case mstrm of
    --         Nothing -> do
    --             E.throwIO $ ConnectionError ProtocolError "Stream not open"
    --         Just strm@(Stream{streamState}) -> do
    --             state <- readIORef streamState
    --             case state of
    --                 Open (Body q clen blen) -> atomically $ writeTQueue q pl
    --                 -- First frame of the stream after stream headers
    --                 Open JustOpened -> undefined

-- | read an output frame from the connection context, and then send the frame
-- using the connection sender
frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender ctx@Context{outputQ} connSender = do
    (sid, pre, out) <- dequeue outputQ
    sendOutput connSender out
