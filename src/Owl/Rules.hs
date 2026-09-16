-- | Rules and semantic actions (master spec §22). Predicate is
-- defined once, in §15, and reused here unchanged.
--
-- Conflict semantics (the spec's own explicit requirement: "define
-- explicit conflict semantics before implementation rather than
-- letting incidental list order decide"):
--
--   * Read-state (MarkRead / MarkUnread) is mutually exclusive -- the
--     LAST matching rule (by the caller-supplied rule order) wins.
--     Rule order is something the user controls directly, so "later
--     rules override earlier ones for the same category" is a
--     deterministic, predictable convention, not incidental ordering.
--   * Destination actions (Archive / Move _ / Delete) are mutually
--     exclusive -- a message can only end up in one place. Among
--     Archive/Move, the LAST matching rule wins, same reasoning as
--     read-state. Delete is a deliberate exception: it takes absolute
--     precedence over Archive/Move regardless of rule order, since
--     silently failing to delete something because another rule
--     wanted to relocate it instead is a worse failure mode than the
--     reverse.
--   * Label is purely additive -- every distinct label from every
--     matching rule is included; duplicates (the same label fired by
--     more than one rule) are collapsed.
--
-- evaluateRules is given no MailMembership parameter, but §15's own
-- matches needs one for InMailbox predicates. Resolved with an empty
-- MailMembership (Owl.Search.Predicate.MailMembership Map.empty),
-- which is semantically correct here, not a workaround: a message
-- being evaluated against rules has not yet been filed into any
-- mailbox -- filing it is one of the rule's own possible outcomes
-- (Move) -- so it genuinely has no membership to report.
module Owl.Rules
  ( Action (..)
  , Rule (..)
  , evaluateRules
  ) where

import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe, maybeToList)

import Owl.Domain.Id (LabelId, MailboxId)
import Owl.Message.Types (Message)
import Owl.Search.Predicate (MailMembership (..), Predicate, matches)

data Action
  = Archive
  | MarkRead
  | MarkUnread
  | Delete
  | Label LabelId
  | Move MailboxId
  deriving stock (Eq, Show)

-- | Field is ruleActions, not `then` -- `then` is a reserved Haskell
-- keyword and cannot be a field name.
data Rule = Rule
  { ruleWhen    :: !Predicate
  , ruleActions :: !(NonEmpty Action)
  }
  deriving stock (Eq, Show)

evaluateRules :: [Rule] -> Message -> [Action]
evaluateRules rules msg =
  labelActions ++ maybeToList readStateAction ++ maybeToList destinationAction
  where
    firedActions = concatMap actionsIfMatch rules

    actionsIfMatch rule
      | matches (MailMembership Map.empty) msg (ruleWhen rule) = NE.toList (ruleActions rule)
      | otherwise                                               = []

    readStateAction   = lastMatching isReadStateAction firedActions
    destinationAction = resolveDestination firedActions
    labelActions      = nub [a | a@(Label _) <- firedActions]

    isReadStateAction MarkRead   = True
    isReadStateAction MarkUnread = True
    isReadStateAction _          = False

    isDestinationAction Archive  = True
    isDestinationAction (Move _) = True
    isDestinationAction Delete   = True
    isDestinationAction _        = False

    resolveDestination actions
      | Delete `elem` actions = Just Delete
      | otherwise              = lastMatching isDestinationAction actions

    lastMatching p = listToMaybe . reverse . filter p
