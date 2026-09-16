-- | Configuration & First Run's config layer (master spec §7),
-- deliberately scoped to the pure, TOML-library-independent parts:
-- ConfigSource, RawConfig, the opaque Config, ConfigError, and
-- validateConfig. loadConfig itself (actual TOML file reading, via
-- tomland) is separate follow-up work -- no reason to block this pure,
-- fully-testable half on a dependency that still needs its current
-- bounds verified against real source, the same lesson text-utf7
-- taught the expensive way.
--
-- "Config is opaque after validation" (§7's own words) means its
-- CONSTRUCTOR must not be exported, only the bare type and read-only
-- accessor functions -- a record's own field accessors, exported
-- individually rather than via Config(..). Record update syntax from
-- outside this module still needs the constructor in scope, so this
-- genuinely prevents external code from constructing or mutating a
-- Config value except through validateConfig/loadConfig, matching the
-- smart-constructor discipline used for every other validated type in
-- this codebase (Subject, EmailAddress, UID, ...).
--
-- Schema design, given the spec's own explicit UX goal ("must not
-- expose IMAP URLs... unless the user deliberately opts into a
-- generic backend"): the default per-account case stores only the
-- email address. accountConfigBackendOverride is that opt-in escape
-- hatch -- present only when the user has explicitly configured a
-- manual backend, absent (and invisible in the TOML) otherwise. The
-- DISCOVERED ProviderConfig (from auto-discovery) deliberately has no
-- place in this type at all -- caching that is a separate, internal
-- concern, not something surfaced in the user-facing config file.
module Owl.Config
  ( ConfigSource (..)
  , RawUiPreferences (..)
  , RawAccountBackend (..)
  , RawAccount (..)
  , RawConfig (..)
  , Theme (..)
  , UiPreferences
  , uiTheme
  , AccountBackendOverride
  , overrideImapEndpoint
  , overrideSmtpEndpoint
  , AccountConfig
  , accountConfigName
  , accountConfigEmail
  , accountConfigBackendOverride
  , Config
  , configUi
  , configAccounts
  , ConfigError (..)
  , validateConfig
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text

import Owl.Domain.Address (EmailAddress, mkEmailAddress)
import Owl.Wizard (ServerEndpoint (..), TransportSecurity (..))

data ConfigSource
  = DefaultConfigPath
    -- ^ The XDG-conventional location, e.g. ~/.config/owl/config.toml
    -- on Linux/macOS -- resolved by loadConfig's own IO shell, not
    -- this module, which stays free of any real filesystem knowledge.
  | ExplicitConfigPath FilePath
  deriving stock (Eq, Show)

-- | Mirrors the raw TOML structure literally, before validation --
-- e.g. account emails are still bare Text, not yet checked as valid
-- EmailAddress values. A TOML document can be perfectly well-formed
-- while still containing invalid Owl configuration; RawConfig
-- captures the former, Config only ever the latter.
data RawUiPreferences = RawUiPreferences
  { rawTheme :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Ports are Int here, not Word16 -- tomland's own numeric codec
-- (Toml.int) decodes TOML integers as Int; Word16 is the VALIDATED
-- ServerEndpoint's own field type, and the Int -> Word16 range check
-- happens in validateConfig, which is already the natural place for
-- exactly this kind of check (same reasoning as every other
-- raw-vs-validated field in this module).
data RawAccountBackend = RawAccountBackend
  { rawImapHost     :: Text
  , rawImapPort     :: Int
  , rawImapSecurity :: Text  -- "tls" | "starttls", checked by validateConfig
  , rawSmtpHost     :: Text
  , rawSmtpPort     :: Int
  , rawSmtpSecurity :: Text
  }
  deriving stock (Eq, Show)

data RawAccount = RawAccount
  { rawAccountName    :: Text
  , rawAccountEmail   :: Text
  , rawAccountBackend :: Maybe RawAccountBackend
  }
  deriving stock (Eq, Show)

data RawConfig = RawConfig
  { rawUi       :: RawUiPreferences
  , rawAccounts :: [RawAccount]
  }
  deriving stock (Eq, Show)

data Theme = DarkTheme | LightTheme
  deriving stock (Eq, Show)

data UiPreferences = UiPreferences
  { uiTheme :: Theme
  }
  deriving stock (Eq, Show)

data AccountBackendOverride = AccountBackendOverride
  { overrideImapEndpoint :: ServerEndpoint
  , overrideSmtpEndpoint :: ServerEndpoint
  }
  deriving stock (Eq, Show)

data AccountConfig = AccountConfig
  { accountConfigName            :: Text
  , accountConfigEmail           :: EmailAddress
  , accountConfigBackendOverride :: Maybe AccountBackendOverride
  }
  deriving stock (Eq, Show)

-- | Deliberately not exporting the Config constructor -- see this
-- module's own top-level note.
data Config = Config
  { configUi       :: UiPreferences
  , configAccounts :: [AccountConfig]
  }
  deriving stock (Eq, Show)

data ConfigError
  = ConfigFileNotFound FilePath
    -- ^ A missing file is the ordinary, expected first-run case, not
    -- a malformed-content error -- kept genuinely distinct from
    -- ConfigParseFailed so the caller (the onboarding wizard) can
    -- decide what "not found" means for its own flow (start fresh)
    -- rather than loadConfig silently deciding that itself.
  | ConfigParseFailed Text
  | ConfigInvalidField Text Text  -- (field path, reason)
  | ConfigDuplicateAccountName Text
  deriving stock (Eq, Show)

validateConfig :: RawConfig -> Either ConfigError Config
validateConfig raw = do
  ui <- validateUi (rawUi raw)
  accounts <- traverse validateAccount (rawAccounts raw)
  checkNoDuplicateNames accounts
  pure (Config ui accounts)
  where
    validateUi rawPrefs = case rawTheme rawPrefs of
      Nothing      -> Right (UiPreferences DarkTheme)
      Just "dark"  -> Right (UiPreferences DarkTheme)
      Just "light" -> Right (UiPreferences LightTheme)
      Just other   -> Left (ConfigInvalidField "ui.theme" ("unrecognized theme: " <> other))

    validateAccount rawAcct = do
      email <- either
        (Left . ConfigInvalidField ("account." <> rawAccountName rawAcct <> ".email") . Text.pack . show)
        Right
        (mkEmailAddress (rawAccountEmail rawAcct))
      backendOverride <- traverse validateBackend (rawAccountBackend rawAcct)
      pure (AccountConfig (rawAccountName rawAcct) email backendOverride)

    validateBackend rawBackend = do
      imapSec  <- parseSecurity (rawImapSecurity rawBackend)
      smtpSec  <- parseSecurity (rawSmtpSecurity rawBackend)
      imapPort <- portInRange "backend.imap_port" (rawImapPort rawBackend)
      smtpPort <- portInRange "backend.smtp_port" (rawSmtpPort rawBackend)
      pure AccountBackendOverride
        { overrideImapEndpoint = ServerEndpoint (rawImapHost rawBackend) imapPort imapSec
        , overrideSmtpEndpoint = ServerEndpoint (rawSmtpHost rawBackend) smtpPort smtpSec
        }

    portInRange fieldName p
      | p >= 0 && p <= 65535 = Right (fromIntegral p)
      | otherwise            = Left (ConfigInvalidField fieldName ("port out of range: " <> Text.pack (show p)))

    parseSecurity "tls"      = Right TLSImplicit
    parseSecurity "starttls" = Right STARTTLS
    parseSecurity other      = Left (ConfigInvalidField "backend.security" ("unrecognized transport security: " <> other))

    checkNoDuplicateNames accounts = case findDuplicate (map accountConfigName accounts) of
      Just dup -> Left (ConfigDuplicateAccountName dup)
      Nothing  -> Right ()

    findDuplicate = go Set.empty
      where
        go _    []       = Nothing
        go seen (x : xs)
          | x `Set.member` seen = Just x
          | otherwise            = go (Set.insert x seen) xs
