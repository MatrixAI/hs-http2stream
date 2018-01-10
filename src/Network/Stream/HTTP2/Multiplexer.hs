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
frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} connReceive = forever $ do
    -- Receive and decode the frame header and payload
    hd <- connReceive frameHeaderLength
    let (ftyp, fhdr@FrameHeader{..}) = decodeFrameHeader hd

    settings <- readIORef http2settings
    checkFrameHeader' settings (ftyp, fhdr)

    pl <- connReceive payloadLength
    fpl <- case decodeFramePayload ftyp fhdr pl of
        Left err -> E.throwIO err
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
            mstrm <- search streamTable streamId
            case mstrm of
                Nothing -> do
                    -- The stream is not open/half-closed, so fail
                    E.throwIO $ StreamError StreamClosed streamId
                Just strm@(Stream{..}) -> do
                    atomically $ modifyTVar' streamWindow (recvLen-)
                    state <- readIORef streamState
                    case state of
                        Open (Body q clen blen) -> atomically $ writeTQueue q pl
                        -- First frame of the stream after stream headers
                        Open JustOpened -> undefined

        HeadersFrame mpri hdrblk -> do
            -- Need to read the stream headers and make a new stream
            csid <- readIORef clientStreamId
            when (csid > streamId) $ do
                E.throwIO $ ConnectionError ProtocolError
                          $ "New client stream identifier must not decrease"
            Settings{initialWindowSize} <- readIORef http2settings 
            strm@Stream{streamBody, streamPrecedence} <- newStream streamId initialWindowSize
            prec <- readIORef streamPrecedence
            insert streamTable streamId strm
            opened ctx strm
            
            let is = atomically $ readTQueue streamBody
            sendQ <- atomically $ newTQueue
            let os = atomically . writeTQueue sendQ
            atomically $ writeTQueue acceptQ (is, os) 
     
        PriorityFrame pri -> undefined
        RSTStreamFrame eid -> undefined
        SettingsFrame sl -> do
            sendSettingsAck
        PushPromiseFrame sid hdrblk -> undefined
        PingFrame bs -> undefined
        GoAwayFrame lastStreamId eid bs -> undefined
        WindowUpdateFrame ws -> undefined
        ContinuationFrame hdrblk -> undefined
        -- Unknown frame type, ignore it
        UnknownFrame ftyp bs -> undefined
  where
    checkFrameHeader' :: Settings -> (FrameTypeId, FrameHeader) -> IO ()
    checkFrameHeader' settings (FramePushPromise, _) = do
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
frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender ctx@Context{controlQ, outputQ, streamTable} connSender = forever $ do
    --cframe <- atomically $ tryReadTQueue controlQ
    let cframe = Nothing
    tid <- myThreadId
    case cframe of
        -- Just (CSettings bs _) -> do
        --     putStrLn $ show tid ++ " frameSender: settings" ++ show cframe
        --     connSender bs
        otherwise -> do 
            (sid, pre, out) <- dequeue outputQ
            frameSender' sid pre out >>= connSender
  where
    frameSender' sid pre out = case out of
        OStream sid sendQ -> do
            -- Expect the stream to already be inserted or this is an error
            Just strm@Stream{streamState} <- search streamTable sid 
            ss <- readIORef streamState
            enqueue outputQ sid pre out
            if isOpen ss 
              then do
                  (atomically $ readTQueue sendQ) >>= \x -> case x of
                      Nothing -> return $ encodeFrame (encodeInfo setEndStream sid) (DataFrame "")
                      Just x -> do 
                          putStrLn $ "Data " ++ show x
                          return $ encodeFrame (encodeInfo id sid) (DataFrame x)
              else do
                  opened ctx strm
                  putStrLn $ "Headers " ++ show sid
                  -- TODO: Header List packing needs to occur here, may need to
                  -- change types
                  return $ encodeFrame (encodeInfo id sid) (HeadersFrame Nothing "")

