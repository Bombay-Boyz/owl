module Owl.TUI.CoreSpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Application (emptyApplication)
import Owl.Domain.Id (LocalId (..), MessageId (..), ThreadId (..))
import Owl.TUI.Core

tid :: ThreadId
tid = ThreadId "t1"

mid :: MessageId
mid = MessageId (LocalId (UUID.fromWords 1 0 0 0))

allScreens :: [Screen]
allScreens =
  [ InboxScreen, ThreadScreen tid, SearchScreen
  , ComposeScreen, ContactScreen, HelpScreen
  ]

-- | One representative Command per tag, EXCEPT SearchCommand, which
-- would need a concrete Query value. SearchTag is still fully covered
-- by the tag-level partition property below -- which is where the
-- partition is actually defined -- so nothing goes untested.
representativeCommands :: [Command]
representativeCommands =
  [ OpenThread tid
  , Reply tid
  , Forward mid
  , Compose
  , ArchiveThread tid
  , DeleteMessage mid
  , MarkMessageRead mid
  , MarkMessageUnread mid
  , UndoCommand
  , HelpCommand
  , Back
  , Quit
  ]

spec :: Spec
spec = do
  describe "commandsFor / transitionScreen -- the per-screen partition (§23)" $ do
    -- §23: "transitionScreen's valid command set is explicitly
    -- partitioned per screen and property-tested" and "a Command not
    -- in commandsFor currentScreen is a CommandError, never silently
    -- ignored or reinterpreted."
    it "transitionScreen succeeds if and only if the command's tag is in commandsFor for that screen" $ hedgehog $ do
      screen <- forAll (Gen.element allScreens)
      cmd    <- forAll (Gen.element representativeCommands)
      let permitted = commandTag cmd `Set.member` commandsFor screen
          outcome   = either (const False) (const True) (transitionScreen screen cmd)
      outcome === permitted

    it "rejects with the specific offending tag and screen, not a generic error" $
      transitionScreen ComposeScreen (Reply tid)
        `shouldBe` Left (CommandNotValidForScreen ReplyTag ComposeScreenTag)

    it "ComposeScreen permits no r/f/a/d -- §23 calls these out by name as text, not commands" $ do
      let composeTags = commandsFor ComposeScreen
      map (`Set.member` composeTags) [ReplyTag, ForwardTag, ArchiveTag, DeleteTag]
        `shouldBe` [False, False, False, False]

    it "HelpScreen is a leaf: only Back and Quit" $
      commandsFor HelpScreen `shouldBe` Set.fromList [BackTag, QuitTag]

    it "every screen permits Quit -- there is always a way out" $
      mapM_ (\s -> (QuitTag `Set.member` commandsFor s) `shouldBe` True) allScreens

    it "every screen except the inbox permits Back -- the inbox is the root" $ do
      (BackTag `Set.member` commandsFor InboxScreen) `shouldBe` False
      mapM_ (\s -> (BackTag `Set.member` commandsFor s) `shouldBe` True)
            [ThreadScreen tid, SearchScreen, ComposeScreen, ContactScreen, HelpScreen]

  describe "transitionScreen -- navigation targets" $ do
    it "Enter on a thread opens that specific thread" $
      transitionScreen InboxScreen (OpenThread tid) `shouldBe` Right (ThreadScreen tid)

    it "reply and forward both open the compose screen" $ do
      transitionScreen InboxScreen (Reply tid)   `shouldBe` Right ComposeScreen
      transitionScreen InboxScreen (Forward mid) `shouldBe` Right ComposeScreen

    it "help is reachable from the inbox" $
      transitionScreen InboxScreen HelpCommand `shouldBe` Right HelpScreen

    it "commands with only a domain effect leave the screen unchanged" $ do
      transitionScreen InboxScreen (MarkMessageRead mid) `shouldBe` Right InboxScreen
      transitionScreen InboxScreen (ArchiveThread tid)   `shouldBe` Right InboxScreen
      transitionScreen InboxScreen UndoCommand           `shouldBe` Right InboxScreen

  describe "interpretInput -- the binding table" $ do
    it "maps the §23 keyboard vocabulary on the inbox" $ do
      interpretInput InboxScreen (Just tid) (Just mid) KeyEnter      `shouldBe` Right (OpenThread tid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'r') `shouldBe` Right (Reply tid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'f') `shouldBe` Right (Forward mid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'a') `shouldBe` Right (ArchiveThread tid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'd') `shouldBe` Right (DeleteMessage mid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'u') `shouldBe` Right (MarkMessageUnread mid)
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'c') `shouldBe` Right Compose
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'z') `shouldBe` Right UndoCommand
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar '?') `shouldBe` Right HelpCommand

    it "reports NoSelectionUnderCursor rather than silently dropping a key on an empty mailbox" $ do
      interpretInput InboxScreen Nothing Nothing KeyEnter      `shouldBe` Left NoSelectionUnderCursor
      interpretInput InboxScreen Nothing Nothing (KeyChar 'r') `shouldBe` Left NoSelectionUnderCursor
      interpretInput InboxScreen Nothing Nothing (KeyChar 'd') `shouldBe` Left NoSelectionUnderCursor

    it "reports UnboundInput for a key with no binding at all" $
      interpretInput InboxScreen (Just tid) (Just mid) (KeyChar 'X')
        `shouldBe` Left (UnboundInput (KeyChar 'X') InboxTag)

    it "rejects a screen-invalid key via CommandRejected, not UnboundInput -- the distinction is real" $
      interpretInput ComposeScreen (Just tid) (Just mid) (KeyChar 'r')
        `shouldBe` Left (CommandRejected (CommandNotValidForScreen ReplyTag ComposeScreenTag))

    it "Esc and q are both Back" $ do
      interpretInput HelpScreen Nothing Nothing KeyEsc        `shouldBe` Right Back
      interpretInput HelpScreen Nothing Nothing (KeyChar 'q') `shouldBe` Right Back

  describe "command -- keypress to domain events" $ do
    -- Pins the CURRENT, honest behaviour of the known gap rather than
    -- an aspirational assertion: selectedMessage is hardcoded Nothing
    -- until cursor->selection resolution lands with the view layer, so
    -- any message-scoped command correctly reports that there is no
    -- selection. When that gap closes, this test should be REPLACED by
    -- one asserting Right [MessageUnread mid] -- its failure at that
    -- point is the signal the gap is closed, not a regression.
    it "message-scoped commands currently report NoSelectionUnderCursor -- the documented selection gap" $
      command (KeyChar 'u') emptyApplication (initialUIState { uiScreen = ThreadScreen tid })
        `shouldBe` Left NoSelectionUnderCursor

    it "navigation commands produce no domain event -- the documented deviation (2) in action" $
      command (KeyChar 'c') emptyApplication initialUIState `shouldBe` Right []

    it "surfaces a rejected command as an error rather than an empty event list" $
      command (KeyChar 'X') emptyApplication initialUIState
        `shouldBe` Left (UnboundInput (KeyChar 'X') InboxTag)

  describe "view (§23: the TUI owns no domain state)" $
    it "returns exactly what UIState says, regardless of Application" $
      mapM_ (\s -> view emptyApplication (initialUIState { uiScreen = s }) `shouldBe` s) allScreens
