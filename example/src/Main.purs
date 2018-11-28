module Main where

import Prelude
import Data.These (These (Both))
import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple (..))
import Data.Argonaut (class EncodeJson, class DecodeJson, encodeJson, decodeJson, fail)
import URI (Authority (..), Host (NameAddress))
import URI.Port as Port
import URI.Host.RegName as RegName
import Effect (Eff)
import Effect.Ref as Ref
import Effect.Console (log)

import Sparrow.Client (Topic (..), Client, allocateDependencies, unpackClient)


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

client :: Client Effect InitIn InitOut DeltaIn DeltaOut
client call = do
  log "Calling..."
  count <- Ref.new 0
  call
    { initIn: InitIn
    , receive: \{sendCurrent,initOut,unsubscribe} DeltaOut -> do
        log "Received DeltaOut..."
        c <- Ref.modify count (\x -> x + 1)
        when (c >= 10) unsubscribe
    , onReject:
        log "Rejected..."
    }
    ( \mReturn -> do
        case mReturn of
          Nothing -> log "Failed..."
          Just {sendCurrent,initOut: InitOut,unsubscribe} -> do
            log "Success InitOut"
            sendCurrent DeltaIn
        pure Nothing
    )


main :: Effect Unit
main = do
  env <- allocateDependencies false $ Authority Nothing $
    Both (NameAddress (RegName.unsafeFromString"localhost")) (Port.unsafeFromInt 3000)
    -- set timeout?
  unpackClient env (Topic ["foo"]) client
