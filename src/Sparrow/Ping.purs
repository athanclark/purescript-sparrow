module Sparrow.Ping where

import Prelude
import Data.Maybe (Maybe (..))
import Data.Argonaut (class EncodeJson, class DecodeJson, encodeJson, decodeJson, fail)
import Data.Array as Array
import Control.Alternative ((<|>))


newtype PingPong a = PingPong (Maybe a)

instance encodeJsonPingPong :: EncodeJson a => EncodeJson (PingPong a) where
  encodeJson (PingPong mx) = case mx of
    Nothing -> encodeJson ""
    Just x -> encodeJson [x]

instance decodeJsonPingPong :: DecodeJson a => DecodeJson (PingPong a) where
  decodeJson json = do
    let ping = do
          s <- decodeJson json
          if s == "" then pure (PingPong Nothing) else fail "Not a PingPong"
        content = do
          a <- decodeJson json
          case Array.head a of
            Nothing -> fail "Not a PingPong"
            x -> pure (PingPong x)
    ping <|> content
