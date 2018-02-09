{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module Experimental where

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
