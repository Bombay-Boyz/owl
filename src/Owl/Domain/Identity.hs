-- | A sending identity (master spec §10's abstract-noun list: "Identity
-- ... sketched where this document doesn't need to pin the shape
-- down" -- §21's replyTo needs it pinned down now, grounded in that
-- section's own explicit "multiple identities" test requirement: one
-- account can compose as more than one From address (e.g. a primary
-- address plus a delegated alias).
--
-- Removed from Owl.Domain.Opaque now that it has a real shape; see
-- that module's own warning about conflicting declarations.
module Owl.Domain.Identity
  ( Identity (..)
  ) where

import Data.Text (Text)

import Owl.Domain.Address (EmailAddress)
import Owl.Domain.Id (AccountId)

data Identity = Identity
  { identityAccountId    :: !AccountId
  , identityEmailAddress :: !EmailAddress
  , identityDisplayName  :: !(Maybe Text)
  , identityIsDefault    :: !Bool
  }
  deriving stock (Eq, Show)
