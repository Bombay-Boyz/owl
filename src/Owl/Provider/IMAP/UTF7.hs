-- | Modified UTF-7 for IMAP mailbox names (RFC 3501 §5.1.3). Hand-
-- rolled rather than using a library, after the one real library
-- found (text-utf7) turned out to be genuinely broken -- its own
-- source imports Data.Text.Internal.Unsafe.Shift, a module that no
-- longer exists in current `text` versions, not merely a stale bound
-- that allow-newer could paper over. This is a small, precisely-
-- specified, well-bounded algorithm -- exactly the kind of narrow task
-- where hand-rolling is more defensible than continuing to depend on
-- a dead package.
--
-- '&' is IMAP's shift character (not '+', as in general RFC 2152
-- UTF-7); the modified BASE64 alphabet uses ',' in place of '/' and
-- has no padding; a literal '&' is encoded as "&-".
--
-- CONFIDENCE NOTE: this is hand-written bit manipulation with no
-- external oracle to check against beyond the test vectors below
-- (sourced from other real, independent implementations -- Erlang's
-- imap_utf7 and the Rust utf7-imap crate -- not invented). Expect this
-- to need at least one round of correction once actually compiled and
-- tested.
module Owl.Provider.IMAP.UTF7
  ( decodeMailboxUtf7
  , encodeMailboxUtf7
  ) where

import Data.Bits (shiftL, shiftR, (.&.))
import Data.Char (chr, ord)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

-- | Standard base64 alphabet with ',' replacing '/', per RFC 3501.
modifiedBase64Alphabet :: String
modifiedBase64Alphabet = ['A' .. 'Z'] ++ ['a' .. 'z'] ++ ['0' .. '9'] ++ "+,"

base64Value :: Char -> Maybe Int
base64Value c = lookup c (zip modifiedBase64Alphabet [0 ..])

decodeMailboxUtf7 :: Text -> Text
decodeMailboxUtf7 = Text.pack . go . Text.unpack
  where
    go [] = []
    go ('&' : '-' : rest) = '&' : go rest
    go ('&' : rest) =
      let (encoded, afterDash) = break (== '-') rest
          remaining = case afterDash of
            ('-' : xs) -> xs
            xs         -> xs  -- unterminated shift sequence: runs to end of string
      in decodeShiftSequence encoded ++ go remaining
    go (c : rest) = c : go rest

decodeShiftSequence :: String -> String
decodeShiftSequence encoded = combineSurrogates (takeWord16s (concatMap toBits (mapMaybe base64Value encoded)))
  where
    toBits n = [ (n `shiftR` i) .&. 1 | i <- [5, 4 .. 0] ]
    takeWord16s bits = case splitAt 16 bits of
      (chunk, rest)
        | length chunk == 16 -> bitsToInt chunk : takeWord16s rest
        | otherwise          -> []  -- fewer than 16 bits left is padding, not a code unit
    bitsToInt = foldl (\acc b -> acc * 2 + b) 0

combineSurrogates :: [Int] -> String
combineSurrogates [] = []
combineSurrogates (hi : lo : rest)
  | hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF =
      chr (0x10000 + ((hi - 0xD800) `shiftL` 10) + (lo - 0xDC00)) : combineSurrogates rest
combineSurrogates (u : rest) = chr u : combineSurrogates rest

encodeMailboxUtf7 :: Text -> Text
encodeMailboxUtf7 = Text.pack . go . Text.unpack
  where
    go [] = []
    go ('&' : rest) = '&' : '-' : go rest
    go s@(c : _)
      | isPlainAscii c =
          let (asciiRun, rest) = span isPlainAscii s
          in asciiRun ++ go rest
      | otherwise =
          let (nonAsciiRun, rest) = break isPlainAscii s
          in '&' : encodeShiftSequence nonAsciiRun ++ "-" ++ go rest

    isPlainAscii c = c >= ' ' && c <= '~' && c /= '&'

encodeShiftSequence :: String -> String
encodeShiftSequence chars = bitsToBase64 (concatMap toBits16 (concatMap toUtf16Units chars))
  where
    toUtf16Units c
      | ord c <= 0xFFFF = [ord c]
      | otherwise =
          let cp = ord c - 0x10000
          in [0xD800 + (cp `shiftR` 10), 0xDC00 + (cp .&. 0x3FF)]

    toBits16 u = [ (u `shiftR` i) .&. 1 | i <- [15, 14 .. 0] ]

    bitsToBase64 [] = []
    bitsToBase64 bits = case splitAt 6 bits of
      (chunk, rest)
        | length chunk == 6 -> (modifiedBase64Alphabet !! bitsToInt chunk) : bitsToBase64 rest
        | otherwise         -> [modifiedBase64Alphabet !! bitsToInt (chunk ++ replicate (6 - length chunk) 0)]

    bitsToInt = foldl (\acc b -> acc * 2 + b) 0
