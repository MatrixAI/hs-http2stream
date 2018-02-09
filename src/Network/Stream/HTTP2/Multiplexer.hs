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


frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver Context{..} recv = forever $ do
    -- Receive and decode the frame header and payload
    typhdr@(_,FrameHeader{payloadLength, streamId}) <- decodeFrameHeader
                                                    <$> recv frameHeaderLength

    readIORef http2Settings >>= checkFrameHeader' typhdr
    fpl <- recv payloadLength
    pl <- case uncurry decodeFramePayload typhdr fpl of
        Left err  -> E.throwIO err
        Right pl' -> return pl'
 
    -- Update connection window size by bytes read
    let frameLen = frameHeaderLength + payloadLength
    atomically $ modifyTVar' connectionWindow (frameLen-)

    if isControl streamId
        then control pl
        else stream streamId (frameLen, pl)
  where
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
                    _ -> traceStack "Failed settings control" (pure ())
                atomicWriteIORef http2Settings set'
                sendSettingsAck 

    stream :: StreamId -> (Int, FramePayload) -> IO ()
    stream sid (frameLen, pl) = 
        search openedStreams sid >>= \case
            Just open@OpenStream{} -> goOpen sid (frameLen, pl) open
            Nothing -> do
                psid <- readIORef peerStreamId
                if sid > psid
                    then goIdle pl sid
                    else goClosed sid (ClosedStream sid Finished)

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
        enqueueControl controlQ $ CFrame frame

    sendSettingsAck = do
        let !ack = settingsFrame setAck []
        enqueueControl controlQ $ CSettings ack []
    
    -- Do we really need to pass the empty IdleStream tag to goIdle?
    goIdle :: FramePayload -> StreamId -> IO ()
    goIdle HeadersFrame{} sid = do
        cont <- readIORef continued
        -- Need to read the stream headers and make a new stream
        hsid <- readIORef hostStreamId
        when (hsid > sid) $ 
            E.throwIO $ ConnectionError ProtocolError
                        "New host stream identifier must not decrease"
        Settings{initialWindowSize} <- readIORef http2Settings 
        open@OpenStream{inputStream, outputStream} <- openStream sid initialWindowSize
        insert openedStreams sid open
        enqueueAccept acceptQ (unInput inputStream, unOutput outputStream)

    goIdle _ sid = sendReset ProtocolError sid

    goOpen :: StreamId -> (Int, FramePayload) -> Stream 'Open -> IO ()
    goOpen sid (paylen, fpl) OpenStream{window, inputStream} = handleFrame fpl
      where
        handleFrame :: FramePayload -> IO ()
        handleFrame (DataFrame dfp) = atomically $ do
            nextInput inputStream dfp 
            modifyTVar' window (paylen-) 
        handleFrame SettingsFrame{} = 
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
    dataSender' sid pre ostrm@Output{} = do
        out <- atomically $ nextOutput ostrm
        enqueue outputQ sid pre ostrm
        return $ encodeFrame (encodeInfo id sid) (DataFrame out)

--     sendHeaders sid strm =
--         -- TODO: Header List packing needs to occur here, may need to
--         -- change types
--         return $ encodeFrame (encodeInfo id sid) (HeadersFrame Nothing "")
