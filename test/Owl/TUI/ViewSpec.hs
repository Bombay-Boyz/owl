module Owl.TUI.ViewSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Application
  ( Application (messages, threads)
  , MessageState (..)
  , ThreadState (..)
  , emptyApplication
  )
import Owl.Domain.Address (mkEmailAddress)
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Event (Event (..))
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.TUI.Core
import Owl.TUI.View

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

addrNamed :: Text -> Text -> Address
addrNamed name email = Address (Just name) (either (error . show) id (mkEmailAddress email))

addrBare :: Text -> Address
addrBare email = Address Nothing (either (error . show) id (mkEmailAddress email))

atDay :: Int -> UTCTime
atDay d = UTCTime (fromGregorian 2026 1 d) (secondsToDiffTime 0)

mkMsg :: Int -> ThreadId -> Address -> Text -> Int -> Bool -> Message
mkMsg n threadId from subjText day isSeen = Message
  { identity    = MessageIdentity { messageId = mkMid n, rfcId = Nothing }
  , accountId   = AccountId "acct"
  , threadId    = threadId
  , sender      = from
  , recipients  = [addrBare "me@example.com"]
  , subject     = either (error . show) id (mkSubject subjText)
  , sentAt      = atDay day
  , body        = BodyT.Body (Just "body text") Nothing
  , attachments = []
  , flags       = if isSeen then Set.singleton Seen else Set.empty
  , references  = []
  , replyTo     = []
  }

-- Thread A: two messages (one unread), newest on day 5.
-- Thread B: one message, read, day 9  -> newest overall, sorts first.
-- Thread C: one message, day 1, but ARCHIVED -> must not appear.
appFixture :: Application
appFixture = emptyApplication
  { messages = MessageState
      { messageStateMessages = Map.fromList
          [ (mkMid 1, mkMsg 1 (ThreadId "A") (addrNamed "Alice" "alice@example.com") "Project update" 3 True)
          , (mkMid 2, mkMsg 2 (ThreadId "A") (addrNamed "Bob" "bob@example.net")     "Re: Project update" 5 False)
          , (mkMid 3, mkMsg 3 (ThreadId "B") (addrBare "carol@example.org")          "Invoice" 9 True)
          , (mkMid 4, mkMsg 4 (ThreadId "C") (addrNamed "Dave" "dave@example.com")   "Old thing" 1 True)
          ]
      , archivedMessages = Set.singleton (mkMid 4)
      , deletedMessages  = Set.empty
      }
  , threads = ThreadState (Map.fromList
      [ (ThreadId "A", Set.fromList [mkMid 1, mkMid 2])
      , (ThreadId "B", Set.singleton (mkMid 3))
      , (ThreadId "C", Set.singleton (mkMid 4))
      ])
  }

fullView :: InboxView
fullView = buildInboxView appFixture 0 defaultViewportRows 0

-- Total accessors: this project bans partial `head` (-Wx-partial as an
-- error), and rightly so -- a test that explodes on an empty list
-- reports a crash instead of a useful expectation failure.
rowFor :: ThreadId -> Maybe InboxRow
rowFor t = listToMaybe (filter ((== t) . rowThreadId) (viewRows fullView))

lineAt :: Int -> Doc -> Maybe DocLine
lineAt i d = listToMaybe (drop i (docLines d))

firstSpanAt :: Int -> Doc -> Maybe DocSpan
firstSpanAt i d = lineAt i d >>= listToMaybe . lineSpans

spec :: Spec
spec = do
  describe "buildInboxView -- row construction" $ do
    it "orders threads newest-first" $
      map rowThreadId (viewRows fullView) `shouldBe` [ThreadId "B", ThreadId "A"]

    it "omits a thread whose every message is archived -- absent, not an empty row" $
      map rowThreadId (viewRows fullView) `shouldNotContain` [ThreadId "C"]

    it "reports the thread's newest message's sender and subject" $ do
      fmap rowSender  (rowFor (ThreadId "A")) `shouldBe` Just "Bob"
      fmap rowSubject (rowFor (ThreadId "A")) `shouldBe` Just "Re: Project update"
      fmap rowDate    (rowFor (ThreadId "A")) `shouldBe` Just (atDay 5)

    it "marks a thread unread if ANY message in it is unread, not just the newest" $ do
      fmap rowUnread (rowFor (ThreadId "A")) `shouldBe` Just True
      fmap rowUnread (rowFor (ThreadId "B")) `shouldBe` Just False

    it "counts the visible messages in the thread" $
      fmap rowMessageCount (rowFor (ThreadId "A")) `shouldBe` Just 2

    it "falls back to the bare address when there is no display name" $
      fmap rowSender (rowFor (ThreadId "B")) `shouldBe` Just "carol@example.org"

    it "reports the total thread count independently of the window size" $
      viewTotalThreads (buildInboxView appFixture 0 1 0) `shouldBe` 2

  describe "buildInboxView -- the viewport bound (§23)" $ do
    it "never returns more rows than the requested limit" $
      length (viewRows (buildInboxView appFixture 0 1 0)) `shouldBe` 1

    it "returns no rows for a zero or negative limit rather than failing" $ do
      viewRows (buildInboxView appFixture 0 0 0)    `shouldBe` []
      viewRows (buildInboxView appFixture 0 (-5) 0) `shouldBe` []

    it "clamps a cursor past the end of a shrinking mailbox" $
      viewCursor (buildInboxView appFixture 0 defaultViewportRows 999) `shouldBe` 1

    it "clamps a negative offset and cursor" $ do
      viewOffset (buildInboxView appFixture (-3) defaultViewportRows 0) `shouldBe` 0
      viewCursor (buildInboxView appFixture 0 defaultViewportRows (-3)) `shouldBe` 0

    it "yields an empty view for an application with no messages at all" $
      viewRows (buildInboxView emptyApplication 0 defaultViewportRows 0) `shouldBe` []

  describe "selection" $ do
    it "selects the row under the cursor" $ do
      selectedThreadId (buildInboxView appFixture 0 defaultViewportRows 0) `shouldBe` Just (ThreadId "B")
      selectedThreadId (buildInboxView appFixture 0 defaultViewportRows 1) `shouldBe` Just (ThreadId "A")

    it "has no selection in an empty inbox" $
      selectedThreadId (buildInboxView emptyApplication 0 defaultViewportRows 0) `shouldBe` Nothing

  describe "threadMessageIds" $ do
    it "returns a thread's visible messages newest-first" $
      threadMessageIds appFixture (ThreadId "A") `shouldBe` [mkMid 2, mkMid 1]

    it "excludes already-archived messages" $
      threadMessageIds appFixture (ThreadId "C") `shouldBe` []

    it "returns nothing for an unknown thread" $
      threadMessageIds appFixture (ThreadId "nope") `shouldBe` []

  describe "renderInbox" $ do
    it "renders an explicit message for an empty inbox, never a blank screen" $
      renderInbox (buildInboxView emptyApplication 0 defaultViewportRows 0)
        `shouldBe` Doc [DocLine [DocSpan "No messages." Dim]]

    it "renders one line per row" $
      length (docLines (renderInbox fullView)) `shouldBe` 2

    it "emphasises the cursor row as Selected" $
      fmap spanEmphasis (firstSpanAt 0 (renderInbox fullView)) `shouldBe` Just Selected

    it "emphasises a non-selected unread row as Unread and marks it" $ do
      fmap spanEmphasis (firstSpanAt 1 (renderInbox fullView)) `shouldBe` Just Unread
      fmap spanText     (firstSpanAt 1 (renderInbox fullView)) `shouldBe` Just "* "

  describe "Core.command with a populated Application -- the closed selection gap" $ do
    it "archiving a thread expands to one MessageArchived per visible message" $
      command (KeyChar 'a') appFixture (initialUIState { uiCursor = 1 })
        `shouldBe` Right [MessageArchived (mkMid 2), MessageArchived (mkMid 1)]

    it "a message-scoped command resolves to the newest message in the selected thread" $
      command (KeyChar 'u') appFixture (initialUIState { uiCursor = 1 })
        `shouldBe` Right [MessageUnread (mkMid 2)]

    it "still reports NoSelectionUnderCursor when the inbox is genuinely empty" $
      command (KeyChar 'u') emptyApplication initialUIState
        `shouldBe` Left NoSelectionUnderCursor

  describe "applyInput -- cursor movement (UI-only, never a Command)" $ do
    it "j and the down arrow both move the cursor down" $ do
      applyInput appFixture initialUIState (KeyChar 'j')
        `shouldBe` Right (Continue (initialUIState { uiCursor = 1 }) [])
      applyInput appFixture initialUIState KeyDown
        `shouldBe` Right (Continue (initialUIState { uiCursor = 1 }) [])

    it "k and the up arrow both move the cursor up" $ do
      let atOne = initialUIState { uiCursor = 1 }
      applyInput appFixture atOne (KeyChar 'k')
        `shouldBe` Right (Continue (initialUIState { uiCursor = 0 }) [])
      applyInput appFixture atOne KeyUp
        `shouldBe` Right (Continue (initialUIState { uiCursor = 0 }) [])

    it "parks at the last row rather than walking off the end" $
      applyInput appFixture (initialUIState { uiCursor = 1 }) (KeyChar 'j')
        `shouldBe` Right (Continue (initialUIState { uiCursor = 1 }) [])

    it "parks at the first row rather than going negative" $
      applyInput appFixture initialUIState (KeyChar 'k')
        `shouldBe` Right (Continue (initialUIState { uiCursor = 0 }) [])

    it "emits no domain events -- moving a highlight is not a mail change" $ do
      let result = applyInput appFixture initialUIState (KeyChar 'j')
      fmap (\r -> case r of Continue _ evs -> evs; Exit -> [error "unexpected"]) result
        `shouldBe` Right []

    it "does not fall over on an empty inbox" $
      applyInput emptyApplication initialUIState (KeyChar 'j')
        `shouldBe` Right (Continue (initialUIState { uiCursor = 0 }) [])

  describe "applyInput -- navigation and history" $ do
    it "Enter opens the selected thread and remembers where it came from" $
      applyInput appFixture initialUIState KeyEnter
        `shouldBe` Right (Continue initialUIState
          { uiScreen         = ThreadScreen (ThreadId "B")
          , uiPreviousScreen = Just InboxScreen
          } [])

    it "? opens help, and Back returns to exactly the screen help was opened from" $ do
      let opened = applyInput appFixture (initialUIState { uiScreen = ThreadScreen (ThreadId "A") }) (KeyChar '?')
      case opened of
        Right (Continue st []) -> do
          uiScreen st `shouldBe` HelpScreen
          uiPreviousScreen st `shouldBe` Just (ThreadScreen (ThreadId "A"))
          case applyInput appFixture st (KeyChar 'q') of
            Right (Continue back []) -> uiScreen back `shouldBe` ThreadScreen (ThreadId "A")
            other -> expectationFailure ("unexpected Back result: " ++ show other)
        other -> expectationFailure ("unexpected help result: " ++ show other)

    it "Back with no history falls back to the inbox rather than failing" $ do
      let stranded = initialUIState { uiScreen = HelpScreen, uiPreviousScreen = Nothing }
      case applyInput appFixture stranded KeyEsc of
        Right (Continue st []) -> uiScreen st `shouldBe` InboxScreen
        other -> expectationFailure ("unexpected result: " ++ show other)

    it "a domain-effect command stays on the same screen and keeps the cursor" $ do
      let atOne = initialUIState { uiCursor = 1 }
      case applyInput appFixture atOne (KeyChar 'u') of
        Right (Continue st evs) -> do
          uiScreen st `shouldBe` InboxScreen
          uiCursor st `shouldBe` 1
          evs `shouldBe` [MessageUnread (mkMid 2)]
        other -> expectationFailure ("unexpected result: " ++ show other)

    it "archiving from the inbox expands over the whole selected thread" $
      case applyInput appFixture (initialUIState { uiCursor = 1 }) (KeyChar 'a') of
        Right (Continue _ evs) ->
          evs `shouldBe` [MessageArchived (mkMid 2), MessageArchived (mkMid 1)]
        other -> expectationFailure ("unexpected result: " ++ show other)

  describe "applyInput -- quitting" $
    it "q on the inbox exits, because the inbox has no Back to fall through to" $
      applyInput appFixture initialUIState (KeyChar 'q') `shouldBe` Right Exit

  describe "renderHelp (§23: discoverability, one source of truth)" $ do
    it "shows only the bindings valid for the current screen" $ do
      let helpText d = [t | DocLine spans <- docLines d, DocSpan t _ <- spans]
      helpText (renderHelp ComposeScreen) `shouldNotContain` ["reply"]
      helpText (renderHelp InboxScreen)   `shouldContain`    ["reply"]

    it "help on the help screen offers only the ways out" $ do
      let helpText d = [t | DocLine spans <- docLines d, DocSpan t _ <- spans]
      helpText (renderHelp HelpScreen) `shouldNotContain` ["archive"]
      helpText (renderHelp HelpScreen) `shouldContain`    ["back"]

    it "titles the panel with the screen it describes" $ do
      let firstText d = fmap spanText (firstSpanAt 0 d)
      firstText (renderHelp InboxScreen) `shouldBe` Just "Keys -- Inbox"

  describe "buildThreadView" $ do
    it "orders a thread's messages oldest-first -- reading order, the reverse of the inbox" $
      map trMessageId (tvRows (buildThreadView appFixture (ThreadId "A") 0))
        `shouldBe` [mkMid 1, mkMid 2]

    it "titles the thread from its FIRST message, not a Re: reply" $
      tvSubject (buildThreadView appFixture (ThreadId "A") 0)
        `shouldBe` "Project update"

    it "marks each message's own unread state" $
      map trUnread (tvRows (buildThreadView appFixture (ThreadId "A") 0))
        `shouldBe` [False, True]

    it "excludes archived messages, like the inbox does" $
      tvRows (buildThreadView appFixture (ThreadId "C") 0) `shouldBe` []

    it "clamps a cursor past the end of the thread" $
      tvCursor (buildThreadView appFixture (ThreadId "A") 99) `shouldBe` 1

    it "renders a snippet of the message body" $
      map trSnippet (tvRows (buildThreadView appFixture (ThreadId "A") 0))
        `shouldBe` ["body text", "body text"]

  describe "renderThread" $ do
    it "says so explicitly when a thread has no visible messages" $
      renderThread (buildThreadView appFixture (ThreadId "C") 0)
        `shouldBe` Doc [DocLine [DocSpan "This thread has no visible messages." Dim]]

    it "renders a subject header plus one line per message" $
      length (docLines (renderThread (buildThreadView appFixture (ThreadId "A") 0)))
        `shouldBe` 3

  describe "per-message cursor within a thread -- the closed refinement" $ do
    it "acts on the message under the cursor, not merely the newest" $ do
      let onThread c = initialUIState { uiScreen = ThreadScreen (ThreadId "A"), uiCursor = c }
      command (KeyChar 'u') appFixture (onThread 0) `shouldBe` Right [MessageUnread (mkMid 1)]
      command (KeyChar 'u') appFixture (onThread 1) `shouldBe` Right [MessageUnread (mkMid 2)]

    it "clamps cursor movement to the thread's length, not the inbox's" $ do
      let onThread c = initialUIState { uiScreen = ThreadScreen (ThreadId "B"), uiCursor = c }
      -- Thread B holds exactly one message: j must not move past it.
      case applyInput appFixture (onThread 0) (KeyChar 'j') of
        Right (Continue st []) -> uiCursor st `shouldBe` 0
        other -> expectationFailure ("unexpected: " ++ show other)

    it "still archives the WHOLE thread from inside it, regardless of cursor" $
      case applyInput appFixture (initialUIState { uiScreen = ThreadScreen (ThreadId "A"), uiCursor = 0 }) (KeyChar 'a') of
        Right (Continue _ evs) ->
          evs `shouldBe` [MessageArchived (mkMid 2), MessageArchived (mkMid 1)]
        other -> expectationFailure ("unexpected: " ++ show other)

  describe "text entry mode -- opening" $ do
    it "s opens a search buffer on the inbox" $
      case applyInput appFixture initialUIState (KeyChar 's') of
        Right (Continue st []) -> uiTextEntry st `shouldBe` Just (TextEntry SearchEntry "")
        other -> expectationFailure ("unexpected: " ++ show other)

    it "s is not a search on a screen that does not permit search" $
      applyInput appFixture (initialUIState { uiScreen = ComposeScreen }) (KeyChar 's')
        `shouldBe` Left (UnboundInput (KeyChar 's') ComposeScreenTag)

  describe "text entry mode -- editing" $ do
    let typing t = initialUIState { uiTextEntry = Just (TextEntry SearchEntry t) }
        entryTextOf r = case r of
          Right (Continue st _) -> fmap entryText (uiTextEntry st)
          _                     -> Nothing

    it "appends printable characters" $
      entryTextOf (applyInput appFixture (typing "inv") (KeyChar 'o')) `shouldBe` Just "invo"

    it "appends characters that would otherwise be commands" $ do
      entryTextOf (applyInput appFixture (typing "") (KeyChar 'd')) `shouldBe` Just "d"
      entryTextOf (applyInput appFixture (typing "") (KeyChar 'q')) `shouldBe` Just "q"
      entryTextOf (applyInput appFixture (typing "") (KeyChar 'j')) `shouldBe` Just "j"

    it "backspace removes the last character" $
      entryTextOf (applyInput appFixture (typing "invo") KeyBackspace) `shouldBe` Just "inv"

    it "backspace on an empty buffer is harmless" $
      entryTextOf (applyInput appFixture (typing "") KeyBackspace) `shouldBe` Just ""

  describe "text entry mode -- SAFETY: no keystroke reaches the domain" $ do
    let typing t = initialUIState { uiTextEntry = Just (TextEntry SearchEntry t) }
        eventsOf r = case r of
          Right (Continue _ evs) -> Just evs
          _                      -> Nothing

    it "typing d does not delete, typing a does not archive, typing u does not unread" $ do
      eventsOf (applyInput appFixture (typing "") (KeyChar 'd')) `shouldBe` Just []
      eventsOf (applyInput appFixture (typing "") (KeyChar 'a')) `shouldBe` Just []
      eventsOf (applyInput appFixture (typing "") (KeyChar 'u')) `shouldBe` Just []

    it "typing q does not quit the application" $
      applyInput appFixture (typing "") (KeyChar 'q') `shouldNotBe` Right Exit

    it "typing j does not move the list cursor" $
      case applyInput appFixture (typing "") (KeyChar 'j') of
        Right (Continue st _) -> uiCursor st `shouldBe` 0
        other -> expectationFailure ("unexpected: " ++ show other)

  describe "text entry mode -- finishing" $ do
    let typing t = initialUIState { uiTextEntry = Just (TextEntry SearchEntry t) }

    it "Esc cancels and discards the buffer" $
      case applyInput appFixture (typing "invoice") KeyEsc of
        Right (Continue st []) -> do
          uiTextEntry st `shouldBe` Nothing
          uiScreen st    `shouldBe` InboxScreen
        other -> expectationFailure ("unexpected: " ++ show other)

    it "Enter submits, closes the buffer and opens the search screen" $
      case applyInput appFixture (typing "invoice") KeyEnter of
        Right (Continue st []) -> do
          uiTextEntry st      `shouldBe` Nothing
          uiScreen st         `shouldBe` SearchScreen
          uiPreviousScreen st `shouldBe` Just InboxScreen
        other -> expectationFailure ("unexpected: " ++ show other)

    it "submitting a compose buffer says so rather than silently discarding it" $ do
      let composing = initialUIState
            { uiScreen    = ComposeScreen
            , uiTextEntry = Just (TextEntry ComposeEntry "hello")
            }
      case applyInput appFixture composing KeyEnter of
        Right (Continue st []) -> do
          fmap entryText (uiTextEntry st) `shouldBe` Just "hello"
          uiStatusMessage st `shouldSatisfy` (/= Nothing)
        other -> expectationFailure ("unexpected: " ++ show other)
