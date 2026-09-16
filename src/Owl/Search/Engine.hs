-- | Index-backed query execution (master spec §15): Query AST -> Query
-- planner -> Index operations -> Candidate set -> Verification/ranking.
--
-- For predicates with an exact index (From/To/HasAttachment/IsUnread/
-- InMailbox/InThread/After/Before), the candidate set already IS the
-- exact result. For SubjectContains/Body (phrase and substring
-- matches, which Posting/PostingList carry no positions for), the term
-- index gives a necessary-but-not-sufficient candidate set, verified
-- against the real Message via matches -- exactly the pipeline's own
-- "Verification" stage, not a workaround. And/Or/Not compile to set
-- intersection/union/complement, per §15's stated set-algebra law.
--
-- And's conjuncts are intersected smallest-set-first -- the one
-- concrete optimization §15 asks the planner to make, without building
-- a general cost-based optimizer.
--
-- siByMailbox is a genuine Mailbox -> Set MessageId reverse index
-- (§15's own index table asks for O(log n) lookup here) -- an earlier
-- version of this module answered InMailbox via a full scan over
-- siMembership instead; fixed as part of §17's incremental-maintenance
-- work, since that section is precisely about these indexes being
-- properly maintained structures, not query-time derivations.
module Owl.Search.Engine
  ( SearchIndex (..)
  , buildSearchIndex
  , evaluate
  , search
  , defaultMaxCandidates
  ) where

import Data.Foldable (toList)
import qualified Data.List as List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, utctDay)

import Owl.Domain.Address (EmailAddress, unEmailAddress)
import Owl.Domain.Id (MailboxId, MessageId, ThreadId)
import Owl.Domain.MailAddress (Address (addressEmail))
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (..))
import Owl.Search.Index
  ( InvertedIndex
  , DocumentStatistics
  , Posting (postingMessage)
  , Term
  , buildDocumentStatistics
  , buildInvertedIndex
  , termPostings
  , tokenize
  )
import Owl.Search.Predicate (MailMembership (..), Phrase (..), Predicate (..), Query)
import qualified Owl.Search.Predicate as Predicate
import Owl.Search.Rank (BM25Parameters, QueryTerms (..), bm25)

data SearchIndex = SearchIndex
  { siMessages   :: !(Map MessageId Message)
  , siBySender   :: !(Map Text (Set MessageId))
  , siByRecipient :: !(Map Text (Set MessageId))
  , siByThread   :: !(Map ThreadId (Set MessageId))
  , siByDay      :: !(Map Day (Set MessageId))
  , siByMailbox  :: !(Map MailboxId (Set MessageId))
  , siInverted   :: !InvertedIndex
  , siStats      :: !DocumentStatistics
  , siMembership :: !MailMembership
  }
  deriving stock (Eq, Show)

defaultMaxCandidates :: Int
defaultMaxCandidates = 10000

addressKey :: EmailAddress -> Text
addressKey = Text.toCaseFold . unEmailAddress

buildSearchIndex :: MailMembership -> [Message] -> SearchIndex
buildSearchIndex membership msgs = SearchIndex
  { siMessages   = Map.fromList [ (messageId (identity m), m) | m <- msgs ]
  , siBySender   = Map.fromListWith Set.union senderEntries
  , siByRecipient = Map.fromListWith Set.union recipientEntries
  , siByThread   = Map.fromListWith Set.union [ (threadId m, Set.singleton (messageId (identity m))) | m <- msgs ]
  , siByDay      = Map.fromListWith Set.union [ (utctDay (sentAt m), Set.singleton (messageId (identity m))) | m <- msgs ]
  , siByMailbox  = Map.fromListWith Set.union
      [ (mb, Set.singleton mid) | (mid, mbs) <- Map.toList membershipMap0, mb <- Set.toList mbs ]
  , siInverted   = buildInvertedIndex msgs
  , siStats      = buildDocumentStatistics msgs
  , siMembership = membership
  }
  where
    senderEntries    = [ (addressKey (addressEmail (sender m)), Set.singleton (messageId (identity m))) | m <- msgs ]
    recipientEntries = [ (addressKey (addressEmail r), Set.singleton (messageId (identity m))) | m <- msgs, r <- recipients m ]
    membershipMap0   = case membership of MailMembership m -> m

evaluate :: SearchIndex -> Predicate -> Set MessageId
evaluate idx predicate = case predicate of
  From addr              -> Map.findWithDefault Set.empty (addressKey addr) (siBySender idx)
  To addr                -> Map.findWithDefault Set.empty (addressKey addr) (siByRecipient idx)
  -- Subjects are not tokenized into siInverted anywhere in this pass
  -- (only body text is) -- so, unlike Body below, there is no correct
  -- way to narrow the candidate set via the term index here. This
  -- degrades honestly to a full scan-then-verify (still exact, just
  -- not index-accelerated).
  SubjectContains q      -> verify universe (SubjectContains q)
  Body phrase@(Phrase p) -> verify (candidatesForTerms (tokenize p)) (Body phrase)
  HasAttachment          -> Set.fromList [ mid | (mid, m) <- Map.toList (siMessages idx), not (null (attachments m)) ]
  IsUnread               -> Set.fromList [ mid | (mid, m) <- Map.toList (siMessages idx), matches' m IsUnread ]
  InMailbox mbid         -> Map.findWithDefault Set.empty mbid (siByMailbox idx)
  InThread tid           -> Map.findWithDefault Set.empty tid (siByThread idx)
  After day              -> Set.unions [ s | (d, s) <- Map.toList (siByDay idx), d > day ]
  Before day             -> Set.unions [ s | (d, s) <- Map.toList (siByDay idx), d < day ]
  And ps                 -> foldr1 Set.intersection (List.sortOn Set.size (map (evaluate idx) (toList ps)))
  Or ps                  -> Set.unions (map (evaluate idx) (toList ps))
  Not p                  -> Set.difference universe (evaluate idx p)
  where
    universe      = Map.keysSet (siMessages idx)
    matches' m p  = Predicate.matches (siMembership idx) m p

    candidatesForTerms []    = universe
    candidatesForTerms terms = foldr1 Set.intersection (map termCandidates terms)
    termCandidates t = Set.fromList (map postingMessage (termPostings (siInverted idx) t))

    verify candidates p = Set.filter (\mid -> maybe False (\m -> matches' m p) (Map.lookup mid (siMessages idx))) candidates

collectTerms :: Predicate -> [Term]
collectTerms predicate = case predicate of
  SubjectContains q -> tokenize q
  Body (Phrase p)   -> tokenize p
  And ps            -> concatMap collectTerms (toList ps)
  Or ps             -> concatMap collectTerms (toList ps)
  Not p             -> collectTerms p
  _                 -> []

search :: Int -> BM25Parameters -> SearchIndex -> Query -> [MessageId]
search maxCandidates params idx query =
  List.sortOn (negate . bm25 params (siStats idx) queryTerms) capped
  where
    candidates = Set.toList (evaluate idx query)
    capped     = List.take maxCandidates candidates
    queryTerms = QueryTerms (Map.fromList
      [ (t, (length ps, ps))
      | t <- collectTerms query
      , let ps = termPostings (siInverted idx) t
      ])
