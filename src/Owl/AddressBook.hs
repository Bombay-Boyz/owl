-- | Address book and recipient resolution (master spec §16).
--
-- Design decisions §16 leaves genuinely open, stated plainly rather
-- than silently assumed:
--
--  * §16 asks to "distinguish Contact, Correspondent, RecentRecipient,
--    UnknownSender." Contact, Correspondent, and RecentRecipient all
--    feed the same scoring/candidate mechanism (scoreCandidate takes a
--    bare Contact), so they are represented as one Contact record
--    carrying a ContactSource set (which of the three origins apply --
--    a person can be more than one at once) rather than three separate
--    wrapper types that would all need converting to the same shape
--    anyway. UnknownSender is genuinely separate -- a sender with no
--    Person record at all -- and never participates in scoring.
--  * MatchKind's ranking order: the given ADT's constructor order
--    (ExactAddress, ExactName, AliasMatch, PrefixMatch, ContainsMatch)
--    and the prose's stated order ("exact address, exact name, prefix,
--    alias, recency, frequency") disagree on whether alias or prefix
--    ranks better. matchKindRank follows the prose's explicit order,
--    since a data declaration's constructor sequence is not
--    necessarily meaningful the way a stated ranking is.
--  * recentRank/frequencyRank are monotonic proxies (elapsed days since
--    last contact; negated message count), not literal dense ranks
--    computed by comparing against every other candidate --
--    scoreCandidate's own given signature (RecipientQuery -> Contact
--    -> CandidateScore) only ever sees one Contact at a time, so a
--    true cross-candidate rank cannot be computed there; a monotonic
--    proxy produces the identical sort order and is computable from
--    one Contact alone.
--  * Prefix/contains lookups degrade to an honest full scan over the
--    address book rather than an unverified "clever" Map range trick
--    -- the same trade-off already made for SubjectContains in §15,
--    for the same reason: address-book-scale full scan is genuinely
--    fine, and a subtly wrong optimization is worse than a correct,
--    simple one.
module Owl.AddressBook
  ( ContactSource (..)
  , Contact (..)
  , UnknownSender (..)
  , MatchKind (..)
  , matchKindRank
  , CandidateScore (..)
  , NormalizedText
  , unNormalizedText
  , normalizeText
  , ContactIndex
  , RecipientQuery (..)
  , AddressBook (..)
  , RecipientCandidate (..)
  , mkAddressBook
  , scoreCandidate
  , resolveRecipients
  ) where

import qualified Data.List as List
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, diffUTCTime)

import Owl.Domain.Address (EmailAddress, unEmailAddress)
import Owl.Domain.Id (PersonId)
import Owl.Domain.Person (Person (..))

data ContactSource = FromSavedContact | FromCorrespondence | FromRecentRecipient
  deriving stock (Eq, Ord, Show)

data Contact = Contact
  { contactPerson        :: !Person
  , contactSources       :: !(Set ContactSource)
  , contactLastContacted :: !(Maybe UTCTime)
  , contactMessageCount  :: !Word
  }
  deriving stock (Eq, Show)

-- | A message's sender who matches no known Person at all.
newtype UnknownSender = UnknownSender EmailAddress
  deriving stock (Eq, Show)

data MatchKind = ExactAddress | ExactName | AliasMatch | PrefixMatch | ContainsMatch
  deriving stock (Eq, Show)

-- | Prose order (§16): "exact address, exact name, prefix, alias" --
-- see this module's own top-level note on why this doesn't follow the
-- ADT's declaration order.
matchKindRank :: MatchKind -> Int
matchKindRank ExactAddress  = 0
matchKindRank ExactName     = 1
matchKindRank PrefixMatch   = 2
matchKindRank AliasMatch    = 3
matchKindRank ContainsMatch = 4

data CandidateScore = CandidateScore
  { matchRank     :: Int
  , recentRank    :: Int
  , frequencyRank :: Int
  , stableId      :: PersonId
  }
  deriving stock (Eq, Ord, Show)

newtype NormalizedText = NormalizedText Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

unNormalizedText :: NormalizedText -> Text
unNormalizedText (NormalizedText t) = t

normalizeText :: Text -> NormalizedText
normalizeText = NormalizedText . Text.toCaseFold . Text.strip

type ContactIndex = Map NormalizedText (Set PersonId)

data RecipientQuery = RecipientQuery
  { queryText :: !Text
  , queryAsOf :: !UTCTime
  }
  deriving stock (Eq, Show)

data AddressBook = AddressBook
  { abContacts :: !(Map PersonId Contact)
  , abIndex    :: !ContactIndex
  }
  deriving stock (Eq, Show)

data RecipientCandidate = RecipientCandidate
  { candidateContact :: !Contact
  , candidateScore   :: !CandidateScore
  }
  deriving stock (Eq, Show)

mkAddressBook :: [Contact] -> AddressBook
mkAddressBook contacts = AddressBook
  { abContacts = byId
  , abIndex    = Map.fromListWith Set.union
      [ (normalizeText key, Set.singleton pid)
      | (pid, contact) <- Map.toList byId
      , key <- searchableStrings (contactPerson contact)
      ]
  }
  where
    byId = Map.fromList [ (personId (contactPerson c), c) | c <- contacts ]

searchableStrings :: Person -> [Text]
searchableStrings person =
  maybe [] pure (personName person)
    ++ map unEmailAddress (NE.toList (personEmails person))
    ++ Set.toList (personAliases person)

scoreCandidate :: RecipientQuery -> Contact -> CandidateScore
scoreCandidate query contact = CandidateScore
  { matchRank     = matchKindRank (bestMatchKind query (contactPerson contact))
  , recentRank    = maybe maxBound (daysSince (queryAsOf query)) (contactLastContacted contact)
  , frequencyRank = negate (fromIntegral (contactMessageCount contact))
  , stableId      = personId (contactPerson contact)
  }

daysSince :: UTCTime -> UTCTime -> Int
daysSince now past = max 0 (round (diffUTCTime now past / 86400))

-- | Exact checks (address/name/alias) come before the prefix check, so
-- an exact alias match (e.g. querying "Ally" when "Ally" is itself the
-- alias) is never swallowed by "is a prefix of itself" trivially being
-- true. The prefix check itself explicitly excludes equality, so it
-- only ever fires on a genuine partial match.
bestMatchKind :: RecipientQuery -> Person -> MatchKind
bestMatchKind query person
  | qNorm `elem` addressNorms = ExactAddress
  | Just qNorm == nameNorm    = ExactName
  | qNorm `elem` aliasNorms   = AliasMatch
  | maybe False (\n -> qNorm `Text.isPrefixOf` n && qNorm /= n) nameNorm
      || any (\a -> qNorm `Text.isPrefixOf` a && qNorm /= a) aliasNorms = PrefixMatch
  | otherwise = ContainsMatch
  where
    qNorm        = Text.toCaseFold (Text.strip (queryText query))
    addressNorms = map (Text.toCaseFold . unEmailAddress) (NE.toList (personEmails person))
    nameNorm     = Text.toCaseFold <$> personName person
    aliasNorms   = map Text.toCaseFold (Set.toList (personAliases person))

-- | May be empty: "no match" is a real result (§16).
resolveRecipients :: RecipientQuery -> AddressBook -> [RecipientCandidate]
resolveRecipients query book
  | Text.null qText = []
  | otherwise =
      List.sortOn candidateScore
        [ RecipientCandidate contact (scoreCandidate query contact)
        | pid <- Set.toList candidatePersonIds
        , Just contact <- [Map.lookup pid (abContacts book)]
        ]
  where
    qNorm  = normalizeText (queryText query)
    qText  = unNormalizedText qNorm
    exactMatches = Map.findWithDefault Set.empty qNorm (abIndex book)
    prefixMatches = Set.unions
      [ pids | (k, pids) <- Map.toList (abIndex book), qText `Text.isPrefixOf` unNormalizedText k ]
    containsMatches = Set.unions
      [ pids | (k, pids) <- Map.toList (abIndex book), qText `Text.isInfixOf` unNormalizedText k ]
    candidatePersonIds = Set.unions [exactMatches, prefixMatches, containsMatches]
