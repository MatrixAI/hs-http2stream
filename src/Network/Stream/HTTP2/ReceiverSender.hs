{-# LANGUAGE BangPatterns #-} 
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Multiplexer where

import qualified Control.Exception as E
import Control.Concurrent.STM
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder.Extra as B
import Network.HPACK
import Network.HTTP2
import Network.Stream.HTTP2.Types

data Connection = Connection
  {   
    connSender :: ByteString -> IO ()
  , connReceiver :: BufSize -> IO ByteString  
  }

-- | Read a frame from a function returning bytes representing a read from the
-- connection.
receiveInput :: (BufSize -> IO ByteString) -> IO (Int, Input)
receiveInput recvN = do    
    (tid, hdr@{payloadLength, streamId, flags}) <- decodeFrameHeader <$> recvN frameHeaderLength
    pl <- recvN payloadLength
    case decodeFramePayload tid hdr pl of
         Left h2error -> E.throwIO h2err
         Right pl'    -> return (frameHeaderLength + payloadLength, makeInput)
  where
    makeInput
        | isControl tid       = IControl pl'
        | FrameHeaders <- tid = IHeaders streamId pl'
        | FrameData    <- tid = IData streamId pl'

-- | Given a function that sends on the connection, encode the frame and send.
--   TODO: replace with ByteString Builder implementation as this uses
--   BS.concat which is quite slow.
sendOutput :: (ByteString -> IO ()) -> Output -> IO ()
sendOutput send out@(OHeader sid flags ohdrs@HeadersFrame{}) = do
    send $ encodeFrame (EncodeInfo flags sid Nothing) ohdrs
sendOutput send out@(OData sid flags odata@DataFrame{}) = do 
    send $ encodeFrame (EncodeInfo flags sid Nothing) odata

-- | For a given connection and connection context, receive an incoming frame
-- on that connection. Only 1 of these should be run per connection, as some of
-- the stored data (IORef stuff) is not thread safe. 
frameReceiver :: Context -> Connection -> IO ()
frameReceiver ctx@Context{..} Connection{connReceive} = do
    (readlen, inframe) <- receiveInput connReceiver
    -- Update connection window size by bytes read
    atomically $ modifyTVar' (readlen-) 
    case inframe of
        frameControl@(IControl sid ctl) -> control
        frameHeaders@(IHeaders sid hdrblk) -> headers
        frameData@(IData sid pl) -> stream
  where
    control = do
    headers = do
        -- Need to read the stream headers and make a new stream
        readIORef clientStreamId
        when (sid <= clientStreamId) $ do
            E.throwIO $ ConnectionError ProtocolError
                      $ "New client stream identifier must not decrease"
        

    stream = do
        mstrm <- search streamTable sid
        case mstrm of
            Nothing -> do
                E.throwIO $ ConnectionError ProtocolError "Stream not open"
            Just strm@(Stream{streamState}) -> do
                let Open (Body q clen blen) = streamState
                atomically $ writeTQueue q pl

        
frameSender :: Context -> Connection -> IO ()
frameSender ctx@Context{outputQ} Connection{connSender} = do
    (sid, pre, out) <- dequeue outputQ
    
    sendOutput connSender out
