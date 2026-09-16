-- | Subject line vocabulary (master spec §10). The one real invariant
-- mkSubject enforces: an unfolded header value must never contain a
-- literal CR or LF -- a raw CR/LF smuggled into a value at this
-- boundary is a header-injection vector, the same class of untrusted-
-- input concern the master spec calls out at the message boundary in
-- §12. Beyond that, Subject imposes no content restriction: there is
-- no RFC-mandated length limit on a Subject value, and inventing one
-- here would be exactly the kind of made-up constraint the master spec
-- warns against.
--
-- MessageError itself now lives in Owl.Domain.MessageError, shared with
-- the message boundary's validateMessage (§12) -- see that module.
module Owl.Domain.Subject
  ( Subject
  , unSubject
  , mkSubject
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

import Owl.Domain.MessageError (MessageError (..))

newtype Subject = Subject Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

unSubject :: Subject -> Text
unSubject (Subject t) = t

mkSubject :: Text -> Either MessageError Subject
mkSubject raw
  | Text.any (\c -> c == '\r' || c == '\n') raw = Left SubjectContainsLineBreak
  | otherwise                                    = Right (Subject raw)
