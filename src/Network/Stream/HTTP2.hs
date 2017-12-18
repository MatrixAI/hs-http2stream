{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2 where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK
import Data.IORef
import Data.Tuple.Extra

import Network.Stream.HTTP2.Types
import Network.Stream.HTTP2.Multiplexer
import Network.Stream.HTTP2.EncodeFrame
import System.IO.Streams 
import qualified Control.Exception as E
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad

acceptStream :: Context -> IO StreamPair
acceptStream ctx@Context{acceptQ, outputQ} = do
    strm@Stream{..} <- atomically $ readTQueue acceptQ
    is <- makeInputStream $ readStream strm
    os <- makeOutputStream $ writeStream strm
    return (is, os)
  where
    -- readStream Stream{..} = do
    --     !bs <- atomically $ readTQueue readQ
    --     case bs of
    --          "" -> return Nothing
    --          _  -> return $ Just bs 
    readStream = undefined
    -- writeStream Stream{..} (Just bs) = do
    --     pre <- readIORef streamPrecedence
    --     enqueue outputQ streamNumber pre bs
    writeStream = undefined

-- dialStream :: Context -> IO StreamPair
-- dialStream ctx@Context{streamTable, clientStreamId} = do
--     csid <- atomicModifyIORef' clientStreamId $ dupe . (+2)
--     strm@Stream{streamNumber, streamPrecedence} <- newStream csid 65535
--     opened ctx strm
--     atomically $ enqueue outputQ streamNumber streamPrecedence strm
dialStream = undefined
    
----------------------------------------------------------------

-- Start a thread for receiving frames and sending frames
-- Does not use the thread pool manager from the Warp implementation
attachMuxer :: (Int -> IO ByteString) -> (ByteString -> IO ()) -> IO Context
attachMuxer recvConn sendConn = do
    checkPreface
    ctx <- newContext
    -- Receiver
    tid <- forkIO $ frameReceiver ctx recvConn
    -- Sender
    -- frameSender is the main thread because it ensures to send
    -- a goway frame.
    tid2 <- forkIO $ _frameSender ctx tid
    return ctx
  where 
    _frameSender ctx tid = frameSender ctx sendConn `E.finally` do
        clearContext ctx
        -- stop mgr
        killThread tid
    checkPreface = do
        preface <- recvConn connectionPrefaceLength
        when (connectionPreface /= preface) $ do
            goaway sendConn ProtocolError "Preface mismatch"
            E.throwIO $ ConnectionError ProtocolError "Preface mismatch"

-- connClose must not be called here since Run:fork calls it
goaway :: (ByteString -> IO ()) -> ErrorCodeId -> ByteString -> IO ()
goaway connSend etype debugmsg = connSend bytestream
  where
    bytestream = goawayFrame 0 etype debugmsg
