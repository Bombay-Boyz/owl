-- | Master spec §10 lists Attachment among the abstract nouns left for
-- implementation; §12's boundary discipline (bounded count and
-- cumulative size, filename as a display string only -- never a
-- filesystem path) is what actually constrains its shape, so it is
-- defined here rather than staying a bare `data Attachment` in
-- Owl.Domain.Opaque. Attachment is therefore intentionally NOT
-- re-declared there; see that module's own warning about conflicting
-- declarations.
module Owl.Domain.Attachment
  ( Attachment (..)
  , AttachmentError (..)
  , AttachmentLimits (..)
  , validateAttachments
  , sanitizeFilename
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text

-- | attachmentFilename is a display string only, per §12 -- it is never
-- used to derive a filesystem write path; a real write target is
-- Owl-generated.
data Attachment = Attachment
  { attachmentFilename :: !(Maybe Text)
  , attachmentMimeType :: !Text
  , attachmentContent  :: !ByteString
  }
  deriving stock (Eq, Show)

data AttachmentLimits = AttachmentLimits
  { maxAttachmentCount     :: !Int
  , maxAttachmentTotalSize :: !Int   -- ^ cumulative bytes across all attachments on one message
  }
  deriving stock (Eq, Show)

data AttachmentError
  = TooManyAttachments Int Int          -- ^ actual, limit
  | AttachmentsTooLarge Int Int         -- ^ actual cumulative bytes, limit
  deriving stock (Eq, Show)

-- | §12's "cap total attachment count and cumulative attachment size per
-- message" -- checked against every attachment on a message at once
-- (not per-attachment), since it is the aggregate that is the
-- resource-exhaustion shape, not any single attachment's size alone.
validateAttachments :: AttachmentLimits -> [Attachment] -> Either AttachmentError [Attachment]
validateAttachments limits attachmentsToCheck
  | count > maxAttachmentCount limits =
      Left (TooManyAttachments count (maxAttachmentCount limits))
  | totalSize > maxAttachmentTotalSize limits =
      Left (AttachmentsTooLarge totalSize (maxAttachmentTotalSize limits))
  | otherwise = Right (map sanitizeAttachment attachmentsToCheck)
  where
    count     = length attachmentsToCheck
    totalSize = sum (map (ByteString.length . attachmentContent) attachmentsToCheck)

-- | Applies sanitizeFilename to an attachment's own filename, if any.
sanitizeAttachment :: Attachment -> Attachment
sanitizeAttachment att = att { attachmentFilename = sanitizeFilename <$> attachmentFilename att }


-- | Reduces a possibly-adversarial filename to a single safe path
-- component -- no directory separators, no NUL bytes, and never just
-- dots (which could otherwise still form a ".." traversal segment
-- once separators are stripped). Defends against a crafted attachment
-- filename like "../../../.ssh/authorized_keys" being used, in the
-- future, to determine where a saved attachment is written -- nothing
-- writes attachments to disk yet, but this is exactly the kind of
-- validation that's cheap now and easy to forget once a save-to-disk
-- feature actually exists.
sanitizeFilename :: Text -> Text
sanitizeFilename raw =
  if Text.null stripped || Text.all (== '.') stripped
    then "attachment"
    else stripped
  where
    stripped = Text.filter isSafePathChar raw
    isSafePathChar c = c /= forwardSlash && c /= backslash && c /= nulChar
    forwardSlash = '/'
    backslash    = '\92'
    nulChar      = '\NUL'
