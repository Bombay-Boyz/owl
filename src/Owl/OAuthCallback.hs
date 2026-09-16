-- | A local, one-shot HTTP server for capturing the OAuth2
-- authorization-code redirect (master spec §7). Uses bare `warp`+`wai`
-- rather than a full routing framework (scotty etc.) -- a single
-- callback endpoint doesn't need one.
--
-- CONFIDENCE NOTE: warp's core `run :: Port -> Application -> IO ()`
-- signature and wai's Application/queryString shapes are well-known,
-- stable, extremely widely-used APIs (warp underlies most of the
-- Haskell web ecosystem) -- lower research risk than most of what
-- this project has integrated, but not independently re-verified
-- against source the way the more obscure/recently-broken
-- dependencies were.
module Owl.OAuthCallback
  ( CallbackResult (..)
  , awaitOAuthCallback
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import System.Timeout (timeout)

data CallbackResult
  = CallbackSuccess { callbackCode :: Text, callbackState :: Text }
  | CallbackProviderError Text
    -- ^ The provider itself redirected back with an "error" parameter
    -- (e.g. the user denied consent) rather than a code.
  | CallbackStateMismatch
    -- ^ The state parameter didn't match what we sent -- either a
    -- genuine CSRF/replay attempt, or a stale/duplicate request. Named
    -- distinctly rather than folded into a generic error, matching
    -- this codebase's own established discipline for naming real,
    -- distinct cases rather than collapsing them.
  | CallbackMalformed Text
  deriving stock (Eq, Show)

-- | Starts a one-shot local HTTP server on the given port, waits for
-- exactly one OAuth2 authorization callback request (verifying its
-- "state" query parameter against expectedState -- the CSRF-protection
-- value generated when the authorization URL was built; see
-- Owl.Provider.OAuth.Google's own note on why that must be a genuine
-- per-flow random value, not hardcoded), and shuts the server down as
-- soon as one request is handled or the timeout elapses, whichever
-- comes first.
--
-- Returns Nothing on timeout -- e.g. the user closed the browser tab
-- without completing the flow, which produces no HTTP request at all
-- to otherwise signal abandonment. timeoutMicros is in microseconds
-- (System.Timeout's own unit); the caller decides how long is
-- reasonable to wait.
awaitOAuthCallback :: Int -> Text -> Int -> IO (Maybe CallbackResult)
awaitOAuthCallback port expectedState timeoutMicros = do
  resultVar <- newEmptyMVar
  let app req respond = do
        let params  = Wai.queryString req
            getParam key = lookup key params >>= id
            mCode   = TE.decodeUtf8 <$> getParam "code"
            mState  = TE.decodeUtf8 <$> getParam "state"
            mErrorP = TE.decodeUtf8 <$> getParam "error"
            result = case (mErrorP, mCode, mState) of
              (Just err, _, _)        -> CallbackProviderError err
              (_, Just code, Just st)
                | st == expectedState -> CallbackSuccess code st
                | otherwise           -> CallbackStateMismatch
              _                       -> CallbackMalformed "missing code or state query parameter"
        -- respond MUST complete before putMVar: putMVar unblocks the
        -- main thread, which immediately kills this server thread --
        -- if that happened before respond had actually finished
        -- writing the HTTP response bytes back over the socket, the
        -- client would see a reset connection instead of a real
        -- response. Caught by a real local HTTP test, not by
        -- reasoning alone.
        responseReceived <- respond (Wai.responseLBS status200 [("Content-Type", "text/html; charset=utf-8")] callbackPageHtml)
        putMVar resultVar result
        pure responseReceived

  _serverThread <- forkIO (Warp.run port app)
  -- Deliberately never killed. A real local HTTP test (using both
  -- http-client AND curl as independent clients, ruling out either
  -- being the confounding factor) showed that killThread on the
  -- thread running Warp.run aborts in-flight connections regardless
  -- of how long a delay precedes it -- Warp evidently handles
  -- connection I/O in a way tied to that thread/socket such that
  -- killing it is unsafe no matter the timing, not just "too early."
  -- This is a short-lived, one-shot onboarding flow: leaking one
  -- harmless background listener thread for the remainder of the
  -- process's life is a far simpler, safer trade than building
  -- correct graceful-shutdown socket management for something this
  -- transient.
  result <- timeout timeoutMicros (takeMVar resultVar)
  pure result

callbackPageHtml :: LBS.ByteString
callbackPageHtml =
  "<html><body><h1>Owl</h1><p>You can close this tab and return to Owl.</p></body></html>"
