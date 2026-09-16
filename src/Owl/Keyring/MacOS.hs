-- | KeyringHandle's real macOS backend (master spec §7), implemented
-- by shelling out to the `security` command-line tool rather than
-- depending on a Haskell keyring library -- neither of the two that
-- exist is viable (one hasn't been touched since 2017 and supports
-- only macOS+KWallet; the other, from 2018, explicitly documents that
-- macOS isn't supported at all). `security` is a stable, long-
-- documented OS primitive, arguably more battle-tested than any
-- third-party Haskell wrapper around it would be.
--
-- KNOWN, DISCLOSED LIMITATION: `security add-generic-password -w
-- <password>` takes the secret as a literal command-line argument.
-- For the brief duration of that call, the secret is visible to other
-- processes on the same machine (e.g. via `ps`). This is a real
-- property of `security`'s own CLI design -- there is no documented
-- stdin-based alternative -- not something introduced here. Disclosed
-- plainly rather than glossed over.
--
-- Secrets are required to be valid UTF-8 text: the command line is a
-- text interface, and our own realistic secret types (passwords,
-- OAuth2 bearer tokens) are always text. A ByteString that isn't valid
-- UTF-8 is rejected with a named error rather than silently mangled.
module Owl.Keyring.MacOS
  ( macOSKeyringHandle
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

import Owl.Domain.Id (AccountId (..))
import Owl.Wizard (KeyringError (..), KeyringHandle (..))

-- | Namespaces every entry Owl creates in the keychain, distinguishing
-- them from other applications' entries. The AccountId itself is the
-- per-account distinguishing key within that namespace.
serviceName :: String
serviceName = "owl-mail"

macOSKeyringHandle :: KeyringHandle IO
macOSKeyringHandle = KeyringHandle
  { storeSecret  = storeSecretImpl
  , loadSecret   = loadSecretImpl
  , deleteSecret = deleteSecretImpl
  }

accountArg :: AccountId -> String
accountArg (AccountId txt) = Text.unpack txt

runSecurityProcess :: [String] -> IO (Either KeyringError (ExitCode, String, String))
runSecurityProcess args = do
  result <- try (readProcessWithExitCode "security" args "") :: IO (Either SomeException (ExitCode, String, String))
  pure $ case result of
    Left e  -> Left (KeyringUnavailable (Text.pack (show e)))
    Right r -> Right r

storeSecretImpl :: AccountId -> ByteString -> IO (Either KeyringError ())
storeSecretImpl acctId secretBytes = case TE.decodeUtf8' secretBytes of
  Left _ -> pure (Left (KeyringUnavailable "secret is not valid UTF-8 text; the macOS security CLI backend requires text-representable secrets"))
  Right secretText -> do
    outcome <- runSecurityProcess
      [ "add-generic-password"
      , "-a", accountArg acctId
      , "-s", serviceName
      , "-w", Text.unpack secretText
      , "-U"
      ]
    pure $ case outcome of
      Left e                            -> Left e
      Right (ExitSuccess, _, _)         -> Right ()
      Right (ExitFailure code, _, err') -> Left (KeyringAccessDenied (renderFailure "add-generic-password" code err'))

loadSecretImpl :: AccountId -> IO (Either KeyringError ByteString)
loadSecretImpl acctId = do
  outcome <- runSecurityProcess ["find-generic-password", "-a", accountArg acctId, "-s", serviceName, "-w"]
  pure $ case outcome of
    Left e -> Left e
    Right (ExitSuccess, out, _) -> Right (TE.encodeUtf8 (Text.pack (chomp out)))
    Right (ExitFailure code, _, err')
      | "could not be found" `isInfixOf` err' -> Left (KeyringSecretNotFound acctId)
      | otherwise                              -> Left (KeyringAccessDenied (renderFailure "find-generic-password" code err'))

deleteSecretImpl :: AccountId -> IO (Either KeyringError ())
deleteSecretImpl acctId = do
  outcome <- runSecurityProcess ["delete-generic-password", "-a", accountArg acctId, "-s", serviceName]
  pure $ case outcome of
    Left e -> Left e
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure code, _, err')
      | "could not be found" `isInfixOf` err' -> Left (KeyringSecretNotFound acctId)
      | otherwise                              -> Left (KeyringAccessDenied (renderFailure "delete-generic-password" code err'))

renderFailure :: Text -> Int -> String -> Text
renderFailure cmd code err' = cmd <> " exited " <> Text.pack (show code) <> ": " <> Text.pack err'

chomp :: String -> String
chomp s = case reverse s of
  ('\n' : rest) -> reverse rest
  _             -> s
