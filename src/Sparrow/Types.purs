module Sparrow.Types where

import Sparrow.Session (SessionID)

import Prelude
import Data.Maybe (Maybe (..))
import Data.Either (Either (..))
import Data.Argonaut (class DecodeJson, class EncodeJson, decodeJson, encodeJson, fail, (.?), (:=), (~>), jsonEmptyObject)
import Data.Generic (class Generic, gEq, gShow, gCompare)
import Data.List as List
import Data.String (joinWith)
import Control.Alternative ((<|>))
import Control.Monad.Aff (Fiber)
import Text.Parsing.StringParser (Parser, runParser)
import Text.Parsing.StringParser.Combinators (sepBy)
import Text.Parsing.StringParser.String (regex, char)



type ClientReturn m initOut deltaIn =
  { sendCurrent   :: deltaIn -> m Unit -- was vs. can't be successful?
  , initOut       :: initOut
  , unsubscribe   :: m Unit
  }

type ClientArgs m initIn initOut deltaIn deltaOut =
  { receive  :: ClientReturn m initOut deltaIn -> deltaOut -> m Unit
  , initIn   :: initIn
  , onReject :: m Unit -- ^ From a delta rejection, not init one
  }

type Client eff m initIn initOut deltaIn deltaOut =
  ( ClientArgs m initIn initOut deltaIn deltaOut
    -> (Maybe (ClientReturn m initOut deltaIn) -> m (Maybe (Fiber eff Unit))) -- for Eff compatability
    -> m Unit
    ) -> m Unit

staticClient :: forall eff m initIn initOut
              . Monad m
             => ((initIn -> (Maybe initOut -> m Unit) -> m Unit) -> m Unit) -- ^ Invoke
             -> Client eff m initIn initOut JSONVoid JSONVoid
staticClient f invoke = f \initIn onInitOut -> invoke
  { receive: \_ _ -> pure unit
  , initIn
  , onReject: pure unit
  }
  ( \mReturn -> do
       case mReturn of
         Nothing -> onInitOut Nothing
         Just {initOut,unsubscribe} -> do
           unsubscribe
           onInitOut (Just initOut)
       pure Nothing
  )




-- * Topic

newtype Topic = Topic (Array String)

derive instance genericTopic :: Generic Topic

instance showTopic :: Show Topic where
  show = gShow

instance eqTopic :: Eq Topic where
  eq = gEq

instance ordTopic :: Ord Topic where
  compare = gCompare


instance decodeJsonTopic :: DecodeJson Topic where
  decodeJson json = do
    s <- decodeJson json
    case runParser breaker s of
      Left e -> fail e
      Right x -> pure (Topic x)
    where
      breaker :: Parser (Array String)
      breaker = List.toUnfoldable <$> regex "[^\\/]*" `sepBy` char '/'

instance encodeJsonTopic :: EncodeJson Topic where
  encodeJson (Topic t) = encodeJson (joinWith "/" t)



-- * HTTP

data JSONVoid

instance encodeJsonJSONVoid :: EncodeJson JSONVoid where
  encodeJson _ = encodeJson ""

instance decodeJsonJSONVoid :: DecodeJson JSONVoid where
  decodeJson _ = fail "JSONVoid"


newtype WithSessionID a = WithSessionID
  { sessionID :: SessionID
  , content   :: a
  }

derive instance genericWithSessionID :: Generic a => Generic (WithSessionID a)

instance eqWithSessionID :: (Eq a, Generic a) => Eq (WithSessionID a) where
  eq = gEq

instance showWithSessionID :: (Show a, Generic a) => Show (WithSessionID a) where
  show = gShow

instance encodeJsonWithSessionID :: EncodeJson a => EncodeJson (WithSessionID a) where
  encodeJson (WithSessionID {sessionID,content})
    =  "sessionID" := sessionID
    ~> "content" := content
    ~> jsonEmptyObject

instance decodeJsonWithSessionID :: DecodeJson a => DecodeJson (WithSessionID a) where
  decodeJson json = do
    o <- decodeJson json
    sessionID <- o .? "sessionID"
    content <- o .? "content"
    pure $ WithSessionID {sessionID,content}


data InitResponse a
  = InitBadEncoding String
  | InitDecodingError String -- when manually decoding the content, casted
  | InitRejected
  | InitResponse a

derive instance genericInitResponse :: Generic a => Generic (InitResponse a)

instance eqInitResponse :: (Eq a, Generic a) => Eq (InitResponse a) where
  eq = gEq

instance showInitResponse :: (Show a, Generic a) => Show (InitResponse a) where
  show = gShow

instance encodeJsonInitResponse :: EncodeJson a => EncodeJson (InitResponse a) where
  encodeJson x = case x of
    InitBadEncoding y -> "error" := ("badRequest" := y ~> jsonEmptyObject) ~> jsonEmptyObject
    InitDecodingError y -> "error" := ("decoding" := y ~> jsonEmptyObject) ~> jsonEmptyObject
    InitRejected -> "error" := "rejected" ~> jsonEmptyObject
    InitResponse y -> "content" := y ~> jsonEmptyObject

instance decodeJsonInitResponse :: DecodeJson a => DecodeJson (InitResponse a) where
  decodeJson json = do
    o <- decodeJson json
    let error' = do
          json' <- o .? "error"
          let errorO = do
                o' <- decodeJson json'
                let badRequest = InitBadEncoding <$> o' .? "badRequest"
                    decoding = InitDecodingError <$> o' .? "decoding"
                badRequest <|> decoding
              errorS = do
                s <- decodeJson json'
                if s == "rejected" then pure InitRejected else fail "Not an InitResponse"
          errorO <|> errorS
        response = InitResponse <$> o .? "content"
    response <|> error'


-- WebSocket

newtype WithTopic a = WithTopic
  { topic   :: Topic
  , content :: a
  }


derive instance genericWithTopic :: Generic a => Generic (WithTopic a)

instance eqWithTopic :: (Eq a, Generic a) => Eq (WithTopic a) where
  eq = gEq

instance showWithTopic :: (Show a, Generic a) => Show (WithTopic a) where
  show = gShow

instance encodeJsonWithTopic :: EncodeJson a => EncodeJson (WithTopic a) where
  encodeJson (WithTopic {topic,content})
    =  "topic" := topic
    ~> "content" := content
    ~> jsonEmptyObject

instance decodeJsonWithTopic :: DecodeJson a => DecodeJson (WithTopic a) where
  decodeJson json = do
    o <- decodeJson json
    topic <- o .? "topic"
    content <- o .? "content"
    pure $ WithTopic {topic,content}




data WSHTTPResponse
  = NoSessionID

derive instance genericWSHTTPResponse :: Generic WSHTTPResponse

instance eqWSHTTPResponse :: Eq WSHTTPResponse where
  eq = gEq

instance showWSHTTPResponse :: Show WSHTTPResponse where
  show = gShow

instance decodeJsonWSHTTPResponse :: DecodeJson WSHTTPResponse where
  decodeJson json = do
    o <- decodeJson json
    s <- o .? "error"
    if s == "no sessionID query parameter" then pure NoSessionID else fail "Not a WSHTTPResponse"

instance encodeJsonWSHTTPResponse :: EncodeJson WSHTTPResponse where
  encodeJson NoSessionID = "error" := "no sessionID query parameter" ~> jsonEmptyObject


data WSIncoming a
  = WSUnsubscribe Topic
  | WSIncoming a

derive instance genericWSIncoming :: Generic a => Generic (WSIncoming a)

instance eqWSIncoming :: (Eq a, Generic a) => Eq (WSIncoming a) where
  eq = gEq

instance showWSIncoming :: (Show a, Generic a) => Show (WSIncoming a) where
  show = gShow

instance encodeJsonWSIncoming :: EncodeJson a => EncodeJson (WSIncoming a) where
  encodeJson x = case x of
    WSUnsubscribe topic -> "unsubscribe" := topic ~> jsonEmptyObject
    WSIncoming y -> "content" := y ~> jsonEmptyObject

instance decodeJsonWSIncoming :: DecodeJson a => DecodeJson (WSIncoming a) where
  decodeJson json = do
    o <- decodeJson json
    let usub = WSUnsubscribe <$> o .? "unsubscribe"
        incoming = WSIncoming <$> o .? "content"
    usub <|> incoming

data WSOutgoing a
  = WSTopicsSubscribed (Array Topic)
  | WSTopicAdded Topic
  | WSTopicRemoved Topic
  | WSTopicRejected Topic
  | WSDecodingError String
  | WSOutgoing a

derive instance genericWSOutgoing :: Generic a => Generic (WSOutgoing a)

instance eqWSOutgoing :: (Eq a, Generic a) => Eq (WSOutgoing a) where
  eq = gEq

instance showWSOutgoing :: (Show a, Generic a) => Show (WSOutgoing a) where
  show = gShow

instance encodeJsonWSOutgoing :: EncodeJson a => EncodeJson (WSOutgoing a) where
  encodeJson x = case x of
    WSDecodingError e -> "error" := ("decoding" := e ~> jsonEmptyObject) ~> jsonEmptyObject
    WSTopicsSubscribed subs -> "subs" := ("init" := subs ~> jsonEmptyObject) ~> jsonEmptyObject
    WSTopicAdded sub -> "subs" := ("add" := sub ~> jsonEmptyObject) ~> jsonEmptyObject
    WSTopicRemoved sub -> "subs" := ("del" := sub ~> jsonEmptyObject) ~> jsonEmptyObject
    WSTopicRejected sub -> "subs" := ("reject" := sub ~> jsonEmptyObject) ~> jsonEmptyObject
    WSOutgoing y -> "content" := y ~> jsonEmptyObject

instance decodeJsonWSOutgoing :: DecodeJson a => DecodeJson (WSOutgoing a) where
  decodeJson json = do
    o <- decodeJson json
    let content = WSOutgoing <$> o .? "content"
        error' = do
          o' <- o .? "error"
          WSDecodingError <$> o' .? "decoding"
        subs = do
          o' <- o .? "subs"
          let init = WSTopicsSubscribed <$> o' .? "init"
              add = WSTopicAdded <$> o' .? "add"
              del = WSTopicRemoved <$> o' .? "del"
              reject = WSTopicRejected <$> o' .? "reject"
          init <|> add <|> del <|> reject
    content <|> error' <|> subs
