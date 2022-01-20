{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Distribution
  ( tests
  ) where

import Data.Foldable (for_, traverse_)
import Data.Primitive.ByteArray
import GHC.Float
import GHC.Prim

import qualified System.Metrics.Distribution as Distribution
import System.Metrics.Distribution.Internal.Stripe64
  ( Stripe
  , stripeAddN#
  , stripeCombine#
  , stripeAddN
  , stripeCombine
  )
import Tasks (addToDistributionWithMultipleWriters)
import Test.Hspec
import Test.HUnit
import Test.Inspection
  ( Property (NoAllocation)
  , Result (Failure, Success)
  , inspectTest
  , mkObligation
  )

tests :: Spec
tests =
  describe "The `Distribution` metric" $ do
    it "yields zero values when empty" test_empty
    it "computes its statistics correctly" test_stats
    it "computes its statistics correctly (with `addN`)" test_stats_addN
    it "is thread-safe" test_threads
    it "does not allocate memory while holding spinlocks" test_no_allocate

-- | Check that an distribution with no values returns zero for all its
-- statistics.
--
-- We return zero rather than @NaN@ or @Infinity@ in order to accomodate
-- downstream consumers that cannot parse such values as floats.
test_empty :: IO ()
test_empty = do
  dist <- Distribution.new
  stats <- Distribution.read dist

  assertBool "Mean of empty distribution not zero" $
    Distribution.mean stats == 0.0
  assertBool "Variance of empty distribution not zero" $
    Distribution.variance stats == 0.0
  assertBool "Count of empty distribution not zero" $
    Distribution.count stats == 0
  assertBool "Count of empty distribution not zero" $
    Distribution.sum stats == 0.0
  assertBool "Minimum of empty distribution not zero" $
    Distribution.min stats == 0.0
  assertBool "Maximum of empty distribution not zero" $
    Distribution.max stats == 0.0

test_stats :: IO ()
test_stats = do
  let sample = map (fromIntegral @Int) [1..10]
      sampleCount = length sample
      sampleSum = sum sample
      sampleMean = sampleSum / fromIntegral sampleCount
      sampleVariance =
        let sq x = x*x
            sumDiffSquares = sum $ map (sq . subtract sampleMean) sample
        in  sumDiffSquares / fromIntegral sampleCount

  dist <- Distribution.new
  traverse_ (Distribution.add dist) sample
  stats <- Distribution.read dist

  assertBool "Mean not correct" $
    Distribution.mean stats `approxEq` sampleMean
  assertBool "Variance not correct" $
    Distribution.variance stats `approxEq` sampleVariance
  assertBool "Count not correct" $
    Distribution.count stats == fromIntegral sampleCount
  assertBool "Sum not correct" $
    Distribution.sum stats `approxEq` sampleSum
  assertBool "Minimum not correct" $
    Distribution.min stats `approxEq` minimum sample
  assertBool "Maximum not correct" $
    Distribution.max stats `approxEq` maximum sample

test_stats_addN :: IO ()
test_stats_addN = do
  let repetition = 2
      sample = map (fromIntegral @Int @Double) [1..10]
      sampleCount = length sample
      sampleSum = sum sample
      sampleMean = sampleSum / fromIntegral sampleCount
      sampleVariance =
        let sq x = x*x
            sumDiffSquares = sum $ map (sq . subtract sampleMean) sample
        in  sumDiffSquares / fromIntegral sampleCount

  dist <- Distribution.new
  for_ sample $ \x ->
    Distribution.addN dist x repetition
  stats <- Distribution.read dist

  assertBool "Mean not correct" $
    Distribution.mean stats `approxEq` sampleMean
  assertBool "Variance not correct" $
    Distribution.variance stats `approxEq` sampleVariance
  assertBool "Count not correct" $
    Distribution.count stats == fromIntegral sampleCount * fromIntegral repetition
  assertBool "Sum not correct" $
    Distribution.sum stats `approxEq` (sampleSum * fromIntegral repetition)
  assertBool "Minimum not correct" $
    Distribution.min stats `approxEq` minimum sample
  assertBool "Maximum not correct" $
    Distribution.max stats `approxEq` maximum sample

approxEq :: Double -> Double -> Bool
approxEq x y = abs (x - y) < 1e-12

test_threads :: IO ()
test_threads = do
  result <- addToDistributionWithMultipleWriters
  result `seq` pure ()

-- | Ensure that functions that hold locks never allocate memory. If
-- they did, threads running those functions could receive exceptions or
-- be descheduled by the runtime while holding the lock, which could
-- result in deadlock or severe performance degredation, respectively.
test_no_allocate :: IO ()
test_no_allocate = do
  case $(inspectTest (mkObligation 'testStripeAddN NoAllocation)) of
    Failure msg -> assertFailure msg
    Success _msg -> pure ()

  case $(inspectTest (mkObligation 'testStripeCombine NoAllocation)) of
    Failure msg -> assertFailure msg
    Success _msg -> pure ()

testStripeAddN#
  :: MutableByteArray# RealWorld
  -> Double#
  -> Int#
  -> State# RealWorld
  -> State# RealWorld
testStripeAddN# = stripeAddN#

testStripeCombine#
  :: MutableByteArray# RealWorld
  -> MutableByteArray# RealWorld
  -> State# RealWorld
  -> State# RealWorld
testStripeCombine# = stripeCombine#

testStripeAddN :: Stripe -> Double -> Int -> IO ()
testStripeAddN = stripeAddN

testStripeCombine :: Stripe -> Stripe -> IO ()
testStripeCombine = stripeCombine
