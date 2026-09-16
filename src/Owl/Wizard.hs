-- | Configuration & First Run's pure core (master spec §7): the
-- discovery/auth/keyring types the given signatures reference, and
-- the onboarding wizard's own state machine. Deliberately scoped to
-- the pure pieces only -- TOML config load/save and the real DNS/
-- keyring/OAuth IO shells are separate, later work; this module has
-- no IO in it at all, matching the spec's own stated requirement that
-- stepWizard be "unit-testable without a terminal or a network."
--
-- AuthError and KeyringError are necessary additions: KeyringHandle
-- and WizardError both reference them in the given signatures, but
-- neither is given a concrete shape anywhere in §7's text.
--   * AuthError covers what can go wrong OBTAINING credentials (the
--     OAuth2 flow itself, or writing a freshly-obtained secret to the
--     keyring) -- distinct from DiscoveryError (finding the server)
--     and ProviderError (§20 -- actually connecting/authenticating
--     against the server, which is what TestingConnection checks).
--   * KeyringError is scoped to exactly what KeyringHandle's three
--     operations can fail at: the OS store being unavailable, access
--     being denied, or a requested secret simply not existing.
module Owl.Wizard
  ( Domain (..)
  , ServerEndpoint (..)
  , TransportSecurity (..)
  , OAuth2Endpoints (..)
  , AuthMechanism (..)
  , ProviderConfig (..)
  , DiscoveryError (..)
  , KeyringError (..)
  , KeyringHandle (..)
  , AuthError (..)
  , WizardError (..)
  , WizardStep (..)
  , WizardEvent (..)
  , stepWizard
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word16)
import URI.ByteString (URI)

import Owl.Domain.Address (EmailAddress)
import Owl.Domain.Id (AccountId)
import Owl.Provider.Types (ProviderError)

newtype Domain = Domain Text
  deriving stock (Eq, Show)

data ServerEndpoint = ServerEndpoint
  { endpointHost     :: !Text
  , endpointPort     :: !Word16
  , endpointSecurity :: !TransportSecurity
  }
  deriving stock (Eq, Show)

data TransportSecurity = TLSImplicit | STARTTLS
  deriving stock (Eq, Show)

-- | Deliberately protocol-level and provider-agnostic (authorize/
-- token endpoint URIs and a scope string) rather than carrying
-- hoauth2's own typed Idp/Application values directly -- those are
-- necessarily specific to one concrete provider (Owl.Provider.OAuth.
-- Google's own GoogleProvider marker type, for instance), whereas
-- ProviderConfig here is meant to stay generic across whichever
-- provider auto-discovery actually finds. The provider-specific
-- hoauth2 wiring is a separate concern, layered on top once a
-- concrete provider is known.
data OAuth2Endpoints = OAuth2Endpoints
  { oauth2AuthorizeUrl :: !URI
  , oauth2TokenUrl     :: !URI
  , oauth2Scope        :: !Text
  }
  deriving stock (Eq, Show)

data AuthMechanism = OAuth2 !OAuth2Endpoints | PasswordAuth
  deriving stock (Eq, Show)

data ProviderConfig = ProviderConfig
  { imapEndpoint :: !ServerEndpoint
  , smtpEndpoint :: !ServerEndpoint
  , authMethod   :: !AuthMechanism
  }
  deriving stock (Eq, Show)

data DiscoveryError
  = DomainParseFailed Text
  | DnsLookupFailed Text
  | NoEndpointsDiscovered
  deriving stock (Eq, Show)

data KeyringError
  = KeyringUnavailable Text
  | KeyringAccessDenied Text
  | KeyringSecretNotFound AccountId
  deriving stock (Eq, Show)

data KeyringHandle m = KeyringHandle
  { storeSecret  :: AccountId -> ByteString -> m (Either KeyringError ())
  , loadSecret   :: AccountId -> m (Either KeyringError ByteString)
  , deleteSecret :: AccountId -> m (Either KeyringError ())
  }

data AuthError
  = OAuthFlowFailed Text
  | KeyringWriteFailed KeyringError
  | PasswordEntryCancelled
  deriving stock (Eq, Show)

data WizardError
  = WizardDiscoveryFailed DiscoveryError
  | WizardAuthFailed AuthError
  | WizardConnectionFailed ProviderError
  | WizardCancelled
  deriving stock (Eq, Show)

data WizardStep
  = PromptEmail
  | Discovering EmailAddress
  | Authenticate ProviderConfig
  | TestingConnection ProviderConfig
  | Complete
  | Failed WizardError
  deriving stock (Eq, Show)

data WizardEvent
  = EmailEntered EmailAddress
  | DiscoveryDone (Either DiscoveryError ProviderConfig)
  | AuthDone (Either AuthError ())
  | ConnectionTested (Either ProviderError ())
  | Cancelled
  deriving stock (Eq, Show)

-- | Total over its input, exactly like apply (§24) and transition
-- (§19). Two design decisions worth stating explicitly:
--   * A mismatched (step, event) pair -- one that doesn't correspond
--     to a legitimate transition for the CURRENT step -- is a no-op:
--     the step is left unchanged, rather than the event silently
--     corrupting or advancing state it has no business affecting.
--   * Complete and Failed are genuinely terminal: no further event,
--     INCLUDING Cancelled, moves the wizard away from them. Without
--     this explicit guard, a stray Cancelled arriving after the
--     wizard already finished would incorrectly "un-complete" it back
--     into Failed WizardCancelled -- caught and fixed while designing
--     this, not after.
stepWizard :: WizardStep -> WizardEvent -> WizardStep
stepWizard PromptEmail           (EmailEntered email)         = Discovering email
stepWizard (Discovering _)       (DiscoveryDone (Left err))    = Failed (WizardDiscoveryFailed err)
stepWizard (Discovering _)       (DiscoveryDone (Right cfg))   = Authenticate cfg
stepWizard (Authenticate _)      (AuthDone (Left err))         = Failed (WizardAuthFailed err)
stepWizard (Authenticate cfg)    (AuthDone (Right ()))         = TestingConnection cfg
stepWizard (TestingConnection _) (ConnectionTested (Left err)) = Failed (WizardConnectionFailed err)
stepWizard (TestingConnection _) (ConnectionTested (Right ())) = Complete
stepWizard step@Complete   _ = step
stepWizard step@(Failed _) _ = step
stepWizard _ Cancelled = Failed WizardCancelled
stepWizard step _ = step
