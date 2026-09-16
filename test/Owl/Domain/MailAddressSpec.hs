module Owl.Domain.MailAddressSpec (spec) where

import Test.Hspec

import Owl.Domain.MailAddress

spec :: Spec
spec = describe "sanitizeDisplayName (header-injection defense)" $ do
  it "strips a CR from a display name" $
    sanitizeDisplayName (Just "Evil\rBcc: attacker@evil.com") `shouldBe` Just "EvilBcc: attacker@evil.com"

  it "strips an LF from a display name" $
    sanitizeDisplayName (Just "Evil\nBcc: attacker@evil.com") `shouldBe` Just "EvilBcc: attacker@evil.com"

  it "strips a full CRLF sequence" $
    sanitizeDisplayName (Just "Evil\r\nBcc: attacker@evil.com") `shouldBe` Just "EvilBcc: attacker@evil.com"

  it "leaves an ordinary display name untouched" $
    sanitizeDisplayName (Just "Alice Smith") `shouldBe` Just "Alice Smith"

  it "leaves Nothing as Nothing" $
    sanitizeDisplayName Nothing `shouldBe` Nothing
