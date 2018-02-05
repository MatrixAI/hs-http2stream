{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-} 
{-# LANGUAGE GADTs #-}

module Network.Stream.HTTP2.Types where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK
import Data.IORef
import Control.Concurrent.STM
import Control.Exception (SomeException)

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M

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

data Output = OStream !StreamId !(TQueue ByteString)

instance Show Output where
  show (OStream sid _) = "OStream StreamId " ++ show sid

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
  OpenStream   :: { context     :: !Context
                  , streamId    :: !StreamId
                  , precedence  :: !(IORef Precedence)
                  , window      :: !(TVar WindowSize)
                  , readStream  :: ReadStream
                  , writeStream :: WriteStream
                  } -> Stream 'Open
  ClosedStream :: StreamId -> ClosedCode -> Stream 'Closed

openStream :: Context -> StreamId -> WindowSize -> IO (Stream 'Open)
openStream ctx sid win = OpenStream ctx sid <$> newIORef defaultPrecedence 
                                            <*> newTVarIO win
                                            <*> newTQueueIO
                                            <*> newTQueueIO

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

-- -- search :: StreamTable -> M.Key -> IO (Maybe (Stream a))
-- -- search (StreamTable ref) k = M.lookup k <$> readIORef ref

updateAllStreamWindow :: (WindowSize -> WindowSize) -> StreamTable a -> IO ()
updateAllStreamWindow = undefined
-- updateAllStreamWindow adst (StreamTable ref) = do
--      strms <- M.elems <$> readIORef ref
--      forM_ strms $ \strm -> atomically $ modifyTVar (streamWindow strm) adst

-- {-# INLINE forkAndEnqueueWhenReady #-}
-- forkAndEnqueueWhenReady :: IO () -> PriorityTree Output -> Output -> Manager -> IO ()
-- forkAndEnqueueWhenReady wait outQ out mgr = bracket setup teardown $ \_ ->
--     void . forkIO $ do
--         wait
--         enqueueOutput outQ out
--   where
--     setup = addMyId mgr
--     teardown _ = deleteMyId mgr

-- {-# INLINE enqueueOutput #-}
-- enqueueOutput :: PriorityTree Output -> Output -> IO ()
-- enqueueOutput outQ out = do
--     let Stream{..} = outputStream out
--     pre <- readIORef streamPrecedence
--     enqueue outQ streamNumber pre out

-- {-# INLINE enqueueControl #-}
-- enqueueControl :: TQueue Control -> Control -> IO ()
-- enqueueControl ctlQ ctl = atomically $ writeTQueue ctlQ ctl

----------------------------------------------------------------

-- functions to read and write from the stream in the IO monad
type ReadStream = TQueue ByteString
type WriteStream = TQueue (Maybe ByteString)
