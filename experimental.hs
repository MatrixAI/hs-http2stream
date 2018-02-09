{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module Experimental where

-- TODO: if the flow control window is exhausted, enqueue a WINDOW_UPDATE
-- frame to renew the window
-- data FrameReceiver where
--     RawHeader              :: ByteString -> FrameReceiver
--     VerifyHeader           :: FrameReceiver Settings -> (FrameTypeId, FrameHeader) -> FrameReceiver
--     ReceiveFramePayload    :: FrameReceiver
--     UpdateConnectionWindow :: Int -> FrameReceiver
--     UpdateStreamWindow     :: StreamId -> Int -> FrameReceiver
--     UpdateSettings         :: FrameReceiver -> FrameReceiver
--     ControlPayload         :: FramePayload -> FrameReceiver
--     StreamPayload          :: StreamId -> FramePayload -> FrameReceiver
--     Loop                   :: FrameReceiver
--     OnConnectionError      :: HTTP2Error -> FrameReceiver
--     OnStreamError          :: HTTP2Error -> FrameReceiver

-- checkHeader :: FrameReceiver -> FrameReceiver
-- checkHeader (FrameReceiver rawhdr) = checkHeader . verifyHeader . decodeFrameHeader rawhdr
-- checkHeader (VerifyHeader (ReceiverSettings s) typhdr) = case ehdr of
--     Left ce@ConnectionError{} -> OnConnectionError ce
--     Left se@StreamError{}     -> OnStreamError se
--     Right typhdr'             -> ReceiveFramePayload
--   where 
--     ehdr = checkFrameHeader typhdr
--     verifyHeader = VerifyHeader ReceiverSettings

import Data.IORef

data StreamState =
    Idle
  | Open
  | HalfClosed
  | Closed
  | Reserved
  deriving Show

data ClosedCode = Finished
                | Killed
                | Reset !String
                | ResetByMe String
                deriving Show

data Stream (a :: Either StreamState StreamState) where
  IdleStream   :: Stream ('Left 'Idle)
  OpenStream   :: StreamInfo -> Stream ('Right 'Open)
  ClosedStream :: ClosedCode -> Stream ('Left 'Closed)

data StreamInfo = StreamInfo {
    context    :: !String
  , number     :: !Int
  , precedence :: !Int
  } deriving Show

eval :: Stream a -> IO ()
eval = \case
    x@IdleStream -> goIdle x
    y@(OpenStream si) -> goOpen y
    z@(ClosedStream cc) -> goClosed z
  where
    goIdle :: Stream ('Left 'Idle) -> IO ()
    goIdle x = putStrLn "Idle"
    goOpen :: Stream ('Right 'Open) -> IO ()
    goOpen x = putStrLn "Open"
    goClosed :: Stream ('Left 'Closed) -> IO ()
    goClosed x = putStrLn "Closed"

type ReadStream = IORef Int
type WriteStream = IORef Int
