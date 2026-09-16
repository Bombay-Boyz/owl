module Owl.Config.TomlSpec (spec) where

import Control.Exception (finally)
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import Test.Hspec

import Owl.Config
import Owl.Config.Toml (loadConfig, saveConfig)

testConfigPath :: IO FilePath
testConfigPath = do
  tmpDir <- getTemporaryDirectory
  pure (tmpDir </> "owl-test-config-roundtrip.toml")

mkRawConfigFixture :: RawConfig
mkRawConfigFixture = RawConfig
  { rawUi = RawUiPreferences { rawTheme = Just "light" }
  , rawAccounts =
      [ RawAccount
          { rawAccountName    = "personal"
          , rawAccountEmail   = "user@example.com"
          , rawAccountBackend = Nothing
          }
      , RawAccount
          { rawAccountName    = "work"
          , rawAccountEmail   = "work@example.org"
          , rawAccountBackend = Just RawAccountBackend
              { rawImapHost     = "imap.example.org"
              , rawImapPort     = 993
              , rawImapSecurity = "tls"
              , rawSmtpHost     = "smtp.example.org"
              , rawSmtpPort     = 587
              , rawSmtpSecurity = "starttls"
              }
          }
      ]
  }

spec :: Spec
spec = describe "Owl.Config.Toml" $ do
  it "reports ConfigFileNotFound for a path that doesn't exist" $ do
    path <- testConfigPath
    exists <- doesFileExist path
    if exists then removeFile path else pure ()
    result <- loadConfig (ExplicitConfigPath path)
    result `shouldBe` Left (ConfigFileNotFound path)

  it "recovers an equal Config after saveConfig then loadConfig, including a nested backend override" $ do
    path <- testConfigPath
    let source = ExplicitConfigPath path
    (case validateConfig mkRawConfigFixture of
      Left err       -> expectationFailure ("fixture itself failed to validate: " ++ show err)
      Right original -> do
        saveResult <- saveConfig source original
        saveResult `shouldBe` Right ()
        loadResult <- loadConfig source
        loadResult `shouldBe` Right original
      ) `finally` do
        exists <- doesFileExist path
        if exists then removeFile path else pure ()
