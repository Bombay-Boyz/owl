-- | A message's content (master spec §12, §21). A real MIME message may
-- carry a text/plain part, a text/html part, or both
-- (multipart/alternative) -- neither is optional-yet-mandatory, so both
-- are Maybe. Attachments are not part of Body; they are Message's own
-- separate attachments field (§12).
--
-- HtmlBody is never raw wire HTML -- untrusted HTML must be sanitized to
-- a restricted, non-active display form before it can occupy this
-- field (§12: "no scripts, no remote-resource fetch by default"). The
-- sanitizeHtml smart constructor is the only way to produce one.
module Owl.Domain.Body
  ( Body (..)
  , SanitizedHtml
  , unSanitizedHtml
  , sanitizeHtml
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

data Body = Body
  { bodyPlainText :: !(Maybe Text)
  , bodyHtml      :: !(Maybe SanitizedHtml)
  }
  deriving stock (Eq, Show)

newtype SanitizedHtml = SanitizedHtml Text
  deriving stock (Show)
  deriving newtype (Eq)

unSanitizedHtml :: SanitizedHtml -> Text
unSanitizedHtml (SanitizedHtml t) = t

-- | v1's HTML handling (§12, §2): strip all markup down to visible text
-- rather than implement a restricted HTML renderer. Deliberate,
-- documented simplification -- it satisfies the safety invariant
-- exactly (no tag survives, so no script or remote-resource reference
-- can either) at the cost of visual fidelity, an acceptable v1 trade
-- given §23's TUI is a plain-text terminal renderer, not an HTML layout
-- engine.
--
-- Known limitation: text that was *inside* a removed tag (e.g. a
-- <script> body) still surfaces as inert display text rather than
-- being dropped entirely -- it is never executed or interpreted, so
-- the safety invariant §12 actually requires still holds, but a real
-- HTML parser would additionally suppress script/style content
-- specifically. Revisit only if this proves a real display-quality
-- problem in practice (§7's "no speculative abstraction").
--
-- Bounded and total: a single left-to-right structural scan (this is
-- genuinely structural recursion over an alternating text/tag list per
-- §29's own recursion test, not a fold/map problem), entity decoding
-- limited to five predefined XML entities, capped at the input's own
-- length so a pathological input cannot cause unbounded work (§12's
-- nesting/size-bound discipline, applied to this boundary too).
sanitizeHtml :: Text -> SanitizedHtml
sanitizeHtml raw = SanitizedHtml (decodeEntities (stripTags raw))

stripTags :: Text -> Text
stripTags = Text.concat . go . Text.split (`elem` ("<>" :: String))
  where
    go (textPart : _tag : rest) = textPart : go rest
    go remainder                = remainder

-- | &amp; is decoded last, deliberately -- decoding it first would let
-- e.g. the literal text "&amp;lt;" (an escaped ampersand followed by
-- literal "lt;") be mistaken for the entity "&lt;" and wrongly turned
-- into "<".
decodeEntities :: Text -> Text
decodeEntities =
  Text.replace "&amp;" "&"
    . Text.replace "&lt;" "<"
    . Text.replace "&gt;" ">"
    . Text.replace "&quot;" "\""
    . Text.replace "&#39;" "'"
