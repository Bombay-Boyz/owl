module Owl.Domain.IdSpec (spec) where

import Test.Hspec

import Owl.Domain.Id

spec :: Spec
spec = describe "mkMailboxId (§10: never derived from a raw folder name alone)" $ do
  it "produces different MailboxIds for the same folder name under different accounts" $
    mkMailboxId (AccountId "acct1") "INBOX" `shouldNotBe` mkMailboxId (AccountId "acct2") "INBOX"

  it "produces different MailboxIds for different folder names under the same account" $
    mkMailboxId (AccountId "acct1") "INBOX" `shouldNotBe` mkMailboxId (AccountId "acct1") "Sent"

  it "is deterministic for the same account and folder name" $
    mkMailboxId (AccountId "acct1") "INBOX" `shouldBe` mkMailboxId (AccountId "acct1") "INBOX"
