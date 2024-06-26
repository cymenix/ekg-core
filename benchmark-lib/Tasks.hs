{-# LANGUAGE BangPatterns #-}

module Tasks
  ( incrementCounterWithMultipleWriters
  , addToDistributionWithMultipleWriters
  ) where

import Control.Concurrent
import Control.Monad
import Data.Int (Int64)
import qualified System.Metrics.Counter as C
import qualified System.Metrics.Distribution as D

-- | Perform 100,000 atomic increments using 100 concurrent writers, and
-- check the final count.
incrementCounterWithMultipleWriters :: IO Int64
incrementCounterWithMultipleWriters = do
    counter <- C.new
    locks <- replicateM n newEmptyMVar
    mapM_ (forkIO . work counter iters) locks
    mapM_ takeMVar locks
    total <- C.read counter
    unless (fromIntegral total == n*iters) $
      error "Incorrect count!"
    pure total
  where
    n = 100
    iters = 100000

    work :: C.Counter -> Int -> MVar () -> IO ()
    work !_ 0 !lock     = putMVar lock ()
    work counter i lock = C.inc counter >> work counter (i - 1) lock

-- | Perform 100,000 atomic sample additions using 100 concurrent
-- writers, and check the final count.
addToDistributionWithMultipleWriters :: IO Int64
addToDistributionWithMultipleWriters = do
    distrib <- D.new
    locks <- replicateM n newEmptyMVar
    mapM_ (forkIO . work distrib iters) locks
    mapM_ takeMVar locks
    total <- D.count <$> D.read distrib
    unless (fromIntegral total == n*iters) $
      error "Incorrect count!"
    pure total
  where
    n = 100
    iters = 100000

    work :: D.Distribution -> Int -> MVar () -> IO ()
    work !_ 0 !lock     = putMVar lock ()
    work distrib i lock = D.add distrib 1.0 >> work distrib (i - 1) lock
