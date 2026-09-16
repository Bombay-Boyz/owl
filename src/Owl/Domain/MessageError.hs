-- | Master spec §10/§12 share one MessageError across mkSubject and
-- validateMessage -- the same "one type, one evaluator" ethos already
-- used for Predicate (§15) -- so it lives in its own module rather than
-- inside Owl.Domain.Subject, where it started, once it needed to grow
-- constructors that Subject itself has no reason to know about.
module Owl.Domain.MessageError
  ( MessageError (..)
  ) where

import Owl.Domain.Address (AddressError)
import Owl.Domain.Attachment (AttachmentError)

data MessageError
  = SubjectContainsLineBreak
  | MessageMissingSender
  | MessageInvalidSender AddressError
  | MessageInvalidRecipient AddressError
  | MessageAttachmentsInvalid AttachmentError
  | MessageMissingOrInvalidDate
  deriving stock (Eq, Show)
