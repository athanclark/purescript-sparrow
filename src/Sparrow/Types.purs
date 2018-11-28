-- | This module defines the data types used by the protocol over the wire, and the definition of
-- | a user-level "client" that can handle a fully specified `initIn`, `initOut`, `deltaIn` and `deltaOut`
-- | transmission schema for a topic. Generally this module should be considered "internal".


module Sparrow.Types where

import Sparrow.Session (SessionID)

import Prelude
import Data.Maybe (Maybe (..))
import Data.Either (Either (..))
import Data.Argonaut (class DecodeJson, class EncodeJson, decodeJson, encodeJson, fail, (.?), (:=), (~>), jsonEmptyObject)
import Data.Argonaut.JSONVoid (JSONVoid)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Eq (genericEq)
import Data.Generic.Rep.Ord (genericCompare)
import Data.Generic.Rep.Show (genericShow)
import Data.List as List
import Data.String (joinWith)
import Data.String.NonEmpty (NonEmptyString)
import Data.String.NonEmpty as StringNE
import Data.String.Yarn (class IsString)
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as ArrayNE
import URI.Path (Path (..))
import URI.Path.Segment as Segment
import Control.Alternative ((<|>))
import Effect (Effect)
import Effect.Aff (Fiber)
import Text.Parsing.StringParser (Parser, runParser)
import Text.Parsing.StringParser.Combinators (sepBy)
import Text.Parsing.StringParser.CodePoints (regex, char)
import Partial.Unsafe (unsafePartial)



type ClientReturn initOut deltaIn =
  { sendCurrent   :: deltaIn -> Effect Unit -- TODO was vs. can't be successful?
  , initOut       :: initOut
  , unsubscribe   :: Effect Unit
  }

type ClientArgs initIn initOut deltaIn deltaOut =
  { receive  :: ClientReturn initOut deltaIn -> deltaOut -> Effect Unit
  , initIn   :: initIn
  , onReject :: Effect Unit -- ^ From a delta rejection, not init one
  }

type Client initIn initOut deltaIn deltaOut =
  ( ClientArgs initIn initOut deltaIn deltaOut
    -> (Maybe (ClientReturn initOut deltaIn) -> Effect (Maybe (Fiber Unit))) -- for Eff compatability
    -> Effect Unit
    ) -> Effect Unit

staticClient :: forall initIn initOut
              . ((initIn -> (Maybe initOut -> Effect Unit) -> Effect Unit) -> Effect Unit) -- ^ Invoke
             -> Client initIn initOut JSONVoid JSONVoid
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

newtype Topic = Topic (NonEmptyArray NonEmptyString)

topicToPath :: Topic -> Path
topicToPath (Topic xs) = Path
  ([ Segment.unsafeSegmentFromString "dependencies"
   ] <> (Segment.unsafeSegmentFromString <<< StringNE.toString <$> ArrayNE.toArray xs))

derive instance genericTopic :: Generic Topic _

instance showTopic :: Show Topic where
  show (Topic t) = joinWith "/" (StringNE.toString <$> ArrayNE.toArray t)

instance eqTopic :: Eq Topic where
  eq = genericEq

instance ordTopic :: Ord Topic where
  compare = genericCompare


instance decodeJsonTopic :: DecodeJson Topic where
  decodeJson json = do
    s <- decodeJson json
    case runParser breaker s of
      Left e -> fail e
      Right x -> case ArrayNE.fromArray x of
        Nothing -> fail "empty topic set"
        Just x' -> pure $ unsafePartial $ Topic $ StringNE.unsafeFromString <$> x'
    where
      breaker :: Parser (Array String)
      breaker = List.toUnfoldable <$> regex "[^\\/]*" `sepBy` char '/'

instance encodeJsonTopic :: EncodeJson Topic where
  encodeJson t = encodeJson (show t)

instance isStringTopic :: IsString Topic where
  fromString s = unsafePartial $
    case runParser breaker s of
      Right x -> case ArrayNE.fromArray x of
        Just x' -> Topic $ StringNE.unsafeFromString <$> x'
    where
      breaker :: Parser (Array String)
      breaker = List.toUnfoldable <$> regex "[^\\/]*" `sepBy` char '/'


-- * HTTP


newtype WithSessionID a = WithSessionID
  { sessionID :: SessionID
  , content   :: a
  }

derive instance genericWithSessionID :: Generic a b => Generic (WithSessionID a) _

instance eqWithSessionID :: (Eq a, Generic a b) => Eq (WithSessionID a) where
  eq = genericEq

instance showWithSessionID :: (Show a, Generic a b) => Show (WithSessionID a) where
  show = genericShow

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

derive instance genericInitResponse :: Generic a b => Generic (InitResponse a) _

instance eqInitResponse :: (Eq a, Generic a b) => Eq (InitResponse a) where
  eq = genericEq

instance showInitResponse :: (Show a, Generic a b) => Show (InitResponse a) where
  show = genericShow

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


derive instance genericWithTopic :: Generic a b => Generic (WithTopic a) _

instance eqWithTopic :: (Eq a, Generic a b) => Eq (WithTopic a) where
  eq = genericEq

instance showWithTopic :: (Show a, Generic a b) => Show (WithTopic a) where
  show = genericShow

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

derive instance genericWSHTTPResponse :: Generic WSHTTPResponse _

instance eqWSHTTPResponse :: Eq WSHTTPResponse where
  eq = genericEq

instance showWSHTTPResponse :: Show WSHTTPResponse where
  show = genericShow

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

derive instance genericWSIncoming :: Generic a b => Generic (WSIncoming a) _

instance eqWSIncoming :: (Eq a, Generic a b) => Eq (WSIncoming a) where
  eq = genericEq

instance showWSIncoming :: (Show a, Generic a b) => Show (WSIncoming a) where
  show = genericShow

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

derive instance genericWSOutgoing :: Generic a b => Generic (WSOutgoing a) _

instance eqWSOutgoing :: (Eq a, Generic a b) => Eq (WSOutgoing a) where
  eq = genericEq

instance showWSOutgoing :: (Show a, Generic a b) => Show (WSOutgoing a) where
  show = genericShow

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
