{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

module Network.Stream.HTTP2 where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad

import qualified Control.Exception as E

import Data.IORef

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS

import Debug.Trace

import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.EncodeFrame
import Network.Stream.HTTP2.Receiver
import Network.Stream.HTTP2.Sender
import Network.Stream.HTTP2.Types

import System.IO (Handle, hClose)

----------------------------------------------------------------

acceptStream :: Context -> IO (Maybe (Input, Output))
acceptStream Context{acceptQ} = atomically $ tryReadTQueue acceptQ

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
            -> Handle
            -> IO Context
attachMuxer hostType conn = do
    connPreface hostType
    ctx@Context{} <- newContext
    case hostType of 
        HClient -> updateHostPeerIds ctx 1 2
        HServer -> updateHostPeerIds ctx 2 1
    _ <- forkIO $ frameReceiver ctx debugReceive `E.catch` onConnError
    _ <- forkIO $ frameSender ctx debugSend `E.catch` onConnError
    return ctx
  where
    debugReceive ::  Int -> IO ByteString
    debugReceive i = do
        bs <- BS.hGet conn i
        traceIO "\n"
        when (i == 9) $
            traceIO . show $ decodeFrameHeader bs
        traceStack (show i ++ " " ++ show hostType ++ " Receive CallStack " ++ show bs) (pure ())
        return bs

    debugSend :: ByteString -> IO ()
    debugSend bs = do
        traceIO "\n"
        when (BS.length bs == 9) $
            traceIO .show $ decodeFrameHeader bs
        traceStack (show hostType ++ " Send CallStack " ++ show bs) (pure ())
        BS.hPut conn bs

    onConnError :: HTTP2Error -> IO ()
    onConnError e@(ConnectionError ec bs) = do 
        goaway debugSend ec bs 
        hClose conn

    updateHostPeerIds Context{hostStreamId, peerStreamId} hid pid = do
        atomicModifyIORef' hostStreamId $ const (hid, ())
        atomicModifyIORef' peerStreamId $ const (pid, ())
    
    connPreface HServer = do
        preface <- debugReceive connectionPrefaceLength
        when (connectionPreface /= preface) $ do
            goaway debugSend ProtocolError "Preface mismatch"
            E.throwIO $ ConnectionError ProtocolError "Preface mismatch"
        debugSend $ settingsFrame id []

    connPreface HClient = debugSend connectionPreface

-- connClose must not be called here since Run:fork calls it
goaway :: (ByteString -> IO ()) -> ErrorCodeId -> ByteString -> IO ()
goaway send etype debugmsg = send bytestream
  where
    bytestream = goawayFrame 0 etype debugmsg
