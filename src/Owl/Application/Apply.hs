-- | Event algebra (master spec §24): apply is total over its input
-- type -- every constructor has a defined result for every reachable
-- Application, even if Left. -Wincomplete-patterns enforces this at
-- compile time (§30), not just as a convention.
--
-- DraftCreated/DraftChanged/MessageSent are honest no-ops: Draft has
-- zero constructors until §21 gives it real fields, and MessageSent's
-- own payload is a bare MessageId with no message content to act on --
-- the same structural gap already noted for deltaFor in
-- Owl.Index.Delta (§17). Not fabricated logic for what these can't yet
-- do.
--
-- markRead/archive/moveMessage/sendDraft: §24's own text permits "the
-- direct version stays" when refactoring into the Event algebra adds
-- more friction than it removes. Their given/inferred signatures are
-- total (no Either), even though apply is not -- resolved by routing
-- through apply and collapsing an UnknownMessage error into a silent
-- no-op: marking a message Owl has no record of as read isn't the kind
-- of invariant violation apply's own Either exists to surface.
module Owl.Application.Apply
  ( DomainError (..)
  , apply
  , markRead
  , archive
  , moveMessage
  , sendDraft
  , UndoStack (..)
  , emptyUndoStack
  , pushUndo
  , popUndo
  , invertEvent
  , undo
  ) where

import qualified Data.Map.Strict as Map
import Data.Sequence (Seq (..))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Owl.AddressBook (Contact (..), abContacts, mkAddressBook)
import Owl.Compose (Draft (draftId))
import Owl.Domain.Person (Person (personId))
import Owl.Application
import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (MailboxId, MessageId)
import Owl.Event (Event (..))
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (..))
import Owl.Search.Predicate (addMembership, removeMembership)

data DomainError
  = UnknownMessage MessageId
  | DuplicateMessage MessageId
  deriving stock (Eq, Show)

apply :: Event -> Application -> Either DomainError Application
apply event app = case event of
  MessageReceived msg ->
    let mid = messageId (identity msg)
        MessageState msgs archivedM deletedM = messages app
    in if Map.member mid msgs
         then Left (DuplicateMessage mid)
         else
           let msgs'  = Map.insert mid msg msgs
               ThreadState tmap = threads app
               tmap'  = Map.insertWith Set.union (threadId msg) (Set.singleton mid) tmap
           in Right app
                { messages = MessageState msgs' archivedM deletedM
                , threads  = ThreadState tmap'
                }

  MessageRead mid -> withKnownMessage mid app $ \msg ->
    app { messages = setMessage mid (msg { flags = Set.insert Seen (flags msg) }) (messages app) }

  MessageUnread mid -> withKnownMessage mid app $ \msg ->
    app { messages = setMessage mid (msg { flags = Set.delete Seen (flags msg) }) (messages app) }

  MessageArchived mid -> withKnownMessage mid app $ \_ ->
    app { messages = (messages app) { archivedMessages = Set.insert mid (archivedMessages (messages app)) } }

  MessageUnarchived mid -> withKnownMessage mid app $ \_ ->
    app { messages = (messages app) { archivedMessages = Set.delete mid (archivedMessages (messages app)) } }

  MessageDeleted mid -> withKnownMessage mid app $ \_ ->
    app { messages = (messages app) { deletedMessages = Set.insert mid (deletedMessages (messages app)) } }

  MessageRestored mid -> withKnownMessage mid app $ \_ ->
    app { messages = (messages app) { deletedMessages = Set.delete mid (deletedMessages (messages app)) } }

  MessageMoved mid src dst -> withKnownMessage mid app $ \_ ->
    app { mailboxes = (mailboxes app)
            { membership = addMembership mid dst (removeMembership mid src (membership (mailboxes app))) } }

  MessageLabeled mid mbox -> withKnownMessage mid app $ \_ ->
    app { mailboxes = (mailboxes app) { membership = addMembership mid mbox (membership (mailboxes app)) } }

  MessageUnlabeled mid mbox -> withKnownMessage mid app $ \_ ->
    app { mailboxes = (mailboxes app) { membership = removeMembership mid mbox (membership (mailboxes app)) } }

  DraftCreated draft -> Right app { drafts = insertDraft draft (drafts app) }
  DraftChanged draft -> Right app { drafts = insertDraft draft (drafts app) }

  MessageSent mid -> withKnownMessage mid app (const app)

  ContactChanged contact ->
    let ContactState book     = contacts app
        updatedContacts       = Map.insert (personId (contactPerson contact)) contact (abContacts book)
    in Right app { contacts = ContactState (mkAddressBook (Map.elems updatedContacts)) }

withKnownMessage :: MessageId -> Application -> (Message -> Application) -> Either DomainError Application
withKnownMessage mid app f = case Map.lookup mid (messageStateMessages (messages app)) of
  Nothing  -> Left (UnknownMessage mid)
  Just msg -> Right (f msg)

setMessage :: MessageId -> Message -> MessageState -> MessageState
setMessage mid msg st = st { messageStateMessages = Map.insert mid msg (messageStateMessages st) }

insertDraft :: Draft -> DraftState -> DraftState
insertDraft draft (DraftState m) = DraftState (Map.insert (draftId draft) draft m)

markRead :: MessageId -> Application -> Application
markRead mid app = either (const app) id (apply (MessageRead mid) app)

archive :: MessageId -> Application -> Application
archive mid app = either (const app) id (apply (MessageArchived mid) app)

moveMessage :: MessageId -> MailboxId -> MailboxId -> Application -> Application
moveMessage mid src dst app = either (const app) id (apply (MessageMoved mid src dst) app)

sendDraft :: MessageId -> Application -> Application
sendDraft mid app = either (const app) id (apply (MessageSent mid) app)

-- | Capped at ~10 entries (§24) -- a small, explicitly-scoped in-memory
-- stack, not event sourcing (no log is persisted).
newtype UndoStack = UndoStack (Seq Event)
  deriving stock (Eq, Show)

emptyUndoStack :: UndoStack
emptyUndoStack = UndoStack Seq.empty

pushUndo :: Event -> UndoStack -> UndoStack
pushUndo event (UndoStack s) = UndoStack (Seq.take 10 (event Seq.<| s))

popUndo :: UndoStack -> Maybe (Event, UndoStack)
popUndo (UndoStack Empty)        = Nothing
popUndo (UndoStack (e :<| rest)) = Just (e, UndoStack rest)

-- | Necessarily partial (§24) -- not every event is invertible, so
-- Nothing is a legitimate result, not a bug to route around.
invertEvent :: Event -> Maybe Event
invertEvent (MessageRead mid)          = Just (MessageUnread mid)
invertEvent (MessageUnread mid)        = Just (MessageRead mid)
invertEvent (MessageArchived mid)      = Just (MessageUnarchived mid)
invertEvent (MessageUnarchived mid)    = Just (MessageArchived mid)
invertEvent (MessageDeleted mid)       = Just (MessageRestored mid)
invertEvent (MessageRestored mid)      = Just (MessageDeleted mid)
invertEvent (MessageMoved mid from to) = Just (MessageMoved mid to from)
invertEvent (MessageLabeled mid mbox)  = Just (MessageUnlabeled mid mbox)
invertEvent (MessageUnlabeled mid mbox)= Just (MessageLabeled mid mbox)
invertEvent _                          = Nothing

-- | Pop the most recent event, invert it, and apply the inverse. If
-- the stack is empty, or (defensively) the popped event somehow isn't
-- invertible, this is a no-op rather than an error -- there is nothing
-- destructive about failing to find something to undo.
undo :: UndoStack -> Application -> Either DomainError (Application, UndoStack)
undo stack app = case popUndo stack of
  Nothing -> Right (app, stack)
  Just (event, stack') -> case invertEvent event of
    Nothing       -> Right (app, stack')
    Just invEvent -> (\app' -> (app', stack')) <$> apply invEvent app
