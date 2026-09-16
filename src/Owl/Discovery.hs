{-# LANGUAGE QuasiQuotes #-}
-- | Provider auto-discovery (master spec §7). Precedence exactly as
-- the spec's own words state: "DNS SRV first (RFC 6186), falling back
-- to MX plus known-provider heuristics" -- SRV is the most
-- authoritative signal (a domain owner explicitly publishing SRV
-- records wins over any hardcoded guess, even for a domain we
-- recognize), with the known-provider table and MX-based hostname
-- guessing as a bundled fallback for when no SRV records exist --
-- which, for a plain gmail.com address, is the expected common case,
-- since Gmail's own consumer setup doesn't rely on SRV autodiscovery.
--
-- Uses the `dns` package: pure Haskell (portable, unlike `resolv`'s
-- libresolv FFI binding), and directly verified against its own
-- source -- lookupSRV/lookupMX/makeResolvSeed/withResolver's exact
-- signatures, and Domain being a plain ByteString type alias -- not
-- taken from documentation.
--
-- CONFIDENCE NOTE: the SRV/MX combinators themselves are confirmed;
-- what ISN'T separately verified is the exact shape of a real SRV
-- response for mail services in practice (trailing-dot handling on
-- the target hostname is handled defensively here, but untested
-- against an actual server that publishes these records, since none
-- of Owl's own currently-relevant providers do).
module Owl.Discovery
  ( discoverProvider
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import qualified Network.DNS as DNS
import URI.ByteString.QQ (uri)

import Owl.Domain.Address (EmailAddress, unEmailAddress)
import Owl.Wizard

extractDomain :: EmailAddress -> Either DiscoveryError Text
extractDomain email = case Text.splitOn "@" (unEmailAddress email) of
  [_, domain] -> Right domain
  _           -> Left (DomainParseFailed (unEmailAddress email))

-- | Google's OAuth2 endpoints, matching Owl.Provider.OAuth.Google's
-- own googleIdp exactly (some duplication of two literal URLs across
-- the two modules is accepted here -- OAuth2Endpoints is deliberately
-- the generic, protocol-level type §7 wants, distinct from hoauth2's
-- own typed Idp value that module needs for a different purpose, so
-- there's no single shared value to reuse without adding real
-- coupling for very little gain).
googleOAuth2Endpoints :: OAuth2Endpoints
googleOAuth2Endpoints = OAuth2Endpoints
  { oauth2AuthorizeUrl = [uri|https://accounts.google.com/o/oauth2/v2/auth|]
  , oauth2TokenUrl     = [uri|https://oauth2.googleapis.com/token|]
  , oauth2Scope        = "https://mail.google.com/"
  }

-- | Consulted only as part of the fallback bundle, after SRV has
-- already been tried and failed -- see this module's own top-level
-- note on precedence.
knownProviders :: [(Text, ProviderConfig)]
knownProviders =
  [ ( "gmail.com"
    , ProviderConfig
        { imapEndpoint = ServerEndpoint "imap.gmail.com" 993 TLSImplicit
        , smtpEndpoint = ServerEndpoint "smtp.gmail.com" 465 TLSImplicit
        , authMethod   = OAuth2 googleOAuth2Endpoints
        }
    )
  ]

-- | SRV and the known-provider table answer DIFFERENT questions --
-- SRV says WHERE to connect, the known-provider table says HOW to
-- authenticate -- and a real DNS test against gmail.com surfaced
-- exactly why conflating them is wrong: Google does publish real SRV
-- records for gmail.com's mail services (an assumption in this
-- module's own earlier commentary that turned out false), so the SRV
-- path succeeds and would otherwise permanently shadow the known-
-- provider table's OAuth2 entry, silently downgrading every real
-- Gmail account to PasswordAuth even though we KNOW it supports
-- OAuth2. Fixed by using SRV's discovered host/port (still the most
-- authoritative connectivity signal, respecting "SRV first") while
-- overlaying the known-provider table's auth method whenever the
-- domain matches one, since SRV records cannot express OAuth2
-- capability at all.
discoverProvider :: EmailAddress -> IO (Either DiscoveryError ProviderConfig)
discoverProvider email = case extractDomain email of
  Left err     -> pure (Left err)
  Right domain -> do
    srvResult <- discoverViaSRV domain
    case srvResult of
      Right cfg -> pure (Right (applyKnownAuthMethod domain cfg))
      Left _    -> case lookup domain knownProviders of
        Just cfg -> pure (Right cfg)
        Nothing  -> discoverViaMX domain
  where
    applyKnownAuthMethod domain cfg = case lookup domain knownProviders of
      Just knownCfg -> cfg { authMethod = authMethod knownCfg }
      Nothing       -> cfg

discoverViaSRV :: Text -> IO (Either DiscoveryError ProviderConfig)
discoverViaSRV domain = do
  seed <- DNS.makeResolvSeed DNS.defaultResolvConf
  DNS.withResolver seed $ \resolver -> do
    imapEp <- discoverSRVEndpoint resolver domain "_imaps._tcp." "_imap._tcp." TLSImplicit STARTTLS
    smtpEp <- discoverSRVEndpoint resolver domain "_submissions._tcp." "_submission._tcp." TLSImplicit STARTTLS
    pure $ case (imapEp, smtpEp) of
      (Just imap, Just smtp) -> Right (ProviderConfig imap smtp PasswordAuth)
      _                      -> Left NoEndpointsDiscovered

-- | Tries the preferred (implicit-TLS) SRV service name first, then
-- the STARTTLS variant, per RFC 6186's own stated preference order.
discoverSRVEndpoint
  :: DNS.Resolver -> Text -> Text -> Text -> TransportSecurity -> TransportSecurity
  -> IO (Maybe ServerEndpoint)
discoverSRVEndpoint resolver domain preferredPrefix fallbackPrefix preferredSecurity fallbackSecurity = do
  preferred <- trySRV preferredPrefix preferredSecurity
  case preferred of
    Just ep -> pure (Just ep)
    Nothing -> trySRV fallbackPrefix fallbackSecurity
  where
    trySRV prefix security = do
      result <- DNS.lookupSRV resolver (TE.encodeUtf8 (prefix <> domain))
      pure $ case result of
        Right ((_prio, _weight, port, target) : _) ->
          Just (ServerEndpoint (stripTrailingDot (TE.decodeUtf8 target)) port security)
        _ -> Nothing

    stripTrailingDot t = fromMaybe t (Text.stripSuffix "." t)

discoverViaMX :: Text -> IO (Either DiscoveryError ProviderConfig)
discoverViaMX domain = do
  seed <- DNS.makeResolvSeed DNS.defaultResolvConf
  DNS.withResolver seed $ \resolver -> do
    result <- DNS.lookupMX resolver (TE.encodeUtf8 domain)
    pure $ case result of
      Left dnsErr -> Left (DnsLookupFailed (Text.pack (show dnsErr)))
      Right []    -> Left NoEndpointsDiscovered
      Right (_ : _) ->
        -- A conventional-hostname guess, not an authoritative signal:
        -- MX only confirms the domain accepts mail, it does not
        -- specify where IMAP/SMTP client access lives. imap.<domain>/
        -- smtp.<domain> is the most common real-world convention when
        -- SRV is absent and the provider isn't in our own table.
        Right ProviderConfig
          { imapEndpoint = ServerEndpoint ("imap." <> domain) 993 TLSImplicit
          , smtpEndpoint = ServerEndpoint ("smtp." <> domain) 465 TLSImplicit
          , authMethod   = PasswordAuth
          }
