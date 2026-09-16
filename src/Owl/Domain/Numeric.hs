-- | A shared, minimal numeric vocabulary reused across sections that
-- need "a count that must be positive" (§19's RetryPolicy.maxAttempts;
-- §27's SyncWorkerPool poolSize/maxConnections) -- defined once here
-- rather than each section inventing its own.
module Owl.Domain.Numeric
  ( PositiveInt
  , mkPositiveInt
  , unPositiveInt
  ) where

newtype PositiveInt = PositiveInt Int
  deriving stock (Show)
  deriving newtype (Eq, Ord)

mkPositiveInt :: Int -> Maybe PositiveInt
mkPositiveInt n
  | n > 0     = Just (PositiveInt n)
  | otherwise = Nothing

unPositiveInt :: PositiveInt -> Int
unPositiveInt (PositiveInt n) = n
