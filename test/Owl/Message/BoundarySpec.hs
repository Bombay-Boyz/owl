module Owl.Message.BoundarySpec (spec) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Domain.Attachment (AttachmentLimits (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..))
import Owl.Domain.MailAddress (Address (..))
import qualified Owl.Domain.Address as Address
import qualified Owl.Message.Types as Message
import Owl.Message.Boundary

sampleAcct :: AccountId
sampleAcct = AccountId "personal"

sampleMid :: MessageId
sampleMid = MessageId (LocalId (UUID.fromWords 1 2 3 4))

limits :: AttachmentLimits
limits = AttachmentLimits { maxAttachmentCount = 10, maxAttachmentTotalSize = 1000000 }

sampleBytes :: BC.ByteString
sampleBytes = BC.intercalate "\r\n"
  [ "From: Alice Smith <alice@example.com>"
  , "To: bob@example.net"
  , "Subject: Hello"
  , "Date: Sat, 22 Aug 2026 10:00:00 +0000"
  , "Message-ID: <abc123@example.com>"
  , "Content-Type: text/plain; charset=us-ascii"
  , ""
  , "Hello, Bob!"
  ]

spec :: Spec
spec = describe "the message boundary pipeline end to end" $
  it "parses, decodes, and validates a minimal well-formed message" $ do
    let result = do
          raw       <- either (Left . show) Right (parseMessage sampleBytes)
          decoded   <- either (Left . show) Right (decodeCharset raw)
          validated <- either (Left . show) Right (validateMessage sampleAcct sampleMid limits decoded)
          pure (toMessage validated)
    case result of
      Left err  -> expectationFailure err
      Right msg -> do
        Message.accountId msg `shouldBe` sampleAcct
        addressDisplayName (Message.sender msg) `shouldBe` Just "Alice Smith"
        Address.unEmailAddress (addressEmail (Message.sender msg)) `shouldBe` "alice@example.com"
        map (Address.unEmailAddress . addressEmail) (Message.recipients msg) `shouldBe` ["bob@example.net"]
