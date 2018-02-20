{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
import Network.Stream.HTTP2.Types
import Network
import Network.HTTP2
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent.STM
import Control.Monad
import Control.Concurrent
import Control.Exception
import System.IO
import Debug.Trace

-- The dialer in this situation is actually the socket listener
-- And the listener is the socket dialer
-- How this works:
-- HTTP2 Dialer calls `accept` at the Socket level, but once it establishes 
-- the socket connection established is the 1st to send the HTTP/2 connection 
-- preface.
-- Likewise, the HTTP2 Listener is actually calling `connect` at the Socket 
-- level, but receives the connection preface once the socket connection 
-- has been established.
main :: IO ()
main = main' `catch` restart
  where
    main' :: IO ()
    main' = bracket acquireConn releaseConn $ \sck ->
        forever . void $ do
            (hdl,_,_) <- accept sck
            mtid <- myThreadId 
            Just ctx <- listener hdl mtid
            acceptStream ctx

    acquireConn :: IO Socket
    acquireConn = listenOn (PortNumber 27001)

    releaseConn :: Socket -> IO ()
    releaseConn = sClose

    restart :: HTTP2Error -> IO ()
    restart e@ConnectionError{}  = do
        traceIO "caught error"
        traceIO $ show e

-- test1 :: IO ()
-- test1 = do
--     done <- newEmptyMVar
--     scka <- connectTo (PortNumber 27001)
--     _ <- forkIO $ listener scka
--     sck <- listenOn (PortNumber 27001)
--     (hdl, _, _) <- accept sck
--     dialer hdl
--     takeMVar done

dialer :: Handle -> IO ()
dialer hdl = do
    mtid <- myThreadId
    ctx <- attachMuxer HClient mtid (debugReceiver HClient hdl) (debugSender HClient hdl)
    (_, w) <- dialStream ctx
    (_, w2) <- dialStream ctx
    writeStream w2 "The quick brown fox jumps over the lazy dog"
    writeStream w "asdf"
    writeStream w "asdf2"

listener :: Handle -> ThreadId -> IO (Maybe Context)
listener hdl tid =
    Just <$> attachMuxer HServer tid 
                 (debugReceiver HServer hdl) (debugSender HServer hdl)

debugReceiver :: HTTP2HostType -> Handle -> Int -> IO ByteString
debugReceiver ht hdl i = do
    bs <- BS.hGet hdl i
    traceIO "\n"
    when (i == 9) $
        traceIO . show $ decodeFrameHeader bs
    traceStack (show i ++ " " ++ show ht ++ " Receive CallStack " ++ show bs) (pure ())
    return bs

debugSender :: HTTP2HostType -> Handle -> ByteString -> IO ()
debugSender ht hdl bs = do
    traceIO "\n"
    when (BS.length bs == 9) $
        traceIO .show $ decodeFrameHeader bs
    traceStack (show ht ++ " Send CallStack " ++ show bs) (pure ())
    BS.hPut hdl bs

