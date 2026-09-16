-- | A named mailbox reference (RFC 5322's "mailbox" production: an
-- optional display name plus an address-spec). Distinct from
-- EmailAddress (Owl.Domain.Address, §10) -- EmailAddress is the bare,
-- validated address-spec; Address pairs it with the display name a
-- real header actually carries (e.g. "Alice Smith <alice@example.com>").
-- §10 leaves Address abstract in its noun list because the message
-- boundary (§12), where Message.sender/recipients need a concrete
-- shape, is where that shape is actually needed. Address is therefore
-- intentionally NOT re-declared in Owl.Domain.Opaque; see that
-- module's own warning about conflicting declarations.
--
-- Named in its own module (not Owl.Domain.Address) purely to avoid a
-- same-module name clash with EmailAddress's own module -- the type
-- name itself, Address, matches the master spec exactly.
module Owl.Domain.MailAddress
  ( Address (..)
  , sanitizeDisplayName
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

import Owl.Domain.Address (EmailAddress)

data Address = Address
  { addressDisplayName :: !(Maybe Text)
  , addressEmail       :: !EmailAddress
  }
  deriving stock (Eq, Show)


-- | Strips CR/LF from a display name -- a defense against header
-- injection: a crafted display name containing a carriage return,
-- newline, then "Bcc: attacker@evil.com" could forge extra headers in
-- rendered/sent mail if left unsanitized. Applied both when parsing an
-- incoming Address (Owl.Message.Boundary) and again, defensively, at
-- render time (Owl.Compose, Owl.Provider.SMTP), since an Address can
-- also be constructed by paths that never go through parsing at all.
sanitizeDisplayName :: Maybe Text -> Maybe Text
sanitizeDisplayName = fmap (Text.filter isSafeDisplayNameChar)
  where
    isSafeDisplayNameChar c = c /= carriageReturn && c /= lineFeed
    carriageReturn = '\13'
    lineFeed       = '\10'
