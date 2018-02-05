module Network.Stream.HTTP2.EncodeFrame where

import Data.ByteString (ByteString)
import Network.HTTP2

----------------------------------------------------------------

goawayFrame :: StreamId -> ErrorCodeId -> ByteString -> ByteString
goawayFrame sid etype debugmsg = encodeFrame einfo frame
  where
    einfo = encodeInfo id 0
    frame = GoAwayFrame sid etype debugmsg

resetFrame :: ErrorCodeId -> StreamId -> ByteString
resetFrame etype sid = encodeFrame einfo frame
  where
    einfo = encodeInfo id sid
    frame = RSTStreamFrame etype

settingsFrame :: (FrameFlags -> FrameFlags) -> SettingsList -> ByteString
settingsFrame func alist = encodeFrame einfo $ SettingsFrame alist
  where
    einfo = encodeInfo func 0

pingFrame :: ByteString -> ByteString
pingFrame bs = encodeFrame einfo $ PingFrame bs
  where
    einfo = encodeInfo setAck 0

pingFrameAck :: ByteString -> ByteString
pingFrameAck bs = encodeFrame einfo $ PingFrame bs
  where
    einfo = encodeInfo setAck 1

windowUpdateFrame :: StreamId -> WindowSize -> ByteString
windowUpdateFrame sid winsiz = encodeFrame einfo $ WindowUpdateFrame winsiz
  where
    einfo = encodeInfo id sid
