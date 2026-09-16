-- | BM25 ranking (master spec §15). QueryTerms carries a pre-resolved
-- (corpus document frequency, postings) slice for just the query's
-- terms -- prepared by the caller (Owl.Search.Engine) before scoring --
-- which is what lets bm25's own signature stay exactly as given
-- (BM25Parameters -> DocumentStatistics -> QueryTerms -> MessageId ->
-- Double, no InvertedIndex parameter) despite scoring genuinely needing
-- index-derived numbers.
module Owl.Search.Rank
  ( BM25Parameters (..)
  , QueryTerms (..)
  , defaultBM25Parameters
  , bm25
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.List as List

import Owl.Domain.Id (MessageId)
import Owl.Search.Index (DocumentStatistics (..), Posting (..), Term)

data BM25Parameters = BM25Parameters
  { bm25K1 :: !Double
  , bm25B  :: !Double
  }
  deriving stock (Eq, Show)

-- | Robertson/Sparck-Jones defaults widely used in practice (k1 = 1.2,
-- b = 0.75) -- standard BM25 starting values, not invented for Owl.
defaultBM25Parameters :: BM25Parameters
defaultBM25Parameters = BM25Parameters { bm25K1 = 1.2, bm25B = 0.75 }

newtype QueryTerms = QueryTerms (Map Term (Int, [Posting]))

bm25 :: BM25Parameters -> DocumentStatistics -> QueryTerms -> MessageId -> Double
bm25 params stats (QueryTerms termInfo) mid = sum (map scoreTerm (Map.elems termInfo))
  where
    corpusSize = fromIntegral (Map.size (docLength stats))
    docLen     = fromIntegral (Map.findWithDefault 0 mid (docLength stats))
    avgLen     = avgDocLength stats

    scoreTerm (docFreq, postings) =
      let idf   = if docFreq == 0
                    then 0
                    else log ((corpusSize - fromIntegral docFreq + 0.5) / (fromIntegral docFreq + 0.5) + 1)
          tf    = fromIntegral (maybe 0 postingTf (List.find ((== mid) . postingMessage) postings))
          denom = tf + bm25K1 params * (1 - bm25B params + bm25B params * (if avgLen == 0 then 0 else docLen / avgLen))
      in if denom == 0 then 0 else idf * (tf * (bm25K1 params + 1)) / denom
