module Sparrow.Client where

import Sparrow.Client.Types (SparrowClientT, ask', removeSubscription, registerSubscription, callReject, callOnReceive, Env)
import Sparrow.Types (Topic (..), Client, ClientReturn, ClientArgs, WSIncoming (..), WSOutgoing (..), WithTopic (..), WithSessionID (..))
import Sparrow.Session (SessionID (..))
import Sparrow.Ping (PingPong (..))

import Prelude

import Data.List (List (..))
import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple (..))
import Data.Either (Either (..))
import Data.Array as Array
import Data.URI (URI (..), Authority, HierarchicalPart (..), Query (..), Scheme (..))
import Data.URI.URI as URI
import Data.Functor.Singleton (class SingletonFunctor, liftBaseWith_)
import Data.Typelevel.Undefined (undefined)
import Data.Path.Pathy ((</>), rootDir, dir, file)
import Data.Argonaut (Json, class EncodeJson, class DecodeJson, decodeJson, encodeJson, jsonParser)
import Data.UUID (GENUUID, genUUID)
import Control.Monad.Aff (Fiber, runAff_, killFiber)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (REF, newRef, readRef, writeRef)
import Control.Monad.Eff.Exception (EXCEPTION, Error, throw, throwException, error)
import Control.Monad.Eff.Timer (TIMER, setInterval, clearInterval, setTimeout)
import Control.Monad.Base (class MonadBase, liftBase)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Control (class MonadBaseControl)
import Network.HTTP.Affjax (AJAX, post)
import Network.HTTP.StatusCode (StatusCode (..))
import Queue.One as One
import IxQueue (IxQueue)
import IxQueue as Ix
import WebSocket (WEBSOCKET, newWebSocket)


type Effects eff =
  ( ref :: REF
  , exception :: EXCEPTION
  | eff)


unpackClient :: forall eff m stM initIn initOut deltaIn deltaOut
              . MonadBaseControl (Eff (Effects eff)) m stM
             => SingletonFunctor stM
             => EncodeJson initIn
             => DecodeJson initOut
             => EncodeJson deltaIn
             => DecodeJson deltaOut
             => Topic
             -> Client (Effects eff) m initIn initOut deltaIn deltaOut
             -> SparrowClientT (Effects eff) m Unit
unpackClient topic client = do
  env@{sendInitIn,sendDeltaIn} <- ask'

  lift $ liftBaseWith_ \runM -> do
    threadVar <- newRef Nothing

    let go :: ClientArgs m initIn initOut deltaIn deltaOut
           -> (Maybe (ClientReturn m initOut deltaIn) -> m (Maybe (Fiber (Effects eff) Unit)))
           -> m Unit
        go {receive,initIn,onReject} onOpen = do

          let continue :: Either Error (Maybe Json) -> Eff (Effects eff) Unit
              continue me = case me of
                Left e -> throwException e
                Right mx -> case mx of
                  Nothing -> do
                    mThread <- runM (onOpen Nothing)
                    writeRef threadVar mThread
                  Just x -> case decodeJson x of
                    Left e -> throw e
                    Right (initOut :: initOut) -> do
                      let unsubscribe :: m Unit
                          unsubscribe = do
                            sendDeltaIn (WSUnsubscribe topic)
                            removeSubscription env topic
                          sendCurrent :: deltaIn -> m Unit
                          sendCurrent = \x ->
                            sendDeltaIn $ WSIncoming $ WithTopic {topic,content: encodeJson x}

                          return :: ClientReturn m initOut deltaIn
                          return =
                            { sendCurrent
                            , unsubscribe
                            , initOut
                            }

                          onDeltaOut :: Json -> m Unit
                          onDeltaOut v = case decodeJson v of
                            Left e -> liftBase (throw e)
                            Right (deltaOut :: deltaOut) -> receive return deltaOut

                      mThread <- runM $ do
                        registerSubscription env topic onDeltaOut $ do
                          onReject
                          liftBase $ do
                            mThread <- readRef threadVar
                            case mThread of
                              Nothing -> pure unit
                              Just thread -> runAff_ (\_ -> pure unit) (killFiber (error "Killing thread") thread)

                        onOpen (Just return)

                      writeRef threadVar mThread

          liftBase $ runAff_ continue $ sendInitIn topic $ encodeJson initIn

    runM (client go)


type Effects' eff =
  ( ref :: REF
  , exception :: EXCEPTION
  , ajax :: AJAX
  , timer :: TIMER
  , ws :: WEBSOCKET
  , uuid :: GENUUID
  | eff)


allocateDependencies :: forall m stM a eff
                      . MonadBase (Eff (Effects' eff)) m
                     => MonadBaseControl (Eff (Effects' eff)) m stM
                     => SingletonFunctor stM
                     => Boolean -- TLS
                     -> Authority -- Hostname
                     -> SparrowClientT (Effects' eff) m a
                     -> m Unit
allocateDependencies tls auth client = liftBaseWith_ $ \runM -> do
  let httpURI :: Topic -> URI
      httpURI (Topic topic) = URI (Just $ Scheme $ if tls then "https" else "http")
                                  (HierarchicalPart (Just auth) $ Just $ Right $ case Array.unsnoc topic of
                                      Nothing -> undefined -- throw
                                      Just {init,last} ->
                                        let pre = Array.foldl (\acc x -> acc </> dir x) (rootDir </> dir "dependencies") init
                                        in  pre </> file last
                                  )
                                  Nothing Nothing

  sessionID <- SessionID <$> genUUID

  ( toWS :: One.Queue _ _ (WSIncoming (WithTopic Json))
    ) <- One.newQueue
  ( rejectQueue :: IxQueue _ _ Unit
    ) <- Ix.newIxQueue
  ( receiveQueue :: IxQueue _ _ Json
    ) <- Ix.newIxQueue


  let env :: Env (Effects' eff) m
      env =
        { sendInitIn: \topic initIn -> do
            -- TODO pending topics added
            {status,response} <- post (URI.print $ httpURI topic) $ encodeJson $ WithSessionID
              { sessionID
              , content: initIn
              }

            case status of
              StatusCode code
                | code == 200 -> pure (Just response)
                | otherwise -> pure Nothing
        , sendDeltaIn: liftBase <<< One.putQueue toWS
        , rejectQueue
        , receiveQueue
        }


  pingingThread <- newRef Nothing
  backoff <- One.newQueue
  One.putQueue backoff Nothing
  One.onQueue backoff \mB -> do

    let close :: Eff (Effects' eff) Unit
        close = do
          mThread <- readRef pingingThread
          case mThread of
            Nothing -> pure unit
            Just thread -> clearInterval thread
          case mB of
            Nothing -> One.putQueue backoff (Just 1000)
            Just ms -> One.putQueue backoff (Just (ms * 2))

        call :: Eff (Effects' eff) Unit
        call = newWebSocket
                  { url:  let x = URI (Just $ Scheme $ if tls then "wss" else "ws")
                                    (HierarchicalPart (Just auth) $ Just $ Right $ rootDir </> file "dependencies")
                                    (Just $ Query $ Cons (Tuple "sessionID" $ Just $ show sessionID) Nil)
                                    Nothing
                          in  URI.print x
                  , protocols: []
                  , continue: \_ ->
                    { onopen: \{send} -> do
                        thread <- setInterval (1000 * 10) $
                          send $ show $ encodeJson (PingPong Nothing :: PingPong Unit)
                        writeRef pingingThread (Just thread)
                        One.onQueue toWS (send <<< show <<< encodeJson <<< PingPong <<< Just)
                    , onmessage: \{send,close} r -> case jsonParser r >>= decodeJson of
                        Left e -> throw e
                        Right x -> case x of
                          PingPong Nothing -> pure unit
                          PingPong (Just x) -> case x of
                            WSTopicsSubscribed subs -> pure unit -- FIXME
                            WSTopicAdded sub -> pure unit -- FIXME
                            WSTopicRemoved sub -> pure unit
                            WSTopicRejected sub -> pure unit
                            WSDecodingError e -> pure unit
                            WSOutgoing (WithTopic {topic,content}) -> runM (callOnReceive env topic content)
                    , onclose: \{code,reason,wasClean} -> close
                    , onerror: \e -> close
                    }
                  }

    case mB of
      Nothing -> call
      Just ms -> void $ setTimeout ms call
