module Network.Stream.HTTP2.EncodeFrame where

import qualified Network.HTTP2 as H2
import qualified Data.ByteString as BSStrict

goawayFrame :: H2.StreamId -> H2.ErrorCodeId -> BSStrict.ByteString -> BSStrict.ByteString
goawayFrame streamId errorCode message = H2.encodeFrame info frame
  where
    info = H2.encodeInfo id 0
    frame = H2.GoAwayFrame streamId errorCode message

resetFrame :: H2.ErrorCodeId -> H2.StreamId -> BSStrict.ByteString
resetFrame errorCode streamId = H2.encodeFrame info frame
  where
    info = H2.encodeInfo id streamId
    frame = H2.RSTStreamFrame errorCode

settingsFrame :: (H2.FrameFlags -> H2.FrameFlags) -> H2.SettingsList -> BSStrict.ByteString
settingsFrame func settings = H2.encodeFrame info frame
  where
    info = H2.encodeInfo func 0
    frame = H2.SettingsFrame settings

pingFrame :: BSStrict.ByteString -> BSStrict.ByteString
pingFrame bs = H2.encodeFrame info frame
  where
    info = H2.encodeInfo H2.setAck 0
    frame = H2.PingFrame bs

windowUpdateFrame :: H2.StreamId -> H2.WindowSize -> BSStrict.ByteString
windowUpdateFrame streamId size = H2.encodeFrame info frame
  where
    info = H2.encodeInfo id streamId
    frame = H2.WindowUpdateFrame size
