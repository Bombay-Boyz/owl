-- | Kept as a separate spec file from Owl.Domain.AttachmentSpec
-- deliberately -- no need to merge into or restructure that existing
-- file's own spec definition.
module Owl.Domain.AttachmentSanitizeSpec (spec) where

import Test.Hspec

import Owl.Domain.Attachment (sanitizeFilename)

spec :: Spec
spec = describe "sanitizeFilename (path-traversal defense)" $ do
  it "strips path separators from an attempted traversal filename" $
    sanitizeFilename "../../../.ssh/authorized_keys" `shouldBe` ".......sshauthorized_keys"

  it "falls back to a safe default when the result would be just dots" $
    sanitizeFilename ".." `shouldBe` "attachment"

  it "falls back to a safe default for an empty filename" $
    sanitizeFilename "" `shouldBe` "attachment"

  it "leaves an ordinary filename untouched" $
    sanitizeFilename "invoice.pdf" `shouldBe` "invoice.pdf"
