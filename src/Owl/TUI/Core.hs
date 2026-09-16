-- | The TUI's pure core (master spec §23): "TUI as a projection."
--
-- No terminal code, no brick, no vty, and no mail-domain logic --
-- exactly as §23 requires. Everything here is a pure function over
-- Application (§11) plus UIState, so the overwhelming majority of TUI
-- behaviour is unit-testable with no terminal at all, which is §23's
-- own stated design goal. The brick wiring is a separate, thin layer
-- above this.
--
-- TWO DOCUMENTED DEVIATIONS from §23's literal given signatures, both
-- because the signature as written cannot be implemented faithfully,
-- and silently bending the semantics would be worse than naming it.
--
-- (1) commandsFor :: Screen -> Set Command  ==>  Screen -> Set CommandTag
--
--     Command's constructors carry payloads (OpenThread ThreadId,
--     SearchCommand Query, ...). A Set of fully-applied Commands would
--     require enumerating every possible ThreadId/MessageId/Query,
--     which is not finite; and Query contains a Predicate, which has
--     no Ord instance to be a Set element in the first place. What §23
--     actually asks for is a per-screen PARTITION of the command
--     vocabulary -- exactly a set of nullary tags. The spec's own rule
--     is preserved verbatim: "a Command not in commandsFor
--     currentScreen is a CommandError, never silently ignored or
--     reinterpreted."
--
-- (2) command :: ... -> Either CommandError (NonEmpty Event)
--                  ==>  ... -> Either CommandError [Event]
--
--     Several commands are pure navigation and produce no domain event
--     at all: OpenThread, Compose, Quit, HelpCommand, Back. With
--     NonEmpty, expressing "valid input, no domain effect" would
--     require inventing a fake domain Event for navigation --
--     polluting the event log (§24) with entries describing nothing
--     that happened to the mail store. An empty list says exactly what
--     is true.
module Owl.TUI.Core
  ( -- * Commands
    Command (..)
  , CommandTag (..)
  , commandTag
    -- * Screens
  , Screen (..)
  , ScreenTag (..)
  , screenTag
    -- * UI-only state
  , UIState (..)
  , FocusPane (..)
  , TextEntry (..)
  , EntryPurpose (..)
  , initialUIState
    -- * Errors
  , UiError (..)
  , CommandError (..)
    -- * Input
  , UserInput (..)
    -- * The pure core
  , commandsFor
  , transitionScreen
  , interpretInput
  , command
  , view
    -- * Top-level input handling
  , InputResult (..)
  , applyInput
  , renderHelp
  ) where

import Data.Maybe (listToMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text

import Owl.Application (Application)
import Owl.Domain.Id (MessageId, ThreadId)
import Owl.Event (Event (..))
import Owl.Search.Predicate (Query)
import Owl.TUI.View
  ( Doc (..)
  , DocLine (..)
  , DocSpan (..)
  , Emphasis (..)
  , InboxView
  , ThreadView (tvRows)
  , buildInboxView
  , buildThreadView
  , defaultViewportRows
  , selectedThreadId
  , selectedThreadMessageId
  , threadMessageIds
  , viewRows
  )

-- | §23's given Command type, plus three additions its own prose
-- requires but its type sketch omits: Back and HelpCommand (§23's
-- keyboard vocabulary lists "q back/quit" and "? help") and
-- UndoCommand ("z undo (§24)").
data Command
  = OpenThread ThreadId
  | SearchCommand Query
  | Reply ThreadId
  | Forward MessageId
  | Compose
  | ArchiveThread ThreadId
  | DeleteMessage MessageId
  | MarkMessageRead MessageId
  | MarkMessageUnread MessageId
  | UndoCommand
  | HelpCommand
  | Back
  | Quit
  deriving stock (Eq, Show)

-- | The nullary projection of Command used for per-screen
-- partitioning -- see note (1) above on why Set Command itself is not
-- implementable.
data CommandTag
  = OpenThreadTag
  | SearchTag
  | ReplyTag
  | ForwardTag
  | ComposeTag
  | ArchiveTag
  | DeleteTag
  | MarkReadTag
  | MarkUnreadTag
  | UndoTag
  | HelpTag
  | BackTag
  | QuitTag
  deriving stock (Eq, Ord, Show, Enum, Bounded)

commandTag :: Command -> CommandTag
commandTag = \case
  OpenThread _        -> OpenThreadTag
  SearchCommand _     -> SearchTag
  Reply _             -> ReplyTag
  Forward _           -> ForwardTag
  Compose             -> ComposeTag
  ArchiveThread _     -> ArchiveTag
  DeleteMessage _     -> DeleteTag
  MarkMessageRead _   -> MarkReadTag
  MarkMessageUnread _ -> MarkUnreadTag
  UndoCommand         -> UndoTag
  HelpCommand         -> HelpTag
  Back                -> BackTag
  Quit                -> QuitTag

data Screen
  = InboxScreen
  | ThreadScreen ThreadId
  | SearchScreen
  | ComposeScreen
  | ContactScreen
  | HelpScreen
  deriving stock (Eq, Show)

data ScreenTag
  = InboxTag
  | ThreadTag
  | SearchScreenTag
  | ComposeScreenTag
  | ContactTag
  | HelpScreenTag
  deriving stock (Eq, Ord, Show, Enum, Bounded)

screenTag :: Screen -> ScreenTag
screenTag = \case
  InboxScreen    -> InboxTag
  ThreadScreen _ -> ThreadTag
  SearchScreen   -> SearchScreenTag
  ComposeScreen  -> ComposeScreenTag
  ContactScreen  -> ContactTag
  HelpScreen     -> HelpScreenTag

data FocusPane = MailboxPane | MessageListPane | MessageBodyPane
  deriving stock (Eq, Show)

-- | What an in-progress text buffer is FOR. Carried explicitly rather
-- than inferred from the current screen, because submitting is a
-- different act in each case (a search runs a query; a compose sends
-- a draft) and inferring it would put that decision in two places.
data EntryPurpose = SearchEntry | ComposeEntry
  deriving stock (Eq, Show)

data TextEntry = TextEntry
  { entryPurpose :: !EntryPurpose
  , entryText    :: !Text
  }
  deriving stock (Eq, Show)

-- | §23: "UIState (cursor, scroll, active pane, in-progress compose
-- buffer before it becomes a Draft) is threaded alongside Application
-- but excluded from it (§11) -- mixing it in would make every domain
-- property test carry irrelevant UI fields."
--
-- uiPreviousScreen exists because Back has to go SOMEWHERE, and the
-- answer is genuinely history-dependent: HelpScreen entered from the
-- inbox must return to the inbox, but entered from a thread must
-- return to that thread. A single slot rather than a full stack is
-- deliberate: §23's screen set has no legitimate three-deep nesting,
-- and an unbounded stack would be speculative structure (§7).
data UIState = UIState
  { uiScreen         :: !Screen
  , uiPreviousScreen :: !(Maybe Screen)
  , uiCursor         :: !Int
  , uiScrollOffset   :: !Int
  , uiFocus          :: !FocusPane
  , uiTextEntry      :: !(Maybe TextEntry)
    -- ^ Subsumes what §23 calls the "in-progress compose buffer":
    -- search and compose both need to capture literal text, and one
    -- mechanism serving both is better than two that drift.
    -- Nothing = the screen is interpreting keys as COMMANDS.
    -- Just    = the screen is capturing them as TEXT.
  , uiStatusMessage  :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

initialUIState :: UIState
initialUIState = UIState
  { uiScreen         = InboxScreen
  , uiPreviousScreen = Nothing
  , uiCursor         = 0
  , uiScrollOffset   = 0
  , uiFocus          = MessageListPane
  , uiTextEntry      = Nothing
  , uiStatusMessage  = Nothing
  }

data UiError
  = CommandNotValidForScreen CommandTag ScreenTag
  | NoScreenToReturnTo
  deriving stock (Eq, Show)

data CommandError
  = UnboundInput UserInput ScreenTag
    -- ^ The key is not bound on this screen at all.
  | CommandRejected UiError
    -- ^ The key mapped to a Command, but that Command is not in
    -- commandsFor for the current screen (§23: "never silently
    -- ignored or reinterpreted").
  | NoSelectionUnderCursor
    -- ^ The command needs a selected thread/message and there isn't
    -- one (empty mailbox, or cursor past the end). A real, nameable
    -- condition rather than a silently-dropped keypress.
  deriving stock (Eq, Show)

-- | Deliberately NOT vty's Key type: keeping the pure core free of any
-- terminal library is the whole point of §23's testability claim. The
-- brick layer translates vty events into these.
data UserInput
  = KeyChar Char
  | KeyEnter
  | KeyEsc
  | KeyUp
  | KeyDown
  | KeyBackspace
  deriving stock (Eq, Ord, Show)

-- | §23: "Bindings are scoped per screen, not global -- r/f/a/d are
-- meaningless inside ComposeScreen, and a compose text buffer needs
-- its own bindings that would otherwise collide with navigation keys
-- like j/k."
commandsFor :: Screen -> Set CommandTag
commandsFor screen = Set.fromList $ case screenTag screen of
  InboxTag ->
    [ OpenThreadTag, SearchTag, ReplyTag, ForwardTag, ComposeTag
    , ArchiveTag, DeleteTag, MarkReadTag, MarkUnreadTag
    , UndoTag, HelpTag, QuitTag
    ]
  ThreadTag ->
    [ SearchTag, ReplyTag, ForwardTag, ComposeTag
    , ArchiveTag, DeleteTag, MarkReadTag, MarkUnreadTag
    , UndoTag, HelpTag, BackTag, QuitTag
    ]
  SearchScreenTag  -> [OpenThreadTag, SearchTag, HelpTag, BackTag, QuitTag]
  -- No r/f/a/d here, exactly as §23 calls out by name: inside a
  -- compose buffer those keys are literal text, not commands.
  ComposeScreenTag -> [HelpTag, BackTag, QuitTag]
  ContactTag       -> [ComposeTag, HelpTag, BackTag, QuitTag]
  -- Help is a leaf: you can only leave it.
  HelpScreenTag    -> [BackTag, QuitTag]

-- | O(1) apart from work explicitly delegated to the application
-- layer (§23). Commands that do not change the screen return the
-- current screen unchanged -- they are still valid, they simply have
-- their effect via `command`'s events instead.
transitionScreen :: Screen -> Command -> Either UiError Screen
transitionScreen screen cmd
  | not (commandTag cmd `Set.member` commandsFor screen) =
      Left (CommandNotValidForScreen (commandTag cmd) (screenTag screen))
  | otherwise = case cmd of
      OpenThread tid      -> Right (ThreadScreen tid)
      SearchCommand _     -> Right SearchScreen
      Compose             -> Right ComposeScreen
      Reply _             -> Right ComposeScreen
      Forward _           -> Right ComposeScreen
      HelpCommand         -> Right HelpScreen
      Quit                -> Right screen
      -- Back's real destination lives in UIState (uiPreviousScreen),
      -- which transitionScreen cannot see by its given signature.
      -- This arm only confirms Back is permitted on this screen.
      Back                -> Right screen
      ArchiveThread _     -> Right screen
      DeleteMessage _     -> Right screen
      MarkMessageRead _   -> Right screen
      MarkMessageUnread _ -> Right screen
      UndoCommand         -> Right screen

-- | Translates a raw keypress into a Command, given the current
-- screen and what the cursor is over. Split out from `command` so the
-- binding table is independently testable, and so §23's "? renders
-- only the bindings valid for the current screen" has a single source
-- of truth to render from rather than a second copy of the key map.
--
-- The selected thread/message are passed in rather than dug out of
-- Application here, because "what is under the cursor" is a UI
-- question (it depends on scroll offset and the current view's
-- ordering); answering it inside this function would drag view
-- construction into the binding table.
interpretInput
  :: Screen
  -> Maybe ThreadId
  -> Maybe MessageId
  -> UserInput
  -> Either CommandError Command
interpretInput screen mThread mMessage input = do
  cmd <- case input of
    KeyChar 'r' -> needThread Reply
    KeyChar 'f' -> needMessage Forward
    KeyChar 'a' -> needThread ArchiveThread
    KeyChar 'd' -> needMessage DeleteMessage
    KeyChar 'u' -> needMessage MarkMessageUnread
    KeyEnter    -> needThread OpenThread
    KeyChar 'c' -> Right Compose
    KeyChar 'z' -> Right UndoCommand
    KeyChar '?' -> Right HelpCommand
    -- §23 writes this binding as "q back/quit": one key, two meanings,
    -- resolved by context. Where there is somewhere to go back to, q
    -- goes back; at the root (the inbox, the only screen without
    -- BackTag) it quits. Getting this wrong meant q at the root
    -- surfaced a CommandRejected error instead of exiting -- caught by
    -- a test, not by reading the code.
    KeyChar 'q' -> Right (if backAvailable then Back else Quit)
    -- Esc is back-only, never quit: no convention has Esc exiting an
    -- application, so at the root it simply has no meaning.
    KeyEsc
      | backAvailable -> Right Back
      | otherwise     -> Left (UnboundInput input (screenTag screen))
    _           -> Left (UnboundInput input (screenTag screen))
  if commandTag cmd `Set.member` commandsFor screen
    then Right cmd
    else Left (CommandRejected (CommandNotValidForScreen (commandTag cmd) (screenTag screen)))
  where
    backAvailable = BackTag `Set.member` commandsFor screen
    needThread  f = maybe (Left NoSelectionUnderCursor) (Right . f) mThread
    needMessage f = maybe (Left NoSelectionUnderCursor) (Right . f) mMessage

-- | The domain events a command produces, if any. Empty means "valid,
-- but purely a navigation/UI effect" -- see note (2) above.
--
-- Commands that CONSTRUCT domain data rather than just reference it
-- (Reply, Forward, Compose) deliberately produce no event here:
-- building a Draft needs a freshly-minted MessageId, which is an
-- effect -- §21's own reasoning for threading it in explicitly. They
-- open ComposeScreen; the draft becomes real, emitting DraftCreated,
-- only when the compose layer completes it.
--
-- Selection is resolved through Owl.TUI.View's bounded viewport, which
-- is exactly why §23's given signature threads Application into
-- `command`: ArchiveThread must expand into one MessageArchived per
-- message (Owl.Event's MessageArchived takes a MessageId, not a
-- ThreadId), and that expansion needs a thread -> messages lookup.
--
-- REMAINING REFINEMENT, named rather than hidden: on ThreadScreen the
-- message-scoped commands currently act on the newest message in the
-- thread, not on a per-message cursor within the thread view. A
-- per-message cursor is ThreadScreen's own piece of work; resolving
-- to the newest message is correct and useful behaviour in the
-- meantime, and is what the inbox means by these commands anyway.
command :: UserInput -> Application -> UIState -> Either CommandError [Event]
command input app uiState = do
  cmd <- interpretInput (uiScreen uiState) selectedThread selectedMessage input
  pure (eventsFor cmd)
  where
    (selectedThread, selectedMessage) = resolveSelection app uiState

    eventsFor = \case
      MarkMessageRead mid   -> [MessageRead mid]
      MarkMessageUnread mid -> [MessageUnread mid]
      DeleteMessage mid     -> [MessageDeleted mid]
      ArchiveThread tid     -> map MessageArchived (threadMessageIds app tid)
      _                     -> []

-- | §23's given `view :: Application -> UIState -> Screen`. The screen
-- is simply what UIState says it is -- Application does not and must
-- not influence which screen is displayed, which is exactly the
-- separation §23 demands ("the TUI owns no domain state").
view :: Application -> UIState -> Screen
view _app = uiScreen


-- | What a single keypress did. Exit is a distinct constructor rather
-- than a Bool field on UIState because "the application should stop"
-- is not a property of the interface's state -- it is the absence of
-- any further state.
data InputResult
  = Continue !UIState ![Event]
  | Exit
  deriving stock (Eq, Show)

-- | THE top-level pure entry point: one keypress in, new UI state plus
-- any domain events out. The brick layer does nothing but translate
-- vty events into UserInput, call this, apply the returned Events via
-- Owl.Application.Apply.apply, and draw the result -- which is what
-- §23 means by the TUI being a projection.
--
-- Cursor movement (j/k and the arrow keys) is handled here and NEVER
-- becomes a Command: §23's Command type has no cursor constructors,
-- and rightly so -- moving a highlight is a UI-only effect that must
-- not reach the domain or the event log (§24). Only commands that
-- change mail produce Events.
applyInput :: Application -> UIState -> UserInput -> Either CommandError InputResult
applyInput app uiState input = case uiTextEntry uiState of
  -- While a text buffer is open, interpretInput is NEVER consulted.
  -- Not consulted-then-overridden: genuinely not reached. Typing
  -- "invoice" into a search box must not fire Forward, Undo and
  -- Delete on the way through, which is precisely the collision §23
  -- warns about ("a compose text buffer needs its own bindings that
  -- would otherwise collide with navigation keys like j/k").
  Just entry -> Right (Continue (handleTextEntry entry) [])
  Nothing    -> handleCommandMode
  where
    handleTextEntry entry = case input of
      KeyChar c    -> withEntry entry { entryText = entryText entry <> Text.singleton c }
      KeyBackspace -> withEntry entry { entryText = dropLast (entryText entry) }
      KeyEsc       -> uiState { uiTextEntry = Nothing, uiStatusMessage = Just "Cancelled." }
      KeyEnter     -> submitEntry entry
      -- Arrow keys inside a buffer are cursor movement WITHIN the
      -- text in a full editor; until that exists they are ignored
      -- rather than silently leaking out as list navigation.
      _            -> uiState

    withEntry e = uiState { uiTextEntry = Just e }

    dropLast t = if Text.null t then t else Text.init t

    submitEntry entry = case entryPurpose entry of
      SearchEntry -> uiState
        { uiTextEntry      = Nothing
        , uiScreen         = SearchScreen
        , uiPreviousScreen = Just (uiScreen uiState)
        , uiCursor         = 0
        , uiScrollOffset   = 0
        , uiStatusMessage  = Just ("Search: " <> entryText entry)
        }
      -- Compose submission needs a freshly-minted MessageId (§21),
      -- which is an effect and therefore cannot happen in a pure
      -- function. The buffer is left in place and the caller is told
      -- so, rather than silently discarding what was typed.
      ComposeEntry -> uiState
        { uiStatusMessage = Just "Sending is not wired up yet." }

    handleCommandMode = case input of
      KeyChar 'j' -> Right (Continue (moveCursor 1) [])
      KeyDown     -> Right (Continue (moveCursor 1) [])
      KeyChar 'k' -> Right (Continue (moveCursor (-1)) [])
      KeyUp       -> Right (Continue (moveCursor (-1)) [])
      -- 's' opens a search buffer rather than becoming a Command:
      -- SearchCommand carries a Query, and there is no Query until
      -- something has actually been typed. Still gated on the screen
      -- permitting search at all, so the per-screen partition holds.
      KeyChar 's'
        | SearchTag `Set.member` commandsFor (uiScreen uiState) ->
            Right (Continue uiState
              { uiTextEntry     = Just (TextEntry SearchEntry "")
              , uiStatusMessage = Just "Search: "
              } [])
      _           -> do
        cmd <- interpretInput (uiScreen uiState) selThread selMessage input
        case cmd of
          Quit -> Right Exit
          _    -> do
            events <- command input app uiState
            nextScreen <- either (Left . CommandRejected) Right
                            (transitionScreen (uiScreen uiState) cmd)
            pure (Continue (settle cmd nextScreen) events)

    (selThread, selMessage) = resolveSelection app uiState

    -- The cursor indexes whatever list the CURRENT screen is showing:
    -- inbox rows on the inbox, messages within an opened thread. Using
    -- the inbox count on a thread screen would let the cursor run off
    -- the end of a short thread.
    rowCount = case uiScreen uiState of
      ThreadScreen tid -> length (tvRows (buildThreadView app tid (uiCursor uiState)))
      _                -> length (viewRows (inboxViewFor app uiState))

    -- Clamped against the CURRENT row count, so holding j at the end
    -- of a mailbox parks on the last row rather than walking off it.
    moveCursor delta = uiState
      { uiCursor = max 0 (min (uiCursor uiState + delta) (max 0 (rowCount - 1)))
      , uiStatusMessage = Nothing
      }

    -- Back is the one command whose destination transitionScreen
    -- cannot compute from its given signature (it has no UIState), so
    -- it is resolved here against the remembered previous screen,
    -- falling back to the inbox -- the root -- rather than failing.
    settle cmd nextScreen = case cmd of
      Back -> uiState
        { uiScreen         = maybe InboxScreen id (uiPreviousScreen uiState)
        , uiPreviousScreen = Nothing
        , uiCursor         = 0
        , uiScrollOffset   = 0
        , uiStatusMessage  = Nothing
        }
      _ | nextScreen == uiScreen uiState ->
            -- A command with only a domain effect: stay put, keep the
            -- cursor where it is.
            uiState { uiStatusMessage = Nothing }
        | otherwise -> uiState
            { uiScreen         = nextScreen
            , uiPreviousScreen = Just (uiScreen uiState)
            , uiCursor         = 0
            , uiScrollOffset   = 0
            , uiStatusMessage  = Nothing
            }

-- | §23: "? renders only the bindings valid for the current screen"
-- and "Keyboard-first does not mean requiring memorization -- actions
-- must be discoverable". Driven off commandsFor, so the help text
-- cannot drift out of sync with what the screen actually accepts --
-- there is exactly one source of truth.
renderHelp :: Screen -> Doc
renderHelp screen = Doc (title : map bindingLine visible)
  where
    title = DocLine [DocSpan ("Keys -- " <> screenName screen) Selected]
    visible = filter (\(tag, _, _) -> tag `Set.member` commandsFor screen) allBindings

    bindingLine (_, key, description) = DocLine
      [ DocSpan (pad 6 key) Normal
      , DocSpan description Dim
      ]

    pad n t = t <> Text.replicate (max 0 (n - Text.length t)) " "

    screenName = \case
      InboxScreen    -> "Inbox"
      ThreadScreen _ -> "Thread"
      SearchScreen   -> "Search"
      ComposeScreen  -> "Compose"
      ContactScreen  -> "Contacts"
      HelpScreen     -> "Help"

    allBindings =
      [ (OpenThreadTag, "Enter", "open thread")
      , (ReplyTag,      "r",     "reply")
      , (ForwardTag,    "f",     "forward")
      , (ComposeTag,    "c",     "compose")
      , (ArchiveTag,    "a",     "archive")
      , (DeleteTag,     "d",     "delete")
      , (MarkUnreadTag, "u",     "mark unread")
      , (UndoTag,       "z",     "undo")
      , (SearchTag,     "s",     "search")
      , (HelpTag,       "?",     "help")
      , (BackTag,       "q/Esc", "back")
      , (QuitTag,       "q",     "quit")
      ]


-- | One definition of "what is selected", shared by command and
-- applyInput. They previously each computed this themselves, which
-- was harmless only while the answer was identical on every screen --
-- it stops being identical the moment a thread has its own per-message
-- cursor, so the duplication is removed rather than left to drift.
--
-- This also closes the refinement flagged when `command` was first
-- written: on a thread screen, message-scoped commands now act on the
-- message under the cursor, not merely the newest in the thread.
resolveSelection :: Application -> UIState -> (Maybe ThreadId, Maybe MessageId)
resolveSelection app uiState = case uiScreen uiState of
  ThreadScreen tid ->
    ( Just tid
    , selectedThreadMessageId (buildThreadView app tid (uiCursor uiState))
    )
  InboxScreen  -> fromInbox
  SearchScreen -> fromInbox
  _            -> (Nothing, Nothing)
  where
    inboxView = inboxViewFor app uiState
    fromInbox =
      let mThread = selectedThreadId inboxView
          -- From the inbox the cursor is on a THREAD, so a
          -- message-scoped command means its most recent message --
          -- the ordinary convention for a threaded list.
          mMessage = mThread >>= \t -> listToMaybe (threadMessageIds app t)
      in (mThread, mMessage)

inboxViewFor :: Application -> UIState -> InboxView
inboxViewFor app uiState =
  buildInboxView app (uiScrollOffset uiState) defaultViewportRows (uiCursor uiState)
