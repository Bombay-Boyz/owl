-- | Real tests against actual DNS resolution, not just invented
-- fixtures -- DNS is public infrastructure, so this is a genuine
-- opportunity to verify against reality rather than only fixtures,
-- the same way Owl.Keyring.MacOSSpec verifies against the real
-- Keychain.
module Owl.DiscoverySpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Owl.Discovery (discoverProvider)
import Owl.Domain.Address (EmailAddress, mkEmailAddress)
import Owl.Wizard

mustEmail :: Text -> EmailAddress
mustEmail t = either (error . show) id (mkEmailAddress t)

spec :: Spec
spec = describe "discoverProvider -- real DNS resolution" $ do
  it "resolves a real gmail.com address to the known Gmail config \
     \(confirming SRV correctly finds nothing for gmail.com, and the \
     \known-provider fallback correctly takes over)" $ do
    result <- discoverProvider (mustEmail "someone@gmail.com")
    case result of
      Left err  -> expectationFailure ("expected successful discovery, got: " ++ show err)
      Right cfg -> do
        endpointHost (imapEndpoint cfg) `shouldBe` "imap.gmail.com"
        endpointPort (imapEndpoint cfg) `shouldBe` 993
        endpointHost (smtpEndpoint cfg) `shouldBe` "smtp.gmail.com"
        case authMethod cfg of
          OAuth2 _     -> pure ()
          PasswordAuth -> expectationFailure "expected OAuth2 for the known Gmail entry"

  it "reports a failure gracefully for a domain with no mail infrastructure at all" $ do
    result <- discoverProvider (mustEmail "someone@this-domain-should-not-exist-owl-test-12345.invalid")
    case result of
      Left _  -> pure ()  -- either NoEndpointsDiscovered or DnsLookupFailed is acceptable here
      Right _ -> expectationFailure "unexpectedly discovered a provider for a domain that shouldn't exist"
