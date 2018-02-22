{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Sender where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Reader

import Data.ByteString (ByteString)

import Network.HPACK
import Network.HTTP2
import Network.HTTP2.Priority
import Network.Stream.HTTP2.Types

----------------------------------------------------------------

frameSender :: Context -> (ByteString -> IO ()) -> IO ()
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

nextOutput :: Output -> IO Output
nextOutput (OHeader _ next) = pure next
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
        OMkStream mkStrm -> liftIO mkStrm >>= mkPayload
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

