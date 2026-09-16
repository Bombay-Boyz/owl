module Main (main) where

import Criterion.Main
import Owl.Prelude (owlVersion)

main :: IO ()
main = defaultMain
  [ bench "owlVersion" (whnf length owlVersion) ]
