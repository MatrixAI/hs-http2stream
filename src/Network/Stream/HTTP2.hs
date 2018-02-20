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

acceptStream :: Context -> IO (Maybe (Input, Output))
acceptStream Context{peerStreamId, acceptQ} = do
    atomically $ tryReadTQueue acceptQ

dialStream :: Context -> IO (Input, Output)
dialStream ctx@Context{outputQ, openedStreams, hostStreamId, http2Settings} = do
    hsid <- readIORef hostStreamId
    Settings{initialWindowSize} <- readIORef http2Settings
    dialed@DialStream { inputStream
                      , outputStream
                      , precedence } <- dstream hsid initialWindowSize
    pre <- readIORef precedence
    atomicModifyIORef' hostStreamId (\x -> (x+2, ()))
    insert openedStreams hsid dialed
    enqueue outputQ hsid pre outputStream
    return (inputStream, outputStream)

writeStream :: Output -> ByteString -> IO ()
writeStream (OStream ws) bs = atomically $ writeTQueue ws bs
writeStream (OMkStream mkStrm) bs = join $ writeStream <$> mkStrm
                                                       <*> pure bs
writeStream OEndStream _ = error "Can't write to a finished stream"


----------------------------------------------------------------

-- Start a thread for receiving frames and sending frames
-- Does not use the thread pool manager from the Warp implementation
attachMuxer :: HTTP2HostType 
            -> ThreadId
            -> (Int -> IO ByteString) -> (ByteString -> IO ()) 
            -> IO Context
attachMuxer hostType mtid connRecv connSend  = do
    connPreface hostType
    ctx@Context{} <- newContext
    case hostType of 
        HClient -> updateHostPeerIds ctx 1 2
        HServer -> updateHostPeerIds ctx 2 1
    forkIO $ frameReceiver ctx connRecv `E.catch` throwOut
    forkIO $ frameSender ctx connSend `E.catch` throwOut
    return ctx
  where
    -- Set the stored host and peer stream id depending on whether we are a 
    -- client or a server
    throwOut :: HTTP2Error -> IO ()
    throwOut e@(ConnectionError ec bs) = do 
        goaway connSend ec bs 
        E.throwTo mtid e
    updateHostPeerIds Context{hostStreamId, peerStreamId} hid pid = do
        atomicModifyIORef' hostStreamId $ const (hid, ())
        atomicModifyIORef' peerStreamId $ const (pid, ())
    
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
