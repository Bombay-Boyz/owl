module Owl.AddressBookSpec (spec) where

import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Owl.AddressBook
import Owl.Domain.Address (EmailAddress, mkEmailAddress)
import Owl.Domain.Id (PersonId (..))
import Owl.Domain.Person (Person (..))

mkAddr :: Text -> EmailAddress
mkAddr t = either (error . show) id (mkEmailAddress t)

mkPerson :: Text -> Text -> [Text] -> [Text] -> Person
mkPerson pid name emails aliases = Person
  { personId           = PersonId pid
  , personName         = Just name
  , personEmails       = case map mkAddr emails of
      (e : es) -> e :| es
      []       -> error "mkPerson: fixture needs at least one email"
  , personOrganization = Nothing
  , personPhone        = Nothing
  , personGroups       = Set.empty
  , personNotes        = Nothing
  , personAliases      = Set.fromList aliases
  }

candidatePersonId :: RecipientCandidate -> PersonId
candidatePersonId = personId . contactPerson . candidateContact

t1, t2 :: UTCTime
t1 = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
t2 = UTCTime (fromGregorian 2026 1 10) (secondsToDiffTime 0)

aliceContact, bobContact, carolContact, alisonContact :: Contact
aliceContact = Contact
  { contactPerson        = mkPerson "p1" "Alice Smith" ["alice@example.com"] ["Ally"]
  , contactSources       = Set.singleton FromSavedContact
  , contactLastContacted = Just t2
  , contactMessageCount  = 50
  }
bobContact = Contact
  { contactPerson        = mkPerson "p2" "Bob Jones" ["bob@example.net"] []
  , contactSources       = Set.singleton FromCorrespondence
  , contactLastContacted = Just t1
  , contactMessageCount  = 5
  }
carolContact = Contact
  { contactPerson        = mkPerson "p3" "Carol Alvarez" ["carol@example.org"] []
  , contactSources       = Set.singleton FromRecentRecipient
  , contactLastContacted = Nothing
  , contactMessageCount  = 0
  }
alisonContact = Contact
  { contactPerson        = mkPerson "p4" "Alison Cruz" ["alison@example.com"] []
  , contactSources       = Set.singleton FromCorrespondence
  , contactLastContacted = Just t1
  , contactMessageCount  = 1
  }

book :: AddressBook
book = mkAddressBook [aliceContact, bobContact, carolContact, alisonContact]

queryAt :: Text -> RecipientQuery
queryAt t = RecipientQuery { queryText = t, queryAsOf = t2 }

spec :: Spec
spec = do
  describe "matchKindRank (§16 prose order)" $
    it "ranks ExactAddress best and ContainsMatch worst" $
      map matchKindRank [ExactAddress, ExactName, PrefixMatch, AliasMatch, ContainsMatch]
        `shouldBe` [0, 1, 2, 3, 4]

  describe "resolveRecipients" $ do
    it "returns an empty list for an empty query -- 'no match' is a real result" $
      resolveRecipients (queryAt "") book `shouldBe` []

    it "returns an empty list when nothing matches" $
      resolveRecipients (queryAt "zzz-no-such-thing") book `shouldBe` []

    it "finds Alice by her exact email address" $
      map candidatePersonId (resolveRecipients (queryAt "alice@example.com") book) `shouldBe` [PersonId "p1"]

    it "finds Bob by a name prefix" $
      map candidatePersonId (resolveRecipients (queryAt "Bob") book) `shouldBe` [PersonId "p2"]

    it "finds Alice by her exact alias, not merely a prefix of it" $
      map candidatePersonId (resolveRecipients (queryAt "Ally") book) `shouldBe` [PersonId "p1"]

    it "finds Alice via a partial first-name prefix" $
      map candidatePersonId (resolveRecipients (queryAt "alice") book) `shouldBe` [PersonId "p1"]

    it "breaks a tied match kind (both PrefixMatch) by recency" $
      map candidatePersonId (resolveRecipients (queryAt "ali") book) `shouldBe` [PersonId "p1", PersonId "p4"]

  describe "scoreCandidate" $ do
    it "gives a more recently contacted candidate a better (lower) recentRank" $
      recentRank (scoreCandidate (queryAt "x") aliceContact)
        `shouldSatisfy` (< recentRank (scoreCandidate (queryAt "x") bobContact))

    it "treats a never-contacted candidate as the worst possible recentRank" $
      recentRank (scoreCandidate (queryAt "x") carolContact) `shouldBe` maxBound

    it "gives a higher message count a better (lower) frequencyRank" $
      frequencyRank (scoreCandidate (queryAt "x") aliceContact)
        `shouldSatisfy` (< frequencyRank (scoreCandidate (queryAt "x") bobContact))

    it "uses stableId as the deterministic tie-breaker identity" $
      stableId (scoreCandidate (queryAt "x") aliceContact) `shouldBe` PersonId "p1"
