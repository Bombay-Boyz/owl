module Owl.Search.QuerySpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Test.Hspec

import Owl.Domain.Address (EmailAddress, mkEmailAddress)
import Owl.Search.Predicate
import Owl.Search.Query

expectAddr :: Text -> EmailAddress
expectAddr t = either (error . show) id (mkEmailAddress t)

isLexError :: Either SearchLexError [QueryToken] -> Bool
isLexError = either (const True) (const False)

isParseError :: Either SearchParseError a -> Bool
isParseError = either (const True) (const False)

isRightPred :: Either SearchParseError a -> Bool
isRightPred = either (const False) (const True)

spec :: Spec
spec = do
  describe "lexQuery" $ do
    it "lexes a field:value pair as two tokens" $
      lexQuery "from:alice" `shouldBe` Right [TokField FieldFrom, TokText "alice"]
    it "lexes a quoted phrase as one token" $
      lexQuery "\"annual report\"" `shouldBe` Right [TokPhrase "annual report"]
    it "fails on an unterminated quote" $
      lexQuery "\"annual report" `shouldSatisfy` isLexError
    it "fails on an unknown field" $
      lexQuery "bogus:value" `shouldSatisfy` isLexError

  describe "parseQuery" $ do
    it "parses a bare term as subject-or-body" $
      parseQuery "invoice" `shouldBe` Right (Or (SubjectContains "invoice" :| [Body (Phrase "invoice")]))

    it "parses \"from:alice@example.com invoice\" as an implicit AND" $
      parseQuery "from:alice@example.com invoice" `shouldBe`
        Right (And (From (expectAddr "alice@example.com") :| [Or (SubjectContains "invoice" :| [Body (Phrase "invoice")])]))

    it "parses has:attachment" $
      parseQuery "has:attachment" `shouldBe` Right HasAttachment

    it "parses is:unread" $
      parseQuery "is:unread" `shouldBe` Right IsUnread

    it "rejects has:bogus" $
      parseQuery "has:bogus" `shouldSatisfy` isParseError

    it "respects NOT > AND > OR precedence" $
      parseQuery "NOT has:attachment AND is:unread OR has:attachment" `shouldBe`
        Right (Or (And (Not HasAttachment :| [IsUnread]) :| [HasAttachment]))

    it "parses parenthesized grouping" $
      parseQuery "NOT (has:attachment OR is:unread)" `shouldBe`
        Right (Not (Or (HasAttachment :| [IsUnread])))

    it "parses a valid after: date" $
      parseQuery "after:2026-08-01" `shouldSatisfy` isRightPred

    it "rejects an invalid after: date" $
      parseQuery "after:not-a-date" `shouldSatisfy` isParseError

  describe "parseQueryLive" $ do
    it "falls back to a bare-term match on an unterminated quote" $
      parseQueryLive "\"annual" `shouldBe` Or (SubjectContains "\"annual" :| [Body (Phrase "\"annual")])
    it "matches everything on empty input" $
      parseQueryLive "" `shouldBe` Or (SubjectContains "" :| [Body (Phrase "")])
