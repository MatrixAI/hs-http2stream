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

acceptStream :: Context -> IO (Input, Output)
acceptStream Context{peerStreamId, acceptQ} = do 
    atomically $ readTQueue acceptQ

dialStream :: Context -> IO (Input, Output)
dialStream ctx@Context{outputQ, openedStreams, hostStreamId, http2Settings} = do
    hsid <- readTVarIO hostStreamId
    Settings{initialWindowSize} <- readIORef http2Settings
    ds@DialStream { inputStream
                  , outputStream
                  , precedence } <- dial hsid initialWindowSize
    pre <- readIORef precedence
    atomically $ modifyTVar' hostStreamId (+2)
    insert openedStreams hsid opened
    enqueue outputQ hsid pre outputStream
    return (unInput inputStream, unOutput outputStream)

----------------------------------------------------------------

-- Start a thread for receiving frames and sending frames
-- Does not use the thread pool manager from the Warp implementation
attachMuxer :: HTTP2HostType -> (Int -> IO ByteString) -> (ByteString -> IO ()) -> IO Context
attachMuxer hostType connRecv connSend = do
    connPreface hostType
    ctx@Context{} <- newContext
    case hostType of 
        HClient -> updateHostPeerIds ctx 1 2
        HServer -> updateHostPeerIds ctx 2 1
    tid <- forkIO $ frameReceiver ctx connRecv
    tid2 <- forkIO $ frameSender ctx connSend
    return ctx
  where
    -- Set the stored host and peer stream id depending on whether we are a 
    -- client or a server
    updateHostPeerIds Context{hostStreamId, peerStreamId} hid pid = 
      atomically $ do
        modifyTVar' hostStreamId $ const hid
        modifyTVar' peerStreamId $ const pid
    
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
