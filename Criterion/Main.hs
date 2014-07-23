-- |
-- Module      : Criterion.Main
-- Copyright   : (c) 2009-2014 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Wrappers for compiling and running benchmarks quickly and easily.
-- See 'defaultMain' below for an example.

module Criterion.Main
    (
    -- * How to write benchmarks
    -- $bench

    -- ** Benchmarking IO actions
    -- $io

    -- ** Benchmarking pure code
    -- $pure

    -- ** Fully evaluating a result
    -- $rnf

    -- * Types
      Benchmarkable(..)
    , Benchmark
    -- * Constructing benchmarks
    , bench
    , bgroup
    , nf
    , whnf
    , nfIO
    , whnfIO
    -- * Running benchmarks
    , defaultMain
    , defaultMainWith
    -- * Other useful code
    , makeMatcher
    ) where

import Control.Monad (unless)
import Control.Monad.Trans (liftIO)
import Criterion.IO.Printf (printError, writeCsv)
import Criterion.Internal (runAndAnalyse, runNotAnalyse, prefix)
import Criterion.Main.Options (MatchType(..), Mode(..), defaultConfig, describe)
import Criterion.Measurement (initializeTime)
import Criterion.Monad (Criterion, withConfig)
import Criterion.Types
import Data.List (isPrefixOf, sort, stripPrefix)
import Data.Maybe (fromMaybe)
import Options.Applicative (execParser)
import System.Environment (getProgName)
import System.Exit (ExitCode(..), exitWith)
import System.FilePath.Glob

-- | An entry point that can be used as a @main@ function.
--
-- > import Criterion.Main
-- >
-- > fib :: Int -> Int
-- > fib 0 = 0
-- > fib 1 = 1
-- > fib n = fib (n-1) + fib (n-2)
-- >
-- > main = defaultMain [
-- >        bgroup "fib" [ bench "10" $ whnf fib 10
-- >                     , bench "35" $ whnf fib 35
-- >                     , bench "37" $ whnf fib 37
-- >                     ]
-- >                    ]
defaultMain :: [Benchmark] -> IO ()
defaultMain = defaultMainWith defaultConfig (return ())

makeMatcher :: MatchType -> [String] -> Either String (String -> Bool)
makeMatcher matchKind args =
  case matchKind of
    Prefix -> Right $ \b -> null args || any (`isPrefixOf` b) args
    Glob ->
      let compOptions = compDefault { errorRecovery = False }
      in case mapM (tryCompileWith compOptions) args of
           Left errMsg -> Left . fromMaybe errMsg . stripPrefix "compile :: " $
                          errMsg
           Right ps -> Right $ \b -> null ps || any (`match` b) ps

-- | An entry point that can be used as a @main@ function, with
-- configurable defaults.
--
-- Example:
--
-- > import Criterion.OldConfig
-- > import Criterion.Main
-- >
-- > myConfig = defaultConfig {
-- >              -- Always GC between runs.
-- >              cfgPerformGC = ljust True
-- >            }
-- >
-- > main = defaultMainWith myConfig (return ()) [
-- >          bench "fib 30" $ whnf fib 30
-- >        ]
--
-- If you save the above example as @\"Fib.hs\"@, you should be able
-- to compile it as follows:
--
-- > ghc -O --make Fib
--
-- Run @\"Fib --help\"@ on the command line to get a list of command
-- line options.
defaultMainWith :: Config
                -> Criterion () -- ^ Prepare data prior to executing the first benchmark.
                -> [Benchmark]
                -> IO ()
defaultMainWith defCfg prep bs = do
  wat <- execParser (describe defCfg)
  case wat of
    List -> mapM_ putStrLn . sort . concatMap benchNames $ bs
    Run cfg matchType benches -> do
      shouldRun <- either parseError return .
                   makeMatcher matchType $
                   benches
      unless (null benches || any shouldRun (names bsgroup)) $
        parseError "none of the specified names matches a benchmark"
      withConfig cfg $
        if onlyRun cfg
        then runNotAnalyse shouldRun bsgroup
        else do
          writeCsv ("Name","Mean","MeanLB","MeanUB","Stddev","StddevLB",
                    "StddevUB")
          liftIO initializeTime
          prep
          runAndAnalyse shouldRun bsgroup
  where
  bsgroup = BenchGroup "" bs
  names = go ""
    where go pfx (BenchGroup pfx' bms) = concatMap (go (prefix pfx pfx')) bms
          go pfx (Benchmark desc _)    = [prefix pfx desc]

-- | Display an error message from a command line parsing failure, and
-- exit.
parseError :: String -> IO a
parseError msg = do
  _ <- printError "Error: %s\n" msg
  _ <- printError "Run \"%s --help\" for usage information\n" =<< getProgName
  exitWith (ExitFailure 64)

-- $bench
--
-- The 'Benchmarkable' typeclass represents the class of all code that
-- can be benchmarked.  Every instance must run a benchmark a given
-- number of times.  We are most interested in benchmarking two things:
--
-- * 'IO' actions.  Any 'IO' action can be benchmarked directly.
--
-- * Pure functions.  GHC optimises aggressively when compiling with
--   @-O@, so it is easy to write innocent-looking benchmark code that
--   doesn't measure the performance of a pure function at all.  We
--   work around this by benchmarking both a function and its final
--   argument together.

-- $io
--
-- Any 'IO' action can be benchmarked easily if its type resembles
-- this:
--
-- @
-- 'IO' a
-- @

-- $pure
--
-- Because GHC optimises aggressively when compiling with @-O@, it is
-- potentially easy to write innocent-looking benchmark code that will
-- only be evaluated once, for which all but the first iteration of
-- the timing loop will be timing the cost of doing nothing.
--
-- To work around this, we provide a special type, 'Pure', for
-- benchmarking pure code.  Values of this type are constructed using
-- one of two functions.
--
-- The first is a function which will cause results to be fully
-- evaluated to normal form (NF):
--
-- @
-- 'nf' :: 'NFData' b => (a -> b) -> a -> 'Pure'
-- @
--
-- The second will cause results to be evaluated to weak head normal
-- form (the Haskell default):
--
-- @
-- 'whnf' :: (a -> b) -> a -> 'Pure'
-- @
--
-- As both of these types suggest, when you want to benchmark a
-- function, you must supply two values:
--
-- * The first element is the function, saturated with all but its
--   last argument.
--
-- * The second element is the last argument to the function.
--
-- Here is an example that makes the use of these functions clearer.
-- Suppose we want to benchmark the following function:
--
-- @
-- firstN :: Int -> [Int]
-- firstN k = take k [(0::Int)..]
-- @
--
-- So in the easy case, we construct a benchmark as follows:
--
-- @
-- 'nf' firstN 1000
-- @
--
-- The compiler will correctly infer that the number 1000 must have
-- the type 'Int', and the type of the expression is 'Pure'.

-- $rnf
--
-- The 'whnf' harness for evaluating a pure function only evaluates
-- the result to weak head normal form (WHNF).  If you need the result
-- evaluated all the way to normal form, use the 'nf' function to
-- force its complete evaluation.
--
-- Using the @firstN@ example from earlier, to naive eyes it might
-- /appear/ that the following code ought to benchmark the production
-- of the first 1000 list elements:
--
-- @
-- 'whnf' firstN 1000
-- @
--
-- Because in this case the result will only be forced until it
-- reaches WHNF, what this would /actually/ benchmark is merely the
-- production of the first list element!
