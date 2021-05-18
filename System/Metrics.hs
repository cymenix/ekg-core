{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
-- | A module for defining metrics that can be monitored.
--
-- Metrics are used to monitor program behavior and performance. All
-- metrics have
--
--  * a name, and
--
--  * a way to get the metric's current value.
--
-- This module provides a way to register metrics in a global \"metric
-- store\". The store can then be used to get a snapshot of all
-- metrics. The store also serves as a central place to keep track of
-- all the program's metrics, both user and library defined.
--
-- Here's an example of creating a single counter, used to count the
-- number of request served by a web server:
--
-- > import System.Metrics
-- > import qualified System.Metrics.Counter as Counter
-- >
-- > main = do
-- >     store <- newStore
-- >     requests <- createCounter "myapp.request_count" store
-- >     -- Every time we receive a request:
-- >     Counter.inc requests
--
-- This module also provides a way to register a number of predefined
-- metrics that are useful in most applications. See e.g.
-- 'registerGcMetrics'.
module System.Metrics
    (
      -- * Naming metrics
      -- $naming

      -- * The metric store
      -- $metric-store
      Store
    , newStore

      -- * Metric identifiers
    , Identifier (..)

      -- * Registering metrics
      -- $registering
    , registerCounter
    , registerGauge
    , registerLabel
    , registerDistribution
    , registerGroup

      -- ** Convenience functions
      -- $convenience
    , createCounter
    , createGauge
    , createLabel
    , createDistribution

      -- ** Predefined metrics
      -- $predefined
    , registerGcMetrics

      -- * Deregistering metrics
    , deregisterByName

      -- * Sampling metrics
      -- $sampling
    , Sample
    , sampleAll
    , Value(..)
    ) where

import Control.Applicative ((<$>))
import Control.Monad (forM)
import Data.Hashable
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.HashMap.Strict as M
import qualified Data.HashSet as S
import Data.List (foldl')
import qualified Data.Text as T
import GHC.Generics
import qualified GHC.Stats as Stats
import Prelude hiding (read)

import System.Metrics.Counter (Counter)
import qualified System.Metrics.Counter as Counter
import System.Metrics.Distribution (Distribution)
import qualified System.Metrics.Distribution as Distribution
import System.Metrics.Gauge (Gauge)
import qualified System.Metrics.Gauge as Gauge
import System.Metrics.Label (Label)
import qualified System.Metrics.Label as Label

-- $naming
-- Compound metric names should be separated using underscores.
-- Example: @request_count@. Periods in the name imply namespacing.
-- Example: @\"myapp.users\"@. Some consumers of metrics will use
-- these namespaces to group metrics in e.g. UIs.
--
-- Libraries and frameworks that want to register their own metrics
-- should prefix them with a namespace, to avoid collision with
-- user-defined metrics and metrics defined by other libraries. For
-- example, the Snap web framework could prefix all its metrics with
-- @\"snap.\"@.
--
-- It's customary to suffix the metric name with a short string
-- explaining the metric's type e.g. using @\"_ms\"@ to denote
-- milliseconds.

------------------------------------------------------------------------
-- * The metric store

-- $metric-store
-- The metric store is a shared store of metrics. It allows several
-- disjoint components (e.g. libraries) to contribute to the set of
-- metrics exposed by an application. Libraries that want to provide a
-- set of metrics should defined a register method, in the style of
-- 'registerGcMetrics', that registers the metrics in the 'Store'. The
-- register function should document which metrics are registered and
-- their types (i.e. counter, gauge, label, or distribution).

-- | A mutable metric store.
newtype Store = Store { storeState :: IORef State }

type GroupId = Int

-- | The 'Store' state.
data State = State
     { stateMetrics :: !(M.HashMap Identifier (Either MetricSampler GroupId))
     , stateGroups  :: !(IM.IntMap GroupSampler)
     , stateNextId  :: {-# UNPACK #-} !Int
     }

data GroupSampler = forall a. GroupSampler
     { groupSampleAction   :: !(IO a)
     , groupSamplerMetrics :: !(M.HashMap Identifier (a -> Value))
     }

-- TODO: Rename this to Metric and Metric to SampledMetric.
data MetricSampler = CounterS !(IO Int64)
                   | GaugeS !(IO Int64)
                   | LabelS !(IO T.Text)
                   | DistributionS !(IO Distribution.Stats)

-- | Create a new, empty metric store.
newStore :: IO Store
newStore = do
    state <- newIORef $ State M.empty IM.empty 0
    return $ Store state

------------------------------------------------------------------------
-- * Metric identifiers

-- Documentation TODO

data Identifier = Identifier
    { idName :: T.Text
    , idTags :: M.HashMap T.Text T.Text
    }
    deriving (Eq, Generic, Show)

instance Hashable Identifier

------------------------------------------------------------------------
-- Internal state manipulation

-- | Verify the internal consistency of the state.
verifyState :: State -> Bool
verifyState State{..} =
      groupsFromGroups == groupsFromMetrics
  &&  maybe True (< stateNextId) largestGroupId
  where
    groupsFromGroups = getSamplerIdentifiers <$> stateGroups
    groupsFromMetrics =
      foldl' insert_ IM.empty
        [(id', groupId) | (id', Right groupId) <- M.toList stateMetrics]
      where
        insert_ im (name, groupId) = IM.alter (putName name) groupId im
        putName identifier =
            Just . maybe (S.singleton identifier) (S.insert identifier)

    largestGroupId = fst <$> IM.lookupMax stateGroups

getSamplerIdentifiers :: GroupSampler -> S.HashSet Identifier
getSamplerIdentifiers GroupSampler{..} = M.keysSet groupSamplerMetrics

-- Delete an identifier and its associated metric. When no metric is
-- registered at the identifier, the original state is returned.
delete :: Identifier -> State -> State
delete identifier state@State{..} =
    case M.lookup identifier stateMetrics of
        Nothing -> state
        Just (Left _) -> State
            { stateMetrics = M.delete identifier stateMetrics
            , stateGroups = stateGroups
            , stateNextId = stateNextId
            }
        Just (Right groupID) -> State
            { stateMetrics = M.delete identifier stateMetrics
            , stateGroups =
                let delete_ = overSamplerMetrics $ \hm ->
                        let hm' = M.delete identifier hm
                        in  if M.null hm' then Nothing else Just hm'
                in  IM.update delete_ groupID stateGroups
            , stateNextId = stateNextId
            }

overSamplerMetrics ::
  (Functor f) =>
  (forall a. M.HashMap Identifier a -> f (M.HashMap Identifier a)) ->
  GroupSampler ->
  f GroupSampler
overSamplerMetrics f GroupSampler{..} =
  flip fmap (f groupSamplerMetrics) $ \groupSamplerMetrics' ->
      GroupSampler
          { groupSampleAction = groupSampleAction
          , groupSamplerMetrics = groupSamplerMetrics'
          }

insert :: Identifier -> MetricSampler -> State -> State
insert identifier sample state = state
    { stateMetrics =
        M.insert identifier (Left sample) $ stateMetrics state
    }

register' :: Identifier -> MetricSampler -> State -> State
register' identifier sample =
  insert identifier sample . delete identifier

insertGroup
    :: M.HashMap Identifier
       (a -> Value)  -- ^ Metric identifiers and getter functions
    -> IO a          -- ^ Action to sample the metric group
    -> State
    -> State
insertGroup getters cb State{..} = State
    { stateMetrics =
        M.foldlWithKey' (register_ stateNextId) stateMetrics getters
    , stateGroups =
        IM.insert stateNextId (GroupSampler cb getters) stateGroups
    , stateNextId = stateNextId + 1
    }
  where
    register_ groupId metrics name _ =
        M.insert name (Right groupId) metrics

registerGroup'
    :: M.HashMap Identifier
       (a -> Value)  -- ^ Metric identifiers and getter functions
    -> IO a          -- ^ Action to sample the metric group
    -> State
    -> State
registerGroup' getters cb =
  insertGroup getters cb . delete_
  where
    delete_ state = foldl' (flip delete) state (M.keys getters)

deregisterByName' :: T.Text -> State -> State
deregisterByName' name state =
    let identifiers = -- to remove
          filter (\i -> name == idName i) $ M.keys $ stateMetrics state
    in  foldl' (flip delete) state identifiers

------------------------------------------------------------------------
-- * Registering metrics

-- $registering
-- Before metrics can be sampled they need to be registered with the
-- metric store. Passing a metric identifier that has already been used
-- to one of the register functions will replace the existing metric.

-- | Register a non-negative, monotonically increasing, integer-valued
-- metric. The provided action to read the value must be thread-safe.
-- Also see 'createCounter'.
registerCounter :: Identifier -- ^ Counter identifier
                -> IO Int64   -- ^ Action to read the current metric value
                -> Store      -- ^ Metric store
                -> IO ()
registerCounter identifier sample store =
    register identifier (CounterS sample) store

-- | Register an integer-valued metric. The provided action to read
-- the value must be thread-safe. Also see 'createGauge'.
registerGauge :: Identifier -- ^ Gauge identifier
              -> IO Int64   -- ^ Action to read the current metric value
              -> Store      -- ^ Metric store
              -> IO ()
registerGauge identifier sample store =
    register identifier (GaugeS sample) store

-- | Register a text metric. The provided action to read the value
-- must be thread-safe. Also see 'createLabel'.
registerLabel :: Identifier -- ^ Label identifier
              -> IO T.Text  -- ^ Action to read the current metric value
              -> Store      -- ^ Metric store
              -> IO ()
registerLabel identifier sample store =
    register identifier (LabelS sample) store

-- | Register a distribution metric. The provided action to read the
-- value must be thread-safe. Also see 'createDistribution'.
registerDistribution
    :: Identifier             -- ^ Distribution identifier
    -> IO Distribution.Stats  -- ^ Action to read the current metric
                              -- value
    -> Store                  -- ^ Metric store
    -> IO ()
registerDistribution identifier sample store =
    register identifier (DistributionS sample) store

register :: Identifier
         -> MetricSampler
         -> Store
         -> IO ()
register identifier sample store =
    atomicModifyIORef' (storeState store) $ \state ->
        (register' identifier sample state, ())

-- | Register an action that will be executed any time one of the
-- metrics computed from the value it returns needs to be sampled.
--
-- When one or more of the metrics listed in the first argument needs
-- to be sampled, the action is executed and the provided getter
-- functions will be used to extract the metric(s) from the action's
-- return value.
--
-- The registered action might be called from a different thread and
-- therefore needs to be thread-safe.
--
-- This function allows you to sample groups of metrics together. This
-- is useful if
--
-- * you need a consistent view of several metric or
--
-- * sampling the metrics together is more efficient.
--
-- For example, sampling GC statistics needs to be done atomically or
-- a GC might strike in the middle of sampling, rendering the values
-- incoherent. Sampling GC statistics is also more efficient if done
-- in \"bulk\", as the run-time system provides a function to sample all
-- GC statistics at once.
--
-- Note that sampling of the metrics is only atomic if the provided
-- action computes @a@ atomically (e.g. if @a@ is a record, the action
-- needs to compute its fields atomically if the sampling is to be
-- atomic.)
--
-- Example usage:
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > import qualified Data.HashMap.Strict as M
-- > import GHC.Stats
-- > import System.Metrics
-- >
-- > main = do
-- >     store <- newStore
-- >     let metrics =
-- >             [ ("num_gcs", Counter . numGcs)
-- >             , ("max_bytes_used", Gauge . maxBytesUsed)
-- >             ]
-- >     registerGroup (M.fromList metrics) getGCStats store
registerGroup
    :: M.HashMap Identifier
       (a -> Value)  -- ^ Metric names and getter functions.
    -> IO a          -- ^ Action to sample the metric group
    -> Store         -- ^ Metric store
    -> IO ()
registerGroup getters cb store = do
    atomicModifyIORef' (storeState store) $ \state ->
        (registerGroup' getters cb state, ())

------------------------------------------------------------------------
-- ** Convenience functions

-- $convenience
-- These functions combined the creation of a mutable reference (e.g.
-- a 'Counter') with registering that reference in the store in one
-- convenient function.

-- | Create and register a zero-initialized counter.
createCounter :: Identifier -- ^ Counter identifier
              -> Store      -- ^ Metric store
              -> IO Counter
createCounter identifier store = do
    counter <- Counter.new
    registerCounter identifier (Counter.read counter) store
    return counter

-- | Create and register a zero-initialized gauge.
createGauge :: Identifier -- ^ Gauge identifier
            -> Store      -- ^ Metric store
            -> IO Gauge
createGauge identifier store = do
    gauge <- Gauge.new
    registerGauge identifier (Gauge.read gauge) store
    return gauge

-- | Create and register an empty label.
createLabel :: Identifier -- ^ Label identifier
            -> Store      -- ^ Metric store
            -> IO Label
createLabel identifier store = do
    label <- Label.new
    registerLabel identifier (Label.read label) store
    return label

-- | Create and register an event tracker.
createDistribution :: Identifier -- ^ Distribution identifier
                   -> Store      -- ^ Metric store
                   -> IO Distribution
createDistribution identifier store = do
    event <- Distribution.new
    registerDistribution identifier (Distribution.read event) store
    return event

------------------------------------------------------------------------
-- * Predefined metrics

-- $predefined
-- This library provides a number of pre-defined metrics that can
-- easily be added to a metrics store by calling their register
-- function.

#if MIN_VERSION_base(4,10,0)
-- | Convert nanoseconds to milliseconds.
nsToMs :: Int64 -> Int64
nsToMs s = round (realToFrac s / (1000000.0 :: Double))
#else
-- | Convert seconds to milliseconds.
sToMs :: Double -> Int64
sToMs s = round (s * 1000.0)
#endif

-- | Register a number of metrics related to garbage collector
-- behavior.
--
-- To enable GC statistics collection, either run your program with
--
-- > +RTS -T
--
-- or compile it with
--
-- > -with-rtsopts=-T
--
-- The runtime overhead of @-T@ is very small so it's safe to always
-- leave it enabled.
--
-- Registered counters:
--
-- [@rts.gc.bytes_allocated@] Total number of bytes allocated
--
-- [@rts.gc.num_gcs@] Number of garbage collections performed
--
-- [@rts.gc.num_bytes_usage_samples@] Number of byte usage samples taken
--
-- [@rts.gc.cumulative_bytes_used@] Sum of all byte usage samples, can be
-- used with @numByteUsageSamples@ to calculate averages with
-- arbitrary weighting (if you are sampling this record multiple
-- times).
--
-- [@rts.gc.bytes_copied@] Number of bytes copied during GC
--
-- [@rts.gc.init_cpu_ms@] CPU time used by the init phase, in
-- milliseconds. GHC 8.6+ only.
--
-- [@rts.gc.init_wall_ms@] Wall clock time spent running the init
-- phase, in milliseconds. GHC 8.6+ only.
--
-- [@rts.gc.mutator_cpu_ms@] CPU time spent running mutator threads,
-- in milliseconds. This does not include any profiling overhead or
-- initialization.
--
-- [@rts.gc.mutator_wall_ms@] Wall clock time spent running mutator
-- threads, in milliseconds. This does not include initialization.
--
-- [@rts.gc.gc_cpu_ms@] CPU time spent running GC, in milliseconds.
--
-- [@rts.gc.gc_wall_ms@] Wall clock time spent running GC, in
-- milliseconds.
--
-- [@rts.gc.cpu_ms@] Total CPU time elapsed since program start, in
-- milliseconds.
--
-- [@rts.gc.wall_ms@] Total wall clock time elapsed since start, in
-- milliseconds.
--
-- Registered gauges:
--
-- [@rts.gc.max_bytes_used@] Maximum number of live bytes seen so far
--
-- [@rts.gc.current_bytes_used@] Current number of live bytes
--
-- [@rts.gc.current_bytes_slop@] Current number of bytes lost to slop
--
-- [@rts.gc.max_bytes_slop@] Maximum number of bytes lost to slop at any one time so far
--
-- [@rts.gc.peak_megabytes_allocated@] Maximum number of megabytes allocated
--
-- [@rts.gc.par_tot_bytes_copied@] Number of bytes copied during GC, minus
-- space held by mutable lists held by the capabilities.  Can be used
-- with 'parMaxBytesCopied' to determine how well parallel GC utilized
-- all cores.
--
-- [@rts.gc.par_avg_bytes_copied@] Deprecated alias for
-- @par_tot_bytes_copied@.
--
-- [@rts.gc.par_max_bytes_copied@] Sum of number of bytes copied each GC by
-- the most active GC thread each GC. The ratio of
-- @par_tot_bytes_copied@ divided by @par_max_bytes_copied@ approaches
-- 1 for a maximally sequential run and approaches the number of
-- threads (set by the RTS flag @-N@) for a maximally parallel run.
registerGcMetrics :: Store -> IO ()
registerGcMetrics store =
    let taglessId :: T.Text -> Identifier
        taglessId name = Identifier name mempty in
    registerGroup
#if MIN_VERSION_base(4,10,0)
    (M.fromList
     [ (taglessId "rts.gc.bytes_allocated"          , Counter . fromIntegral . Stats.allocated_bytes)
     , (taglessId "rts.gc.num_gcs"                  , Counter . fromIntegral . Stats.gcs)
     , (taglessId "rts.gc.num_bytes_usage_samples"  , Counter . fromIntegral . Stats.major_gcs)
     , (taglessId "rts.gc.cumulative_bytes_used"    , Counter . fromIntegral . Stats.cumulative_live_bytes)
     , (taglessId "rts.gc.bytes_copied"             , Counter . fromIntegral . Stats.copied_bytes)
#if MIN_VERSION_base(4,12,0)
     , (taglessId "rts.gc.init_cpu_ms"              , Counter . nsToMs . Stats.init_cpu_ns)
     , (taglessId "rts.gc.init_wall_ms"             , Counter . nsToMs . Stats.init_elapsed_ns)
#endif
     , (taglessId "rts.gc.mutator_cpu_ms"           , Counter . nsToMs . Stats.mutator_cpu_ns)
     , (taglessId "rts.gc.mutator_wall_ms"          , Counter . nsToMs . Stats.mutator_elapsed_ns)
     , (taglessId "rts.gc.gc_cpu_ms"                , Counter . nsToMs . Stats.gc_cpu_ns)
     , (taglessId "rts.gc.gc_wall_ms"               , Counter . nsToMs . Stats.gc_elapsed_ns)
     , (taglessId "rts.gc.cpu_ms"                   , Counter . nsToMs . Stats.cpu_ns)
     , (taglessId "rts.gc.wall_ms"                  , Counter . nsToMs . Stats.elapsed_ns)
     , (taglessId "rts.gc.max_bytes_used"           , Gauge . fromIntegral . Stats.max_live_bytes)
     , (taglessId "rts.gc.current_bytes_used"       , Gauge . fromIntegral . Stats.gcdetails_live_bytes . Stats.gc)
     , (taglessId "rts.gc.current_bytes_slop"       , Gauge . fromIntegral . Stats.gcdetails_slop_bytes . Stats.gc)
     , (taglessId "rts.gc.max_bytes_slop"           , Gauge . fromIntegral . Stats.max_slop_bytes)
     , (taglessId "rts.gc.peak_megabytes_allocated" , Gauge . fromIntegral . (`quot` (1024*1024)) . Stats.max_mem_in_use_bytes)
     , (taglessId "rts.gc.par_tot_bytes_copied"     , Gauge . fromIntegral . Stats.par_copied_bytes)
     , (taglessId "rts.gc.par_avg_bytes_copied"     , Gauge . fromIntegral . Stats.par_copied_bytes)
     , (taglessId "rts.gc.par_max_bytes_copied"     , Gauge . fromIntegral . Stats.cumulative_par_max_copied_bytes)
     ])
    getRTSStats
#else
    (M.fromList
     [ (taglessId "rts.gc.bytes_allocated"          , Counter . Stats.bytesAllocated)
     , (taglessId "rts.gc.num_gcs"                  , Counter . Stats.numGcs)
     , (taglessId "rts.gc.num_bytes_usage_samples"  , Counter . Stats.numByteUsageSamples)
     , (taglessId "rts.gc.cumulative_bytes_used"    , Counter . Stats.cumulativeBytesUsed)
     , (taglessId "rts.gc.bytes_copied"             , Counter . Stats.bytesCopied)
     , (taglessId "rts.gc.mutator_cpu_ms"           , Counter . sToMs . Stats.mutatorCpuSeconds)
     , (taglessId "rts.gc.mutator_wall_ms"          , Counter . sToMs . Stats.mutatorWallSeconds)
     , (taglessId "rts.gc.gc_cpu_ms"                , Counter . sToMs . Stats.gcCpuSeconds)
     , (taglessId "rts.gc.gc_wall_ms"               , Counter . sToMs . Stats.gcWallSeconds)
     , (taglessId "rts.gc.cpu_ms"                   , Counter . sToMs . Stats.cpuSeconds)
     , (taglessId "rts.gc.wall_ms"                  , Counter . sToMs . Stats.wallSeconds)
     , (taglessId "rts.gc.max_bytes_used"           , Gauge . Stats.maxBytesUsed)
     , (taglessId "rts.gc.current_bytes_used"       , Gauge . Stats.currentBytesUsed)
     , (taglessId "rts.gc.current_bytes_slop"       , Gauge . Stats.currentBytesSlop)
     , (taglessId "rts.gc.max_bytes_slop"           , Gauge . Stats.maxBytesSlop)
     , (taglessId "rts.gc.peak_megabytes_allocated" , Gauge . Stats.peakMegabytesAllocated)
     , (taglessId "rts.gc.par_tot_bytes_copied"     , Gauge . gcParTotBytesCopied)
     , (taglessId "rts.gc.par_avg_bytes_copied"     , Gauge . gcParTotBytesCopied)
     , (taglessId "rts.gc.par_max_bytes_copied"     , Gauge . Stats.parMaxBytesCopied)
     ])
    getGcStats
#endif
    store

#if MIN_VERSION_base(4,10,0)
-- | Get RTS statistics.
getRTSStats :: IO Stats.RTSStats
getRTSStats = do
    enabled <- Stats.getRTSStatsEnabled
    if enabled
        then Stats.getRTSStats
        else return emptyRTSStats

-- | Empty RTS statistics, as if the application hasn't started yet.
emptyRTSStats :: Stats.RTSStats
emptyRTSStats = Stats.RTSStats
    { gcs                                  = 0
    , major_gcs                            = 0
    , allocated_bytes                      = 0
    , max_live_bytes                       = 0
    , max_large_objects_bytes              = 0
    , max_compact_bytes                    = 0
    , max_slop_bytes                       = 0
    , max_mem_in_use_bytes                 = 0
    , cumulative_live_bytes                = 0
    , copied_bytes                         = 0
    , par_copied_bytes                     = 0
    , cumulative_par_max_copied_bytes      = 0
# if MIN_VERSION_base(4,11,0)
    , cumulative_par_balanced_copied_bytes = 0
# if MIN_VERSION_base(4,12,0)
    , init_cpu_ns                          = 0
    , init_elapsed_ns                      = 0
# endif
# endif
    , mutator_cpu_ns                       = 0
    , mutator_elapsed_ns                   = 0
    , gc_cpu_ns                            = 0
    , gc_elapsed_ns                        = 0
    , cpu_ns                               = 0
    , elapsed_ns                           = 0
    , gc                                   = emptyGCDetails
    }

emptyGCDetails :: Stats.GCDetails
emptyGCDetails = Stats.GCDetails
    { gcdetails_gen                       = 0
    , gcdetails_threads                   = 0
    , gcdetails_allocated_bytes           = 0
    , gcdetails_live_bytes                = 0
    , gcdetails_large_objects_bytes       = 0
    , gcdetails_compact_bytes             = 0
    , gcdetails_slop_bytes                = 0
    , gcdetails_mem_in_use_bytes          = 0
    , gcdetails_copied_bytes              = 0
    , gcdetails_par_max_copied_bytes      = 0
# if MIN_VERSION_base(4,11,0)
    , gcdetails_par_balanced_copied_bytes = 0
# endif
    , gcdetails_sync_elapsed_ns           = 0
    , gcdetails_cpu_ns                    = 0
    , gcdetails_elapsed_ns                = 0
    }
#else
-- | Get GC statistics.
getGcStats :: IO Stats.GCStats
# if MIN_VERSION_base(4,6,0)
getGcStats = do
    enabled <- Stats.getGCStatsEnabled
    if enabled
        then Stats.getGCStats
        else return emptyGCStats

-- | Empty GC statistics, as if the application hasn't started yet.
emptyGCStats :: Stats.GCStats
emptyGCStats = Stats.GCStats
    { bytesAllocated         = 0
    , numGcs                 = 0
    , maxBytesUsed           = 0
    , numByteUsageSamples    = 0
    , cumulativeBytesUsed    = 0
    , bytesCopied            = 0
    , currentBytesUsed       = 0
    , currentBytesSlop       = 0
    , maxBytesSlop           = 0
    , peakMegabytesAllocated = 0
    , mutatorCpuSeconds      = 0
    , mutatorWallSeconds     = 0
    , gcCpuSeconds           = 0
    , gcWallSeconds          = 0
    , cpuSeconds             = 0
    , wallSeconds            = 0
    , parTotBytesCopied      = 0
    , parMaxBytesCopied      = 0
    }
# else
getGcStats = Stats.getGCStats
# endif

-- | Helper to work around rename in GHC.Stats in base-4.6.
gcParTotBytesCopied :: Stats.GCStats -> Int64
# if MIN_VERSION_base(4,6,0)
gcParTotBytesCopied = Stats.parTotBytesCopied
# else
gcParTotBytesCopied = Stats.parAvgBytesCopied
# endif
#endif

------------------------------------------------------------------------
-- * Deregistering metrics

-- Documentation TODO

-- | Deregister all metrics (of any type) with the given name.
deregisterByName :: T.Text -> Store -> IO ()
deregisterByName name store =
    atomicModifyIORef' (storeState store) $ \state ->
        (deregisterByName' name state, ())

------------------------------------------------------------------------
-- * Sampling metrics

-- $sampling
-- The metrics register in the store can be sampled together. Sampling
-- is /not/ atomic. While each metric will be retrieved atomically,
-- the sample is not an atomic snapshot of the system as a whole. See
-- 'registerGroup' for an explanation of how to sample a subset of all
-- metrics atomically.

-- | A sample of some metrics.
type Sample = M.HashMap Identifier Value

-- | Sample all metrics. Sampling is /not/ atomic in the sense that
-- some metrics might have been mutated before they're sampled but
-- after some other metrics have already been sampled.
sampleAll :: Store -> IO Sample
sampleAll store = do
    state <- readIORef (storeState store)
    let metrics = stateMetrics state
        groups = stateGroups state
    cbSample <- sampleGroups $ IM.elems groups
    sample <- readAllRefs metrics
    let allSamples = sample ++ cbSample
    return $! M.fromList allSamples

-- | Sample all metric groups.
sampleGroups :: [GroupSampler] -> IO [(Identifier, Value)]
sampleGroups cbSamplers = concat `fmap` sequence (map runOne cbSamplers)
  where
    runOne :: GroupSampler -> IO [(Identifier, Value)]
    runOne GroupSampler{..} = do
        a <- groupSampleAction
        return $! map (\ (identifier, f) -> (identifier, f a))
                      (M.toList groupSamplerMetrics)

-- | The value of a sampled metric.
data Value = Counter {-# UNPACK #-} !Int64
           | Gauge {-# UNPACK #-} !Int64
           | Label {-# UNPACK #-} !T.Text
           | Distribution !Distribution.Stats
           deriving (Eq, Show)

sampleOne :: MetricSampler -> IO Value
sampleOne (CounterS m)      = Counter <$> m
sampleOne (GaugeS m)        = Gauge <$> m
sampleOne (LabelS m)        = Label <$> m
sampleOne (DistributionS m) = Distribution <$> m

-- | Get a snapshot of all values.  Note that we're not guaranteed to
-- see a consistent snapshot of the whole map.
readAllRefs :: M.HashMap Identifier (Either MetricSampler GroupId)
            -> IO [(Identifier, Value)]
readAllRefs m = do
    forM ([(name, ref) | (name, Left ref) <- M.toList m]) $ \ (name, ref) -> do
        val <- sampleOne ref
        return (name, val)
