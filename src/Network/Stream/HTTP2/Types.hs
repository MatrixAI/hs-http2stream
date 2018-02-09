{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

module Network.Stream.HTTP2.Types where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK
import Data.IORef
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad


import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M

-- These are the types that are exposed in the library API --
newtype ReadStream = ReadStream { unReadStream :: TQueue ByteString }
streamRead :: ReadStream -> STM ByteString
streamRead (ReadStream rs) = readTQueue rs

newtype WriteStream = WriteStream { unWriteStream :: TQueue ByteString }
streamWrite :: WriteStream -> ByteString -> STM ()
streamWrite (WriteStream ws)= writeTQueue ws

-- These types are used internally by the frame receiver and sender --
-- You can think of the control flow like:
-- frameReceiver -> Input ~ ReadStream -> readStream
-- writeStream -> WriteStream ~ Output -> frameSender
-- so Input represents the side of the stream that frameReceiver writes into
-- and ReadStream represents reading from API land (through streamRead) and
-- vice versa

newtype Input = Input { unInput :: ReadStream }
nextInput :: Input -> ByteString -> STM ()
nextInput = writeTQueue . unReadStream . unInput

newtype Output = Output { unOutput :: WriteStream }
nextOutput :: Output -> STM ByteString
nextOutput = readTQueue . unWriteStream . unOutput

------------------------------------------------------------------

data Context = Context {
  -- HTTP/2 settings received from a browser
    http2Settings      :: !(IORef Settings)
  , firstSettings      :: !(IORef Bool)
  , openedStreams      :: !(StreamTable 'Open)
  , closedStreams      :: !(StreamTable 'Closed)
  , concurrency        :: !(IORef Int)
  , priorityTreeSize   :: !(IORef Int)
  -- | RFC 7540 says "Other frames (from any stream) MUST NOT
  --   occur between the HEADERS frame and any CONTINUATION
  --   frames that might follow". This field is used to implement
  --   this requirement.
  , continued          :: !(IORef (Maybe StreamId))
  , hostStreamId       :: !(IORef StreamId)
  , peerStreamId       :: !(IORef StreamId)
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

{-# INLINE enqueueControl #-}
enqueueControl :: TQueue Control -> Control -> IO ()
enqueueControl ctlQ = atomically . writeTQueue ctlQ

type Accept = (ReadStream, WriteStream)

{-# INLINE enqueueAccept #-}
enqueueAccept :: TQueue Accept -> 
                 Accept -> IO ()
enqueueAccept acceptQ = atomically . writeTQueue acceptQ

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef False
                     <*> newStreamTable
                     <*> newStreamTable
                     <*> newIORef 0
                     <*> newIORef 0
                     <*> newIORef Nothing
                     <*> newIORef 1
                     <*> newIORef 2
                     <*> newTQueueIO
                     <*> newTQueueIO
                     <*> newPriorityTree
                     <*> newTQueueIO
                     <*> newDynamicTableForEncoding defaultDynamicTableSize
                     <*> newDynamicTableForDecoding defaultDynamicTableSize 4096
                     <*> newTVarIO defaultInitialWindowSize

clearContext :: Context -> IO ()
clearContext _ctx = return ()

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
  OpenStream   :: { streamId     :: !StreamId
                  , precedence   :: !(IORef Precedence)
                  , window       :: !(TVar WindowSize)
                  , inputStream  :: Input
                  , outputStream :: Output
                  } -> Stream 'Open
  ClosedStream :: StreamId -> ClosedCode -> Stream 'Closed

openStream :: StreamId -> WindowSize -> IO (Stream 'Open)
openStream sid win = OpenStream sid <$> newIORef defaultPrecedence 
                                    <*> newTVarIO win
                                    <*> (Input . ReadStream <$> newTQueueIO)
                                    <*> (Output . WriteStream <$> newTQueueIO)

closeStream :: StreamId -> ClosedCode -> Stream 'Closed
closeStream = ClosedStream

-- TODO: support push streams
-- newPushStream :: Context -> WindowSize -> Precedence -> IO (Stream ('Right 'Open))
-- newPushStream Context{hostStreamId} win pre = do
--     sid <- atomicModifyIORef' hostStreamId inc2
--     IdleStream <$> newStreamInfo sid win pre
--   where
--     inc2 x = let !x' = x + 2 in (x', x')

----------------------------------------------------------------

newtype StreamTable a = StreamTable (IORef (IntMap (Stream a)))

newStreamTable :: IO (StreamTable a)
newStreamTable = StreamTable <$> newIORef M.empty

insert :: StreamTable a -> M.Key -> Stream a -> IO ()
insert (StreamTable ref) k v = atomicModifyIORef' ref $ \m ->
    let !m' = M.insert k v m
    in (m', ())

-- remove :: StreamTable -> M.Key -> IO ()
-- remove (StreamTable ref) k = atomicModifyIORef' ref $ \m ->
--     let !m' = M.delete k m
--     in (m', ())

search :: StreamTable a -> M.Key -> IO (Maybe (Stream a))
search (StreamTable ref) k = M.lookup k <$> readIORef ref

updateAllStreamWindow :: (WindowSize -> WindowSize) -> StreamTable 'Open -> IO ()
updateAllStreamWindow adst (StreamTable ref) = do
    strms <- M.elems <$> readIORef ref
    forM_ strms $ \strm -> atomically $ modifyTVar (window strm) adst

----------------------------------------------------------------
data HTTP2HostType = HClient | HServer deriving Show
