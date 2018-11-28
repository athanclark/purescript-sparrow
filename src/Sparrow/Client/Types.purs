-- | This module defines the programming environment required to run a sparrow client. This module should
-- | be considered internal w.r.t. the sparrow protocol.

module Sparrow.Client.Types where

import Sparrow.Types (Topic, WSIncoming, WithTopic)

import Prelude
import Data.Argonaut (Json)
import Data.Maybe (Maybe)
import Effect (Effect)
import Effect.Aff (Aff)
import Queue (READ, WRITE)
import IxQueue as Ix




-- * Types

-- | Represents the stored machinery necessary for a client connection to work with multiple topics
type Env =
  { sendInitIn   :: Topic -> Json -> Aff (Maybe Json) -- ^ `initIn -> Maybe initOut`
  , receiveQueue :: Ix.IxQueue (read :: READ, write :: WRITE) Json -- ^ `<- deltaOut`
  , rejectQueue  :: Ix.IxQueue (read :: READ, write :: WRITE) Unit -- ^ kill the subscription
  , sendDeltaIn  :: WSIncoming (WithTopic Json) -> Effect Unit -- ^ `deltaIn -> Unit`
  }


-- * Functions

-- | Add a subscription to the machinery
registerSubscription :: Env
                     -> Topic -- ^ Subscription topic
                     -> (Json -> Effect Unit) -- ^ onDeltaOut
                     -> Effect Unit -- ^ onReject
                     -> Effect Unit
registerSubscription {rejectQueue,receiveQueue} topic onDeltaOut onReject = do
  let topic' = show topic
  Ix.on receiveQueue topic' onDeltaOut
  Ix.once rejectQueue topic' \_ -> Ix.del receiveQueue topic' *> onReject

-- | Remove a subscription from the machinery
removeSubscription :: Env -> Topic -> Effect Unit
removeSubscription {rejectQueue,receiveQueue} topic = do
  let topic' = show topic
  void $ Ix.del rejectQueue topic'
  void $ Ix.del receiveQueue topic'

-- | Call the stored rejection mechanism
callReject :: Env -> Topic -> Effect Unit
callReject {rejectQueue} topic =
  Ix.put rejectQueue (show topic) unit

-- | Call the stored onReceive mechanism
callOnReceive :: Env -> Topic -> Json -> Effect Unit
callOnReceive {receiveQueue} topic v =
  Ix.put receiveQueue (show topic) v

