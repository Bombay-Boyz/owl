module Owl.WizardSpec (spec) where

import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Domain.Address (EmailAddress, mkEmailAddress)
import Owl.Provider.Types (ProviderError (..))
import Owl.Wizard

testEmail :: EmailAddress
testEmail = either (error . show) id (mkEmailAddress "user@example.com")

testEndpoint :: ServerEndpoint
testEndpoint = ServerEndpoint
  { endpointHost     = "imap.example.com"
  , endpointPort     = 993
  , endpointSecurity = TLSImplicit
  }

testProviderConfig :: ProviderConfig
testProviderConfig = ProviderConfig
  { imapEndpoint = testEndpoint
  , smtpEndpoint = testEndpoint { endpointPort = 465 }
  , authMethod   = PasswordAuth
  }

-- | A small, curated, representative set of events -- used for the
-- property test below rather than a fully free-form Hedgehog
-- generator, since generating arbitrary EmailAddress/ProviderConfig/
-- URI values would add real complexity for no extra confidence: the
-- terminal-state invariant this property checks doesn't depend on
-- WHICH event arrives, only on whether the CURRENT step is terminal.
representativeEvents :: [WizardEvent]
representativeEvents =
  [ EmailEntered testEmail
  , DiscoveryDone (Right testProviderConfig)
  , DiscoveryDone (Left NoEndpointsDiscovered)
  , AuthDone (Right ())
  , AuthDone (Left PasswordEntryCancelled)
  , ConnectionTested (Right ())
  , ConnectionTested (Left ProviderTimeout)
  , Cancelled
  ]

spec :: Spec
spec = do
  describe "stepWizard -- happy path" $ do
    it "PromptEmail -> Discovering on EmailEntered" $
      stepWizard PromptEmail (EmailEntered testEmail) `shouldBe` Discovering testEmail

    it "Discovering -> Authenticate on successful discovery" $
      stepWizard (Discovering testEmail) (DiscoveryDone (Right testProviderConfig))
        `shouldBe` Authenticate testProviderConfig

    it "Authenticate -> TestingConnection on successful auth" $
      stepWizard (Authenticate testProviderConfig) (AuthDone (Right ()))
        `shouldBe` TestingConnection testProviderConfig

    it "TestingConnection -> Complete on successful connection test" $
      stepWizard (TestingConnection testProviderConfig) (ConnectionTested (Right ()))
        `shouldBe` Complete

  describe "stepWizard -- failure transitions" $ do
    it "Discovering -> Failed on discovery failure" $
      stepWizard (Discovering testEmail) (DiscoveryDone (Left NoEndpointsDiscovered))
        `shouldBe` Failed (WizardDiscoveryFailed NoEndpointsDiscovered)

    it "Authenticate -> Failed on auth failure" $
      stepWizard (Authenticate testProviderConfig) (AuthDone (Left PasswordEntryCancelled))
        `shouldBe` Failed (WizardAuthFailed PasswordEntryCancelled)

    it "TestingConnection -> Failed on connection failure" $
      stepWizard (TestingConnection testProviderConfig) (ConnectionTested (Left ProviderTimeout))
        `shouldBe` Failed (WizardConnectionFailed ProviderTimeout)

  describe "stepWizard -- cancellation from any non-terminal step" $ do
    it "cancels from PromptEmail" $
      stepWizard PromptEmail Cancelled `shouldBe` Failed WizardCancelled

    it "cancels from Discovering" $
      stepWizard (Discovering testEmail) Cancelled `shouldBe` Failed WizardCancelled

    it "cancels from Authenticate" $
      stepWizard (Authenticate testProviderConfig) Cancelled `shouldBe` Failed WizardCancelled

    it "cancels from TestingConnection" $
      stepWizard (TestingConnection testProviderConfig) Cancelled `shouldBe` Failed WizardCancelled

  describe "stepWizard -- terminal states reject every further event, including Cancelled" $ do
    it "Complete ignores a stray Cancelled (does not un-complete)" $
      stepWizard Complete Cancelled `shouldBe` Complete

    it "Complete ignores every representative event" $
      mapM_ (\ev -> stepWizard Complete ev `shouldBe` Complete) representativeEvents

    it "Failed ignores every representative event, including another Cancelled" $ do
      let failedStep = Failed WizardCancelled
      mapM_ (\ev -> stepWizard failedStep ev `shouldBe` failedStep) representativeEvents

  describe "stepWizard -- mismatched (step, event) pairs are no-ops" $ do
    it "PromptEmail ignores a ConnectionTested event" $
      stepWizard PromptEmail (ConnectionTested (Right ())) `shouldBe` PromptEmail

    it "Discovering ignores an AuthDone event" $
      stepWizard (Discovering testEmail) (AuthDone (Right ())) `shouldBe` Discovering testEmail

  describe "stepWizard -- property: terminal states never change, for any event" $
    it "holds for Complete and for Failed, across representative events" $ hedgehog $ do
      ev <- forAll (Gen.element representativeEvents)
      stepWizard Complete ev === Complete
      let failedStep = Failed (WizardDiscoveryFailed NoEndpointsDiscovered)
      stepWizard failedStep ev === failedStep
