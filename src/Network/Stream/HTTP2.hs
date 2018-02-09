{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

module Network.Stream.HTTP2 where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
-- import Network.HPACK
import Data.IORef

import Network.Stream.HTTP2.Types
import Network.Stream.HTTP2.Multiplexer
import Network.Stream.HTTP2.EncodeFrame
import qualified Control.Exception as E
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad

acceptStream :: Context -> IO (ReadStream, WriteStream)
acceptStream Context{acceptQ} = atomically $ readTQueue acceptQ

dialStream :: Context -> IO (ReadStream, WriteStream)
dialStream ctx@Context{outputQ, openedStreams, hostStreamId, http2Settings} = do
    hsid <- atomicModifyIORef' hostStreamId (\x -> (x+2, x))
    Settings{initialWindowSize} <- readIORef http2Settings
    opened@OpenStream { inputStream
                      , outputStream
                      , precedence } <- openStream hsid initialWindowSize
    pre <- readIORef precedence
    insert openedStreams hsid opened
    enqueue outputQ hsid pre outputStream
    return (unInput inputStream, unOutput outputStream)

----------------------------------------------------------------

-- Start a thread for receiving frames and sending frames
-- Does not use the thread pool manager from the Warp implementation
attachMuxer ::  HTTP2HostType -> (Int -> IO ByteString) -> (ByteString -> IO ()) -> IO Context
attachMuxer hostType connRecv connSend = do
    connPreface hostType
    ctx@Context{} <- newContext
    tid <- forkIO $ frameReceiver ctx connRecv
    tid2 <- forkIO $ frameSender ctx connSend
    return ctx
  where 
    connPreface HServer = do
        preface <- connRecv connectionPrefaceLength
        when (connectionPreface /= preface) $ do
            goaway connSend ProtocolError "Preface mismatch"
            E.throwIO $ ConnectionError ProtocolError "Preface mismatch"
        connSend $ settingsFrame id []

    connPreface HClient = connSend connectionPreface

-- connClose must not be called here since Run:fork calls it
goaway :: (ByteString -> IO ()) -> ErrorCodeId -> ByteString -> IO ()
goaway connSend etype debugmsg = connSend bytestream
  where
    bytestream = goawayFrame 0 etype debugmsg
