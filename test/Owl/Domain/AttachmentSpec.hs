module Owl.Domain.AttachmentSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Owl.Domain.Attachment

spec :: Spec
spec = describe "validateAttachments" $ do
  let limits = AttachmentLimits { maxAttachmentCount = 2, maxAttachmentTotalSize = 100 }
      small n = Attachment
        { attachmentFilename = Nothing
        , attachmentMimeType = "text/plain"
        , attachmentContent  = BC.replicate n 'a'
        }

  it "accepts attachments within both limits" $
    validateAttachments limits [small 10, small 10] `shouldBe` Right [small 10, small 10]

  it "rejects too many attachments" $
    validateAttachments limits [small 1, small 1, small 1]
      `shouldBe` Left (TooManyAttachments 3 2)

  it "rejects attachments exceeding the cumulative size cap" $
    validateAttachments limits [small 60, small 60]
      `shouldBe` Left (AttachmentsTooLarge 120 100)

  it "accepts zero attachments" $
    validateAttachments limits [] `shouldBe` Right []
