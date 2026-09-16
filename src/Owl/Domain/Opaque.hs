-- | Deliberately abstract, per master spec §10: "These remain
-- intentionally abstract here -- Draft gets its fields defined in §21,
-- Person's shape is sketched in §16, and the rest ... are left for
-- implementation where this document doesn't need to pin the shape
-- down." Message is excluded on purpose -- it is fully defined at the
-- message boundary (§12).
--
-- Attachment and Address (§10's abstract-noun list originally included
-- both) have SINCE been given concrete shapes -- Owl.Domain.Attachment
-- and Owl.Domain.MailAddress respectively -- once the message boundary
-- (§12) needed them pinned down. Person and Contact have likewise
-- since been given concrete shapes -- Owl.Domain.Person and
-- Owl.AddressBook respectively -- once §16 needed them pinned down.
-- Per this module's own warning, all four are removed from here rather
-- than left as a conflicting duplicate declaration.
--
-- A bare `data X` here must never be paired with a second, conflicting
-- `data X = X { ... }` elsewhere without removing the declaration from
-- this module first.
module Owl.Domain.Opaque
  ( Account
  , Identity
  , Thread
  , Mailbox
  , Label
  , Draft
  ) where

-- Eq/Show derived even though every type here is uninhabited (zero
-- constructors) -- the same vacuous-instance precedent as Phase 2's
-- UID/UIDValidity stubs, needed here so a type built ON TOP of these
-- (e.g. Owl.Event's DraftCreated Draft) can itself derive Eq/Show.
data Account
  deriving stock (Eq, Show)
data Identity
  deriving stock (Eq, Show)
data Thread
  deriving stock (Eq, Show)
data Mailbox
  deriving stock (Eq, Show)
data Label
  deriving stock (Eq, Show)
data Draft
  deriving stock (Eq, Show)
