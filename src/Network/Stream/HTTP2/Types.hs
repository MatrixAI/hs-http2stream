{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Stream.HTTP2.Types where

import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad

import Data.ByteString (ByteString)
import Data.IORef

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M

import Network.HPACK
import Network.HTTP2
import Network.HTTP2.Priority

----------------------------------------------------------------

type Input = TQueue ByteString
enqueueInput :: Input -> ByteString -> STM ()
enqueueInput = writeTQueue 

type Output = TQueue ByteString

data P2PStream = P2PStream StreamId Input Output

-- TODO: OHeader should provide a ByteString builder 
-- so that we can do header continuation encoding
-- Also why is the bytestring building in the frame builder not using
-- strict-bytestring-builder?
data Framer = FMkStream StreamId (DynamicTable -> IO ByteString) 
                                 (TQueue ByteString)
            | FStream StreamId (TQueue ByteString)
            | FEndStream StreamId
            | FTerminal StreamId 

------------------------------------------------------------------

data Context = Context {
  -- HTTP/2 settings received from a browser
    http2Settings      :: !(IORef Settings)
  , firstSettings      :: !(IORef Bool)
  , openedStreams      :: !(StreamTable 'Open)
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
  , acceptQ            :: !(TQueue P2PStream)
  , outputQ            :: !(PriorityTree Framer)
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

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef False
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

----------------------------------------------------------------

-- Idea... introduce an InitStream which does the initial request response 
-- header thing. What transitions the stream from InitStream to OpenStream?
-- InitStream will be parsed immediately when in server mode to send response
-- headers and transition the stream to open stream state.
-- the frame sender 
data Stream (a :: StreamState) where
  OpenStream   :: { streamId     :: !StreamId
                  , precedence   :: !(IORef Precedence)
                  , window       :: !(TVar WindowSize)
                  , inputStream  :: Input
                  , outputStream :: Output
                  } -> Stream 'Open
  ClosedStream :: StreamId -> ClosedCode -> Stream 'Closed

data StreamState = Idle
                 | Open
                 | Closed
                 deriving Show

data ClosedCode = Finished
                | Killed
                | Reset !ErrorCodeId
                | ResetByMe SomeException
                deriving Show

openStream :: StreamId -> WindowSize -> Precedence
           -> IO (Stream 'Open)
openStream sid win pre = OpenStream sid <$> newIORef pre
                                        <*> newTVarIO win
                                        <*> newTQueueIO
                                        <*> newTQueueIO

makeHeader :: HeaderList -> DynamicTable -> IO ByteString
makeHeader = flip
           $ encodeHeader defaultEncodeStrategy (256*1024)

responseHeader :: DynamicTable -> IO ByteString
responseHeader = makeHeader reshdr
  where
    reshdr = [ (":status", "200") ]

requestHeader :: DynamicTable -> IO ByteString
requestHeader = makeHeader reqhdr
  where
    reqhdr = [ (":method", "GET")
             , (":scheme", "ipfs")
             , (":path", "/") ]

----------------------------------------------------------------

newtype StreamTable a = StreamTable (IORef (IntMap (Stream a)))

newStreamTable :: IO (StreamTable a)
newStreamTable = StreamTable <$> newIORef M.empty

insert :: StreamTable a -> M.Key -> Stream a -> IO ()
insert (StreamTable ref) k v = atomicModifyIORef' ref $ \m ->
    let !m' = M.insert k v m
    in (m', ())

remove :: StreamTable a -> M.Key -> IO ()
remove (StreamTable ref) k = atomicModifyIORef' ref $ \m ->
    let !m' = M.delete k m
    in (m', ())

search :: StreamTable a -> M.Key -> IO (Maybe (Stream a))
search (StreamTable ref) k = M.lookup k <$> readIORef ref

updateAllStreamWindow :: (WindowSize -> WindowSize) -> StreamTable 'Open -> IO ()
updateAllStreamWindow adst (StreamTable ref) = do
    strms <- M.elems <$> readIORef ref
    atomically $ forM_ strms $ \strm -> modifyTVar (window strm) adst

----------------------------------------------------------------

{-# INLINE enqueueQ #-}
enqueueQ :: TQueue a -> a -> IO ()
enqueueQ q = atomically . writeTQueue q

data HTTP2HostType = HClient | HServer deriving Show
