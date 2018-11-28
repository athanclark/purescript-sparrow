module Sparrow.Client
  ( module Types
  , unpackClient
  , allocateDependencies
  ) where

import Sparrow.Client.Types (removeSubscription, registerSubscription, callReject, callOnReceive, Env)
import Sparrow.Types (Topic, Client, ClientReturn, ClientArgs, WSIncoming (..), WSOutgoing (..), WithTopic (..), WithSessionID (..), topicToPath)
import Sparrow.Types (Topic (..), Client, ClientReturn, ClientArgs) as Types
import Sparrow.Session (SessionID (..))
import Sparrow.Ping (PingPong (..))

import Prelude

import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple (..))
import Data.Either (Either (..))
import Data.Argonaut (Json, class EncodeJson, class DecodeJson, decodeJson, encodeJson, jsonParser, stringify)
import Data.UUID (genUUID)
import Data.Set (Set)
import Data.Set as Set
import URI (AbsoluteURI (..), Authority, HierarchicalPart (HierarchicalPartAuth), Query, Path (..), HierPath, UserInfo, Host, Port)
import URI.Scheme (unsafeFromString) as Scheme
import URI.AbsoluteURI (print) as AbsoluteURI
import URI.Extra.QueryPairs (QueryPairs (..), Key, Value, keyFromString, valueFromString)
import URI.Extra.QueryPairs (print) as QueryPairs
import URI.Path.Segment (unsafeSegmentFromString) as Segment
import URI.HostPortPair (HostPortPair)
import URI.HostPortPair (print) as HostPortPair
import Effect.Aff (Fiber, runAff_, killFiber)
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Console (warn, log)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Effect.Exception (Error, throw, throwException, error)
import Effect.Timer (setInterval, clearInterval, setTimeout)
import Affjax (post, printResponseFormatError)
import Affjax.RequestBody (RequestBody (Json))
import Affjax.ResponseFormat (json)
import Affjax.StatusCode (StatusCode (..))
import Queue (READ, WRITE)
import Queue.One as One
import IxQueue (IxQueue)
import IxQueue as Ix
import WebSocket (newWebSocket)



unpackClient :: forall initIn initOut deltaIn deltaOut
              . EncodeJson initIn
             => DecodeJson initOut
             => EncodeJson deltaIn
             => DecodeJson deltaOut
             => Env
             -> Topic
             -> Client initIn initOut deltaIn deltaOut
             -> Effect Unit
unpackClient env@{sendInitIn,sendDeltaIn} topic client = do
  threadVar <- Ref.new Nothing

  let go :: ClientArgs initIn initOut deltaIn deltaOut
          -> (Maybe (ClientReturn initOut deltaIn) -> Effect (Maybe (Fiber Unit)))
          -> Effect Unit
      go {receive,initIn,onReject} onOpen = do

        let continue :: Either Error (Maybe Json) -> Effect Unit
            continue me = case me of
              Left e -> throwException e
              Right mx -> case mx of
                Nothing -> do
                  mThread <- onOpen Nothing
                  Ref.write mThread threadVar
                Just json -> case decodeJson json of
                  Left e -> throw ("Json deserialization failed for initOut: " <> e)
                  Right (initOut :: initOut) -> do
                    let unsubscribe :: Effect Unit
                        unsubscribe = do
                          sendDeltaIn (WSUnsubscribe topic)
                          removeSubscription env topic

                        sendCurrent :: deltaIn -> Effect Unit
                        sendCurrent x =
                          sendDeltaIn $ WSIncoming $ WithTopic {topic,content: encodeJson x}

                        return :: ClientReturn initOut deltaIn
                        return =
                          { sendCurrent
                          , unsubscribe
                          , initOut
                          }

                        onDeltaOut :: Json -> Effect Unit
                        onDeltaOut v = case decodeJson v of
                          Left e -> throw e
                          Right (deltaOut :: deltaOut) -> receive return deltaOut

                    registerSubscription env topic onDeltaOut $ do
                      onReject
                      mThread <- Ref.read threadVar
                      case mThread of
                        Nothing -> pure unit
                        Just thread -> runAff_ (\_ -> pure unit) (killFiber (error "Killing thread") thread)

                    mThread <- onOpen (Just return)
                    Ref.write mThread threadVar

        runAff_ continue $ sendInitIn topic $ encodeJson initIn

  client go



allocateDependencies :: Boolean -- ^ TLS
                     -> Authority UserInfo (HostPortPair Host Port) -- ^ Hostname
                     -> Effect Env
allocateDependencies tls auth = do
  let httpURI :: Topic -> AbsoluteURI UserInfo (HostPortPair Host Port) Path HierPath Query
      httpURI topic =
        AbsoluteURI
          (Scheme.unsafeFromString $ if tls then "https" else "http")
          (HierarchicalPartAuth auth (topicToPath topic))
          Nothing

  sessionID <- SessionID <$> genUUID

  ( toWS :: One.Queue (read :: READ, write :: WRITE) (WSIncoming (WithTopic Json))
    ) <- One.new
  ( rejectQueue :: IxQueue (read :: READ, write :: WRITE) Unit
    ) <- Ix.new
  ( receiveQueue :: IxQueue (read :: READ, write :: WRITE) Json
    ) <- Ix.new
  ( pendingTopicsAdded :: Ref (Set Topic)
    ) <- Ref.new Set.empty
  ( pendingTopicsRemoved :: Ref (Set Topic)
    ) <- Ref.new Set.empty


  let env :: Env
      env =
        { sendInitIn: \topic initIn -> do
            _ <- liftEffect $ Ref.modify (Set.insert topic) pendingTopicsAdded
            let uriOpts =
                  { printUserInfo: identity
                  , printHosts: HostPortPair.print identity identity
                  , printPath: identity
                  , printHierPath: identity
                  , printQuery: identity
                  }
                uri = AbsoluteURI.print uriOpts (httpURI topic)
            {status,statusText,body} <- post json uri $ Json $ encodeJson $ WithSessionID
              { sessionID
              , content: initIn
              }

            case status of
              StatusCode code
                | code == 200 -> case body of
                    Left e -> Nothing <$ liftEffect (warn (printResponseFormatError e))
                    Right response -> pure (Just response)
                | otherwise ->
                    let err = "http request bad status: " <> show code <> " " <> statusText
                    in  Nothing <$ liftEffect (warn err)
        , sendDeltaIn: \x -> do
            case x of
              WSUnsubscribe sub -> void $ Ref.modify (Set.insert sub) pendingTopicsRemoved
              _ -> pure unit
            One.put toWS x
        , rejectQueue
        , receiveQueue
        }


  pingingThread <- Ref.new Nothing
  backoff <- One.new
  One.put backoff Nothing
  One.on backoff \mB -> do

    let close :: Effect Unit
        close = do
          mThread <- Ref.read pingingThread
          case mThread of
            Nothing -> pure unit
            Just thread -> clearInterval thread
          case mB of
            Nothing -> One.put backoff (Just 1000)
            Just ms -> One.put backoff (Just (ms * 2))

        call :: Effect Unit
        call = newWebSocket
                  { url:  let x :: AbsoluteURI UserInfo (HostPortPair Host Port) Path HierPath (QueryPairs Key Value)
                              x = AbsoluteURI
                                    (Scheme.unsafeFromString $ if tls then "wss" else "ws")
                                    (HierarchicalPartAuth auth $ Path [Segment.unsafeSegmentFromString "dependencies"])
                                    (Just $ QueryPairs [Tuple (keyFromString "sessionID") $ Just $ valueFromString $ show sessionID])
                              uriOpts =
                                { printUserInfo: identity
                                , printHosts: HostPortPair.print identity identity
                                , printPath: identity
                                , printHierPath: identity
                                , printQuery: QueryPairs.print identity identity
                                }
                          in  AbsoluteURI.print uriOpts x
                  , protocols: []
                  , continue: \_ ->
                    { onopen: \{send} -> do
                        thread <- setInterval (1000 * 10) $
                          send $ stringify $ encodeJson (PingPong Nothing :: PingPong Unit)
                        Ref.write (Just thread) pingingThread
                        One.on toWS (send <<< stringify <<< encodeJson <<< PingPong <<< Just)
                    , onmessage: \{send} r -> case jsonParser r >>= decodeJson of
                        Left e -> throw e
                        Right x -> case x of
                          PingPong Nothing -> pure unit
                          PingPong (Just y) -> case y of
                            WSTopicsSubscribed subs -> pure unit -- FIXME
                            WSTopicAdded sub -> do
                              pending <- Set.member sub <$> Ref.read pendingTopicsAdded
                              if pending
                                 then void $ Ref.modify (Set.delete sub) pendingTopicsAdded
                                 else warn $ "Unexpected topic added: " <> show sub
                            WSTopicRemoved sub -> do
                              pending <- Set.member sub <$> Ref.read pendingTopicsRemoved
                              if pending
                                 then void $ Ref.modify (Set.delete sub) pendingTopicsRemoved
                                 else warn $ "Unexpected topic removed: " <> show sub
                            WSTopicRejected sub -> callReject env sub
                            WSDecodingError e -> throw e
                            WSOutgoing (WithTopic {topic,content}) -> callOnReceive env topic content
                    , onclose: \{code,reason,wasClean} -> do
                        log $ "Closing sparrow socket: " <> show code <> ", reason: " <> show reason <> ", was clean: " <> show wasClean
                        close
                    , onerror: \e -> do
                        warn $ "Sparrow socket error: " <> show e
                        close
                    }
                  }

    case mB of
      Nothing -> call
      Just ms -> void (setTimeout ms call)

  pure env
