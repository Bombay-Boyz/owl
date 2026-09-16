module Owl.Domain.AddressSpec (spec) where

import Data.Either (isRight)
import Data.Text (Text)
import qualified Data.Text as Text
import Hedgehog (Gen, evalEither, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Domain.Address

spec :: Spec
spec = do
  describe "mkEmailAddress" $ do
    it "accepts an ordinary address" $
      mkEmailAddress "alice@example.com" `shouldSatisfy` isRight

    it "accepts a subdomain and plus-addressing" $
      mkEmailAddress "alice+tag@mail.example.co.uk" `shouldSatisfy` isRight

    it "rejects an empty string" $
      mkEmailAddress "" `shouldBe` Left AddressEmpty

    it "rejects a missing @" $
      mkEmailAddress "alice.example.com" `shouldBe` Left MissingAtSign

    it "rejects more than one @" $
      mkEmailAddress "alice@bob@example.com" `shouldBe` Left MultipleAtSigns

    it "rejects an empty local part" $
      mkEmailAddress "@example.com" `shouldBe` Left LocalPartEmpty

    it "rejects a leading dot in the local part" $
      mkEmailAddress ".alice@example.com" `shouldBe` Left LocalPartInvalidDotPlacement

    it "rejects consecutive dots in the local part" $
      mkEmailAddress "al..ice@example.com" `shouldBe` Left LocalPartInvalidDotPlacement

    it "rejects an empty domain" $
      mkEmailAddress "alice@" `shouldBe` Left DomainEmpty

    it "rejects a domain with no dot" $
      mkEmailAddress "alice@localhost" `shouldBe` Left DomainMissingDot

    it "rejects a domain literal" $
      mkEmailAddress "alice@[192.0.2.1]" `shouldBe` Left DomainLiteralUnsupported

    it "rejects a domain label starting with a hyphen" $
      mkEmailAddress "alice@-example.com"
        `shouldBe` Left (DomainLabelInvalidHyphenPlacement "-example")

    it "rejects a local part over 64 octets" $
      mkEmailAddress (Text.replicate 65 "a" <> "@example.com")
        `shouldBe` Left (LocalPartTooLong 65)

  describe "normalizeAddress" $ do
    it "lowercases a mixed-case address" $
      case mkEmailAddress "Alice.Smith@Example.COM" of
        Left err   -> expectationFailure (show err)
        Right addr -> unNormalizedAddress (normalizeAddress addr) `shouldBe` "alice.smith@example.com"

    it "matches Text.toLower for any generated well-formed address" $ hedgehog $ do
      localPart <- forAll genLocalPart
      domain    <- forAll genDomain
      let raw = localPart <> "@" <> domain
      addr <- evalEither (mkEmailAddress raw)
      unNormalizedAddress (normalizeAddress addr) === Text.toLower raw

genLocalPart :: Gen Text
genLocalPart = Gen.text (Range.linear 1 20) Gen.alphaNum

genDomain :: Gen Text
genDomain = do
  label1 <- Gen.text (Range.linear 1 10) Gen.alphaNum
  label2 <- Gen.text (Range.linear 2 10) Gen.alpha
  pure (label1 <> "." <> label2)
