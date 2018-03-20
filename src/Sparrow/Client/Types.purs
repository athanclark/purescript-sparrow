module Sparrow.Client.Types where

import Sparrow.Types (Topic, WSIncoming, WithTopic)

import Prelude
import Data.Argonaut (Json)
import Data.Maybe (Maybe)
import Data.Functor.Singleton (class SingletonFunctor, liftBaseWith_)
import Control.Monad.Aff (Aff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (REF)
import Control.Monad.Reader (ReaderT (..))
import Control.Monad.Base (class MonadBase, liftBase)
import Control.Monad.Trans.Class (class MonadTrans)
import Control.Monad.Trans.Control (class MonadBaseControl)
import Queue (READ, WRITE)
import IxQueue as Ix



registerSubscription :: forall m stM eff
                      . MonadBaseControl (Eff (ref :: REF | eff)) m stM
                     => SingletonFunctor stM
                     => Env (ref :: REF | eff) m -> Topic -> (Json -> m Unit) -> m Unit -> m Unit
registerSubscription {rejectQueue,receiveQueue} topic onDeltaOut onReject = liftBaseWith_ \runM -> do
  Ix.onIxQueue receiveQueue (show topic) (runM <<< onDeltaOut)
  Ix.onceIxQueue rejectQueue (show topic) \_ -> do
    void $ Ix.delIxQueue receiveQueue (show topic)
    runM onReject

removeSubscription :: forall m eff
                    . MonadBase (Eff (ref :: REF | eff)) m
                   => Env (ref :: REF | eff) m -> Topic -> m Unit
removeSubscription {rejectQueue,receiveQueue} topic = liftBase $ do
  void $ Ix.delIxQueue rejectQueue (show topic)
  void $ Ix.delIxQueue receiveQueue (show topic)

callReject :: forall m eff
            . MonadBase (Eff (ref :: REF | eff)) m
           => Env (ref :: REF | eff) m -> Topic -> m Unit
callReject {rejectQueue} topic =
  liftBase (Ix.putIxQueue rejectQueue (show topic) unit)

callOnReceive :: forall m eff
               . MonadBase (Eff (ref :: REF | eff)) m
              => Env (ref :: REF | eff) m -> Topic -> Json -> m Unit
callOnReceive {receiveQueue} topic v =
  liftBase (Ix.putIxQueue receiveQueue (show topic) v)


type Env eff m =
  { sendInitIn   :: Topic -> Json -> Aff eff (Maybe Json)
  , receiveQueue :: Ix.IxQueue (read :: READ, write :: WRITE) eff Json
  , rejectQueue :: Ix.IxQueue (read :: READ, write :: WRITE) eff Unit
  , sendDeltaIn :: WSIncoming (WithTopic Json) -> m Unit
  }


newtype SparrowClientT eff m a = SparrowClientT (ReaderT (Env eff m) m a)

runSparrowClientT :: forall eff m a. Env eff m -> SparrowClientT eff m a -> m a
runSparrowClientT env (SparrowClientT (ReaderT f)) = f env


instance functorSparrowClientT :: Functor m => Functor (SparrowClientT eff m) where
  map f (SparrowClientT (ReaderT g)) = SparrowClientT (ReaderT \r -> map f (g r))

instance applySparrowClientT :: Apply m => Apply (SparrowClientT eff m) where
  apply (SparrowClientT (ReaderT f)) (SparrowClientT (ReaderT g)) = SparrowClientT (ReaderT \r -> apply (f r) (g r))

instance applicativeSparrowClientT :: Applicative m => Applicative (SparrowClientT eff m) where
  pure x = SparrowClientT (ReaderT \_ -> pure x)

instance bindSparrowClientT :: Bind m => Bind (SparrowClientT eff m) where
  bind (SparrowClientT (ReaderT g)) f = SparrowClientT $ ReaderT \r ->
    bind (g r) (runSparrowClientT r <<< f)

instance monadSparrowClientT :: Monad m => Monad (SparrowClientT eff m)

instance monadTransSparrowClientT :: MonadTrans (SparrowClientT eff) where
  lift x = SparrowClientT (ReaderT \_ -> x)


ask' :: forall eff m. Applicative m => SparrowClientT eff m (Env eff m)
ask' = SparrowClientT $ ReaderT \r -> pure r
