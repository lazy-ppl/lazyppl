{-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables #-}

{- | This file defines
    1. Two monads: `Prob` (for probability measures) and `Meas` (for unnormalized measures)
    2. The inference methods produce samples from an unnormalized measure. We provide three inference methods: 
       a. 'mh' (Metropolis-Hastings algorithm based on lazily mutating parts of the tree at random).
       b. 'mhirreducible', which randomly restarts for a properly irreducible Metropolis-Hastings kernel.
       c. 'lwis' (simple reference likelihood weighted importance sampling)
    See also SingleSite for a separate single-site Metropolis-Hastings algorithm, akin to Wingate et al., via GHC.Exts.Heap and System.IO.Unsafe.)
-}

module LazyPPL
    ( -- * Types
      Tree(Tree), Prob(Prob), runProb, Meas(Meas),
      -- * Basic interface
      uniform, sample, score,
      -- * Monte Carlo simulation
      weightedsamples, mh, mhirreducible, lwis, 
      -- * Helper function
      every) where

import Control.Monad.Trans.Writer
import Control.Monad.Trans.Class
import Data.Monoid
import System.Random hiding (uniform)
import Control.Monad
import Control.Monad.Extra
import Control.Monad.State.Lazy (State, state , put, get, runState)
import Numeric.Log


-- | A 'Tree' is a lazy, infinitely wide and infinitely deep rose tree, labelled by Doubles
-- | Our source of randomness will be a Tree, populated by uniform [0,1] choices for each label.
-- | Often people would just use a list or stream instead of a tree.
-- | But a tree allows us to be lazy about how far we are going all the time.
data Tree = Tree Double [Tree]

-- | A probability distribution over a is 
-- | a function 'Tree -> a'
-- | The idea is that it uses up bits of the tree as it runs
newtype Prob a = Prob (Tree -> a)

-- | Split tree splits a tree in two (bijectively)
splitTree :: Tree -> (Tree , Tree)
splitTree (Tree r (t : ts)) = (t , Tree r ts)


-- | Probabilities form a monad.
-- | Sequencing is done by splitting the tree
-- | and using different bits for different computations.
instance Monad Prob where
  return a = Prob $ const a
  (Prob m) >>= f = Prob $ \g ->
    let (g1, g2) = splitTree g
        (Prob m') = f (m g1)
    in m' g2
instance Functor Prob where fmap = liftM
instance Applicative Prob where {pure = return ; (<*>) = ap}

{- | An unnormalized measure is represented by a probability distribution over pairs of a weight and a result -}
newtype Meas a = Meas (WriterT (Product (Log Double)) Prob a)
  deriving(Functor, Applicative, Monad)

-- | A uniform sample is a building block for probability distributions
uniform :: Prob Double
uniform = Prob $ \(Tree r _) -> r
-- ^ Implemented by getting the label at the head of the tree and discard the rest

-- | The first way of building an unnormalized measure is sampling from a probability measure. 
sample :: Prob a -> Meas a
sample p = Meas $ lift p

-- | The second way of building an unnormalized measure is scoring or weighting the measure by a positive real.
score :: Double -> Meas ()
score r = Meas $ tell $ Product $ (Exp . log) (if r==0 then exp(-300) else r)
-- ^ score 0 is convenient, but to avoid numeric issues, we use exp(-300) instead.

scoreLog :: Log Double -> Meas ()
scoreLog r = Meas $ tell $ Product r

scoreProductLog :: Product (Log Double) -> Meas ()
scoreProductLog r = Meas $ tell r


{- | Preliminaries for the simulation methods. Generate a tree with uniform random labels
    This uses 'split' to split a random seed -}
randomTree :: RandomGen g => g -> Tree
randomTree g = let (a,g') = random g in Tree a (randomTrees g')
randomTrees :: RandomGen g => g -> [Tree]
randomTrees g = let (g1,g2) = split g in randomTree g1 : randomTrees g2

{- | 'runProb' runs a probability deterministically, given a source of randomness -}
runProb :: Prob a -> Tree -> a
runProb (Prob a) = a

{- | 'weightedsamples' runs an unnormalized measure and gets out a stream of (result,weight) pairs -}
weightedsamples :: forall a. Meas a -> IO [(a,Log Double)]
weightedsamples (Meas m) =
  do
    let helper :: Prob [(a, Product (Log Double))]
        helper = do
          (x, w) <- runWriterT m
          rest <- helper
          return $ (x, w) : rest
    newStdGen
    g <- getStdGen
    let rs = randomTree g
    let xws = runProb helper rs
    return $ map (\(x,w) -> (x, getProduct w)) xws

{- | Likelihood weighted importance sampling first draws n weighted samples,
    and then samples a stream of results from that regarded as an empirical distribution -}
lwis :: Int -> Meas a -> IO [a]
lwis n m = do
  xws <- weightedsamples m
  let xws' = take n $ accumulate xws 0
  let max = snd $ last xws'
  newStdGen
  g <- getStdGen
  let rs = (randoms g :: [Double])
  return $ map (\r -> fst $ head $ filter (\(x, w) -> w >= Exp (log r) * max) xws') rs
  where accumulate ((x, w) : xws) a = (x, w + a) : (x, w + a) : accumulate xws (w + a)
        accumulate [] a = []

{-- | __Metropolis-Hastings__ (MH): Produce a stream of samples, using Metropolis Hastings
    We use 'mutatetree p' to propose different distributions.
    If p = 1/dimension then this is a bit like single-site lightweight MH.
    (Wingate, Stuhlmuller, Goodman, AISTATS 2011.) 
    If p = 1 then this is like multi-site lightweight MH 

    The algorithm is as follows:

    Top level: produces a stream of samples.
    * Split the random number generator in two
    * One part is used as the first seed for the simulation,
    * and one part is used for the randomness in the MH algorithm.

    Then, run 'step' over and over to get a stream of '(tree, result, weight)'s.
    The stream of seeds is used to produce a stream of result/weight pairs.

    NB There are three kinds of randomness in the step function.
    1. The start tree 't', which is the source of randomness for simulating the
    program m to start with. This is sort-of the point in the "state space".
    2. The randomness needed to propose a new tree ('g1')
    3. The randomness needed to decide whether to accept or reject that ('g2')
    The tree t is an argument and result,
    but we use a state monad ('get'/'put') to deal with the other randomness '(g, g1, g2)'

    Steps of the 'step' function:
    1. Randomly change some sites, 
    2. Rerun the model with the new tree, to get a new weight 'w''.
    3. Compute the MH acceptance ratio. This is the probability of either returning the new seed or the old one.
    4. Accept or reject the new sample based on the MH ratio.
    
--}

mh :: forall a. Double -> Meas a -> IO [(a,Product (Log Double))]
mh p (Meas m) = do
    -- Top level: produce a stream of samples.
    -- Split the random number generator in two
    -- One part is used as the first seed for the simulation,
    -- and one part is used for the randomness in the MH algorithm.
    newStdGen
    g <- getStdGen
    let (g1,g2) = split g
    let t = randomTree g1
    let (x, w) = runProb (runWriterT m) t
    -- Now run step over and over to get a stream of (tree,result,weight)s.
    let (samples,_) = runState (iterateM step (t,x,w)) g2
    -- The stream of seeds is used to produce a stream of result/weight pairs.
    return $ map (\(_,x,w) -> (x,w)) samples
    {- NB There are three kinds of randomness in the step function.
    1. The start tree 't', which is the source of randomness for simulating the
    program m to start with. This is sort-of the point in the "state space".
    2. The randomness needed to propose a new tree ('g1')
    3. The randomness needed to decide whether to accept or reject that ('g2')
    The tree t is an argument and result,
    but we use a state monad ('get'/'put') to deal with the other randomness '(g,g1,g2)' -}
    where step :: RandomGen g => (Tree,a,Product (Log Double)) -> State g (Tree,a,Product (Log Double))
          step (t, x, w) = do
            -- Randomly change some sites
            g <- get
            let (g1, g2) = split g
            let t' = mutateTree p g1 t
            -- Rerun the model with the new tree, to get a new
            -- weight w'.
            let (x', w') = runProb (runWriterT m) t'
            -- MH acceptance ratio. This is the probability of either
            -- returning the new seed or the old one.
            let ratio = getProduct w' / getProduct w
            let (r, g2') = random g2
            put g2'
            if r < min 1 (exp $ ln ratio) -- (trace ("-- Ratio: " ++ show ratio) ratio))
              then return (t', x', w') -- trace ("---- Weight: " ++ show w') w')
              else return (t, x, w) -- trace ("---- Weight: " ++ show w) w)


-- | Replace the labels of a tree randomly, with probability p
mutateTree :: forall g. RandomGen g => Double -> g -> Tree -> Tree
mutateTree p g (Tree a ts) =
  let (a',g') = (random g :: (Double,g)) in
  let (a'',g'') = random g' in
  Tree (if a'<p then a'' else a) (mutateTrees p g'' ts)
mutateTrees :: RandomGen g => Double -> g -> [Tree] -> [Tree]
mutateTrees p g (t:ts) = let (g1,g2) = split g in mutateTree p g1 t : mutateTrees p g2 ts



{- | Irreducible form of 'mh'. Takes 'p' like 'mh', but also 'q', which is the chance of proposing an all-sites change. -}

mhirreducible :: forall a. Double -> Double -> Meas a -> IO [(a,Product (Log Double))]
mhirreducible p q (Meas m) = do
    -- Top level: produce a stream of samples.
    -- Split the random number generator in two
    -- One part is used as the first seed for the simulation,
    -- and one part is used for the randomness in the MH algorithm.
    newStdGen
    g <- getStdGen
    let (g1,g2) = split g
    let t = randomTree g1
    let (x, w) = runProb (runWriterT m) t
    -- Now run step over and over to get a stream of (tree,result,weight)s.
    let (samples,_) = runState (iterateM step (t,x,w)) g2
    -- The stream of seeds is used to produce a stream of result/weight pairs.
    return $ map (\(t,x,w) -> (x,w)) samples
    {- NB There are three kinds of randomness in the step function.
    1. The start tree 't', which is the source of randomness for simulating the
    program m to start with. This is sort-of the point in the "state space".
    2. The randomness needed to propose a new tree ('g1')
    3. The randomness needed to decide whether to accept or reject that ('g2')
    The tree t is an argument and result,
    but we use a state monad ('get'/'put') to deal with the other randomness '(g,g1,g2)' -}
    where step :: RandomGen g => (Tree,a,Product (Log Double)) -> State g (Tree,a,Product (Log Double))
          step (t,x,w) = do
            -- Randomly change some sites
            g <- get
            let (g1,g2) = split g
            -- Decide whether to resample all sites (r<q) or just some of them
            let (r,g1') = random g1
            let t' = if r<q then randomTree g1' else mutateTree p g1' t
            -- Rerun the model with the new tree, to get a new
            -- weight w'.
            let (x', w') = runProb (runWriterT m) t'
            -- MH acceptance ratio. This is the probability of either
            -- returning the new seed or the old one.
            let ratio = getProduct w' / getProduct w
            let (r,g2') = random g2
            put g2'
            if r < min 1 (exp $ ln ratio) then return (t',x',w') else return (t,x,w)



-- | Useful function which thins out a list. --
every :: Int -> [a] -> [a]
every n xs = case drop (n -1) xs of
  (y : ys) -> y : every n ys
  [] -> []

