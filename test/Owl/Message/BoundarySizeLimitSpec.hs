-- | Kept separate from Owl.Message.BoundarySpec deliberately -- no
-- need to merge into or restructure that existing file's own spec.
module Owl.Message.BoundarySizeLimitSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Test.Hspec

import Owl.Message.Boundary (parseMessageWithLimit)

spec :: Spec
spec = describe "parseMessageWithLimit (§12 hardening: reject oversized input before parsing)" $ do
  it "rejects raw input exceeding the given limit, without attempting to parse it" $ do
    let oversized = BC.replicate 100 'x'  -- deliberately not valid RFC 5322 either -- size check must fire first
    case parseMessageWithLimit 50 oversized of
      Left _  -> pure ()
      Right _ -> expectationFailure "expected rejection for input exceeding the limit"

  it "still succeeds for genuinely valid input within the limit" $ do
    let withinLimit = BC.pack "From: a@example.com\r\nTo: b@example.com\r\n\r\nhi\r\n"
    case parseMessageWithLimit 1000 withinLimit of
      Left err -> expectationFailure ("expected successful parse, got: " ++ show err)
      Right _  -> pure ()
