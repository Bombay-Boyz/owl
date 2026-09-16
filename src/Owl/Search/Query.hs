-- | Query lexing and parsing (master spec §15). Implemented as
-- precedence-respecting recursive descent, not a literal Pratt
-- operator-precedence table -- functionally identical for this fixed
-- three-level grammar (NOT highest, then AND, then OR, matching §15
-- exactly), but worth saying plainly rather than overclaiming the
-- technique.
--
-- Text-syntax scope: from:/to:/subject:/after:/before:/has:attachment/
-- is:unread, bare terms, and quoted phrases. Deliberately NOT
-- supporting in:<mailbox> or thread:<id> yet -- InMailbox needs a
-- mailbox-name -> MailboxId resolution that depends on the mailbox
-- catalog (§17), which parseQuery's pure Text -> Either SearchParseError
-- Query signature has no room to carry; InMailbox/InThread remain
-- fully implemented in Predicate/matches/index execution, just not
-- reachable through typed query text in this pass.
module Owl.Search.Query
  ( Field (..)
  , QueryToken (..)
  , SearchLexError (..)
  , SearchParseError (..)
  , lexQuery
  , parseQuery
  , parseQueryLive
  ) where

import Data.Char (isSpace)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import Owl.Domain.Address (mkEmailAddress)
import Owl.Search.Predicate (Phrase (..), Predicate (..), Query)

data Field = FieldFrom | FieldTo | FieldSubject | FieldAfter | FieldBefore | FieldHas | FieldIs
  deriving stock (Eq, Show)

data QueryToken
  = TokField Field
  | TokText Text
  | TokPhrase Text
  | TokAnd
  | TokOr
  | TokNot
  | TokLParen
  | TokRParen
  deriving stock (Eq, Show)

data SearchLexError
  = UnterminatedQuote Text
  | UnknownField Text
  deriving stock (Eq, Show)

data SearchParseError
  = LexingFailed SearchLexError
  | UnexpectedEndOfQuery
  | UnexpectedToken QueryToken
  | ExpectedFieldValue Field
  | InvalidDate Text
  | InvalidFieldValue Field Text
  | UnbalancedParens
  deriving stock (Eq, Show)

-- | O(tokens): a single left-to-right scan.
lexQuery :: Text -> Either SearchLexError [QueryToken]
lexQuery = go . Text.strip
  where
    go t
      | Text.null t = Right []
      | Text.head t == '(' = (TokLParen :) <$> go (Text.strip (Text.tail t))
      | Text.head t == ')' = (TokRParen :) <$> go (Text.strip (Text.tail t))
      | Text.head t == '"' =
          let (phrase, rest) = Text.breakOn "\"" (Text.tail t)
          in if Text.null rest
               then Left (UnterminatedQuote t)
               else (TokPhrase phrase :) <$> go (Text.strip (Text.drop 1 rest))
      | otherwise =
          -- A word ends at whitespace OR at an unspaced paren -- so
          -- "is:unread)" lexes as the value "unread" followed by a
          -- separate TokRParen, not a value of "unread)".
          let (word, rest) = Text.break (\c -> isSpace c || c == '(' || c == ')') t
          in (++) <$> classify word <*> go (Text.strip rest)

    classify w
      | Text.toUpper w == "AND" = Right [TokAnd]
      | Text.toUpper w == "OR"  = Right [TokOr]
      | Text.toUpper w == "NOT" = Right [TokNot]
      | Text.any (== ':') w =
          let (fieldText, rest0) = Text.breakOn ":" w
              valueText = Text.drop 1 rest0
          in case fieldFromText fieldText of
               Nothing                    -> Left (UnknownField fieldText)
               Just field | Text.null valueText -> Right [TokField field]
                          | otherwise            -> Right [TokField field, TokText valueText]
      | otherwise = Right [TokText w]

fieldFromText :: Text -> Maybe Field
fieldFromText t = case Text.toLower t of
  "from"    -> Just FieldFrom
  "to"      -> Just FieldTo
  "subject" -> Just FieldSubject
  "after"   -> Just FieldAfter
  "before"  -> Just FieldBefore
  "has"     -> Just FieldHas
  "is"      -> Just FieldIs
  _         -> Nothing

type Tokens = [QueryToken]

parseQuery :: Text -> Either SearchParseError Query
parseQuery raw = do
  tokens <- either (Left . LexingFailed) Right (lexQuery raw)
  (predicate, remaining) <- parseOr tokens
  case remaining of
    []      -> Right predicate
    (t : _) -> Left (UnexpectedToken t)

-- Precedence, lowest to highest: Or > And > Not > Primary.
parseOr :: Tokens -> Either SearchParseError (Predicate, Tokens)
parseOr ts = parseAnd ts >>= uncurry go
  where
    go acc (TokOr : rest) = do
      (next, rest') <- parseAnd rest
      go (combine Or acc next) rest'
    go acc rest = Right (acc, rest)

parseAnd :: Tokens -> Either SearchParseError (Predicate, Tokens)
parseAnd ts = parseUnary ts >>= uncurry go
  where
    go acc (TokAnd : rest) = parseUnary rest >>= \(next, rest') -> go (combine And acc next) rest'
    go acc rest@(t : _) | continuesImplicitAnd t = parseUnary rest >>= \(next, rest') -> go (combine And acc next) rest'
    go acc rest = Right (acc, rest)

    continuesImplicitAnd t = t /= TokOr && t /= TokRParen

combine :: (NonEmpty Predicate -> Predicate) -> Predicate -> Predicate -> Predicate
combine ctor p1 p2 = ctor (p1 :| [p2])

parseUnary :: Tokens -> Either SearchParseError (Predicate, Tokens)
parseUnary (TokNot : rest) = do
  (p, rest') <- parseUnary rest
  Right (Not p, rest')
parseUnary ts = parsePrimary ts

parsePrimary :: Tokens -> Either SearchParseError (Predicate, Tokens)
parsePrimary [] = Left UnexpectedEndOfQuery
parsePrimary (TokLParen : rest) = do
  (p, rest') <- parseOr rest
  case rest' of
    (TokRParen : rest'') -> Right (p, rest'')
    _                    -> Left UnbalancedParens
parsePrimary (TokPhrase p : rest) = Right (bareTermPredicate p, rest)
parsePrimary (TokText w : rest)   = Right (bareTermPredicate w, rest)
parsePrimary (TokField field : rest) = case rest of
  (TokText value : rest') -> (\p -> (p, rest')) <$> fieldPredicate field value
  _                       -> Left (ExpectedFieldValue field)
parsePrimary (t : _) = Left (UnexpectedToken t)

-- | An unqualified term searches both subject and body, matching
-- common search-box convention (Gmail-style).
bareTermPredicate :: Text -> Predicate
bareTermPredicate w = Or (SubjectContains w :| [Body (Phrase w)])

fieldPredicate :: Field -> Text -> Either SearchParseError Predicate
fieldPredicate FieldFrom value = either (const (Left (InvalidFieldValue FieldFrom value))) (Right . From) (mkEmailAddress value)
fieldPredicate FieldTo value   = either (const (Left (InvalidFieldValue FieldTo value))) (Right . To) (mkEmailAddress value)
fieldPredicate FieldSubject value = Right (SubjectContains value)
fieldPredicate FieldAfter value  = After <$> parseDay value
fieldPredicate FieldBefore value = Before <$> parseDay value
fieldPredicate FieldHas value
  | Text.toLower value == "attachment" = Right HasAttachment
  | otherwise                          = Left (InvalidFieldValue FieldHas value)
fieldPredicate FieldIs value
  | Text.toLower value == "unread" = Right IsUnread
  | otherwise                      = Left (InvalidFieldValue FieldIs value)

parseDay :: Text -> Either SearchParseError Day
parseDay t = maybe (Left (InvalidDate t)) Right (parseTimeM True defaultTimeLocale "%Y-%m-%d" (Text.unpack t))

-- | Best-effort, total parse for live, incomplete search-as-you-type
-- input. Tries the strict parser first; on any lex/parse failure
-- (typically an unterminated quote or a dangling field with no value
-- yet), falls back to treating the whole raw input as one prefix-style
-- bare term rather than surfacing a syntax error mid-keystroke. This is
-- a deliberately simplified fallback, not true "expand this partial
-- word against the index" completion -- that is index-aware
-- autocomplete for the TUI layer to build on top of this, not
-- something a pure text parser can do alone.
parseQueryLive :: Text -> Query
parseQueryLive raw = case parseQuery raw of
  Right q -> q
  Left _
    | Text.null stripped -> Or (SubjectContains Text.empty :| [Body (Phrase Text.empty)])
    | otherwise           -> bareTermPredicate stripped
  where
    stripped = Text.strip raw
