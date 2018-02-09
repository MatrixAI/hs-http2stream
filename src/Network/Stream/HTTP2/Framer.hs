{-# LANGUAGE GADTs #-}

module Network.Stream.HTTP2.Protocol where

import Network.HTTP2
-- | The idea here is to try to encode all the control flow and logical aspects
-- of the HTTP2 protocol into a monad, which is then interpreted by the
-- frameReceiver, as in something like Free Protocol a :: IO a 
-- We don't want to care about the actual implementation of the
-- FrameHeaders, FrameTypes, FramePayloads, etc, we just want the frame types
-- themselves. We want to do the bare minimum to capture the idea of receiving
-- a frame, 

data Protocol a where
  ReceiveFrame :: Protocol 

frameReceiver :: Free Protocol a
frameReceiver = do
    
