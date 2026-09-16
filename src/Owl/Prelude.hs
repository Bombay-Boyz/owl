-- | Owl's foundation module. Deliberately minimal during Phase 0 (see the
-- master spec, §25) — this phase's only gate is that the toolchain
-- (build, lint, format, test, benchmark) works before any feature code
-- exists. Real domain modules land here phase by phase.
module Owl.Prelude (owlVersion) where

owlVersion :: String
owlVersion = "0.0.0.0"
