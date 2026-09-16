module Owl.Provider.IMAP.UTF7Spec (spec) where

import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Provider.IMAP.UTF7 (decodeMailboxUtf7, encodeMailboxUtf7)

spec :: Spec
spec = do
  describe "decodeMailboxUtf7 (real, independently-sourced test vectors)" $ do
    it "decodes a plain ASCII name unchanged" $
      decodeMailboxUtf7 "INBOX" `shouldBe` "INBOX"

    it "decodes a literal '&' encoded as '&-'" $
      decodeMailboxUtf7 "Foo&-Bar" `shouldBe` "Foo&Bar"

    it "decodes a Cyrillic name (source: Erlang imap_utf7 / Rust utf7-imap crate)" $
      decodeMailboxUtf7 "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-" `shouldBe` "\1054\1090\1087\1088\1072\1074\1083\1077\1085\1085\1099\1077"

    it "decodes a French name with an accented character (source: Erlang imap_utf7)" $
      decodeMailboxUtf7 "Bo&AO4-te de r&AOk-ception" `shouldBe` "Bo\238te de r\233ception"

    it "decodes a mixed ASCII/non-ASCII Gmail-style path" $
      decodeMailboxUtf7 "[Gmail]/&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-" `shouldBe` "[Gmail]/\1054\1090\1087\1088\1072\1074\1083\1077\1085\1085\1099\1077"

  describe "encodeMailboxUtf7 / decodeMailboxUtf7 round-trip" $
    it "recovers the original text for any generated Unicode string" $ hedgehog $ do
      text <- forAll (Gen.text (Range.linear 0 30) Gen.unicode)
      decodeMailboxUtf7 (encodeMailboxUtf7 text) === text
