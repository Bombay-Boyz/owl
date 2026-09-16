module Owl.Provider.IMAPSpec (spec) where

import Test.Hspec

import Owl.Application (MailboxKind (..))
import Owl.Provider.IMAP (inferMailboxKind)

spec :: Spec
spec = describe "inferMailboxKind (name-based heuristic, §20)" $ do
  it "recognizes INBOX case-insensitively" $ do
    inferMailboxKind "INBOX" `shouldBe` Inbox
    inferMailboxKind "inbox" `shouldBe` Inbox

  it "recognizes Gmail's actual special-folder names" $ do
    inferMailboxKind "[Gmail]/Sent Mail" `shouldBe` Sent
    inferMailboxKind "[Gmail]/Drafts" `shouldBe` DraftsMailbox
    inferMailboxKind "[Gmail]/Trash" `shouldBe` Trash
    inferMailboxKind "[Gmail]/All Mail" `shouldBe` ArchiveMailbox

  it "falls back to CustomMailbox for anything unrecognized" $
    inferMailboxKind "Projects/Owl" `shouldBe` CustomMailbox
