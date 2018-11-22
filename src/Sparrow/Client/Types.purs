module Sparrow.Client.Types where

import Sparrow.Types (Topic, WSIncoming, WithTopic)

import Prelude
import Data.Argonaut (Json)
import Data.Maybe (Maybe)
import Data.Functor.Singleton (class SingletonFunctor, liftBaseWith_)
import Effect (Effect)
import Effect.Aff (Aff)
import Control.Monad.Reader (ReaderT (..))
import Control.Monad.Base (class MonadBase, liftBase)
import Control.Monad.Trans.Class (class MonadTrans)
import Control.Monad.Trans.Control (class MonadBaseControl)
import Queue (READ, WRITE)
import IxQueue as Ix




-- * Types

type Env m =
  { sendInitIn   :: Topic -> Json -> Aff (Maybe Json)
  , receiveQueue :: Ix.IxQueue (read :: READ, write :: WRITE) Json
  , rejectQueue :: Ix.IxQueue (read :: READ, write :: WRITE) Unit
  , sendDeltaIn :: WSIncoming (WithTopic Json) -> m Unit
  }


newtype SparrowClientT m a = SparrowClientT (ReaderT (Env m) m a)

runSparrowClientT :: forall m a. Env m -> SparrowClientT m a -> m a
runSparrowClientT env (SparrowClientT (ReaderT f)) = f env


instance functorSparrowClientT :: Functor m => Functor (SparrowClientT m) where
  map f (SparrowClientT (ReaderT g)) = SparrowClientT (ReaderT \r -> map f (g r))

instance applySparrowClientT :: Apply m => Apply (SparrowClientT m) where
  apply (SparrowClientT (ReaderT f)) (SparrowClientT (ReaderT g)) = SparrowClientT (ReaderT \r -> apply (f r) (g r))

instance applicativeSparrowClientT :: Applicative m => Applicative (SparrowClientT m) where
  pure x = SparrowClientT (ReaderT \_ -> pure x)

instance bindSparrowClientT :: Bind m => Bind (SparrowClientT m) where
  bind (SparrowClientT (ReaderT g)) f = SparrowClientT $ ReaderT \r ->
    bind (g r) (runSparrowClientT r <<< f)

instance monadSparrowClientT :: Monad m => Monad (SparrowClientT m)

instance monadTransSparrowClientT :: MonadTrans SparrowClientT where
  lift x = SparrowClientT (ReaderT \_ -> x)


ask' :: forall m. Applicative m => SparrowClientT m (Env m)
ask' = SparrowClientT $ ReaderT \r -> pure r



-- * Functions

registerSubscription :: forall m stM
                      . MonadBaseControl Effect m stM
                     => SingletonFunctor stM
                     => Env m
                     -> Topic -- ^ Subscription topic
                     -> (Json -> m Unit) -- ^ onDeltaOut
                     -> m Unit -- ^ onReject
                     -> m Unit
registerSubscription {rejectQueue,receiveQueue} topic onDeltaOut onReject = liftBaseWith_ \runM -> do
  Ix.on receiveQueue (show topic) (runM <<< onDeltaOut)
  Ix.once rejectQueue (show topic) \_ -> do
    void $ Ix.del receiveQueue (show topic)
    runM onReject

removeSubscription :: forall m
                    . MonadBase Effect m
                   => Env m -> Topic -> m Unit
removeSubscription {rejectQueue,receiveQueue} topic = liftBase $ do
  void $ Ix.del rejectQueue (show topic)
  void $ Ix.del receiveQueue (show topic)

callReject :: forall m
            . MonadBase Effect m
           => Env m -> Topic -> m Unit
callReject {rejectQueue} topic =
  liftBase (Ix.put rejectQueue (show topic) unit)

callOnReceive :: forall m
               . MonadBase Effect m
              => Env m -> Topic -> Json -> m Unit
callOnReceive {receiveQueue} topic v =
  liftBase (Ix.put receiveQueue (show topic) v)

