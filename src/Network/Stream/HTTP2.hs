{-# LANGUAGE BangPatterns #-}

module Network.Stream.HTTP2 where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HPACK
import Data.IORef
import Data.Tuple.Extra

import Network.Stream.HTTP2.Types

acceptStream :: Context -> IO StreamPair
acceptStream ctx@Context{acceptQ, outputQ} = do
    strm{streamNumber, streamState} <- atomically $ dequeue acceptQ
    if isOpen streamState
      then do
        let Body readQ clen blen = streamState
        is <- makeInputStream readStream
        os <- makeOutputStream writeStream
        return (is, os)
          where
            readStream = do
              !bs <- atomically $ readTQueue readQ
              case bs of
                   "" -> return Nothing
                   _  -> return $ Just bs 
            writeStream (Just bs) = do
              pre <- readIORef streamPrecedence
              atomically $ writeTQueue outQ streamNumber pre bs
            writeQ Nothing = do
              pre <- readIORef streamPrecedence
              atomically $ writeTQueue outQ streamNumber pre ""
 
dialStream :: Context -> IO StreamPair
dialStream ctx@Context{streamTable, clientStreamId} = do
    csid <- atomicModifyIORef' clientStreamId $ dupe . (+2)
    strm{streamNumber, streamPrecedence} <- newStream csid 65535
    opened ctx strm
    atomically $ dialQ streamNumber streamPrecedence strm
    
----------------------------------------------------------------

-- Start a thread for receiving frames and sending frames
-- Does not use the thread pool manager from the Warp implementation
attachMuxer :: (BufSize -> IO ByteString) -> (ByteString -> IO ()) -> IO Context
attachMuxer recvConn sendConn = do
    checkPreface
    ctx <- newContext
    -- Receiver
    tid <- forkIO $ frameReceiver ctx recvConn
    -- Sender
    -- frameSender is the main thread because it ensures to send
    -- a goway frame.
    tid2 <- forkIO $ _frameSender
    return ctx
  where 
    _frameSender = frameSender ctx sendConn `E.finally` do
        clearContext ctx
        -- stop mgr
        killThread tid
    checkPreface = do
        preface <- recvConn connectionPrefaceLength
        when (connectionPreface /= preface) $ do
            goaway conn ProtocolError "Preface mismatch"
            E.throwIO $ ConnectionError ProtocolError "Preface mismatch"

