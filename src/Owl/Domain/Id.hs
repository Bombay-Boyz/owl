-- | Owl's identity vocabulary (master spec §10). Every newtype here
-- derives (Eq, Ord) because each is used as a Data.Map.Strict.Map or
-- Data.Set.Set key somewhere in the domain (search indexes, §15;
-- thread/mailbox membership, §17; per-account sync state, §19; the STM
-- runtime split, §27) -- stated once, here, per the master spec's own
-- convention, rather than repeated at every call site. Show is also
-- derived on each -- not required by §10 itself, but needed for
-- readable Hspec/Hedgehog failure output in the property-test suite
-- built alongside this module.
module Owl.Domain.Id
  ( AccountId (..)
  , LocalId (..)
  , MessageId (..)
  , ThreadId (..)
  , PersonId (..)
  , AddressId (..)
  , MailboxId (..)
  , mkMailboxId
  , LabelId (..)
  ) where

import Data.Text (Text)
import Data.UUID (UUID)

newtype AccountId = AccountId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | Owl's own identity, never a wire-supplied one -- see §13.
newtype LocalId = LocalId UUID
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | Never a raw Text, never an IMAP UID -- see §13.
newtype MessageId = MessageId LocalId
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | Owl-issued; unique across accounts (§10's multi-account identity note).
newtype ThreadId = ThreadId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype PersonId = PersonId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype AddressId = AddressId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | Owl-issued; unique across accounts (§10's multi-account identity note).
newtype MailboxId = MailboxId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | Mints a MailboxId from (AccountId, provider folder name) -- never
-- from the raw folder name alone (§10: "so two accounts' 'INBOX' are
-- distinct MailboxIds"). \NUL is used as the internal separator
-- specifically because it can never legitimately appear in either an
-- AccountId or an IMAP folder name, avoiding any ambiguity a printable
-- separator (e.g. "/") would risk given real folder names already
-- contain "/" (e.g. Gmail's "[Gmail]/Sent Mail"). This was a real,
-- previously-unfixed gap -- earlier phases used MailboxId's bare
-- constructor directly in test fixtures without ever actually building
-- this minting function.
mkMailboxId :: AccountId -> Text -> MailboxId
mkMailboxId (AccountId acctText) folderName = MailboxId (acctText <> "\NUL" <> folderName)

newtype LabelId = LabelId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)
