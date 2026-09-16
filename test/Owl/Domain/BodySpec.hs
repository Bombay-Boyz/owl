module Owl.Domain.BodySpec (spec) where

import Test.Hspec

import Owl.Domain.Body

spec :: Spec
spec = describe "sanitizeHtml" $ do
  it "strips a simple tag, keeping its text content" $
    unSanitizedHtml (sanitizeHtml "<b>hello</b>") `shouldBe` "hello"

  it "strips tag markers around a script body (content stays as inert text)" $
    unSanitizedHtml (sanitizeHtml "<script>alert(1)</script>ok")
      `shouldBe` "alert(1)ok"

  it "decodes standard XML entities" $
    unSanitizedHtml (sanitizeHtml "a &amp; b &lt;3")
      `shouldBe` "a & b <3"

  it "does not double-decode an escaped ampersand" $
    unSanitizedHtml (sanitizeHtml "&amp;lt;") `shouldBe` "&lt;"

  it "leaves plain text with no markup unchanged" $
    unSanitizedHtml (sanitizeHtml "just text") `shouldBe` "just text"
