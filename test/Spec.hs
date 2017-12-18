{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Network.Stream.HTTP2
import Network.HTTP2
import Network
import qualified Data.ByteString as BS
import System.IO.Streams

main :: IO ()
main = do
    sck <- listenOn (PortNumber 27001)
    (hdl, hname, pno) <- accept sck
    ctx <- attachMuxer (BS.hGet hdl) (BS.hPut hdl) 
    (is, os) <- dialStream ctx
    write (Just "Hello World on HTTP2") os
