{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
import Network
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Concurrent
import Control.Concurrent.STM
import GHC.IO.Handle (Handle)
import Control.Monad
import Debug.Trace

main :: IO ()
main =  do
    done <- newEmptyMVar
    _ <- forkIO $ listener done
    sck <- listenOn (PortNumber 27001)
    (hdl, _, _) <- accept sck
    dialer hdl
    takeMVar done

dialer :: Handle -> IO ()
dialer hdl = do
    -- do multistream select here
    -- ...
    -- okay we've aggreed to use HTTP2
    -- now select dialStream of this library to be the dialStream for this
    -- connection
    -- oh and we've got to pass specific Configuration information into the
    -- http2 muxer
    ctx <- attachMuxer HClient (debugReceiver hdl) (debugSender hdl) 
    return ()
    

    -- (_, w) <- dialStream ctx
    -- (_, w2) <- dialStream ctx
    -- atomically $ do
    --     writeTQueue w2 $ Just "The quick brown fox jumps over the lazy dog"
    --     writeTQueue w  $ Just "asdf"
    --     writeTQueue w  $ Just "asdf2"

debugReceiver :: Handle -> Int -> IO ByteString
debugReceiver hdl i = do
    bs <- BS.hGet hdl i
    traceStack ("\nReceiver CallStack " ++ show bs) (pure ())
    return bs

debugSender ::Handle -> ByteString -> IO ()
debugSender hdl bs = do
    traceStack ("\nSender CallStack " ++ show bs) (pure ())
    BS.hPut hdl bs

listener :: MVar () -> IO ()
listener done = do
    -- putStrLn "running streamListener on 27001"
    hdl <- connectTo "localhost" (PortNumber 27001)
    ctx <- attachMuxer HServer (debugReceiver hdl) (debugSender hdl)
    _ <- acceptStream ctx
    putMVar done ()
