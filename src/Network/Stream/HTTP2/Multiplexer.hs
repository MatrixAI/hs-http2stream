{-# LANGUAGE BangPatterns #-} 
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}

module Network.Stream.HTTP2.Multiplexer where

import qualified Control.Exception as E
import Data.IORef
import Control.Concurrent.STM
import Debug.Trace
import qualified Data.ByteString as BS
--import Data.ByteString.Builder (Builder)
--import qualified Data.ByteString.Builder.Extra as B
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.Types
-- import Network.Stream.HTTP2.FTypes
import Network.Stream.HTTP2.EncodeFrame
import Control.Monad

-- TODO: if the flow control window is exhausted, enqueue a WINDOW_UPDATE
-- frame to renew the window
frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} recv = forever $ do
    -- Receive and decode the frame header and payload
    typhdr@(_,FrameHeader{payloadLength, streamId}) <- decodeFrameHeader 
                                                    <$> recv frameHeaderLength

    readIORef http2Settings >>= checkFrameHeader' typhdr

    fpl <- recv payloadLength
    pl <- case uncurry decodeFramePayload typhdr fpl of
        Left err  -> E.throwIO err
        Right pl' -> return pl'
 
    -- Update connection window size by bytes read
    let recvLen = frameHeaderLength + payloadLength
    atomically $ modifyTVar' connectionWindow (recvLen-)

    --search streamTable streamId
    when (isControl streamId) $ control pl
    pure Nothing >>= \case
        Just open@OpenStream{} -> goOpen streamId (recvLen, pl) open
        Just closed@ClosedStream{} -> goClosed streamId closed
        Nothing -> do
            psid <- readIORef peerStreamId
            if streamId > psid
                then goIdle pl streamId
                else goClosed streamId (ClosedStream streamId Finished)
  where
    -- received a frame payload on the control stream
    -- probably connection settings
    -- need to reply to the first frame of the connection settings
    -- what should we do?
    control :: FramePayload -> IO ()
    control (SettingsFrame sl) =
        case checkSettingsList sl of
            Just h2error -> E.throwIO h2error -- settings list received was invalid
            Nothing -> do
                set <- readIORef http2Settings
                let set' = updateSettings set sl
                let ws = initialWindowSize set
                forM_ sl $ \case
                    (SettingsInitialWindowSize, ws') -> 
                        updateAllStreamWindow (\x -> x + ws' - ws) openedStreams
                    _ -> traceStack "Failed settings control" mzero
                atomicWriteIORef http2Settings set'
                sendSettingsAck

    checkFrameHeader' :: (FrameTypeId, FrameHeader) -> Settings -> IO ()
    checkFrameHeader' (FramePushPromise, _) _ = 
        E.throwIO $ ConnectionError ProtocolError "push promise is not allowed"
    checkFrameHeader' typhdr@(_, FrameHeader{}) settings =
        let typhdr' = checkFrameHeader settings typhdr in
        either E.throwIO mempty typhdr'

    -- sendGoaway e
    --   | Just (ConnectionError err msg) <- E.fromException e = do
    --       csid <- readIORef clientStreamId
    --       let !frame = goawayFrame csid err msg
    --       atomically $ writeTQueue controlQ $ CGoaway frame
    --   | otherwise = return ()

    sendReset err sid = do
        let !frame = resetFrame err sid
        atomically $ writeTQueue controlQ $ CFrame frame

    sendSettingsAck = do
        let !ack = settingsFrame setAck []
        atomically $ writeTQueue controlQ $ CSettings ack []
    
    -- Do we really need to pass the empty IdleStream tag to goIdle?
    goIdle :: FramePayload -> StreamId -> IO ()
    goIdle (HeadersFrame _ _) sid = do
        -- Need to read the stream headers and make a new stream
        hsid <- readIORef hostStreamId
        when (hsid > sid) $ 
            E.throwIO $ ConnectionError ProtocolError
                        "New host stream identifier must not decrease"
        Settings{initialWindowSize} <- readIORef http2Settings 
        open@OpenStream{readStream, writeStream} <- openStream ctx sid initialWindowSize
        insert openedStreams sid open
        atomically $ writeTQueue acceptQ (readStream,writeStream)

    goIdle _ sid = sendReset ProtocolError sid

    goOpen :: StreamId -> (Int, FramePayload) -> Stream 'Open -> IO ()
    goOpen sid (recvLen, fpl) OpenStream{..} = do
        cont <- readIORef continued
        handleFrame fpl
          where
            handleFrame :: FramePayload -> IO ()
            handleFrame (DataFrame dfp) = atomically $ do
                writeTQueue readStream dfp 
                modifyTVar' window (recvLen-) 
            handleFrame (SettingsFrame sl) = 
                error "This should have been handled by checkFrameHeader"
                
            handleFrame (WindowUpdateFrame ws) = 
                if isControl sid
                  then
                    atomically $ modifyTVar' connectionWindow (ws+)
                  else
                    atomically $ modifyTVar' window (ws+) 

    goClosed :: StreamId -> Stream 'Closed -> IO ()
    goClosed sid _ = sendReset StreamClosed sid

frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender Context{controlQ, outputQ} connSender = forever $ do
    control <- atomically $ tryReadTQueue controlQ
    case control of
        Just (CSettings bs _) -> connSender bs
        Just (CFrame bs) -> connSender bs
        Nothing -> do
            (sid, pre, ostrm) <- dequeue outputQ
            dataSender' sid pre ostrm >>= connSender
        _ -> print control
  where
    dataSender' sid pre ostrm@(OStream _ outs) = do
        out <- atomically $ readTQueue outs
        enqueue outputQ sid pre ostrm
        return $ encodeFrame (encodeInfo id sid) (DataFrame out)

--     sendHeaders sid strm =
--         -- TODO: Header List packing needs to occur here, may need to
--         -- change types
--         return $ encodeFrame (encodeInfo id sid) (HeadersFrame Nothing "")
