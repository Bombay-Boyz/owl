-- | The TOML load/save IO shell for §7's Config (Owl.Config holds the
-- pure types and validateConfig; this module is the only place that
-- touches tomland or the filesystem).
--
-- CONFIDENCE NOTE: every combinator used here (table, tableMap,
-- _KeyText, dioptional, int, text, decodeFileEither, encodeToFile) is
-- confirmed directly against tomland's own source (pulled and grepped,
-- not taken from documentation summaries) -- but the exact interaction
-- of dioptional wrapping a whole TABLE (as opposed to a plain scalar
-- field, which is the only case directly confirmed via a real
-- example) hasn't been separately verified. This is the single most
-- likely thing here to need a small correction once actually compiled.
module Owl.Config.Toml
  ( resolveConfigPath
  , loadConfig
  , saveConfig
  ) where

import Control.Exception (IOException, try)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, getHomeDirectory)
import System.FilePath (takeDirectory, (</>))
import qualified Toml

import Owl.Config
import Owl.Domain.Address (unEmailAddress)
import Owl.Wizard (ServerEndpoint (..), TransportSecurity (..))

resolveConfigPath :: ConfigSource -> IO FilePath
resolveConfigPath (ExplicitConfigPath p) = pure p
resolveConfigPath DefaultConfigPath = do
  home <- getHomeDirectory
  pure (home </> ".config" </> "owl" </> "config.toml")

-- | The per-account TOML table's fields, excluding the name -- the
-- name is the table's own key under [account.<name>] (via tableMap),
-- not a field inside it.
data RawAccountFields = RawAccountFields
  { fieldsEmail   :: Text
  , fieldsBackend :: Maybe RawAccountBackend
  }

rawUiCodec :: Toml.TomlCodec RawUiPreferences
rawUiCodec = RawUiPreferences
  <$> Toml.dioptional (Toml.text "theme") Toml..= rawTheme

rawAccountBackendCodec :: Toml.TomlCodec RawAccountBackend
rawAccountBackendCodec = RawAccountBackend
  <$> Toml.text "imap_host"     Toml..= rawImapHost
  <*> Toml.int  "imap_port"     Toml..= rawImapPort
  <*> Toml.text "imap_security" Toml..= rawImapSecurity
  <*> Toml.text "smtp_host"     Toml..= rawSmtpHost
  <*> Toml.int  "smtp_port"     Toml..= rawSmtpPort
  <*> Toml.text "smtp_security" Toml..= rawSmtpSecurity

rawAccountFieldsCodec :: Toml.TomlCodec RawAccountFields
rawAccountFieldsCodec = RawAccountFields
  <$> Toml.text "email" Toml..= fieldsEmail
  <*> Toml.dioptional (Toml.table rawAccountBackendCodec "backend") Toml..= fieldsBackend

rawConfigCodec :: Toml.TomlCodec RawConfig
rawConfigCodec = mkRawConfig
  <$> Toml.dioptional (Toml.table rawUiCodec "ui") Toml..= (Just . rawUi)
  <*> Toml.tableMap Toml._KeyText (Toml.table rawAccountFieldsCodec) "account" Toml..= accountsAsMap
  where
    mkRawConfig maybeUi accountsMap =
      RawConfig (fromMaybe (RawUiPreferences Nothing) maybeUi) (map toRawAccount (Map.toList accountsMap))

    toRawAccount (name, fields) = RawAccount name (fieldsEmail fields) (fieldsBackend fields)

    accountsAsMap cfg = Map.fromList
      [ (rawAccountName a, RawAccountFields (rawAccountEmail a) (rawAccountBackend a))
      | a <- rawAccounts cfg
      ]

loadConfig :: ConfigSource -> IO (Either ConfigError Config)
loadConfig source = do
  path   <- resolveConfigPath source
  exists <- doesFileExist path
  if not exists
    then pure (Left (ConfigFileNotFound path))
    else do
      result <- try (Toml.decodeFileEither rawConfigCodec path)
        :: IO (Either IOException (Either [Toml.TomlDecodeError] RawConfig))
      pure $ case result of
        Left ioErr        -> Left (ConfigParseFailed (Text.pack (show ioErr)))
        Right (Left errs) -> Left (ConfigParseFailed (Text.pack (show errs)))
        Right (Right raw) -> validateConfig raw

-- | The one place permitted to walk back from the validated Config to
-- RawConfig -- entirely through Config's own public, read-only
-- accessors (see Owl.Config's note on why its constructor isn't
-- exported), never by constructing a Config directly.
saveConfig :: ConfigSource -> Config -> IO (Either ConfigError ())
saveConfig source cfg = do
  path <- resolveConfigPath source
  createDirectoryIfMissing True (takeDirectory path)
  result <- try (Toml.encodeToFile rawConfigCodec path (toRawConfig cfg)) :: IO (Either IOException Text)
  pure $ case result of
    Left ioErr -> Left (ConfigParseFailed (Text.pack (show ioErr)))
    Right _    -> Right ()
  where
    toRawConfig c = RawConfig
      { rawUi       = RawUiPreferences (themeToText (uiTheme (configUi c)))
      , rawAccounts = map toRawAccount (configAccounts c)
      }

    themeToText DarkTheme  = Just "dark"
    themeToText LightTheme = Just "light"

    toRawAccount a = RawAccount
      { rawAccountName    = accountConfigName a
      , rawAccountEmail   = unEmailAddress (accountConfigEmail a)
      , rawAccountBackend = fmap toRawBackend (accountConfigBackendOverride a)
      }

    toRawBackend override = RawAccountBackend
      { rawImapHost     = endpointHost (overrideImapEndpoint override)
      , rawImapPort     = fromIntegral (endpointPort (overrideImapEndpoint override))
      , rawImapSecurity = securityToText (endpointSecurity (overrideImapEndpoint override))
      , rawSmtpHost     = endpointHost (overrideSmtpEndpoint override)
      , rawSmtpPort     = fromIntegral (endpointPort (overrideSmtpEndpoint override))
      , rawSmtpSecurity = securityToText (endpointSecurity (overrideSmtpEndpoint override))
      }

    securityToText TLSImplicit = "tls"
    securityToText STARTTLS    = "starttls"
