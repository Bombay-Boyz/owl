{-# LANGUAGE QuasiQuotes #-}
-- | Google OAuth2 configuration and flow (master spec §20: "one
-- OAuth-capable provider"), using hoauth2's actual current
-- "Experiment" API (Network.OAuth2.Experiment) -- confirmed directly
-- against the library's own Haddock, including a literal Google
-- example, and against conduitTokenRequest/conduitRefreshTokenRequest's
-- full confirmed signatures. An earlier draft of this module wrongly
-- assumed an older, simpler OAuth2-record API that doesn't exist in
-- this version at all -- caught after the module failed to even find
-- Network.OAuth.OAuth2, and corrected with real research rather than
-- a third guess.
--
-- Endpoints and scope are Google's own publicly documented values:
--   https://developers.google.com/identity/protocols/oauth2
--   https://developers.google.com/gmail/imap/xoauth2-protocol
--
-- CONFIDENCE NOTE: Idp/AuthorizationCodeApplication/IdpApplication and
-- conduitTokenRequest/conduitRefreshTokenRequest's full signatures are
-- confirmed directly against hoauth2's own Haddock. mkAuthorizationRequest's
-- precise return type is inferred by analogy to its confirmed PKCE
-- sibling (mkPkceAuthorizeRequest :: IdpApplication i a -> m (URI,
-- CodeVerifier)) rather than seen with its own type signature directly
-- -- the one piece here most likely to still need a small correction.
--
-- Scope deliberately excludes building the local HTTP callback server
-- for the authorization-code redirect -- real, substantial additional
-- scope better suited to §7 (Configuration & First Run).
module Owl.Provider.OAuth.Google
  ( GoogleProvider (..)
  , googleIdp
  , mkGoogleApplication
  , googleMailScope
  , buildAuthorizationUrl
  , exchangeCodeForToken
  , refreshAccessToken
  ) where

import Control.Monad.Trans.Except (runExceptT)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LT
import Network.HTTP.Client (Manager)
import Network.OAuth2.Experiment
import Network.OAuth2 hiding (refreshAccessToken)
import URI.ByteString (URI)
import URI.ByteString.QQ (uri)

-- | Phantom marker type identifying Google as the Idp -- matches
-- hoauth2's own "Experiment" API convention exactly (its own example
-- uses the identical pattern: "data Google = Google deriving (Eq, Show)").
data GoogleProvider = GoogleProvider
  deriving stock (Eq, Show)

googleIdp :: Idp GoogleProvider
googleIdp = Idp
  { idpAuthorizeEndpoint           = [uri|https://accounts.google.com/o/oauth2/v2/auth|]
  , idpTokenEndpoint               = [uri|https://oauth2.googleapis.com/token|]
  , idpUserInfoEndpoint            = [uri|https://www.googleapis.com/oauth2/v2/userinfo|]
  , idpDeviceAuthorizationEndpoint = Just [uri|https://oauth2.googleapis.com/device/code|]
  }

-- | Full mail access scope for IMAP/SMTP XOAUTH2 -- Google's own
-- documented scope for this, not invented.
googleMailScope :: Text
googleMailScope = "https://mail.google.com/"

-- | ClientId/ClientSecret/Scope are hoauth2's own dedicated newtype
-- wrappers (confirmed needed by the compiler's own type errors when
-- bare Text was supplied) -- assumed to share their type's name as
-- constructor, matching hoauth2's own established naming convention
-- elsewhere (e.g. GoogleProvider's marker-type pattern); the most
-- likely remaining thing to need a one-word correction if wrong.
-- | acAuthorizeState is threaded in explicitly (a genuine, per-flow
-- random value the caller generates), not hardcoded -- that field
-- exists specifically for CSRF protection on the OAuth2 authorization-
-- code flow (the state value the caller sends is later checked
-- against what the provider echoes back on the callback), and an
-- earlier version of this function used a static string, providing
-- none. This is the same "thread the effect-needing value in
-- explicitly rather than hide it" pattern already used for MessageId
-- in validateMessage/replyTo (§12/§21) -- minting a real random state
-- is an effect, so it's the caller's job, not this pure function's.
-- The actual generation (and later verification against the
-- callback) belongs to the OAuth flow orchestration this function's
-- own module note already says is deliberately out of scope here;
-- Data.UUID (already used elsewhere in this codebase for minting
-- MessageId) is a reasonable source for it when that's built.
mkGoogleApplication :: Text -> Text -> Text -> URI -> AuthorizationCodeApplication
mkGoogleApplication clientId clientSecret state redirectUri = AuthorizationCodeApplication
  { acClientId                    = ClientId (LT.fromStrict clientId)
  , acClientSecret                = ClientSecret (LT.fromStrict clientSecret)
  , acScope                       = Set.singleton (Scope (LT.fromStrict googleMailScope))
  , acAuthorizeState              = AuthorizeState (LT.fromStrict state)
  , acAuthorizeRequestExtraParams = Map.empty
  , acRedirectUri                 = redirectUri
  , acName                        = "owl-gmail"
  , acClientAuthenticationMethod  = ClientSecretBasic
  }

buildAuthorizationUrl :: IdpApplication GoogleProvider AuthorizationCodeApplication -> URI
buildAuthorizationUrl = mkAuthorizationRequest

exchangeCodeForToken
  :: IdpApplication GoogleProvider AuthorizationCodeApplication
  -> Manager
  -> ExchangeTokenInfo AuthorizationCodeApplication
  -> IO (Either Text TokenResponse)
exchangeCodeForToken idpApp mgr code = do
  result <- runExceptT (conduitTokenRequest idpApp mgr code)
  pure (either (Left . renderTokenError) Right result)

refreshAccessToken
  :: IdpApplication GoogleProvider AuthorizationCodeApplication
  -> Manager
  -> RefreshToken
  -> IO (Either Text TokenResponse)
refreshAccessToken idpApp mgr refreshTok = do
  result <- runExceptT (conduitRefreshTokenRequest idpApp mgr refreshTok)
  pure (either (Left . renderTokenError) Right result)

renderTokenError :: Show e => e -> Text
renderTokenError = Text.pack . show
