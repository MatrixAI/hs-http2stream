{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Stream.HTTP2.Types where

import Data.ByteString (ByteString)
import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK
import Data.IORef
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad
import System.IO.Streams

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M
import qualified Control.Exception as E
----------------------------------------------------------------

data Context = Context {
  -- HTTP/2 settings received from a browser
    http2settings      :: !(IORef Settings)
  , firstSettings      :: !(IORef Bool)
  , streamTable        :: !StreamTable
  , concurrency        :: !(IORef Int)
  , priorityTreeSize   :: !(IORef Int)
  -- | RFC 7540 says "Other frames (from any stream) MUST NOT
  --   occur between the HEADERS frame and any CONTINUATION
  --   frames that might follow". This field is used to implement
  --   this requirement.
  , continued          :: !(IORef (Maybe StreamId))
  , clientStreamId     :: !(IORef StreamId)
  , serverStreamId     :: !(IORef StreamId)
  , inputQ             :: !(TQueue Frame)
  , acceptQ            :: !(TQueue StreamReaderWriter)
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

instance Show (Output) where
  show (OStream sid _) = "OStream StreamId " ++ show sid

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
clearContext _ctx = return ()

----------------------------------------------------------------

-- data OpenState =
  -- JustOpened
  -- | Continued [HeaderBlockFragment]
  --             !Int  -- Total size
  --             !Int  -- The number of continuation frames
  --             !Bool -- End of stream
  --             !Priority
  -- | NoBody (TokenHeaderList,ValueTable) !Priority
  -- | HasBody (TokenHeaderList,ValueTable) !Priority
  -- Body !(TQueue ByteString)
         -- !(Maybe Int) -- received Content-Length
         --              -- compared the body length for error checking
         -- !(IORef Int) -- actual body length

data ClosedCode = Finished
                | Killed
                | Reset !ErrorCodeId
                | ResetByMe SomeException
                deriving Show

data StreamState =
    Idle
  | Open !(TQueue ByteString) !(TQueue (Maybe ByteString)) -- incoming and outgoing
  | LocalClosed !(TQueue ByteString)                       -- incoming only 
  | RemoteClosed !(TQueue (Maybe ByteString))              -- outgoing only
  | Closed !ClosedCode
  | Reserved

isIdle :: StreamState -> Bool
isIdle Idle = True
isIdle _    = False

isOpen :: StreamState -> Bool
isOpen Open{} = True
isOpen _      = False

isLocalClosed :: StreamState -> Bool
isLocalClosed LocalClosed{} = True
isLocalClosed _             = False

isRemoteClosed :: StreamState -> Bool
isRemoteClosed RemoteClosed{} = True
isRemoteClosed _              = False

isClosed :: StreamState -> Bool
isClosed Closed{} = True
isClosed _        = False

instance Show StreamState where
    show Idle           = "Idle"
    show Open{}         = "Open"
    show LocalClosed{}  = "LocalClosed"
    show RemoteClosed{} = "RemoteClosed"
    show (Closed e)     = "Closed: " ++ show e
    show Reserved       = "Reserved"

----------------------------------------------------------------

data Stream = Stream {
    streamNumber     :: !StreamId
  , streamState      :: !(IORef StreamState)
  , streamWindow     :: !(TVar WindowSize)
  , streamPrecedence :: !(IORef Precedence)
  }

instance Show Stream where
  show s = show (streamNumber s)

newStream :: StreamId -> WindowSize -> IO Stream
newStream sid win = Stream sid <$> newIORef Idle
                               <*> newTVarIO win
                               <*> newIORef defaultPrecedence

newPushStream :: Context -> WindowSize -> Precedence -> IO Stream
newPushStream Context{serverStreamId} win pre = do
    sid <- atomicModifyIORef' serverStreamId inc2
    Stream sid <$> newIORef Reserved
               <*> newTVarIO win
               <*> newIORef pre
  where
    inc2 x = let !x' = x + 2 in (x', x')

readStream :: Stream -> IO ByteString
readStream Stream{streamNumber, streamState} = do
    ss <- readIORef streamState
    bs <- case ss of
            Open ins _ -> atomically $ readTQueue ins
            LocalClosed ins -> atomically $ readTQueue ins
            -- This shouldn't happen
            otherwise -> E.throwIO $ StreamError InternalError streamNumber
    return bs

writeStream :: Stream -> (Maybe ByteString) -> IO ()
writeStream Stream{streamNumber, streamState} bs = do
    ss <- readIORef streamState
    case ss of
        Open _ outs -> atomically $ writeTQueue outs bs
        RemoteClosed outs -> atomically $ writeTQueue outs bs
        -- This shouldn't happen
        otherwise -> E.throwIO $ StreamError InternalError streamNumber

----------------------------------------------------------------

opened :: Context -> Stream -> IO ()
opened Context{concurrency} Stream{streamState} = do
    atomicModifyIORef' concurrency (\x -> (x+1,()))
    ins <- newTQueueIO
    outs <- newTQueueIO
    writeIORef streamState (Open ins outs)

closed :: Context -> Stream -> ClosedCode -> IO ()
closed Context{concurrency,streamTable} Stream{streamState,streamNumber} cc = do
    remove streamTable streamNumber
    atomicModifyIORef' concurrency (\x -> (x-1,()))
    writeIORef streamState (Closed cc) -- anyway

----------------------------------------------------------------

newtype StreamTable = StreamTable (IORef (IntMap Stream))

newStreamTable :: IO StreamTable
newStreamTable = StreamTable <$> newIORef M.empty

insert :: StreamTable -> M.Key -> Stream -> IO ()
insert (StreamTable ref) k v = atomicModifyIORef' ref $ \m ->
    let !m' = M.insert k v m
    in (m', ())

remove :: StreamTable -> M.Key -> IO ()
remove (StreamTable ref) k = atomicModifyIORef' ref $ \m ->
    let !m' = M.delete k m
    in (m', ())

search :: StreamTable -> M.Key -> IO (Maybe Stream)
search (StreamTable ref) k = M.lookup k <$> readIORef ref

updateAllStreamWindow :: (WindowSize -> WindowSize) -> StreamTable -> IO ()
updateAllStreamWindow adst (StreamTable ref) = do
    strms <- M.elems <$> readIORef ref
    forM_ strms $ \strm -> atomically $ modifyTVar (streamWindow strm) adst

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
type StreamReaderWriter = (IO ByteString, Maybe ByteString -> IO ())
