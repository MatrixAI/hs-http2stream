{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Sender where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Reader

import Data.ByteString (ByteString)

import Debug.Trace

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
            (sid, pre, framer) <- dequeue outputQ
            encodeOutput encodeDynamicTable sid framer >>= send
            case nextOutput framer of
                Just FEndStream{} -> 
                    traceIO "hit end stream"
                Just x -> do
                    traceIO "hit other"
                    enqueue outputQ sid pre x
                Nothing -> pure ()
          True -> pure ()

nextOutput :: Framer -> Maybe Framer
nextOutput (FMkStream sid mkHeaders out) = Just $ FStream sid out
nextOutput fstrm@FStream{} = Just fstrm
nextOutput (FEndStream sid) = Nothing

encodeOutput :: DynamicTable -> StreamId -> Framer -> IO ByteString
encodeOutput encodeDT sid = runReaderT mkFrame
  where 
    -- TODO: Use encodeFrameChunks instead of encodeFrame
    mkFrame :: ReaderT Framer IO ByteString
    mkFrame = do
        framer <- ask
        payload <- mkPayload framer
        pure $ encodeFrame (mkEncodeInfo framer) (mkFramePayload framer payload)

    mkPayload :: Framer -> ReaderT Framer IO ByteString
    mkPayload = \case
        FMkStream _ mkHdr _ -> liftIO (mkHdr encodeDT)
        FStream _ out      -> liftIO . atomically $ readTQueue out
        FEndStream{}       -> pure ""
        FTerminal{}        -> error "Library error, please report this: \
                                    \tried to mkPayload for \
                                    \a terminal stream state"

    mkFramePayload :: Framer -> ByteString -> FramePayload
    mkFramePayload FMkStream{} = HeadersFrame Nothing
    mkFramePayload FStream{} = DataFrame
    mkFramePayload FEndStream{} = DataFrame
    mkFramePayload FTerminal{} = error "Library error, please report this: \
                                       \tried to mkFramePayload for \
                                       \a terminal stream state"

    mkEncodeInfo :: Framer -> EncodeInfo
    mkEncodeInfo FMkStream{} = 
        encodeInfo setEndHeader sid
    mkEncodeInfo FStream{} =
        encodeInfo id sid
    mkEncodeInfo FEndStream{} =
        encodeInfo setEndStream sid
    mkEncodeInfo FTerminal{} = error "Library error, please report this: \
                                     \tried to mkEncodeInfo for \
                                     \a terminal stream state"

