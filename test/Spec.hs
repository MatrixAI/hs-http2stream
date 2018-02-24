{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
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
    main' = acquireConn >>= \sck -> 
        bracket (accept sck) (\(hdl, _, _) -> hClose hdl)  $ \(hdl,_,_) -> do
            ctx <- listener hdl
            testResponsePayload ctx

    acquireConn :: IO Socket
    acquireConn = listenOn (PortNumber 27001)

    releaseConn :: Socket -> IO ()
    releaseConn = sClose

    connError :: HTTP2Error -> IO ()
    connError e@ConnectionError{}  = do
        traceIO "caught error"
        traceIO $ show e
        main

-- If we accept and close a stream, we should send no data frames
-- And set the end stream flag on the header of the connection
testNoResponsePayload :: Context -> IO ()
testNoResponsePayload ctx = do
    strm@P2PStream{} <- acceptStream ctx
    closeStream ctx strm

testResponsePayload :: Context -> IO ()
testResponsePayload ctx = do
    strm@P2PStream{} <- acceptStream ctx
    writeStream strm "testResponsePayload"
    closeStream ctx strm
    threadDelay 1000


dialer :: Handle -> IO Context
dialer = attachMuxer HClient 

listener :: Handle -> IO Context
listener = attachMuxer HServer

