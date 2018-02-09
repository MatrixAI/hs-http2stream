{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
import Network.Stream.HTTP2.Types
import Network
import Network.HTTP2
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent
import Control.Concurrent.STM
import GHC.IO.Handle (Handle)
import Control.Monad
import Debug.Trace

-- The dialer in this situation is actually the socket listener
-- And the listener is the socket dialer
-- How this works:
-- HTTP2 Dialer is listening at the Socket level, but once a connection is
-- established is the 1st to send the HTTP/2 connection preface
-- Likewise, the HTTP2 Listener is actually dialing at the Socket level, but
-- receives the connection preface once the socket level connection has been
-- established.
main :: IO ()
main = do
    sck <- listenOn (PortNumber 27001)
    (hdl, _, _) <- accept sck
    listener hdl

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
    ctx <- attachMuxer HClient (debugReceiver HClient hdl) (debugSender HClient hdl) 
    (_, w) <- dialStream ctx
    (_, w2) <- dialStream ctx
    atomically $ do
        streamWrite w2 "The quick brown fox jumps over the lazy dog"
        streamWrite w "asdf"
        streamWrite w "asdf2"

listener :: Handle -> IO ()
listener hdl = do
    ctx <- attachMuxer HServer (debugReceiver HServer hdl) (debugSender HServer hdl)
    (r,w) <- acceptStream ctx
    bs <- atomically $ streamRead r
    print bs

debugReceiver :: HTTP2HostType -> Handle -> Int -> IO ByteString
debugReceiver ht hdl i = do
    bs <- BS.hGet hdl i
    putStrLn "\n"
    when (i == 9) $
        traceShow (decodeFrameHeader bs) mempty
    traceStack (show ht ++ " Receive CallStack " ++ show bs) (pure ())
    return bs

debugSender :: HTTP2HostType -> Handle -> ByteString -> IO ()
debugSender ht hdl bs = do
    traceStack ("\n" ++ show ht ++ " Send CallStack " ++ show bs) (pure ())
    BS.hPut hdl bs


