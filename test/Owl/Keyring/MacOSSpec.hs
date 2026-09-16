-- | A genuine round-trip test against the real macOS Keychain -- not
-- a fixture. Zero risk (no email, no real credentials, just our own
-- store/load/delete round-trip using an obviously-fake test secret),
-- and exactly the kind of "tested against reality, not just
-- invented fixtures" validation this codebase has otherwise lacked
-- for everything touching the outside world. Uses a clearly-named
-- test account so it's unambiguous in Keychain Access if anyone looks.
-- Cleans up both before (in case a prior failed run left stale state)
-- and after itself.
module Owl.Keyring.MacOSSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import Test.Hspec

import Owl.Domain.Id (AccountId (..))
import Owl.Keyring.MacOS (macOSKeyringHandle)
import Owl.Wizard (KeyringError (..), KeyringHandle (..))

testAccount :: AccountId
testAccount = AccountId "owl-test-account-please-ignore"

testSecret :: BS.ByteString
testSecret = TE.encodeUtf8 "owl-test-secret-value-12345"

spec :: Spec
spec = describe "Owl.Keyring.MacOS -- real round-trip against the actual Keychain" $
  it "stores, loads, and deletes a secret, and correctly reports absence" $ do
    let handle = macOSKeyringHandle

    -- Clean slate: a prior failed run may have left this behind.
    _ <- deleteSecret handle testAccount

    notFoundBefore <- loadSecret handle testAccount
    notFoundBefore `shouldBe` Left (KeyringSecretNotFound testAccount)

    storeResult <- storeSecret handle testAccount testSecret
    storeResult `shouldBe` Right ()

    loadResult <- loadSecret handle testAccount
    loadResult `shouldBe` Right testSecret

    deleteResult <- deleteSecret handle testAccount
    deleteResult `shouldBe` Right ()

    notFoundAfter <- loadSecret handle testAccount
    notFoundAfter `shouldBe` Left (KeyringSecretNotFound testAccount)
