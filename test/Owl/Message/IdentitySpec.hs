module Owl.Message.IdentitySpec (spec) where

import Test.Hspec

import Owl.Message.Identity

spec :: Spec
spec = do
  parseRfcMessageIdSpec
  mkUidSpec

parseRfcMessageIdSpec :: Spec
parseRfcMessageIdSpec = describe "parseRfcMessageId" $ do
  it "accepts a minimal well-formed id" $
    fmap unValidatedRfcId (parseRfcMessageId "<a@b>") `shouldBe` Just "<a@b>"

  it "accepts a realistic id" $
    fmap unValidatedRfcId (parseRfcMessageId "<1234.5678@mail.example.com>")
      `shouldBe` Just "<1234.5678@mail.example.com>"

  it "rejects a missing closing bracket" $
    parseRfcMessageId "<abc@def" `shouldBe` Nothing

  it "rejects a missing opening bracket" $
    parseRfcMessageId "abc@def>" `shouldBe` Nothing

  it "rejects an empty local part" $
    parseRfcMessageId "<@b>" `shouldBe` Nothing

  it "rejects an empty domain part" $
    parseRfcMessageId "<a@>" `shouldBe` Nothing

  it "rejects a missing @" $
    parseRfcMessageId "<abcdef>" `shouldBe` Nothing

  it "rejects embedded whitespace" $
    parseRfcMessageId "<a b@c>" `shouldBe` Nothing


mkUidSpec :: Spec
mkUidSpec = describe "mkUID / mkUIDValidity (RFC 9051 nz-number)" $ do
  it "rejects zero" $ do
    mkUID 0 `shouldBe` Nothing
    mkUIDValidity 0 `shouldBe` Nothing
  it "accepts a positive value" $ do
    fmap (const ()) (mkUID 1) `shouldBe` Just ()
    fmap (const ()) (mkUIDValidity 1) `shouldBe` Just ()
