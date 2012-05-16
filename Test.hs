-- | Tests for the 'Tournament' module.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Main where
import qualified Game.Tournament as T
import Game.Tournament (Elimination(..), GameId(..), Rules(..), Tournament(..))
import Test.QuickCheck
import Data.List ((\\), nub, genericLength)
import Data.Maybe (isJust, fromJust)
import Data.Monoid
import Control.Monad (liftM)
import Control.Monad.State (State, get, put, execState)
import Test.Framework (defaultMain, testGroup, plusTestOptions)
import Test.Framework.Options
import Test.Framework.Providers.QuickCheck2 (testProperty)

-- helper instances for positive short ints
newtype RInt = RInt {rInt :: Int} deriving (Eq, Ord, Show, Num, Integral, Real, Enum)
newtype SInt = SInt {sInt :: Int} deriving (Eq, Ord, Show, Num, Integral, Real, Enum)
newtype PInt = PInt {pInt :: Int} deriving (Eq, Ord, Show, Num, Integral, Real, Enum)
instance Arbitrary RInt where arbitrary = liftM RInt (choose (1, 256) :: Gen Int)
instance Arbitrary SInt where arbitrary = liftM SInt (choose (1, 16) :: Gen Int)
instance Arbitrary PInt where arbitrary = liftM PInt (choose (2, 8) :: Gen Int)

-- -----------------------------------------------------------------------------
-- inGroupsOf
-- test positive n <= 256, s <= 16
type GroupArgs = (RInt, SInt)

-- group sizes <= input size
groupsProp1 :: GroupArgs -> Bool
groupsProp1 (n', s') = maximum (map length (T.groups s n)) <= s where
  (n, s) = (fromIntegral n', fromIntegral s')

-- players included == [1..n]
groupsProp2 :: GroupArgs -> Bool
groupsProp2 (n', s') = length pls == n && null (pls \\ [1..n]) where
  pls = concat $ T.groups s n
  (n, s) = (fromIntegral n', fromIntegral s')

-- sum of seeds of groups in full groups differ by at most num_groups
groupsProp3 :: GroupArgs -> Property
groupsProp3 (n', s') = n `mod` s == 0 ==>
  maximum gsums <= minimum gsums + length gs where
    gs = T.groups s n
    gsums = map sum gs
    (n, s) = (fromIntegral n', fromIntegral s')

-- sum of seeds is perfect when groups are full and even sized
groupsProp4 :: GroupArgs -> Property
groupsProp4 (n', s') = n `mod` s == 0 && even s ==>
  maximum gsums == minimum gsums where
    gsums = map sum $ T.groups s n
    (n, s) = (fromIntegral n', fromIntegral s')

-- -----------------------------------------------------------------------------
-- robin
-- test positive n <= 256

-- correct number of rounds
robinProp1 :: RInt -> Bool
robinProp1 n =
  (if odd n then n else n-1) == (genericLength . T.robin) n

-- each round contains the correct number of matches
robinProp2 :: RInt -> Bool
robinProp2 n =
  all (== n `div` 2) $ map genericLength $ T.robin n

-- a player is uniquely listed in each round
robinProp3 :: RInt -> Bool
robinProp3 n = map nub plrs == plrs where
  plrs = map (concatMap (\(x,y) -> [x,y])) $ T.robin n

-- a player is playing all opponents [hence all exactly once by 3]
robinProp4 :: RInt -> Bool
robinProp4 n = all (\i -> [1..n] \\ combatants i == [i]) [1..n] where
  pairsFor k = concatMap (filter (\(x,y) -> x == k || y == k)) $ T.robin n
  combatants k = map (\(x,y) -> if x == k then y else x) $ pairsFor k

-- -----------------------------------------------------------------------------
-- seeds
-- test positive p <= 256, i <= 16
type SeedsArgs = (RInt, SInt)

-- Test using exported duelValid function.
-- All pairs generated by the function should satisfy this by construction.
seedsProps :: SeedsArgs -> Property
seedsProps (p', i') = i < 2^(p-1) ==> T.duelExpected p $ T.seeds p i
  where (p, i) = (fromIntegral p', fromIntegral i')

-- -----------------------------------------------------------------------------
-- elimination
-- test 4 <= n <= 256 <==> 2 <= p <= 8

upd :: [T.Score] -> GameId -> State Tournament ()
upd sc id = do
  t <- get
  put $ T.score id sc t
  return ()

manipDuelLeft :: [GameId] -> State Tournament ()
manipDuelLeft gs = mapM_ (upd [1,0]) $ gs

manipDuelRight :: [GameId] -> State Tournament ()
manipDuelRight gs = mapM_ (upd [0,1]) $ gs

-- When scoring all matches in order of keys -
-- i.e. WB by round inc, then LB by round inc -
-- no game waits for anything, so the results exist at end
duelScorable :: Bool -> Elimination -> PInt -> Bool
duelScorable b e p' = cond1 && cond2 where
  cond1 = isJust . T.results $ t
  cond2 = length r == 2^p
  r = fromJust . T.results $ t
  t = execState (fn (T.keys blank)) $ blank
  fn = if b then manipDuelLeft else manipDuelRight
  blank = T.tournament (Duel e) (2^p)
  p = fromIntegral p'

-- Similar to above, but start out with 2^p + 1 players to check WOs
duelWoScorable :: Bool -> Elimination -> PInt -> Bool
duelWoScorable b e p' = cond1 && cond2 where
  cond1 = isJust . T.results $ t
  cond2 = length r == np
  r = fromJust . T.results $ t
  t = execState (fn (T.keys blank)) $ blank
  fn = if b then manipDuelLeft else manipDuelRight
  blank = T.tournament (Duel e) np
  np = 2^(p-1) + 1  -- but we still only have one more player than 2^p'
  p = 1 + fromIntegral p' -- ensuring power is round up

-- -----------------------------------------------------------------------------
-- Test harness

defOpts = mempty :: TestOptions

durableOpts = defOpts {
  topt_maximum_unsuitable_generated_tests = Just 10000
}

shortOpts = defOpts {
  topt_maximum_generated_tests = Just 5
}

tests = [
    testGroup "seeds" [
      testProperty "seeds produce duelValid True pairs" seedsProps
    ]
  , testGroup "robin" [
      testProperty "robin num rounds" robinProp1
    , testProperty "robin num matches" robinProp2
    , testProperty "robin unique round players" robinProp3
    , testProperty "robin all plaid all" robinProp4
    ]
  , plusTestOptions durableOpts $ testGroup "groups" [
      testProperty "group sizes all <= input s" groupsProp1
    , testProperty "group includes all [1..n]" groupsProp2
    , testProperty "group sum of seeds max diff" groupsProp3
    , testProperty "group sum of seeds min diff" groupsProp4
    ]
  , plusTestOptions shortOpts $ testGroup "duel elimination scorable" [
      testProperty "Duel Single left" (duelScorable True Single)
    , testProperty "Duel Single right" (duelScorable False Single)
    , testProperty "Duel Double left" (duelScorable True Double)
    , testProperty "Duel Double left" (duelScorable False Double)
    , testProperty "Duel Single left wo" (duelScorable True Single)
    , testProperty "Duel Single right wo" (duelScorable False Single)
    , testProperty "Duel Double left wo" (duelScorable True Double)
    , testProperty "Duel Double left wo" (duelScorable False Double)
    ]
  ]

main :: IO ()
main = defaultMain tests
