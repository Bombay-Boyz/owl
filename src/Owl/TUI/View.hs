-- | Narrow view models and rendering for the TUI (master spec §23).
--
-- §23 is explicit that what reaches the renderer must be "narrow view
-- models, not deep domain structures": an InboxRow carries Text, Bool
-- and Int -- never a Message, Address, Body or Subject. Two reasons,
-- both real: the renderer cannot accidentally depend on domain
-- internals, and a row is cheap to construct and compare in tests.
--
-- Doc is defined HERE, in the pure layer, rather than being brick's
-- Widget. Keeping renderInbox free of any terminal library is what
-- makes it unit-testable with no terminal at all -- the same
-- separation that holds across Owl.TUI.Core. The brick layer
-- translates Doc into Widgets; nothing in this module knows brick
-- exists.
--
-- PERFORMANCE GAP, stated plainly rather than papered over:
--
--   §23 specifies the viewport be "computed via the Date-ordered
--   index's O(log n) range-start and O(k) scan (§15)", citing a <5ms
--   navigation budget on a 200k-message mailbox (§33).
--
--   Application as it currently stands has no Date-ordered index:
--   messageStateMessages is a Map keyed by MessageId, and ThreadState
--   is a Map keyed by ThreadId. Ordering threads by date therefore
--   requires visiting every thread and sorting -- O(n log n), not
--   O(log n + k).
--
--   What IS correct here is the BOUND: buildInboxView never returns
--   more than the requested row count, so InboxView, renderInbox, and
--   every consumer downstream are genuinely bounded by construction,
--   and none of them need to change when the index arrives. Closing
--   the gap is a §15/§17 change (add a Date-ordered index to the
--   application state), not a TUI change, and is deliberately not
--   faked here by pretending the current scan is cheaper than it is.
module Owl.TUI.View
  ( -- * Narrow view models
    InboxRow (..)
  , InboxView (..)
  , buildInboxView
  , defaultViewportRows
    -- * Thread view
  , ThreadRow (..)
  , ThreadView (..)
  , buildThreadView
  , selectedThreadMessageId
  , renderThread
    -- * Selection
  , selectedRow
  , selectedThreadId
  , threadMessageIds
    -- * Rendering
  , Doc (..)
  , DocLine (..)
  , DocSpan (..)
  , Emphasis (..)
  , renderInbox
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)

import Owl.Application
  ( Application (messages, threads)
  , MessageState (archivedMessages, deletedMessages, messageStateMessages)
  , ThreadState (..)
  )
import Owl.Domain.Address (unEmailAddress)
import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (MessageId, ThreadId)
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (unSubject)
import Owl.Message.Types (Message (body, flags, sender, sentAt, subject))
import Owl.Domain.Body (Body (bodyPlainText))

-- | One line in the inbox list. Deliberately flat and primitive --
-- see this module's note on narrow view models.
data InboxRow = InboxRow
  { rowThreadId     :: !ThreadId
  , rowSender       :: !Text
  , rowSubject      :: !Text
  , rowDate         :: !UTCTime
  , rowUnread       :: !Bool
  , rowMessageCount :: !Int
  }
  deriving stock (Eq, Show)

-- | A bounded window onto the inbox. viewTotalThreads is carried so a
-- scrollbar or "12 of 4,832" indicator can be rendered without the
-- caller ever holding the full result set -- which is the entire
-- point of the viewport.
data InboxView = InboxView
  { viewRows         :: ![InboxRow]
  , viewOffset       :: !Int
  , viewTotalThreads :: !Int
  , viewCursor       :: !Int
    -- ^ Index into viewRows (viewport-relative), NOT an absolute row
    -- number. Keeping it relative means renderInbox needs no
    -- arithmetic to decide which line is highlighted.
  }
  deriving stock (Eq, Show)

-- | §23: "the current scroll offset plus roughly two screens of
-- rows". Two screens rather than one so that a page-down does not
-- require an immediate rebuild.
defaultViewportRows :: Int
defaultViewportRows = 60

-- | Builds the bounded viewport. offset and limit are clamped so that
-- a cursor past the end of a shrinking mailbox (messages archived by
-- a rule while the user scrolls) cannot produce a negative take or an
-- out-of-range index -- it simply yields fewer rows, or none.
buildInboxView :: Application -> Int -> Int -> Int -> InboxView
buildInboxView app offset limit cursor = InboxView
  { viewRows         = windowRows
  , viewOffset       = safeOffset
  , viewTotalThreads = totalThreads
  , viewCursor       = safeCursor
  }
  where
    ThreadState threadMap = threads app
    msgState   = messages app
    msgMap     = messageStateMessages msgState
    hiddenIds  = Set.union (archivedMessages msgState) (deletedMessages msgState)

    -- O(n log n) over all threads -- see this module's PERFORMANCE GAP
    -- note. Sorted newest-first, which is what an inbox means.
    allRows      = sortOn (Down . rowDate) (mapMaybe toRow (Map.toList threadMap))
    totalThreads = length allRows

    safeOffset = max 0 (min offset (max 0 (totalThreads - 1)))
    windowRows = take (max 0 limit) (drop safeOffset allRows)
    safeCursor = max 0 (min cursor (max 0 (length windowRows - 1)))

    toRow :: (ThreadId, Set MessageId) -> Maybe InboxRow
    toRow (threadId, memberIds) =
      let visibleIds = Set.filter (`Set.notMember` hiddenIds) memberIds
          msgs       = mapMaybe (`Map.lookup` msgMap) (Set.toList visibleIds)
      in case sortOn (Down . sentAt) msgs of
           []           -> Nothing
             -- A thread whose every message is archived or deleted is
             -- not an empty row -- it is absent from the inbox.
           (newest : _) -> Just InboxRow
             { rowThreadId     = threadId
             , rowSender       = renderAddress (sender newest)
             , rowSubject      = unSubject (subject newest)
             , rowDate         = sentAt newest
               -- Unread if ANY message in the thread is unread, which
               -- is what a threaded inbox means -- not just the newest.
             , rowUnread       = any (not . Set.member Seen . flags) msgs
             , rowMessageCount = length msgs
             }

-- | Display name when present, bare address otherwise -- the ordinary
-- convention, and it keeps the row a plain Text.
renderAddress :: Address -> Text
renderAddress addr = case addressDisplayName addr of
  Just name | not (Text.null (Text.strip name)) -> name
  _                                             -> unEmailAddress (addressEmail addr)

selectedRow :: InboxView -> Maybe InboxRow
selectedRow v = case drop (viewCursor v) (viewRows v) of
  (r : _) -> Just r
  []      -> Nothing

selectedThreadId :: InboxView -> Maybe ThreadId
selectedThreadId = fmap rowThreadId . selectedRow

-- | Every message in a thread that is currently visible (not already
-- archived or deleted), NEWEST FIRST. This is what ArchiveThread
-- expands over: Owl.Event's MessageArchived takes a MessageId, so
-- archiving a thread is one event per message, and re-archiving
-- something already archived would be a redundant event.
--
-- Date-ordered rather than Set order (which is by MessageId, i.e.
-- effectively arbitrary) because the head of this list is also what
-- "the message in the selected thread" means for message-scoped
-- commands issued from the inbox.
threadMessageIds :: Application -> ThreadId -> [MessageId]
threadMessageIds app threadId =
  case Map.lookup threadId threadMap of
    Nothing        -> []
    Just memberIds ->
      let visibleIds = Set.toList (Set.filter (`Set.notMember` hiddenIds) memberIds)
          withMsg    = mapMaybe (\i -> (,) i <$> Map.lookup i msgMap) visibleIds
      in map fst (sortOn (Down . sentAt . snd) withMsg)
  where
    ThreadState threadMap = threads app
    msgState  = messages app
    msgMap    = messageStateMessages msgState
    hiddenIds = Set.union (archivedMessages msgState) (deletedMessages msgState)

-- | A minimal structured document: enough to express what an inbox
-- list needs (lines, runs of text, emphasis, a highlighted row) and
-- deliberately nothing more. Not a general layout engine -- §23's own
-- closing instruction is "Do not build a generalized command/plugin
-- framework", and the same restraint applies here.
newtype Doc = Doc { docLines :: [DocLine] }
  deriving stock (Eq, Show)

newtype DocLine = DocLine { lineSpans :: [DocSpan] }
  deriving stock (Eq, Show)

data DocSpan = DocSpan
  { spanText     :: !Text
  , spanEmphasis :: !Emphasis
  }
  deriving stock (Eq, Show)

data Emphasis
  = Normal
  | Unread      -- ^ bold, conventionally
  | Selected    -- ^ the cursor row
  | Dim         -- ^ metadata: dates, counts
  deriving stock (Eq, Show)

-- | §23's given renderInbox. Pure, terminal-free, and total: an empty
-- inbox renders an explicit message rather than zero lines, because a
-- blank screen is indistinguishable from a broken one.
renderInbox :: InboxView -> Doc
renderInbox v
  | null (viewRows v) = Doc [DocLine [DocSpan "No messages." Dim]]
  | otherwise         = Doc (zipWith renderRow [0 ..] (viewRows v))
  where
    renderRow :: Int -> InboxRow -> DocLine
    renderRow i row = DocLine
      [ DocSpan marker emphasis
      , DocSpan (pad 24 (rowSender row)) emphasis
      , DocSpan (pad 48 (rowSubject row)) emphasis
      , DocSpan countText Dim
      ]
      where
        isSelected = i == viewCursor v
        emphasis
          | isSelected      = Selected
          | rowUnread row   = Unread
          | otherwise       = Normal
        marker    = if rowUnread row then "* " else "  "
        countText = if rowMessageCount row > 1
                      then " (" <> Text.pack (show (rowMessageCount row)) <> ")"
                      else ""

    pad :: Int -> Text -> Text
    pad n t
      | Text.length t >= n = Text.take (n - 1) t <> " "
      | otherwise          = t <> Text.replicate (n - Text.length t) " "


-- ---------------------------------------------------------------------
-- Thread view
-- ---------------------------------------------------------------------

-- | One message within an opened thread. Narrow, like InboxRow: the
-- renderer never sees a Message.
data ThreadRow = ThreadRow
  { trMessageId :: !MessageId
  , trFrom      :: !Text
  , trDate      :: !UTCTime
  , trUnread    :: !Bool
  , trSnippet   :: !Text
  }
  deriving stock (Eq, Show)

-- | An opened thread. Unlike InboxView this is NOT windowed: a thread
-- is a bounded conversation (tens of messages at most, not the 200k
-- of §33's inbox budget), so paging it would add machinery for a
-- problem that does not exist. The asymmetry is deliberate, not an
-- oversight.
data ThreadView = ThreadView
  { tvThreadId :: !ThreadId
  , tvSubject  :: !Text
  , tvRows     :: ![ThreadRow]
  , tvCursor   :: !Int
  }
  deriving stock (Eq, Show)

-- | Messages are shown OLDEST FIRST -- reading order for a
-- conversation -- which is the opposite of the inbox's newest-first
-- ordering. threadMessageIds returns newest-first (it exists to find
-- "the latest message"), so this reverses it rather than re-deriving
-- an ordering, keeping one definition of what a thread contains.
buildThreadView :: Application -> ThreadId -> Int -> ThreadView
buildThreadView app threadId cursor = ThreadView
  { tvThreadId = threadId
  , tvSubject  = subjectText
  , tvRows     = rows
  , tvCursor   = max 0 (min cursor (max 0 (length rows - 1)))
  }
  where
    msgMap      = messageStateMessages (messages app)
    orderedIds  = reverse (threadMessageIds app threadId)
    orderedMsgs = mapMaybe (`Map.lookup` msgMap) orderedIds

    -- The thread's subject is the FIRST message's: later replies carry
    -- "Re:" prefixes, and a thread titled "Re: Re: ..." reads badly.
    subjectText = case orderedMsgs of
      (first : _) -> unSubject (subject first)
      []          -> ""

    rows = zipWith toRow orderedIds orderedMsgs

    toRow mid msg = ThreadRow
      { trMessageId = mid
      , trFrom      = renderAddress (sender msg)
      , trDate      = sentAt msg
      , trUnread    = not (Set.member Seen (flags msg))
      , trSnippet   = snippet msg
      }

    snippet msg = case bodyPlainText (body msg) of
      Nothing -> ""
      Just t  ->
        let firstLine = Text.strip (Text.takeWhile (/= '\n') t)
        in if Text.length firstLine > 72
             then Text.take 71 firstLine <> "…"
             else firstLine

selectedThreadMessageId :: ThreadView -> Maybe MessageId
selectedThreadMessageId tv =
  fmap trMessageId (listToMaybe (drop (tvCursor tv) (tvRows tv)))

renderThread :: ThreadView -> Doc
renderThread tv
  | null (tvRows tv) = Doc [DocLine [DocSpan "This thread has no visible messages." Dim]]
  | otherwise        = Doc (header : zipWith renderRow [0 ..] (tvRows tv))
  where
    header = DocLine [DocSpan (tvSubject tv) Selected]

    renderRow i row = DocLine
      [ DocSpan marker emphasis
      , DocSpan (padTo 22 (trFrom row)) emphasis
      , DocSpan (trSnippet row) Dim
      ]
      where
        emphasis
          | i == tvCursor tv = Selected
          | trUnread row     = Unread
          | otherwise        = Normal
        marker = if trUnread row then "* " else "  "

    padTo n t
      | Text.length t >= n = Text.take (n - 1) t <> " "
      | otherwise          = t <> Text.replicate (n - Text.length t) " "
