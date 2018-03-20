module Main where

import Prelude
import Data.Argonaut (class EncodeJson, class DecodeJson, encodeJson, decodeJson, fail)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (CONSOLE, log)

import Sparrow.Client (Client)


data InitIn = InitIn

instance encodeJsonInitIn :: EncodeJson InitIn where
  encodeJson InitIn = encodeJson "InitIn"

data InitOut = InitOut

instance decodeJsonInitOut :: DecodeJson InitOut where
  decodeJson json = do
    s <- decodeJson json
    if s == "InitOut" then pure InitOut else fail "Not an InitOut"

data DeltaIn = DeltaIn

instance encodeJsonDeltaIn :: EncodeJson DeltaIn where
  encodeJson DeltaIn = encodeJson "DeltaIn"

data DeltaOut = DeltaOut

instance decodeJsonDeltaOut :: DecodeJson DeltaOut where
  decodeJson json = do
    s <- decodeJson json
    if s == "DeltaOut" then pure DeltaOut else fail "Not an DeltaOut"


client :: Client eff (Eff eff) InitIn InitOut DeltaIn DeltaOut
client call = do
  log "Calling..."
  call
    { initIn: InitIn
    , receive: \{sendCurrent,initOut,unsubscribe} DeltaOut ->
      log "Received DeltaOut..."
    , onReject:
      log "Rejected..."
    }
    ( \mReturn -> case mReturn of
         Nothing -> log "Failed..."
         Just {sendCurrent,initOut: InitOut,unsubscribe} -> do
           log "Success InitOut"
           sendCurrent DeltaIn
    )


main :: forall e. Eff (console :: CONSOLE | e) Unit
main = do
  log "Hello sailor!"
