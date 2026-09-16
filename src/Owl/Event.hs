-- | Event vocabulary (master spec §24). Only the data type itself is
-- introduced in this phase -- §17's IndexDelta is explicitly derived
-- from an Event's own constructor, so IndexDelta/deltaFor need Event
-- to exist. apply, markRead/archive/moveMessage/sendDraft,
-- invertEvent, and UndoStack are §24's own remaining scope, deferred
-- to that phase.
module Owl.Event
  ( Event (..)
  ) where

import Owl.AddressBook (Contact)
import Owl.Domain.Id (MailboxId, MessageId)
import Owl.Compose (Draft)
import Owl.Message.Types (Message)

data Event
  = MessageReceived Message
  | MessageRead MessageId
  | MessageUnread MessageId
  | MessageArchived MessageId
  | MessageUnarchived MessageId
  | MessageDeleted MessageId
  | MessageRestored MessageId
  | MessageMoved MessageId MailboxId MailboxId    -- from, to
  | MessageLabeled MessageId MailboxId
  | MessageUnlabeled MessageId MailboxId
  | DraftCreated Draft
  | DraftChanged Draft
  | MessageSent MessageId
  | ContactChanged Contact
  deriving stock (Eq, Show)
