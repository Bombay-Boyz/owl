module Owl.Domain.SubjectSpec (spec) where

import Data.Text (Text)
import Hedgehog (Gen, evalEither, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Domain.MessageError (MessageError (..))
import Owl.Domain.Subject

spec :: Spec
spec = do
  describe "mkSubject" $ do
    it "accepts ordinary text" $
      (unSubject <$> mkSubject "Re: quarterly report")
        `shouldBe` Right "Re: quarterly report"

    it "rejects an embedded carriage return" $
      mkSubject "Re: report\rX-Injected: evil" `shouldBe` Left SubjectContainsLineBreak

    it "rejects an embedded line feed" $
      mkSubject "Re: report\nX-Injected: evil" `shouldBe` Left SubjectContainsLineBreak

    it "round-trips any text containing no CR or LF" $ hedgehog $ do
      text <- forAll genLineSafeText
      sub  <- evalEither (mkSubject text)
      unSubject sub === text

genLineSafeText :: Gen Text
genLineSafeText =
  Gen.text (Range.linear 0 40) (Gen.filter (`notElem` ("\r\n" :: String)) Gen.unicode)
