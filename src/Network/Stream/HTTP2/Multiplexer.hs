{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}

module Network.Stream.HTTP2.Multiplexer where

import Control.Concurrent.STM
import qualified Control.Exception as E
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.IORef
import Debug.Trace
import Control.Monad
import Control.Monad.Reader

--import Data.ByteString.Builder (Builder)
--import qualified Data.ByteString.Builder.Extra as B
import Network.HTTP2
import Network.HPACK
import Network.HTTP2.Priority
import Network.Stream.HTTP2.Types

import Network.Stream.HTTP2.EncodeFrame

frameReceiver :: Context -> (Int -> IO BS.ByteString) -> IO ()
frameReceiver ctx@Context{..} recv = forever $ do
    -- Receive and decode the frame header and payload
    hdr <- recv frameHeaderLength
    let typhdr@(_, fhdr) = decodeFrameHeader hdr
    let FrameHeader{payloadLength, streamId} = fhdr

    if hdr == ""
      then pure ()
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
              _ -> traceStack "Failed settings control" (pure ())
            atomicWriteIORef http2Settings set'
            sendSettingsAck

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
        cont <- readIORef continued
        -- Need to read the stream headers and make a new stream
        psid <- readIORef peerStreamId
        when (psid > sid) $
            E.throwIO $ ConnectionError ProtocolError
                        "New peer stream identifier must not decrease"
        atomicModifyIORef' peerStreamId $ const (sid, ())
        Settings{initialWindowSize} <- readIORef http2Settings
        lstrm@ListenStream{precedence} <- lstream sid initialWindowSize
        insert openedStreams sid lstrm
        let rdr = inputStream lstrm
        let wtr = outputStream lstrm
        pre <- readIORef precedence
        enqueue outputQ sid pre wtr
        enqueueQ acceptQ (rdr, wtr)

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
            atomically $ writeTQueue controlQ $ CGoaway frame
        _ -> pure ()

    sendReset err sid = do
        let !frame = resetFrame err sid
        enqueueQ controlQ $ CFrame frame

    sendSettingsAck = do
        let !ack = settingsFrame setAck []
        enqueueQ controlQ $ CSettings ack []

frameSender :: Context -> (BS.ByteString -> IO ()) -> IO ()
frameSender Context {controlQ, outputQ, encodeDynamicTable} send = forever $ do
    control <- atomically $ tryReadTQueue controlQ
    case control of
      Just (CSettings bs _) -> send bs
      Just (CFrame bs) -> send bs
      Nothing -> isEmpty outputQ >>= \case
          False -> do
            (sid, pre, ostrm) <- dequeue outputQ
            encodeOutput encodeDynamicTable sid ostrm >>= send
            enqueue outputQ sid pre =<< nextOutput ostrm
          True -> pure ()
      _ -> traceIO $ show control

nextOutput :: Output -> IO Output
nextOutput (OHeader mkHdr next) = pure next
nextOutput (OMkStream mkStrm) = mkStrm
nextOutput ostrm@OStream{} = pure ostrm
nextOutput OEndStream = error "We shouldn't be calling nextOutput once done"

encodeOutput :: DynamicTable -> StreamId -> Output -> IO ByteString
encodeOutput encodeDT sid = runReaderT mkOutput
  where
    -- TODO: Use encodeFrameChunks instead of encodeFrame
    mkOutput :: ReaderT Output IO ByteString
    mkOutput = do
        ostrm <- ask
        payload <- mkPayload ostrm
        pure $ encodeFrame (mkEncodeInfo ostrm) (mkFramePayload ostrm payload)

    mkPayload :: Output -> ReaderT Output IO ByteString
    mkPayload = \case
        OHeader mkHdr _ -> liftIO $ mkHdr encodeDT
        OStream ostrm   -> liftIO . atomically $ readTQueue ostrm
        OEndStream      -> pure ""

    mkFramePayload :: Output -> ByteString -> FramePayload
    mkFramePayload OHeader{} = HeadersFrame Nothing
    mkFramePayload OStream{} = DataFrame
    mkFramePayload OEndStream = DataFrame

    mkEncodeInfo :: Output -> EncodeInfo
    mkEncodeInfo OHeader{} = encodeInfo setEndHeader sid
    mkEncodeInfo OStream{} = encodeInfo id sid
    mkEncodeInfo OEndStream{} = encodeInfo setEndStream sid

