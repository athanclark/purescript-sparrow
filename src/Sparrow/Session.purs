module Sparrow.Session where


import Prelude

import Data.UUID (UUID, parseUUID)
import Data.Maybe (Maybe (..))
import Data.Argonaut (class DecodeJson, class EncodeJson, decodeJson, encodeJson, fail)
import Data.Generic.Rep (class Generic)


newtype SessionID = SessionID UUID

derive instance genericSessionID :: Generic SessionID _

instance eqSessionID :: Eq SessionID where
  eq (SessionID x) (SessionID y) = x `eq` y

instance showSessionID :: Show SessionID where
  show (SessionID x) = show x

instance decodeJsonSessionID :: DecodeJson SessionID where
  decodeJson json = do
    s <- decodeJson json
    case parseUUID s of
      Nothing -> fail "Not a SessionID"
      Just u -> pure (SessionID u)

instance encodeJsonSessionID :: EncodeJson SessionID where
  encodeJson x = encodeJson (show x)
