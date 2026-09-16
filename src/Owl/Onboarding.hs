-- | Wires §7's onboarding wizard (Owl.Wizard's pure stepWizard) to its
-- real IO shell: DNS discovery, the Keychain, the OAuth2 flow, a real
-- connection test, and TOML persistence. This is the culmination of
-- everything else built for §7 -- every piece here was independently
-- verified (real Gmail DNS resolution, a real local HTTP round-trip
-- for the callback, a real Keychain round-trip) before being wired
-- together, and every hoauth2 API detail used in the OAuth2 path was
-- confirmed directly against its own source (IdpApplication's
-- value-level field order, ExchangeTokenInfo's type-family resolution
-- to plain ExchangeToken, TokenResponse's actual field names) rather
-- than guessed, given how many times this exact library's API drifted
-- across versions earlier in this project.
--
-- Complete carries no data at all (per §7's own given WizardStep
-- type) -- once stepWizard reaches it, the ProviderConfig that
-- succeeded is gone from the PURE state machine's own memory. This is
-- fine: the ORCHESTRATION layer (driveWizard, below) remembers it
-- separately in its own recursion, since it drove every transition
-- and therefore already has what it needs by the time Complete is
-- reached.
--
-- OnboardingError is a genuinely new, orchestration-level type, not
-- reusing WizardError: "the wizard succeeded but saving the resulting
-- config afterward failed" is a different kind of failure than
-- anything WizardError's own cases are designed to represent (the
-- wizard's job is establishing connectivity/auth; persisting the
-- result is a separate step after the wizard's own job is done).
module Owl.Onboarding
  ( OnboardingConfig (..)
  , OnboardingError (..)
  , runOnboarding
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDV4
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Network.OAuth2.Experiment as OAuth2
import Network.OAuth2 (TokenResponse (accessToken), AccessToken (atoken), ExchangeToken (..))
import System.IO (hFlush, hSetEcho, stdin, stdout)
import System.Process (callProcess)
import URI.ByteString (laxURIParserOptions, parseURI, serializeURIRef')

import Owl.Config
import Owl.Config.Toml (saveConfig)
import Owl.Discovery (discoverProvider)
import Owl.Domain.Address (EmailAddress, mkEmailAddress, unEmailAddress)
import Owl.Domain.Id (AccountId (..))
import Owl.OAuthCallback
import qualified Owl.Provider.IMAP as IMAP
import qualified Owl.Provider.OAuth.Google as Google
import qualified Owl.Provider.Types as PT
import Owl.Wizard

data OnboardingConfig = OnboardingConfig
  { onboardingGoogleClientId     :: !Text
  , onboardingGoogleClientSecret :: !Text
  , onboardingRedirectPort       :: !Int
  , onboardingAccountName        :: !Text
  , onboardingConfigSource       :: !ConfigSource
  }

data OnboardingError
  = WizardFailed WizardError
  | ConfigSaveFailed ConfigError
  deriving stock (Eq, Show)

runOnboarding :: OnboardingConfig -> KeyringHandle IO -> IO (Either OnboardingError Config)
runOnboarding cfg keyring = do
  email <- promptForEmail
  driveWizard email Nothing (stepWizard PromptEmail (EmailEntered email))
  where
    accountId = AccountId (onboardingAccountName cfg)

    driveWizard :: EmailAddress -> Maybe ProviderConfig -> WizardStep -> IO (Either OnboardingError Config)
    driveWizard email mProviderConfig step = case step of
      Discovering discEmail -> do
        result <- discoverProvider discEmail
        driveWizard email (either (const Nothing) Just result) (stepWizard step (DiscoveryDone result))

      Authenticate providerConfig -> do
        authResult <- performAuthentication providerConfig
        driveWizard email (Just providerConfig) (stepWizard step (AuthDone authResult))

      TestingConnection providerConfig -> do
        connResult <- performConnectionTest email providerConfig
        driveWizard email (Just providerConfig) (stepWizard step (ConnectionTested connResult))

      Complete -> case mProviderConfig of
        Nothing -> pure (Left (WizardFailed WizardCancelled))
        Just _  -> do
          let rawAccount = RawAccount
                { rawAccountName    = onboardingAccountName cfg
                , rawAccountEmail   = unEmailAddress email
                , rawAccountBackend = Nothing
                }
          case validateConfig (RawConfig (RawUiPreferences Nothing) [rawAccount]) of
            Left err        -> pure (Left (ConfigSaveFailed err))
            Right newConfig -> do
              saveResult <- saveConfig (onboardingConfigSource cfg) newConfig
              pure $ case saveResult of
                Left err -> Left (ConfigSaveFailed err)
                Right () -> Right newConfig

      Failed err -> pure (Left (WizardFailed err))

      -- Only reachable if stepWizard's own no-op semantics kept us
      -- here after a genuinely unexpected event -- shouldn't happen
      -- given this function drives every transition itself.
      PromptEmail -> pure (Left (WizardFailed WizardCancelled))

    performAuthentication :: ProviderConfig -> IO (Either AuthError ())
    performAuthentication providerConfig = case authMethod providerConfig of
      PasswordAuth -> do
        password <- promptForPassword
        storeResult <- storeSecret keyring accountId (TE.encodeUtf8 password)
        pure (either (Left . KeyringWriteFailed) Right storeResult)

      OAuth2 _oauth2Endpoints -> do
        stateUuid <- UUIDV4.nextRandom
        let state           = UUID.toText stateUuid
            redirectUriText = "http://localhost:" <> Text.pack (show (onboardingRedirectPort cfg)) <> "/callback"
        case parseURI laxURIParserOptions (TE.encodeUtf8 redirectUriText) of
          Left err -> pure (Left (OAuthFlowFailed (Text.pack ("failed to construct redirect URI: " ++ show err))))
          Right redirectUri -> do
            let googleApp   = Google.mkGoogleApplication (onboardingGoogleClientId cfg) (onboardingGoogleClientSecret cfg) state redirectUri
                idpApp      = OAuth2.IdpApplication Google.googleIdp googleApp
                authUrl     = Google.buildAuthorizationUrl idpApp
                authUrlText = TE.decodeUtf8 (serializeURIRef' authUrl)
            putStrLn ("Please visit this URL to authorize Owl:\n" ++ Text.unpack authUrlText)
            openInBrowser authUrlText
            callbackResult <- awaitOAuthCallback (onboardingRedirectPort cfg) state (5 * 60 * 1000000)
            case callbackResult of
              Nothing                          -> pure (Left (OAuthFlowFailed "timed out waiting for the OAuth callback"))
              Just (CallbackProviderError err)  -> pure (Left (OAuthFlowFailed err))
              Just CallbackStateMismatch        -> pure (Left (OAuthFlowFailed "CSRF state mismatch on OAuth callback"))
              Just (CallbackMalformed err)      -> pure (Left (OAuthFlowFailed err))
              Just (CallbackSuccess code _)     -> do
                manager <- newManager tlsManagerSettings
                tokenResult <- Google.exchangeCodeForToken idpApp manager (ExchangeToken code)
                case tokenResult of
                  Left err            -> pure (Left (OAuthFlowFailed err))
                  Right tokenResponse -> do
                    let rawToken = atoken (accessToken tokenResponse)
                    storeResult <- storeSecret keyring accountId (TE.encodeUtf8 rawToken)
                    pure (either (Left . KeyringWriteFailed) Right storeResult)

    performConnectionTest :: EmailAddress -> ProviderConfig -> IO (Either PT.ProviderError ())
    performConnectionTest email providerConfig = do
      secretResult <- loadSecret keyring accountId
      case secretResult of
        Left keyringErr -> pure (Left (PT.ProviderAuthenticationFailed (Text.pack (show keyringErr))))
        Right secretBytes -> case TE.decodeUtf8' secretBytes of
          Left _         -> pure (Left (PT.ProviderAuthenticationFailed "stored secret is not valid UTF-8"))
          Right secretText -> do
            let authentication = case authMethod providerConfig of
                  PasswordAuth -> PT.PasswordAuth secretText
                  OAuth2 _     -> PT.OAuth2Auth secretText
                settings = PT.ProviderSettings
                  { PT.settingsAccountId = accountId
                  , PT.imapHost          = endpointHost (imapEndpoint providerConfig)
                  , PT.imapPort          = fromIntegral (endpointPort (imapEndpoint providerConfig))
                  , PT.smtpHost          = endpointHost (smtpEndpoint providerConfig)
                  , PT.smtpPort          = fromIntegral (endpointPort (smtpEndpoint providerConfig))
                  , PT.providerUsername  = unEmailAddress email
                  }
            connResult <- IMAP.connectImap settings authentication
            pure (either Left (const (Right ())) connResult)

promptForEmail :: IO EmailAddress
promptForEmail = do
  putStr "Enter your email address: "
  hFlush stdout
  line <- getLine
  case mkEmailAddress (Text.pack line) of
    Left err    -> do
      putStrLn ("That doesn't look like a valid email address: " ++ show err)
      promptForEmail
    Right email -> pure email

-- | Disables terminal echo while the password is typed -- a genuine,
-- worthwhile thing to get right, not just a nicety: without it, an app
-- password would be visible on screen (and potentially in terminal
-- scrollback/screen-recording) while being entered.
promptForPassword :: IO Text
promptForPassword = do
  putStr "Enter your app password: "
  hFlush stdout
  hSetEcho stdin False
  line <- getLine
  hSetEcho stdin True
  putStrLn ""
  pure (Text.pack line)

-- | Shells out to macOS's `open`, matching the same "battle-tested OS
-- primitive over a third-party wrapper" reasoning used for Keychain
-- access. Failure here is non-fatal: the URL is already printed above,
-- so the user can always open it manually.
openInBrowser :: Text -> IO ()
openInBrowser url = do
  result <- try (callProcess "open" [Text.unpack url]) :: IO (Either SomeException ())
  case result of
    Left _  -> putStrLn "(Could not automatically open your browser -- please open the URL above manually.)"
    Right _ -> pure ()
