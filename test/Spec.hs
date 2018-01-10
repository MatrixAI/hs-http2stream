{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
import Network.HTTP2
import Network.HTTP2.Priority
import Network
import qualified Data.ByteString as BS
import qualified System.IO.Streams as Streams
import Control.Concurrent
import Control.Concurrent.STM
import Network.Stream.HTTP2.Types

main :: IO ()
main = do
    done <- newEmptyMVar
    tid <- forkIO $ streamListener done
    sck <- listenOn (PortNumber 27001)
    (hdl, hname, pno) <- accept sck
    ctx@Context{outputQ} <- attachMuxer HClient (BS.hGet hdl) (BS.hPut hdl) 

    (read, write) <- dialStream HClient ctx
    (read2, write2) <- dialStream HClient ctx
    write2 (Just "The quick brown fox jumps over the lazy dog") 
    write (Just "asdf")
    write (Just "asdf2")
    takeMVar done

streamListener :: MVar () -> IO ()
streamListener done = do
    putStrLn "running streamListener on 27001"
    hdl <- connectTo "localhost" (PortNumber 27001)
    ctx <- attachMuxer HServer (BS.hGet hdl) (BS.hPut hdl)
    (read, write) <- acceptStream ctx
    putMVar done ()
