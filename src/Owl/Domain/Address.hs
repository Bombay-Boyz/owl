-- | Email address vocabulary (master spec §10). Validation here is a
-- hand-rolled, best-effort check of RFC 5321 §4.5.3.1's syntax and
-- length rules -- deliberately narrower than the full RFC 5322 address
-- grammar (no quoted local parts, no domain literals, no comments) and
-- superseded by a mature MIME/RFC library at the message boundary
-- (§12) once real wire input needs parsing. This constructor exists so
-- EmailAddress can never hold an obviously malformed string, not so
-- Owl reimplements RFC 5322 itself (§12's own stated principle).
module Owl.Domain.Address
  ( EmailAddress
  , unEmailAddress
  , mkEmailAddress
  , AddressError (..)
  , NormalizedAddress
  , unNormalizedAddress
  , normalizeAddress
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (traverse_)
import Data.Text (Text)
import qualified Data.Text as Text

-- | Display/canonical form; casing preserved (§10).
newtype EmailAddress = EmailAddress Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

unEmailAddress :: EmailAddress -> Text
unEmailAddress (EmailAddress t) = t

data AddressError
  = AddressEmpty
  | MissingAtSign
  | MultipleAtSigns
  | LocalPartEmpty
  | LocalPartTooLong Int                     -- ^ RFC 5321 §4.5.3.1.1: max 64 octets
  | LocalPartInvalidCharacter Char
  | LocalPartInvalidDotPlacement
  | DomainEmpty
  | DomainTooLong Int                        -- ^ RFC 5321 §4.5.3.1.2: max 255 octets
  | DomainLiteralUnsupported                 -- ^ e.g. "[192.0.2.1]" -- not yet implemented
  | DomainLabelEmpty
  | DomainLabelTooLong Text                  -- ^ RFC 1035 §3.1: max 63 octets per label
  | DomainLabelInvalidCharacter Char
  | DomainLabelInvalidHyphenPlacement Text
  | DomainMissingDot
  | AddressTooLong Int                       -- ^ RFC 5321 §4.5.3.1.3: max 254 octets
  deriving stock (Eq, Show)

mkEmailAddress :: Text -> Either AddressError EmailAddress
mkEmailAddress raw
  | Text.null raw          = Left AddressEmpty
  | Text.length raw > 254  = Left (AddressTooLong (Text.length raw))
  | otherwise = do
      (localPart, domainPart) <- splitAtSign raw
      validateLocalPart localPart
      validateDomain domainPart
      pure (EmailAddress raw)

splitAtSign :: Text -> Either AddressError (Text, Text)
splitAtSign raw = case Text.splitOn "@" raw of
  [localPart, domainPart] -> Right (localPart, domainPart)
  parts
    | length parts < 2 -> Left MissingAtSign
    | otherwise         -> Left MultipleAtSigns

validateLocalPart :: Text -> Either AddressError ()
validateLocalPart local
  | Text.null local                 = Left LocalPartEmpty
  | Text.length local > 64          = Left (LocalPartTooLong (Text.length local))
  | Text.head local == '.'          = Left LocalPartInvalidDotPlacement
  | Text.last local == '.'          = Left LocalPartInvalidDotPlacement
  | Text.isInfixOf ".." local       = Left LocalPartInvalidDotPlacement
  | otherwise = case Text.find (not . isAtextOrDot) local of
      Just c  -> Left (LocalPartInvalidCharacter c)
      Nothing -> Right ()
  where
    isAtextOrDot c = c == '.' || isAtext c

-- | RFC 5322 §3.2.3 atext: alphanumerics plus !#$%&'*+-/=?^_`{|}~
isAtext :: Char -> Bool
isAtext c =
  isAsciiLower c || isAsciiUpper c || isDigit c
    || c `elem` ("!#$%&'*+-/=?^_`{|}~" :: String)

validateDomain :: Text -> Either AddressError ()
validateDomain domain
  | Text.null domain                = Left DomainEmpty
  | Text.length domain > 255        = Left (DomainTooLong (Text.length domain))
  | Text.isPrefixOf "[" domain      = Left DomainLiteralUnsupported
  | not (Text.isInfixOf "." domain) = Left DomainMissingDot
  | otherwise = traverse_ validateLabel (Text.splitOn "." domain)

validateLabel :: Text -> Either AddressError ()
validateLabel label
  | Text.null label        = Left DomainLabelEmpty
  | Text.length label > 63 = Left (DomainLabelTooLong label)
  | Text.head label == '-' = Left (DomainLabelInvalidHyphenPlacement label)
  | Text.last label == '-' = Left (DomainLabelInvalidHyphenPlacement label)
  | otherwise = case Text.find (not . isLdh) label of
      Just c  -> Left (DomainLabelInvalidCharacter c)
      Nothing -> Right ()
  where
    isLdh c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '-'

-- | Comparison key for dedup, indexing, and matching -- never for display
-- or the SMTP envelope (§10). The domain is case-insensitive per RFC
-- 5321; the local part is folded too, since no major provider treats
-- RFC 5321's technical local-part case-sensitivity as real-world
-- case-sensitive -- exactly as §10 states it.
newtype NormalizedAddress = NormalizedAddress Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

unNormalizedAddress :: NormalizedAddress -> Text
unNormalizedAddress (NormalizedAddress t) = t

normalizeAddress :: EmailAddress -> NormalizedAddress
normalizeAddress (EmailAddress raw) = NormalizedAddress (Text.toLower raw)
