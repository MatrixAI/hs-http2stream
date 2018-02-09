{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-} 
{-# LANGUAGE GADTs #-}

module Network.Stream.HTTP2.FTypes where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK
import Control.Concurrent.STM
import Control.Exception (SomeException)

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M

------------------------------------------------------------------

data Context = Context {
  -- HTTP/2 settings received from a browser
    http2Settings      :: !Settings
  , firstSettings      :: !Bool
  , openedStreams      :: !(StreamTable 'Open)
  , closedStreams      :: !(StreamTable 'Closed)
  , concurrency        :: !Int
  , priorityTreeSize   :: !Int
  -- | RFC 7540 says "Other frames (from any stream) MUST NOT
  --   occur between the HEADERS frame and any CONTINUATION
  --   frames that might follow". This field is used to implement
  --   this requirement.
  , continued          :: !(Maybe StreamId)
  , hostStreamId       :: !StreamId
  , peerStreamId       :: !StreamId
  , inputQ             :: !(TQueue Frame)
  , acceptQ            :: !(TQueue (ReadStream, WriteStream))
  , outputQ            :: !(PriorityTree Output)
  , controlQ           :: !(TQueue Control)
  , encodeDynamicTable :: !DynamicTable
  , decodeDynamicTable :: !DynamicTable
  -- the connection window for data from a server to a browser.
  , connectionWindow   :: !(TVar WindowSize)
  }

data Control = CFinish
             | CGoaway    !ByteString
             | CFrame     !ByteString
             | CSettings  !ByteString !SettingsList
             | CSettings0 !ByteString !ByteString !SettingsList
             deriving Show

data Output = OStream !StreamId !(TQueue ByteString)

instance Show Output where
  show (OStream sid _) = "OStream StreamId " ++ show sid

newContext :: IO Context
newContext = Context defaultSettings
                     False
                     newStreamTable
                     newStreamTable
                     0
                     0
                     Nothing
                     1
                     2
                     <$> newTQueueIO
                     <*> newTQueueIO
                     <*> newPriorityTree
                     <*> newTQueueIO
                     <*> newDynamicTableForEncoding defaultDynamicTableSize
                     <*> newDynamicTableForDecoding defaultDynamicTableSize 4096
                     <*> newTVarIO defaultInitialWindowSize

----------------------------------------------------------------

data StreamState =
    Idle
  | Open
  | Closed
  deriving Show

data ClosedCode = Finished
                | Killed
                | Reset !ErrorCodeId
                | ResetByMe SomeException
                deriving Show

data Stream (a :: StreamState) where
    OpenStream   :: { streamId    :: !StreamId
                    , prec        :: !Precedence
                    , window      :: !WindowSize
                    , readStream  :: !(TQueue ByteString)
                    , writeStream :: !(TQueue ByteString)
                    } -> Stream 'Open
    ClosedStream :: { closedCode :: ClosedCode } -> Stream 'Closed

openStream :: StreamId -> WindowSize -> IO (Stream 'Open)
openStream sid win = OpenStream sid defaultPrecedence win
                                <$> newTQueueIO
                                <*> newTQueueIO

----------------------------------------------------------------

type StreamTable a = IntMap (Stream a)

newStreamTable :: StreamTable a
newStreamTable = M.empty

updateStreamWindow :: (WindowSize -> WindowSize) -> Stream 'Open -> Stream 'Open
updateStreamWindow adjust strm@OpenStream{window} = 
    let window' = adjust window 
    in strm{ window = window' }

updateAllStreamWindow :: (WindowSize -> WindowSize) -> StreamTable 'Open -> StreamTable 'Open
updateAllStreamWindow adst st =  updateStreamWindow adst <$> st

---------------------------------------------------------------

type ReadStream = TQueue ByteString
type WriteStream = TQueue ByteString
