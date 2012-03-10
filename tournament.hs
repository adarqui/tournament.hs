-----------------------------------------------------------------------------
--
-- Module      :  Tournament
-- Copyright   :  (c) clux 2012
-- License     :  GPL
--
-- Maintainer  :  clux
-- Stability   :  unstable
-- Portability :  unknown
--
-- Tournament related algorithms
--
-----------------------------------------------------------------------------
module Tournament (
   -- * Duel helpers

     seeds             -- :: Int -> Int -> (Int, Int)
   , duelValid         -- :: Int -> (Int, Int) -> Bool

   -- * Group helpers
   , inGroupsOf        -- :: Int -> Int -> [Group]
   , robin             -- :: Int -> [RobinRound]

   -- * Duel eliminationOf
   , eliminationOf     -- :: Elimination -> Int -> Tournament
   , scoreElimination  -- :: Tournament -> Match -> Tournament


   -- * TODO: what to do here?
   , main

) where

import Data.Char (intToDigit, digitToInt)
import Numeric (showIntAtBase, readInt)
import Data.List (sort, splitAt)
import Data.Bits (shiftL)




main = do
  print $ seeds 3 4
  print $ 15 `inGroupsOf` 5
  print $ 15 `inGroupsOf` 3
  print $ 16 `inGroupsOf` 4

testor t n = mapM_ print (t `eliminationOf` n)

-- -----------------------------------------------------------------------------
-- Duel Helperstestor n = mapM_ print (Single `eliminationOf` n)
-- Based on the theory from http://clux.org/entries/view/2407
-- TODO should somehow ensure 0 < i <= 2^(p-1) in the next fn

-- | Computes both the player seeds (in order) for a duel elimiation match.
-- The first argument, p, is the power of the tournament,
-- and the second, i, is the match number.
-- Well-defined for n > 0 and 0 < i <= 2^(p-1)
seeds :: Int -> Int -> (Int, Int)
seeds p i = (1 - last + 2^p, last) where
  last = let (k, r) = ((floor . logBase 2 . fromIntegral) i, i - 2^k) in
    case r of
      0 -> 2^(p-k)
      _ -> let bstr = reverse $ showIntAtBase 2 intToDigit (i - 2*r) ""
               nr = fst $ readInt 2 (`elem` "01") digitToInt bstr !! 0
           in 2^(p-k-1) + nr `shiftL` (p - length bstr)


-- | Check if the 3 criteria for perfect seeding holds for the current
-- power and seed pair arguments.
-- This can be used to make a measure of how good the seeding was in retrospect
duelValid :: Int -> (Int, Int) -> Bool
duelValid n (a, b) = odd a && even b && a + b == 1 + 2^n


-- -----------------------------------------------------------------------------
-- Group helpers
type Group = [Int]
-- | Splits a numer of players into groups of as close to equal seeding sum
-- as possible. When groupsize is even and s | n, the seed sum is constant.
inGroupsOf :: Int -> Int -> [Group]
0 `inGroupsOf` _ = []
n `inGroupsOf` s = map (sort . filter (<=n) . makeGroup) [1..ngrps] where
  ngrps = ceiling $ fromIntegral n / fromIntegral s
  s' = s - head (filter (\x -> n > ngrps*(s-1-x)) [0..]) -- reduce s if unfillable
  n' = ngrps*s' -- n if filled groups != n (10 inGroupsOf 4 uses n' = 12)
  npairs = (s' `div` 2) * ngrps
  pairs = zip [1..npairs] [n', n'-1..]
  rem = [npairs+1, npairs+2 .. n'-npairs] -- [1..n'] \\ e in pairs
  makeGroup i = leftover ++ concatMap (\(x,y) -> [x,y]) gpairs where
    gpairs = filter ((`elem` [i, i+ngrps .. i+npairs]) . fst) pairs
    leftover = take 1 $ drop (i-1) rem

type RobinRound = [(Int, Int)]
-- | Round robin schedules a list of n players and returns
-- a list of rounds (where a round is a list of pairs). Uses
-- http://en.wikipedia.org/wiki/Round-robin_tournament#Scheduling_algorithm
robin :: Int -> [RobinRound]
robin n = map (filter notDummy . toPairs) rounds where
  n' = if odd n then n+1 else n
  m = n' `div` 2 -- matches per round
  permute (x:xs) = x : (last xs) : (init xs)
  rounds = take (n'-1) $ iterate permute [1..n']
  notDummy (x,y) = all (<=n) [x,y]
  toPairs x =  take m $ zip x (reverse x)

-- -----------------------------------------------------------------------------
-- Duel elimination

data Bracket = Losers | Winners deriving (Show, Eq, Ord)

-- Location fully determines the place of a match in a tournament
data Location = Location {
  brac :: Bracket
, rnd  :: Int
, num  :: Int
} deriving (Show, Eq)

data Match = Match {
  locId   :: Location
, scores  :: Maybe [Int]
, players :: [Int]
} deriving (Show, Eq)

data Elimination = Double | Single deriving (Show, Eq, Ord)
type Tournament = [Match]

-- | Create match shells for an elimination tournament
-- hangles walkovers and leaves the tournament in a stable initial state
eliminationOf :: Elimination -> Int -> Tournament
e `eliminationOf` np
  -- Enforce >2 players for a tournament. It is possible to extend to 2, but:
  -- 2 players Single <=> a best of 1 match
  -- 2 players Double <=> a best of 3 match
  -- and grand final rules fail when LB final is R1 (p=1) as GF is then 2*p-1 == 1 ↯
  | np <= 2 = error "Need >2 competitors for an elimination tournament"

  -- else, a single/double elim with at least 2 WB rounds happening
  | otherwise =
    let p = (ceiling . logBase 2 . fromIntegral) np
        np' = 2^p

        woResults :: [Int] -> Maybe [Int] -> (Int, Int)
        woResults _ Nothing = (0,0)
        woResults (p1:p2:[]) (Just (s1:s2:[])) = if (s1 > s2) then (p1, p2) else (p2, p1)

        woWinner m = fst $ woResults (players m) (scores m)
        woLoser m = snd $ woResults (players m) (scores m)

        -- scores resulting from WO is easy to compute in a duel
        woScores (x:y:[])
          | x == -1 = Just [0, 1] -- bottom player wom
          | y == -1 = Just [1, 0] -- top player won
          | otherwise = Nothing

        -- complete WBR1 by filling in -1 as WO markers for missing (np'-np) players
        markWO (x, y) = map (\x -> if x <= np then x else -1) [x,y]
        makeWbR1 i = Match { locId = l, players = pl, scores = s } where
          l = Location { brac = Winners, rnd = 1, num = i }
          pl = markWO $ seeds p i
          s = woScores pl

        -- make WBR2 shells by using paired WBR1 results to propagate walkover winners
        makeWbR2 (r1m1, r1m2) = Match { locId = l, players = pl, scores = s } where
          l = Location { brac = Winners, rnd = 2, num = num (locId r1m2) `div` 2 }
          pl = map woWinner [r1m1, r1m2]
          s = woScores pl

        -- make LBR1 shells by using paired WBR1 results to propagate WO markers down
        makeLbR1 (r1m1, r1m2) = Match { locId = l, players = pl, scores = s } where
          l = Location { brac = Losers, rnd = 1, num = num (locId r1m2) `div` 2}
          pl = map woLoser [r1m1, r1m2]
          s = woScores pl

        -- make LBR2 shells by using LBR1 results to propagate WO markers if 2x
        makeLbR2 lbm = Match { locId = l, players = pl, scores = Nothing } where
          l = Location { brac = Losers, rnd = 2, num = num (locId lbm) }
          plw = woWinner lbm
          pl = if (odd . num . locId) lbm then [0, plw] else [plw, 0]

        -- make remaining matches empty shells
        emptyMatch l = Match { locId = l, players = [0,0], scores = Nothing}

        makeWbRound k = map makeWbMatch [1..2^(p-k)] where
          makeWbMatch i = emptyMatch $ Location { brac = Winners, rnd = k, num = i }

        makeLbRound k = map makeLbMatch [1..(2^) $ p - 1 - (k+1) `div` 2] where
          makeLbMatch i = emptyMatch $ Location { brac = Losers, rnd = k, num = i }

        -- construct matches
        wbr1 = map makeWbR1 [1..2^(p-1)]
        wbr1pairs = filter (odd . num . locId . fst) $ zip wbr1 (tail wbr1)
        wbr2 = map makeWbR2 $ take (2^(p-2)) wbr1pairs
        lbr1 = map makeLbR1 $ take (2^(p-2)) wbr1pairs
        lbr2 = map makeLbR2 lbr1
        wbRest = concatMap makeWbRound [3..p]
        lbRest = concatMap makeLbRound [3..2*p-2]

        gf1 = Location { brac = Losers, num = 1, rnd = 2*p-1 }
        gf2 = Location { brac = Losers, num = 1, rnd = 2*p }
        gfms = map emptyMatch [gf1, gf2]

        wb = wbr1 ++ wbr2 ++ wbRest
        lb = lbr1 ++ lbr2 ++ lbRest ++ gfms
    in if e == Single then wb else wb ++ lb

-- | Update an Elimination tournament by passing in a scored match
-- returns an updated tournament with the winner propagated to the next round,
-- and the loser propagated to the loser bracket if applicable.
scoreElimination :: Tournament -> Match -> Tournament
scoreElimination t m = 
  let e = if null $ filter ((== Losers) . brac . locId) t then Single else Double
      l = locId m
      mo = head $ filter ((== l) . locId) t
  in t


-- | Checks if a Tournament is valid
{-
tournamentValid :: Tournament -> Bool
tournamentValid t =
  let (wb, lb) = partition ((== Winners) . brac . locId) r
      roundRightWb k = rightSize && uniquePlayers where
        rightSize = 2^(p-k) == length $ filter ((== k) . rnd . locId) wb
        uniquePlayers = 
      rountRightLb k = rightSize && uniquePlayers where
        rightSize = 2^(p - 1 - (k+1) `div` 2) == length $ filter ((== k) . rnd . locId) lb

  in all $ map roundRightWb [1..2^p]
-}

-- | Create match shells for an FFA elimination tournament
--ffaElimination :: Int -> Int -> [Match]
ffaElimination gs adv np
  -- Enforce >2 players, >2 players per match, and >1 group needed.
  -- Not technically limiting, but: gs 2 <=> duel and 1 group <=> best of one.
  | np <= 2 = error "Need >2 players for an FFA elimination"
  | gs <= 2 = error "Need >2 players per match for an FFA elimination"
  | np <= gs = error "Need >1 group for an FFA elimination"
  | adv >= gs = error "Need to eliminate at least one player a match in FFA elimination"
  | adv <= 0 = error "Need >0 players to advance per match in a FFA elimination"
  | otherwise =
    let first = np `inGroupsOf` gs
        makeMatch r g i = Match { locId = l, players = g, scores = Nothing }
          where l = Location { brac = Winners, rnd = r, num = i }
        second = zipWith (makeMatch 1) first [1..]

        nextGroup g = left `inGroupsOf` gs where
          left = adv * length g

        final = [gs `inGroupsOf` gs]
        gps = takeWhile ((>1) . length) $ iterate nextGroup first
        allGps = gps ++ final

    in allGps
