-- | Message flags Owl exchanges with a provider (master spec §12's
-- Message record: flags :: !(Set Flag)). Grounded in IMAP's system
-- flags (RFC 9051 §2.3.2): \Seen, \Answered, \Flagged, \Draft,
-- \Deleted. \Recent is excluded -- IMAP4rev2 (RFC 9051) removes it, and
-- even under RFC 3501 it was session-scoped and never user-settable, so
-- it never belonged in a value Owl's domain persists.
--
-- \Deleted is kept here for provider interop (a RemoteObservation, §19,
-- may carry it) even though Owl's own domain model never sets it
-- itself -- deletion is a soft, undoable domain event
-- (MessageDeleted/MessageRestored, §24), never a flag Owl flips.
module Owl.Domain.Flag
  ( Flag (..)
  ) where

data Flag = Seen | Answered | Flagged | Draft | Deleted
  deriving stock (Eq, Ord, Show)
