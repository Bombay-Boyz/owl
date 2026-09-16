-- | Owl's entry point.
--
-- The --demo seed below is deliberately THROWAWAY SCAFFOLDING and
-- deliberately lives here, in app/, rather than anywhere in the
-- library: it exists only so the TUI can be exercised by hand before
-- the sync loop (§27 / the orchestration work) is built. Nothing in
-- src/ knows it exists, and it should be deleted outright the moment
-- real mail can be loaded -- it is a ladder, not a feature.
module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import System.Environment (getArgs)

import Owl.Application
  ( Application (messages, threads)
  , MessageState (..)
  , ThreadState (..)
  , emptyApplication
  )
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Prelude (owlVersion)
import Owl.TUI.App (runTUI)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--demo"]    -> runApp demoApplication
    ["--version"] -> putStrLn ("Owl " <> owlVersion)
    []            -> runApp emptyApplication
    _             -> putStrLn "usage: owl [--demo | --version]"
  where
    runApp app = do
      _finalState <- runTUI app
      pure ()

-- ---------------------------------------------------------------------
-- Throwaway demo seed -- see this module's header.
-- ---------------------------------------------------------------------

demoApplication :: Application
demoApplication = emptyApplication
  { messages = MessageState
      { messageStateMessages = Map.fromList
          [ (mkMid 1, mkMsg 1 "t-proj" (named "Alice Chen" "alice@example.com")
                        "Q3 planning doc" 3 True)
          , (mkMid 2, mkMsg 2 "t-proj" (named "Bob Iyer" "bob@example.net")
                        "Re: Q3 planning doc" 5 False)
          , (mkMid 3, mkMsg 3 "t-inv"  (bare "billing@vendor.example")
                        "Invoice 4471 is due" 9 False)
          , (mkMid 4, mkMsg 4 "t-lunch" (named "Dana Ruiz" "dana@example.com")
                        "Lunch Thursday?" 7 True)
          ]
      , archivedMessages = Set.empty
      , deletedMessages  = Set.empty
      }
  , threads = ThreadState (Map.fromList
      [ (ThreadId "t-proj",  Set.fromList [mkMid 1, mkMid 2])
      , (ThreadId "t-inv",   Set.singleton (mkMid 3))
      , (ThreadId "t-lunch", Set.singleton (mkMid 4))
      ])
  }

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

named :: Text -> Text -> Address
named n e = Address (Just n) (either (error . show) id (mkEmailAddress e))

bare :: Text -> Address
bare e = Address Nothing (either (error . show) id (mkEmailAddress e))

mkMsg :: Int -> Text -> Address -> Text -> Int -> Bool -> Message
mkMsg n threadName from subjText day isSeen = Message
  { identity    = MessageIdentity { messageId = mkMid n, rfcId = Nothing }
  , accountId   = AccountId "demo"
  , threadId    = ThreadId threadName
  , sender      = from
  , recipients  = [bare "you@example.com"]
  , subject     = either (error . show) id (mkSubject subjText)
  , sentAt      = UTCTime (fromGregorian 2026 1 day) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "Demo message body.") Nothing
  , attachments = []
  , flags       = if isSeen then Set.singleton Seen else Set.empty
  , references  = []
  , replyTo     = []
  }
