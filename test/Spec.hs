{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import Debug.Trace

import Network
import Network.HTTP2
import Network.Stream.HTTP2
import Network.Stream.HTTP2.Types

import System.IO

----------------------------------------------------------------

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
main = main' `catch` connError
  where
    main' :: IO ()
    main' = bracket acquireConn releaseConn $ \sck ->
        forever . void $ do
            (hdl,_,_) <- accept sck
            ctx <- listener hdl
            acceptStream ctx

    acquireConn :: IO Socket
    acquireConn = listenOn (PortNumber 27001)

    releaseConn :: Socket -> IO ()
    releaseConn = sClose

    connError :: HTTP2Error -> IO ()
    connError e@ConnectionError{}  = do
        traceIO "caught error"
        traceIO $ show e
        main

-- test1 :: IO ()
-- test1 = do
--     done <- newEmptyMVar
--     scka <- connectTo (PortNumber 27001)
--     _ <- forkIO $ listener scka
--     sck <- listenOn (PortNumber 27001)
--     (hdl, _, _) <- accept sck
--     dialer hdl
--     takeMVar done

dialer :: Handle -> IO Context
dialer = attachMuxer HClient 

listener :: Handle -> IO Context
listener = attachMuxer HServer

