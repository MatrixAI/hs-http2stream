{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Stream.HTTP2.Receiver where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM

import qualified Control.Exception as E

import Data.ByteString (ByteString)
import Data.IORef

import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.EncodeFrame
import Network.Stream.HTTP2.Types

----------------------------------------------------------------

frameReceiver :: Context -> (Int -> IO ByteString) -> IO ()
frameReceiver ctx@Context{..} recv = forever $ do
    -- Receive and decode the frame header and payload
    hdr <- recv frameHeaderLength
    let typhdr@(_, fhdr) = decodeFrameHeader hdr
    let FrameHeader{payloadLength, streamId} = fhdr

    if hdr == ""
      then yield
      else do
        readIORef http2Settings >>= checkFrameHeader' typhdr

        pl <- if payloadLength > 0
            then recv payloadLength
            else pure ""

        fpl <- case uncurry decodeFramePayload typhdr pl of
            Left err -> E.throwIO err
            Right pl' -> pure pl'

        -- Update connection window size by bytes read
        let frameLen = frameHeaderLength + payloadLength
        atomically $ modifyTVar' connectionWindow (frameLen-)

        if isControl streamId
            then control fhdr fpl
            else stream streamId (frameLen, fpl)
  where
    control :: FrameHeader -> FramePayload -> IO ()
    control FrameHeader{flags} (SettingsFrame sl)
      | testAck flags = pure ()
      | otherwise =
        case checkSettingsList sl of
          -- settings list received was invalid
          Just h2error -> E.throwIO h2error 
          Nothing -> do
            set <- readIORef http2Settings
            let set' = updateSettings set sl
            let ws = initialWindowSize set
            forM_ sl $ \case
              (SettingsInitialWindowSize, ws') ->
                updateAllStreamWindow (\x -> x + ws' - ws) openedStreams
            atomicWriteIORef http2Settings set'
            sendSettingsAck

    control FrameHeader{flags} (PingFrame bs)
      | testAck flags = pure ()
      | otherwise = sendPingAck bs

    control _ (GoAwayFrame sid err bs) = 
        E.throwIO (ConnectionError err bs)

    control _ (WindowUpdateFrame ws) = 
        updateAllStreamWindow (ws+) openedStreams

    stream :: StreamId -> (Int, FramePayload) -> IO ()
    stream sid (frameLen, fpl) = search openedStreams sid >>= \case
        Just open -> handleStream sid (frameLen, fpl) open
        Nothing -> newStream sid fpl

    handleStream :: StreamId -> (Int, FramePayload) -> Stream 'Open -> IO ()
    handleStream sid (paylen, fpl) ostrm = handleFrame fpl
      where
        win = window ostrm
        ins = inputStream ostrm

        handleFrame :: FramePayload -> IO ()
        handleFrame (DataFrame dfp) =
          atomically $ do
            enqueueInput ins dfp
            modifyTVar' win (paylen-)

        handleFrame SettingsFrame{} =
            error "This should have been handled by checkFrameHeader"

        handleFrame (WindowUpdateFrame ws) =
          if isControl sid
            then atomically $ modifyTVar' connectionWindow (ws+)
            else atomically $ modifyTVar' win (ws+)

    newStream :: StreamId -> FramePayload -> IO ()
    newStream sid HeadersFrame{} = do
        psid <- readIORef peerStreamId
        when (psid > sid) $
            E.throwIO $ ConnectionError ProtocolError
                        "New peer stream identifier must not decrease"
        atomicModifyIORef' peerStreamId $ const (sid, ())
        Settings{initialWindowSize} <- readIORef http2Settings
        lstrm@OpenStream{precedence} <- lstream sid initialWindowSize
        insert openedStreams sid lstrm
        let rdr = inputStream lstrm
        let wtr = outputStream lstrm
        pre <- readIORef precedence
        enqueue outputQ sid pre wtr
        enqueueQ acceptQ (rdr, wtr)

    newStream sid (PriorityFrame pri) = prepare outputQ sid pri
    newStream sid _ = sendReset ProtocolError sid


    checkFrameHeader' :: (FrameTypeId, FrameHeader) -> Settings -> IO ()
    checkFrameHeader' (FramePushPromise, _) _ =
        E.throwIO $ ConnectionError ProtocolError "push promise is not allowed"
    checkFrameHeader' typhdr@(_, FrameHeader {}) settings =
        let typhdr' = checkFrameHeader settings typhdr
        in either E.throwIO mempty typhdr'


    sendGoaway e = case E.fromException e of
        Just (ConnectionError err msg) -> do
            psid <- readIORef peerStreamId
            let !frame = goawayFrame psid err msg
            enqueueQ controlQ $ CGoaway frame
        _ -> pure ()

    sendReset err sid = do
        let !frame = resetFrame err sid
        enqueueQ controlQ $ CFrame frame

    sendSettingsAck = do
        let !ack = settingsFrame setAck []
        enqueueQ controlQ $ CSettings ack []
    
    sendPingAck bs = do
        let !ack = pingFrame bs
        enqueueQ controlQ $ CFrame ack

