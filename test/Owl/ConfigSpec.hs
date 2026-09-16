-- | validateConfig's rules -- the pure half of §7's config layer.
--
-- Owl.Config.TomlSpec covers the file round-trip and the missing-file
-- case, but never exercised the validation rules themselves: a
-- well-formed TOML document can still be invalid Owl configuration,
-- and that distinction is the entire reason RawConfig and Config are
-- separate types.
module Owl.ConfigSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Owl.Config
import Owl.Domain.Address (unEmailAddress)
import Owl.Wizard (ServerEndpoint (..), TransportSecurity (..))

rawAccount :: RawAccount
rawAccount = RawAccount
  { rawAccountName    = "personal"
  , rawAccountEmail   = "user@example.com"
  , rawAccountBackend = Nothing
  }

rawBackend :: RawAccountBackend
rawBackend = RawAccountBackend
  { rawImapHost     = "imap.example.org"
  , rawImapPort     = 993
  , rawImapSecurity = "tls"
  , rawSmtpHost     = "smtp.example.org"
  , rawSmtpPort     = 587
  , rawSmtpSecurity = "starttls"
  }

configOf :: Maybe Text -> [RawAccount] -> Either ConfigError Config
configOf theme accts = validateConfig (RawConfig (RawUiPreferences theme) accts)

spec :: Spec
spec = do
  describe "validateConfig -- theme" $ do
    it "defaults to dark when unspecified" $
      fmap (uiTheme . configUi) (configOf Nothing [rawAccount]) `shouldBe` Right DarkTheme

    it "accepts dark and light" $ do
      fmap (uiTheme . configUi) (configOf (Just "dark") [rawAccount])  `shouldBe` Right DarkTheme
      fmap (uiTheme . configUi) (configOf (Just "light") [rawAccount]) `shouldBe` Right LightTheme

    it "rejects an unknown theme, naming the field" $
      configOf (Just "solarized") [rawAccount]
        `shouldBe` Left (ConfigInvalidField "ui.theme" "unrecognized theme: solarized")

  describe "validateConfig -- accounts" $ do
    it "accepts a minimal account and validates its email" $
      fmap (map (unEmailAddress . accountConfigEmail) . configAccounts)
           (configOf Nothing [rawAccount])
        `shouldBe` Right ["user@example.com"]

    it "rejects an invalid email, naming the account" $
      case configOf Nothing [rawAccount { rawAccountEmail = "not-an-email" }] of
        Left (ConfigInvalidField field _) -> field `shouldBe` "account.personal.email"
        other -> expectationFailure ("expected an invalid-field error, got: " ++ show other)

    it "rejects two accounts sharing a name" $
      configOf Nothing [rawAccount, rawAccount]
        `shouldBe` Left (ConfigDuplicateAccountName "personal")

    it "allows two accounts with different names" $
      fmap (map accountConfigName . configAccounts)
           (configOf Nothing [rawAccount, rawAccount { rawAccountName = "work" }])
        `shouldBe` Right ["personal", "work"]

    it "accepts an empty account list -- a fresh install is not invalid" $
      fmap configAccounts (configOf Nothing []) `shouldBe` Right []

  describe "validateConfig -- backend override" $ do
    let withBackend b = configOf Nothing [rawAccount { rawAccountBackend = Just b }]

    it "is absent unless explicitly configured (§7: no IMAP URLs by default)" $
      fmap (map accountConfigBackendOverride . configAccounts) (configOf Nothing [rawAccount])
        `shouldBe` Right [Nothing]

    it "accepts tls and starttls, mapping each correctly" $
      fmap (map (fmap (endpointSecurity . overrideImapEndpoint)) . map accountConfigBackendOverride . configAccounts)
           (withBackend rawBackend)
        `shouldBe` Right [Just TLSImplicit]

    it "carries the smtp endpoint's own distinct security setting" $
      fmap (map (fmap (endpointSecurity . overrideSmtpEndpoint)) . map accountConfigBackendOverride . configAccounts)
           (withBackend rawBackend)
        `shouldBe` Right [Just STARTTLS]

    it "rejects an unknown transport security" $
      withBackend rawBackend { rawImapSecurity = "ssl-maybe" }
        `shouldBe` Left (ConfigInvalidField "backend.security" "unrecognized transport security: ssl-maybe")

    it "rejects a port above 65535" $
      case withBackend rawBackend { rawImapPort = 70000 } of
        Left (ConfigInvalidField field _) -> field `shouldBe` "backend.imap_port"
        other -> expectationFailure ("expected a port error, got: " ++ show other)

    it "rejects a negative port" $
      case withBackend rawBackend { rawSmtpPort = -1 } of
        Left (ConfigInvalidField field _) -> field `shouldBe` "backend.smtp_port"
        other -> expectationFailure ("expected a port error, got: " ++ show other)

    it "accepts the boundary ports 0 and 65535" $ do
      fmap (const ()) (withBackend rawBackend { rawImapPort = 0 })     `shouldBe` Right ()
      fmap (const ()) (withBackend rawBackend { rawImapPort = 65535 }) `shouldBe` Right ()
