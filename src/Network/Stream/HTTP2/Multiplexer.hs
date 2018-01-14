{-# LANGUAGE BangPatterns #-} 
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Multiplexer where

import qualified Control.Exception as E
import Data.IORef
import Control.Concurrent.STM
import Control.Concurrent
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder.Extra as B
import Network.HPACK
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.Types
import Network.Stream.HTTP2.EncodeFrame
import System.IO.Streams hiding (search)
import Control.Monad

-- | For a given connection and connection context, receive and process an 
-- incoming frame. Only 1 of these should be run per connection, as some of
-- the stored data in the context (IORef stuff) is not thread safe. 
-- TODO: if the flow control window is exhausted, enqueue a WINDOW_UPDATE
-- frame to renew the window
frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} connReceive = forever $ do
    -- Receive and decode the frame header and payload
    hd <- connReceive frameHeaderLength
    let (ftyp, fhdr@FrameHeader{..}) = decodeFrameHeader hd

    settings <- readIORef http2settings
    checkFrameHeader' settings (ftyp, fhdr)

    pl <- connReceive payloadLength
    fpl <- case decodeFramePayload ftyp fhdr pl of
        Left err  -> E.throwIO err
        Right pl' -> return pl'
 
    tid <- myThreadId
    putStrLn $ show tid ++ " frameReceiver: " ++ show fpl

    -- Update connection window size by bytes read
    let recvLen = frameHeaderLength + payloadLength
    atomically $ modifyTVar' connectionWindow (recvLen-)

    case fpl of
        -- Receiving a data frame
        -- Pass it to the correct stream
        DataFrame pl -> do
            -- The stream should have been in the streamTable by this point
            -- TODO: How can we make this total?
            Just strm@Stream{..} <- search streamTable streamId
            atomically $ modifyTVar' streamWindow (recvLen-)
            state <- readIORef streamState
            case state of
                Open ins _ -> atomically $ writeTQueue ins pl
                LocalClosed ins -> atomically $ writeTQueue ins pl
                _ -> sendReset StreamClosed streamId

        HeadersFrame mpri hdrblk -> do
            -- Need to read the stream headers and make a new stream
            csid <- readIORef clientStreamId
            when (csid > streamId) $ 
                E.throwIO $ ConnectionError ProtocolError
                            "New client stream identifier must not decrease"
            Settings{initialWindowSize} <- readIORef http2settings 
            strm@Stream{streamState, streamPrecedence} <- newStream streamId initialWindowSize
            prec <- readIORef streamPrecedence
            insert streamTable streamId strm
            opened ctx strm
            atomically $ writeTQueue acceptQ (readStream strm, writeStream strm) 
     
        PriorityFrame pri  -> undefined
        RSTStreamFrame eid -> undefined
        SettingsFrame sl   -> sendSettingsAck
        PushPromiseFrame sid hdrblk -> undefined
        PingFrame bs -> undefined
        GoAwayFrame lastStreamId eid bs -> undefined
        WindowUpdateFrame ws -> undefined
        ContinuationFrame hdrblk -> undefined
        -- Unknown frame type, ignore it
        UnknownFrame ftyp bs -> undefined
  where
    checkFrameHeader' :: Settings -> (FrameTypeId, FrameHeader) -> IO ()
    checkFrameHeader' settings (FramePushPromise, _) = 
        E.throwIO $ ConnectionError ProtocolError "push promise is not allowed"
    checkFrameHeader' settings typhdr@(ftyp, header@FrameHeader{payloadLength}) =
        let typhdr' = checkFrameHeader settings typhdr in
        either E.throwIO mempty typhdr'
 
    sendGoaway e
      | Just (ConnectionError err msg) <- E.fromException e = do
          csid <- readIORef clientStreamId
          let !frame = goawayFrame csid err msg
          atomically $ writeTQueue controlQ $ CGoaway frame
      | otherwise = return ()

    sendReset err sid = do
        let !frame = resetFrame err sid
        atomically $ writeTQueue controlQ $ CFrame frame

    sendSettingsAck = do
        let !ack = settingsFrame setAck []
        atomically $ writeTQueue controlQ $ CSettings ack []


-- | Evaluate the next stream to send frames for, and then send a data frame
-- until either the stream flow-control window is exhausted or there is no more
-- to send on the stream
-- TODO: Support flow control
frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender ctx@Context{controlQ, outputQ, streamTable} connSender = forever $ do
    --cframe <- atomically $ tryReadTQueue controlQ
    let cframe = Nothing
    tid <- myThreadId
    -- TODO: Send control frames first
    case cframe of
        -- Just (CSettings bs _) -> do
        --     putStrLn $ show tid ++ " frameSender: settings" ++ show cframe
        --     connSender bs
        _ -> do 
            (sid, pre, ostrm) <- dequeue outputQ
            frameSender' sid pre ostrm >>= connSender
  where
    frameSender' sid pre ostrm = case ostrm of
        OStream sid outs -> do
            -- Expect the stream to already be inserted or this is an error
            Just strm@Stream{streamState} <- search streamTable sid 
            ss <- readIORef streamState
            -- re enqueue the output
            enqueue outputQ sid pre ostrm
            case ss of
                Idle -> sendHeaders sid strm
                Open _ outs -> send sid outs
                RemoteClosed outs -> send sid outs
                _ -> undefined -- TODO: need to make this a 
                                       -- compile error so that this can't
                                       -- happen
    send sid outs = atomically $ readTQueue outs >>= \out -> 
        let (out', flags) = case out of
                Nothing -> ("", setEndStream)
                Just bs -> (bs, id)
        in return $ encodeFrame (encodeInfo flags sid) (DataFrame out')

    sendHeaders sid strm = do
        -- TODO: Header List packing needs to occur here, may need to
        -- change types
        opened ctx strm
        return $ encodeFrame (encodeInfo id sid) (HeadersFrame Nothing "")

