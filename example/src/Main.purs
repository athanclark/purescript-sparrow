module Main where

import Prelude
import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple (..))
import Data.Argonaut (class EncodeJson, class DecodeJson, encodeJson, decodeJson, fail)
import Data.URI (Authority (..), Host (..), Port (..))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (newRef, readRef, modifyRef)
import Control.Monad.Eff.Console (CONSOLE, log)

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

client :: Client _ (Eff _) InitIn InitOut DeltaIn DeltaOut
client call = do
  log "Calling..."
  count <- newRef 0
  call
    { initIn: InitIn
    , receive: \{sendCurrent,initOut,unsubscribe} DeltaOut -> do
        log "Received DeltaOut..."
        modifyRef count (\x -> x + 1)
        c <- readRef count
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


main :: Eff _ Unit
main = do
  allocateDependencies false (Authority Nothing [Tuple (NameAddress "localhost") (Just $ Port 3000)]) $ do
    -- set timeout?
    unpackClient (Topic ["foo"]) client
