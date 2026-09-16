-- | Term postings and document statistics (master spec §15).
module Owl.Search.Index
  ( Term (..)
  , Posting (..)
  , PostingList (..)
  , InvertedIndex (..)
  , DocumentStatistics (..)
  , tokenize
  , buildInvertedIndex
  , buildDocumentStatistics
  , termPostings
  , insertMessage
  , insertMessageStats
  ) where

import Data.Char (isAlphaNum)
import qualified Data.List as List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

import Owl.Domain.Body (bodyPlainText)
import Owl.Domain.Id (MessageId)
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (..))

newtype Term = Term Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

-- | One occurrence record within a term's postings: which message, and
-- how many times the term appears in it -- BM25's f(t,D) needs this,
-- and a bare [MessageId] posting list can't carry it.
data Posting = Posting
  { postingMessage :: !MessageId
  , postingTf      :: !Word
  }
  deriving stock (Eq, Show)

newtype PostingList = PostingList [Posting]  -- sorted by MessageId
  deriving stock (Eq, Show)

newtype InvertedIndex = InvertedIndex (Map Term PostingList)
  deriving stock (Eq, Show)

-- | Per-document length and the corpus average -- BM25 needs both,
-- neither derivable from PostingList alone.
data DocumentStatistics = DocumentStatistics
  { docLength    :: !(Map MessageId Word)
  , avgDocLength :: !Double
  }
  deriving stock (Eq, Show)

-- | Lowercase alphanumeric-run tokenization -- a documented, simple v1
-- choice ("use an established indexing library if it adequately solves
-- the problem," §15); no stemming, no stop-word removal.
tokenize :: Text -> [Term]
tokenize = map Term . filter (not . Text.null) . Text.split (not . isAlphaNum) . Text.toCaseFold

termFrequencies :: [Term] -> Map Term Word
termFrequencies = foldr (\t -> Map.insertWith (+) t 1) Map.empty

buildInvertedIndex :: [Message] -> InvertedIndex
buildInvertedIndex msgs = InvertedIndex (Map.map (PostingList . List.sortOn postingMessage) grouped)
  where
    grouped = Map.fromListWith (++)
      [ (term, [Posting mid tf])
      | msg <- msgs
      , let mid   = messageId (identity msg)
      , let terms = tokenize (fromMaybe Text.empty (bodyPlainText (body msg)))
      , (term, tf) <- Map.toList (termFrequencies terms)
      ]

buildDocumentStatistics :: [Message] -> DocumentStatistics
buildDocumentStatistics msgs = DocumentStatistics lengths avg
  where
    lengths = Map.fromList
      [ (messageId (identity msg), fromIntegral (length (tokenize (fromMaybe Text.empty (bodyPlainText (body msg))))))
      | msg <- msgs
      ]
    avg = if null msgs then 0 else fromIntegral (sum (Map.elems lengths)) / fromIntegral (length msgs)

termPostings :: InvertedIndex -> Term -> [Posting]
termPostings (InvertedIndex m) t = case Map.lookup t m of
  Just (PostingList ps) -> ps
  Nothing               -> []

-- | Incremental counterpart to buildInvertedIndex (§17): touches only
-- the postings for this one message's terms, not a full rebuild.
insertMessage :: Message -> InvertedIndex -> InvertedIndex
insertMessage msg (InvertedIndex m) = InvertedIndex (foldr insertTerm m (Map.toList termFreqs))
  where
    mid = messageId (identity msg)
    termFreqs = termFrequencies (tokenize (fromMaybe Text.empty (bodyPlainText (body msg))))
    insertTerm (term, tf) idx = Map.insertWith mergeSorted term (PostingList [Posting mid tf]) idx
    mergeSorted (PostingList [newPosting]) (PostingList old) =
      PostingList (List.insertBy (\a b -> compare (postingMessage a) (postingMessage b)) newPosting old)
    mergeSorted new _old = new  -- unreachable: insertTerm always calls with a singleton new list

-- | Incremental counterpart to buildDocumentStatistics (§17): updates
-- the running average from the old count/average, not a full rescan.
insertMessageStats :: Message -> DocumentStatistics -> DocumentStatistics
insertMessageStats msg stats = DocumentStatistics
  { docLength    = Map.insert mid newLen (docLength stats)
  , avgDocLength = (avgDocLength stats * fromIntegral oldCount + fromIntegral newLen) / fromIntegral (oldCount + 1)
  }
  where
    mid      = messageId (identity msg)
    newLen   = fromIntegral (length (tokenize (fromMaybe Text.empty (bodyPlainText (body msg)))))
    oldCount = Map.size (docLength stats)
