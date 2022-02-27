{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
module LazyPPL where

import Control.Monad.Trans.Writer
import Control.Monad.Trans.Class
import Data.Monoid
import System.Random hiding (uniform)
import qualified System.Random as R
import Control.Monad
import Control.Monad.Extra
import Control.Monad.State.Lazy (State, state , put, get, runState)
import Numeric.Log

import GHC.Exts.Heap
import System.Mem
import Unsafe.Coerce
import Data.Maybe

import qualified Data.Map as M

{--
    This file defines
    * Two monads: Prob (for probabilities) and Meas (for unnormalized probabilities)
    * Two inference methods: lwis and mh
--}

-- A "Tree" is a lazy, infinitely wide and infinitely deep tree, labelled by Doubles
-- Our source of randomness will be a Tree, populated by uniform [0,1] choices for each label.
-- Often people would just use a list or stream instead of a tree.
-- But a tree allows us to be lazy about how far we are going all the time.
data Tree = Tree Double [Tree]

-- A probability distribution over a is a state transformer over trees
-- ie a function Tree -> a
-- The idea is that it uses up bits of the tree as it runs
newtype Prob a = Prob (Tree -> a)

-- Two key things to do with trees:
-- Split tree splits a tree in two (bijectively)
-- Get the label at the head of the tree and discard the rest
splitTree :: Tree -> (Tree , Tree)
splitTree (Tree r (t : ts)) = (t , Tree r ts)

uniform :: Prob Double
uniform = Prob $ \(Tree r _) -> r 


-- Probabilities for a monad.
-- Sequencing is done by splitting the tree
-- and using different bits for different computations.
instance Monad Prob where
  return a = Prob $ const a
  (Prob m) >>= f = Prob $ \g ->
                          let (g1,g2) = splitTree g
                              (Prob m') = f (m g1)
                          in m' g2
instance Functor Prob where fmap = liftM
instance Applicative Prob where {pure = return ; (<*>) = ap}

{-- An unnormalized measure is represented by a probability distribution over pairs of a weight and a result --}
newtype Meas a = Meas (WriterT (Product (Log Double)) Prob a)
  deriving(Functor, Applicative, Monad)

{-- The two key methods for Meas are sample (from a probability) and score (aka factor, weight) --}
score :: Double -> Meas ()
score r = Meas $ tell $ Product $ (Exp . log) $ (if r==0 then exp(-300) else r)

scorelog :: Double -> Meas ()
scorelog r = Meas $ tell $ Product $ Exp $ (if r==0 then exp(-300) else r)

sample :: Prob a -> Meas a
sample p = Meas $ lift p

{-- Preliminaries for the simulation methods. Generate a tree with uniform random labels
    This uses SPLIT to split a random seed --}
randomTree :: RandomGen g => g -> Tree
randomTree g = let (a,g') = random g in Tree a (randomTrees g')
randomTrees :: RandomGen g => g -> [Tree]
randomTrees g = let (g1,g2) = split g in (randomTree g1) : (randomTrees g2)

{-- Run prob runs a probability deterministically, given a source of randomness --}
runProb :: Prob a -> Tree -> a
runProb (Prob a) rs = a rs

{-- weightedsamples runs a probability measure and gets out a stream of (result,weight) pairs --}
weightedsamples :: forall a. Meas a -> IO [(a,Log Double)]
weightedsamples (Meas m) =
                    do let helper :: Prob [(a,(Product (Log Double)))]
                           helper = do
                             (x, w) <- runWriterT m
                             rest <- helper
                             return $ (x,w) : rest
                       newStdGen      
                       g <- getStdGen
                       let rs = randomTree g
                       let xws = runProb helper rs
                       return $ map (\(x,w) -> (x,getProduct w)) xws

{-- Likelihood weighted importance sampling first draws n weighted samples,
    and then samples a stream of results from that regarded as an empirical distribution --}
lwis :: Int -> Meas a -> IO [a]
lwis n m =        do xws <- weightedsamples m
                     let xws' = take n $ accumulate xws 0
                     let max = snd $ last xws'
                     newStdGen
                     g <- getStdGen
                     let rs = (randoms g :: [Double])
                     return $ map (\r -> fst $ head $ filter (\(x,w)-> w>=(Exp $ log r) * max) xws') rs
accumulate ((x,w):xws) a = (x,w+a):(accumulate xws (w+a))
accumulate [] a = []

{-- MH: Produce a stream of samples, using Metropolis Hastings
    We use (mutatetree p) to propose different distributions.
    If p = 1/dimension then this is a bit like single-site lightweight MH.
    (Wingate, Stuhlmuller, Goodman, AISTATS 2011.) 
    If p = 1 then this is like multi-site lightweight MH 
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
     return $ map (\(t,x,w) -> (x,w)) $ samples
     -- NB There are three kinds of randomness in the step function.
     -- * The start tree t, which is the source of randomness for simulating the
     --   program m to start with. This is sort-of the point in the "state space".
     -- * The randomness needed to propose a new tree (g1)
     -- * The randomness needed to decide whether to accept or reject that (g2)
     -- The tree t is an argument and result,
     -- but we use a state monad (get/put) to deal with the other randomness (g,g1,g2)
     where step :: RandomGen g => (Tree,a,Product (Log Double)) -> State g (Tree,a,Product (Log Double))
           step (t,x,w) = do
             -- Randomly change some sites
             g <- get
             let (g1,g2) = split g
             let t' = mutateTree p g1 t
             -- Rerun the model with the new tree, to get a new
             -- weight w'.
             let (x', w') = runProb (runWriterT m) t'
             -- MH acceptance ratio. This is the probability of either
             -- returning the new seed or the old one.
             let ratio = (getProduct w') / (getProduct w )
             let (r,g2') = random g2
             put g2'
             if r < (min 1 (exp $ ln $ ratio)) then return (t',x',w') else return (t,x,w)


-- Replace the labels of a tree randomly, with probability p
mutateTree :: forall g. RandomGen g => Double -> g -> Tree -> Tree
mutateTree p g (Tree a ts) = let (a',g') = (random g :: (Double,g)) in let (a'',g'') = random g' in
                                  Tree (if a'<p then a'' else a) (mutateTrees p g'' ts)
mutateTrees :: RandomGen g => Double -> g -> [Tree] -> [Tree]
mutateTrees p g (t:ts) = let (g1,g2) = split g in (mutateTree p g1 t) : (mutateTrees p g2 ts)

{-- Single-site Metropolis-Hastings --}

-- A partial tree, used for examining finite evaluated subtrees of the working infinite
-- random tree.
data PTree = PTree (Maybe Double) [Maybe PTree] deriving Show

type Site = [Int]
type Subst = M.Map Site Double

getSites :: PTree -> [Site]
getSites p = getSites' p []

getSites' :: PTree -> Site  -> [Site]
getSites' (PTree (Just v) ts) site = site : concat [ getSites' t (n:site)  | (n, Just t) <- zip [0..] ts ]
getSites' (PTree Nothing  ts) site = concat [ getSites' t (n:site) | (n, Just t) <- zip [0..] ts ]

-- getSites :: PTree -> [Site]
-- getSites p = map fst $ getSites' p ([],Nothing)

-- getSites' :: PTree -> (Site, Maybe Double)  -> [(Site, Maybe Double)]
-- getSites' (PTree (Just v) ts) (site,_) = (site, Just v) : concat [ getSites' t (n:site, Just v)  | (n, Just t) <- zip [0..] ts ]
-- getSites' (PTree Nothing  ts) (site,_) = concat [ getSites' t (n:site, Nothing) | (n, Just t) <- zip [0..] ts ]

{-
Example of `getSites` working:

pt = PTree (Just 0.1) [ Just ( PTree (Just 0.3) [ Just ( PTree Nothing [ Nothing
                                                                       , Just ( PTree (Just 0.5) [ Nothing
                                                                                                 , Just ( PTree (Just 0.2) []
                                                                                                        )
                                                                                                 ]
                                                                              )
                                                                       , Just ( PTree (Just 0.6) []
                                                                              )
                                                                       ]
                                                       )
                                                ]
                             )
                      , Nothing
                      , Just ( PTree (Just 0.4) []
                             )
                      , Just ( PTree Nothing [ Nothing
                                             , Nothing
                                             , Nothing
                                             , Just ( PTree (Just 0.8) []
                                                    )
                                             ]
                             )
                      ]

> getSites pt
[[],[0],[1,0,0],[1,1,0,0],[2,0,0],[2],[3,3]]

The sites (paths to nodes) are in reverse order.
-}

mutateNode :: Tree -> Site -> Double -> Tree
mutateNode (Tree _ ts) []     d = Tree d ts
mutateNode (Tree v ts) (n:ns) d = Tree v $ (take n ts) ++ (mutateNode (ts!!n) ns d) : (drop (n+1) ts)

mutateNodes :: Tree -> Subst -> Tree
mutateNodes tree sub = M.foldrWithKey (\k d t -> mutateNode t k d) tree sub

randomElement :: RandomGen g => g -> [a] -> (g, a)
randomElement g xs = if (length xs == 0) then error "0d sample space" else (g', xs !! n)
  where (n, g') = randomR (0, length xs - 1) g
               -- ^^^^^^^ In the old version of the `random` package that
               -- we are using, the function is called randomR. In newer
               -- versions it is called uniformR.

mh1 :: forall a. Int -> Meas a -> IO [(a, Product (Log Double))]
mh1 n (Meas m) = do
    newStdGen
    g <- getStdGen
    let (gTree,g') = split g
    let tree = randomTree gTree
    let (x0, w0) = runProb (runWriterT m) tree
    w0 `seq` return ()
    x0 `seq` return ()
    p <- trunc tree
    samples <- map (\(_,_,_,_,s) -> s) <$> iterateNM n step (gTree, g', M.empty, p, (x0, w0))
    return samples
  where step :: RandomGen g => (g, g, Subst, PTree, (a, Product (Log Double))) ->
                            IO (g, g, Subst, PTree, (a, Product (Log Double)))
        step (treeSeed, seed, sub, ptree, (x,w)) =
            do let (seed1, seed2) = split seed
               let sites = getSites ptree
               let (seed1', randSite) = (\(x,y) -> (x, reverse y)) $ randomElement seed1 sites
               let (newNode :: Double, seed1'') = random seed1'
               let (u :: Double, _) = random seed1'' -- the 'u' from Luke's notes
               let sub' = M.insert randSite newNode sub
               let t' = mutateNodes (randomTree treeSeed) sub'               
               let (x',w') = runProb (runWriterT m) t'
               w' `seq` return ()
               x' `seq` return ()
               ptree' <- trunc t'
               -- putStrLn $ show ptree
               -- putStrLn $ show ptree'
               -- putStrLn $ show randSite
               -- putStrLn "---"
               let sites' = getSites ptree'
               let alpha = (fromIntegral (length sites) / fromIntegral (length sites'))
                         * (exp $ ln $ ((getProduct w') / (getProduct w)))
               if u <= alpha
               then return (treeSeed, seed2, sub', ptree', (x',w'))
               else return (treeSeed, seed2, sub,  ptree,  (x,w))

-- Functions for truncating a tree.
getGCClosureData b = do c <- getBoxedClosureData b
                        case c of 
                          BlackholeClosure _ n -> getGCClosureData n
                          -- SelectorClosure _ n -> getGCClosureData n
                          _ -> return c

helperT :: Box -> IO PTree
helperT b = do
  c <- getGCClosureData b
  case c of
    ConstrClosure _ [n,l] [] _ _ "Tree" -> 
      do n' <- getGCClosureData n
         l' <- getGCClosureData l
         -- performGC
         case (n',l') of
           (ConstrClosure {dataArgs = [d], name = "D#"}, ConstrClosure {name = ":"}) ->
             do l'' <- helperB l
                return $ PTree (Just $ unsafeCoerce d) l'' 
           (ThunkClosure {}, ConstrClosure {name = ":"}) -> 
             do l'' <- helperB l
                return $ PTree Nothing l'' 
           (ConstrClosure {dataArgs = [d], name = "D#"}, ThunkClosure {}) ->
                return $ PTree (Just $ unsafeCoerce d) []
           (ThunkClosure {}, ThunkClosure {}) -> undefined
           (SelectorClosure {}, ThunkClosure {}) ->
             return $ PTree Nothing [] 
           (SelectorClosure {}, ConstrClosure {name = ":"}) ->
             do l'' <- helperB l
                return $ PTree Nothing l'' 
           _ -> return $ error $ "Missing case:\n" ++ show n' ++ "\n" ++ show l'
    ThunkClosure {} -> return $ PTree Nothing []

helperB :: Box -> IO [Maybe PTree]
helperB b = do
  c <- getGCClosureData b
  case c of
    ConstrClosure _ [n,l] [] _ _ ":" -> 
      do n' <- getGCClosureData n
         l' <- getGCClosureData l
         case (n',l') of
           (ConstrClosure {name = "Tree"}, ConstrClosure {name = ":"}) ->
             do n'' <- helperT n
                l'' <- helperB l
                return $ (Just n'') : l''
           (ConstrClosure {name = "Tree"}, ThunkClosure {}) ->
             do n'' <- helperT n
                return $ (Just n'') : []
           (ThunkClosure {}, ConstrClosure {name = ":"}) ->
             do l'' <- helperB l
                return $ Nothing : l''
           (ThunkClosure {}, ThunkClosure {}) ->
             return $ [] -- alternatively, Nothing : []
           _ -> return $ error $ "Missing case:\n" ++ show n' ++ "\n" ++ show l'
    ThunkClosure {} -> return []

trunc :: Tree -> IO PTree
trunc t = helperT $ asBox t

{-- Useful function which thins out a list. --}
every :: Int -> [a] -> [a]
every n xs = case drop (n-1) xs of
              (y:ys) -> y : every n ys
              [] -> []

iterateNM :: Int -> (a -> IO a) -> a -> IO [a]
iterateNM 0 f a = return []
iterateNM n f a = do a' <- f a
                     as <- iterateNM (n-1) f a'
                     return $ a : as

-- An example probability distribution.
exampleProb :: Prob Double
exampleProb = do 
             choice <- uniform
             w <- uniform
             x <- uniform
             y <- uniform
             z <- uniform
             case floor (choice * 4.0) of
               0 -> return w 
               1 -> return x  
               2 -> return y  
               3 -> return z  

