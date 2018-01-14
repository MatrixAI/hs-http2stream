{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
-- import Network.HTTP2
-- import Network.HTTP2.Priority
import Network
import qualified Data.ByteString as BS
import Control.Concurrent
-- import Network.Stream.HTTP2.Types

main :: IO ()
main = do
    done <- newEmptyMVar
    _ <- forkIO $ streamListener done
    sck <- listenOn (PortNumber 27001)
    (hdl, _, _) <- accept sck
    ctx <- attachMuxer HClient (BS.hGet hdl) (BS.hPut hdl) 
    (_, w) <- dialStream HClient ctx
    (_, w2) <- dialStream HClient ctx
    w2 (Just "The quick brown fox jumps over the lazy dog") 
    w (Just "asdf")
    w (Just "asdf2")
    takeMVar done

streamListener :: MVar () -> IO ()
streamListener done = do
    putStrLn "running streamListener on 27001"
    hdl <- connectTo "localhost" (PortNumber 27001)
    ctx <- attachMuxer HServer (BS.hGet hdl) (BS.hPut hdl)
    _ <- acceptStream ctx
    putMVar done ()
