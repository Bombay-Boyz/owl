-- | A person in Owl's address book (master spec §16, sketched further
-- than §10 left it: "Name, Email addrs, Organization, Phone, Groups,
-- Notes, Aliases"). No photos, avatars, social profiles, or CRM
-- functionality, per §16's own explicit exclusion.
--
-- personEmails is NonEmpty -- a Person record only exists to represent
-- someone reachable by email, so "zero addresses" would be a Person
-- with no reason to exist as a Person at all.
module Owl.Domain.Person
  ( Person (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Set (Set)
import Data.Text (Text)

import Owl.Domain.Address (EmailAddress)
import Owl.Domain.Id (PersonId)

data Person = Person
  { personId           :: !PersonId
  , personName         :: !(Maybe Text)
  , personEmails       :: !(NonEmpty EmailAddress)
  , personOrganization :: !(Maybe Text)
  , personPhone        :: !(Maybe Text)
  , personGroups       :: !(Set Text)
  , personNotes        :: !(Maybe Text)
  , personAliases      :: !(Set Text)
  }
  deriving stock (Eq, Show)
