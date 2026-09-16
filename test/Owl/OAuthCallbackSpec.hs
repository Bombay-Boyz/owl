-- | A real local HTTP round-trip test -- not a fixture. Starts the
-- actual server, makes an actual HTTP request against it (via curl,
-- a universally-available, battle-tested primitive -- the same
-- reasoning as shelling out to `security` for Keychain access,
-- avoiding a Haskell HTTP client library's own behavior as a
-- confounding variable while debugging), and verifies the result.
-- Uses three distinct ports across the three tests to avoid any
-- port-reuse collision between them.
module Owl.OAuthCallbackSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import System.Process (readProcess)
import Test.Hspec

import Owl.OAuthCallback

tenSeconds :: Int
tenSeconds = 10 * 1000000

fireCallback :: Int -> String -> IO ()
fireCallback port queryString = do
  _ <- readProcess "curl" ["-s", "http://127.0.0.1:" ++ show port ++ "/callback?" ++ queryString] ""
  pure ()

spec :: Spec
spec = describe "Owl.OAuthCallback -- real local HTTP round-trip" $ do
  it "captures a successful callback with matching code and state" $ do
    let port = 18765
    resultAsync <- async (awaitOAuthCallback port "expected-state-123" tenSeconds)
    threadDelay 200000  -- give the server a moment to start listening
    fireCallback port "code=auth-code-abc&state=expected-state-123"
    result <- wait resultAsync
    result `shouldBe` Just (CallbackSuccess "auth-code-abc" "expected-state-123")

  it "reports CallbackStateMismatch when the state doesn't match" $ do
    let port = 18766
    resultAsync <- async (awaitOAuthCallback port "expected-state-456" tenSeconds)
    threadDelay 200000
    fireCallback port "code=auth-code-xyz&state=wrong-state"
    result <- wait resultAsync
    result `shouldBe` Just CallbackStateMismatch

  it "times out and returns Nothing if no callback ever arrives" $ do
    let port = 18767
    result <- awaitOAuthCallback port "expected-state-789" 500000  -- 0.5 second timeout
    result `shouldBe` Nothing
