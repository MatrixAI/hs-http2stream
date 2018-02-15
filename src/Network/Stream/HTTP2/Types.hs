{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

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

-----------------------------------------------------------------

type Input = TQueue ByteString
enqueueInput :: Input -> ByteString -> STM ()
enqueueInput = writeTQueue 

-- TODO: OHeader should provide a ByteString builder 
-- so that we can do header continuation encoding
-- Also why is the bytestring building in the frame builder not using
-- strict-bytestring-builder?
data Output = OHeader (DynamicTable -> IO ByteString)
            | OStream (TQueue ByteString) 
            | OEndStream 

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
  , acceptQ            :: !(TQueue (Input, Output))
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

clearContext :: Context -> IO ()
clearContext ctx = return ()

----------------------------------------------------------------

data Stream (a :: StreamState) where
  DialStream   :: { streamId     :: !StreamId
                  , precedence   :: !(IORef Precedence)
                  , window       :: !(TVar WindowSize)
                  , inputStream  :: Input
                  , outputStream :: Output
                  } -> Stream 'Open
  ListenStream :: { streamId     :: !StreamId
                  , precedence   :: !(IORef Precedence)
                  , window       :: !(TVar WindowSize)
                  , inputStream  :: Input
                  , outputStream :: Output
                  } -> Stream 'Open
  ClosedStream :: StreamId -> ClosedCode -> Stream 'Closed

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

type OpenStreamConstructor =  StreamId 
                           -> IORef Precedence -> TVar WindowSize 
                           -> Input 
                           -> Output 
                           -> Stream 'Open

makeStream :: OpenStreamConstructor
           -> StreamId -> WindowSize -> Output -> IO (Stream 'Open)
makeStream cons sid win hdr = cons sid <$> newIORef defaultPrecedence 
                                       <*> newTVarIO win
                                       <*> newTQueueIO
                                       <*> pure hdr

accept :: StreamId -> WindowSize -> IO (Stream 'Open)
accept sid win = makeStream ListenStream 
                            sid win responseHeader

dial :: StreamId -> WindowSize -> IO (Stream 'Open)
dial sid win = makeStream DialStream 
                          sid win requestHeader

close :: StreamId -> ClosedCode -> Stream 'Closed
close = ClosedStream

----------------------------------------------------------------

makeHeader :: HeaderList -> DynamicTable -> IO ByteString
makeHeader = (flip . defaultHeaderArgs) encodeHeader
  where
    defaultHeaderArgs :: (EncodeStrategy -> Size -> a) -> a
    defaultHeaderArgs = ($ 256*1024) . ($ defaultEncodeStrategy)

requestHeader :: Output
requestHeader = OHeader (makeHeader reqhdr) 
  where
    reqhdr = [ (":method", "GET")
             , (":scheme", "ipfs")
             , (":path", "/") ]

responseHeader :: Output
responseHeader = OHeader (makeHeader reshdr)
  where
    reshdr = [ (":status", "200") ]

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

{-# INLINE enqueueQ #-}
enqueueQ :: TQueue a -> a -> IO ()
enqueueQ q = atomically . writeTQueue q

data HTTP2HostType = HClient | HServer deriving Show
