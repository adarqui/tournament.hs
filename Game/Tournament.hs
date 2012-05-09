-- Based on the theory from http://clux.org/entries/view/2407
{-# LANGUAGE PatternGuards #-}
module Game.Tournament (
   -- * Duel helpers
     seeds             -- :: Int -> Int -> (Int, Int)
   , duelExpected      -- :: Int -> (Int, Int) -> Bool

   -- * Group helpers
   , inGroupsOf        -- :: Int -> Int -> [Group]
   , robin             -- :: Int -> [RobinRound]

   -- * Tournament helpers
   , tournament        -- :: Rules -> Size -> Tournament
   , score             -- :: MatchId -> Maybe [Score] -> Tournament -> Tournament

   , testcase
) where

import Data.Char (intToDigit, digitToInt)
import Numeric (showIntAtBase, readInt)
import Data.List (sort, sortBy, group, groupBy, genericTake)
import Data.Ord (comparing)
import Data.Function (on)
import Data.Bits (shiftL)
import Data.Maybe (fromJust, isJust, fromMaybe)
import Control.Monad.State --TODO: only what needed
import Data.Map (Map)
import qualified Data.Map.Lazy as Map
import qualified Data.Set as Set
import Control.Arrow ((&&&), (>>>), second)
import System.IO.Unsafe (unsafePerformIO) -- while developing

-- -----------------------------------------------------------------------------
-- TODO should somehow ensure 0 < i <= 2^(p-1) in the next fn

-- | Computes both the player seeds (in order) for a duel elimiation match.
-- The first argument, p, is the power of the tournament,
-- and the second, i, is the match number.
-- Well-defined for p > 0 and 0 < i <= 2^(p-1)
seeds :: Int -> Int -> (Int, Int)
seeds p i = (1 - lastSeed + 2^p, lastSeed) where
  lastSeed = let (k, r) = ((floor . logBase 2 . fromIntegral) i, i - 2^k) in
    case r of
      0 -> 2^(p-k)
      _ -> 2^(p-k-1) + nr `shiftL` (p - length bstr) where
        bstr = reverse $ showIntAtBase 2 intToDigit (i - 2*r) ""
        nr = fst $ head $ readInt 2 (`elem` "01") digitToInt bstr

-- | Check if the 3 criteria for perfect seeding holds for the current
-- power and seed pair arguments.
-- This can be used to make a measure of how good the seeding was in retrospect
duelExpected :: Integral a => a -> (a, a) -> Bool
duelExpected n (a, b) = odd a && even b && a + b == 1 + 2^n

-- -----------------------------------------------------------------------------
-- Group helpers
--type Group = [Int]

-- | Splits a numer of players into groups of as close to equal seeding sum
-- as possible. When groupsize is even and s | n, the seed sum is constant.
-- Fixes the number of groups as ceil $ n / s, but will reduce s when all groups not full.
inGroupsOf :: Int -> Int -> [[Int]]
0 `inGroupsOf` _ = []
n `inGroupsOf` s = map (sort . filter (<=n) . makeGroup) [1..ngrps] where
  ngrps = ceiling $ fromIntegral n / fromIntegral s

  -- find largest 0<gs<=s s.t. even distribution => at least one full group, i.e. gs*ngrps - n < ngrps
  gs = until ((< ngrps + n) . (*ngrps)) (subtract 1) s

  modl = ngrps*gs -- modl may be bigger than n, e.e. inGroupsOf 10 4 has a 12 model
  npairs = ngrps * (gs `div` 2)
  pairs = zip [1..npairs] [modl, modl-1..]
  leftovers = [npairs+1, npairs+2 .. modl-npairs] -- [1..modl] \\ e in pairs
  makeGroup i = leftover ++ concatMap (\(x,y) -> [x,y]) gpairs where
    gpairs = filter ((`elem` [i, i+ngrps .. i+npairs]) . fst) pairs
    leftover = take 1 . drop (i-1) $ leftovers

-- | Round robin schedules a list of n players and returns
-- a list of rounds (where a round is a list of pairs). Uses
-- http://en.wikipedia.org/wiki/Round-robin_tournament#Scheduling_algorithm
robin :: Integral a => a -> [[(a,a)]]
robin n = map (filter notDummy . toPairs) rounds where
  n' = if odd n then n+1 else n
  m = n' `div` 2 -- matches per round
  permute (x:xs@(_:_)) = x : last xs : init xs
  permute xs = xs -- not necessary, wont be called on length 1/2 lists
  rounds = genericTake (n'-1) $ iterate permute [1..n']
  notDummy (x,y) = all (<=n) [x,y]
  toPairs x =  genericTake m $ zip x (reverse x)

-- -----------------------------------------------------------------------------
-- Duel elimination

data Bracket = WB | LB deriving (Show, Eq, Ord)
data Round = R Int deriving (Show, Eq, Ord)
data Game = G Int deriving (Show, Eq, Ord)
data MatchId = MID Bracket Round Game deriving (Show, Eq, Ord)
--Note: instanceof Ord MatchId sorts by unequal Bracket, else unequal Round, else Game
gameNum :: MatchId -> Int -- convenience
gameNum (MID _ _ (G g)) = g

type Player = Int
type Score = Int
-- if scored, scored all at once - zip gives the correct association between scores and players
data Match = Match {
  players :: [Int]
, scores  :: Maybe [Score]
} deriving (Show, Eq)


type Matches = Map MatchId Match
--showTournament t = mapM_ print $ Map.toList t

-- Ordered set of winners. Ordering is descending, i.e. head is the winner.
-- NB: more wins =/> better placement (LB player may have more wins than GF winner from WB for example).
type Wins = Int
type Placement = Int
type Results = [(Player, Placement, Wins, Score)] -- last is sum of scores over Tournament
{-data Results = Results {
  player    :: Int
, placement :: Int
, won       :: Int
, sumScore  :: Int
,
} deriving (Show)-}

--type Results = [(Player, Placement)]
data Elimination = Single | Double deriving (Show, Eq, Ord)
data GroupSize = GS Int deriving (Show, Eq, Ord)
data Advancers = Adv Int deriving (Show, Eq, Ord)
data Rules = FFA GroupSize Advancers | Duel Elimination
type Size = Int

data Tournament = Tourney {
  size    :: Size
, rules   :: Rules
, matches :: Matches
, results :: Maybe Results
}

testor :: Tournament -> IO ()
testor Tourney { matches = ms, results = rs } = do
  mapM_ print $ Map.assocs ms
  if isJust rs
    then do
      print "results: (Player, Placement, Wins, ScoreSum)"
      mapM_ print $ fromJust rs
    else print "no results"

-- throws if bad tournament
-- NB: tournament does not have updated Mathces, as this is called mid score
-- uses supplied extra argument for updated matches

makeResults :: Tournament -> Matches -> Maybe Results
makeResults (Tourney {rules = Duel e, size = np}) ms
  | e == Single
  , Just wbf@(Match _ (Just _)) <- Map.lookup (MID WB (R p) (G 1)) ms -- final played
  -- bf lookup here if included!
  = Just . scorify . winner $ wbf

  | e == Double
  , Just gf1@(Match _ (Just gf1sc)) <- Map.lookup (MID LB (R (2*p-1)) (G 1)) ms -- gf1 played
  , Just gf2@(Match _ gf2sc) <- Map.lookup (MID LB (R (2*p)) (G 1)) ms  -- gf2 maybe played
  , isJust gf2sc || maximum gf1sc == head gf1sc -- gf2 played || gf1 conclusive
  = Just . scorify . winner $ if isJust gf2sc then gf2 else gf1

  | otherwise = Nothing

  where
    p = pow np

    -- maps (last bracket's) maxround to the tie-placement
    toPlacement :: Elimination -> Int -> Int
    toPlacement Double maxlbr = if metric <= 4 then metric else 2^(k+1) + 1 + oddExtra where
      metric = 2*p + 1 - maxlbr
      r = metric - 4
      k = (r+1) `div` 2
      oddExtra = if odd r then 0 else 2^k
    toPlacement Single maxr = if metric <= 1 then metric else 2^r + 1 where
      metric = p+1 - maxr
      r = metric - 1

    -- scoring function assumes winner has been calculated so all that remains is:
    -- sort by maximum (last bracket's) round number descending, possibly flipping winners
    -- TODO: portions of this could possibly be used as a rules agnostic version
    scorify :: Int -> Results
    scorify w = map result placements where
      result (pl, pos) = (pl, pos, extract wins, extract scoreSum) where
        extract = fromMaybe 0 . lookup pl

      -- all pipelines start with this. 0 should not exist, -1 => winner got further
      -- scores not Just => should not have gotten this far by guard in score fn
      properms = Map.filter (all (>0) . players) ms

      wins = map (head &&& length)
        . group . sort
        . Map.foldr ((:) . winner) [] $ properms

      scoreSum = map (fst . head &&& foldr ((+) . snd) 0)
        . groupBy ((==) `on` fst)
        . sortBy (comparing fst)
        . Map.foldr ((++) . ((players &&& fromJust . scores) >>> uncurry zip)) [] $ properms

      placements = fixFirst
        . sortBy (comparing snd)
        . map (second (toPlacement e) . (fst . head &&& foldr (max . snd) 1))
        . groupBy ((==) `on` fst)
        . sortBy (comparing fst)
        . Map.foldrWithKey rfold [] $ properms

      rfold (MID br (R r) _) m acc =
        if (e == Single && br == WB) || (e == Double && br == LB)
          then (++ acc) . map (id &&& const r) $ players m
          else acc

      -- reorder start and make sure 2nd element has second place, as toPlacement cant distinguish
      fixFirst (x@(a,_):y@(b,_):rs) = if a == w then x : (b,2) : rs else y : (a,2) : rs
      fixFirst _ = error "<2 players in Match sent to flipFirst"
      -- TODO: if bronzeFinal then need to flip 3 and 4 possibly as well
      --fixForth (x:y:c:d:ls)

makeResults (Tourney {rules = FFA (GS _) (Adv _), size = _}) ms
  | (_, f@(Match _ (Just _))) <- Map.findMax ms
  = Just scorify

  | otherwise = Nothing
  where
    scorify :: Results
    scorify = [(0,0,0,0)]

-- helpers

-- these are rules agnostic
-- TODO: maybe export this?, should do for FFA
getScores :: Match -> [Int]
getScores (Match pls mscrs)
  | Just scrs <- mscrs = map fst . reverse . sortBy (comparing snd) . zip pls $ scrs
  | otherwise = replicate (length pls) 0

-- these can be exported
winner, loser :: Match -> Int
winner = head . getScores
loser = last . getScores

-- duel specific maybe exportable
-- TODO: export under better name
-- computes number of WB rounds from size myTournament
-- double this number to get maximum number of lb rounds (final 2 irregular)
pow :: Int -> Int
pow = ceiling . logBase 2 . fromIntegral

woScores :: [Int] -> Maybe [Int]
woScores ps
  | 0 `notElem` ps && -1 `elem` ps = Just $ map (\x -> if x == -1 then 0 else 1) ps
  | otherwise = Nothing


-- | Create match shells for an FFA elimination tournament.
-- Result comes pre-filled in with either top advancers or advancers `intersect` seedList.
-- This means what the player numbers represent is only fixed per round.
-- TODO: Either String Tournament as return for intelligent error handling
tournament :: Rules -> Size -> Tournament
tournament rs@(FFA (GS gs) (Adv adv)) np
  -- Enforce >2 players, >2 players per match, and >1 group needed.
  -- Not technically limiting, but: gs 2 <=> duel and 1 group <=> best of one.
  | np <= 2 = error "Need >2 players for an FFA elimination"
  | gs <= 2 = error "Need >2 players per match for an FFA elimination"
  | np <= gs = error "Need >1 group for an FFA elimination"
  | adv >= gs = error "Need to eliminate at least one player a match in FFA elimination"
  | adv <= 0 = error "Need >0 players to advance per match in a FFA elimination"
  | otherwise =
    --TODO: allow crossover matches when there are gaps intelligently..
    let minsize = minimum . map length
    --TODO: crossover matches?

        nextGroup g = leftover `inGroupsOf` gs where
          -- force zero non-eliminating matches unless only 1 left
          advm = max 1 $ adv - (gs - minsize g)
          leftover = length g * advm

        grps = takeWhile ((>1) . length) . iterate nextGroup $ np `inGroupsOf` gs
        final = nextGroup $ last grps

        -- finally convert raw group lists to matches
        makeRound grp r = zipWith makeMatch grp [1..] where
          makeMatch g i = (MID WB (R r) (G i), Match g Nothing)

        ms = Map.fromList $ concat $ zipWith makeRound (final : grps) [1..]
    in Tourney { size = np, rules = rs, matches = ms, results = Nothing }


-- | Create match shells for an elimination tournament
-- hangles walkovers and leaves the tournament in a stable initial state
tournament rs@(Duel e) np
  -- Enforce minimum 4 players for a tournament. It is possible to extend to 2 and 3, but:
  -- 3p uses a 4p model with one WO => == RRobin in Double, == Unfair in Single
  -- 2p Single == 1 best of 1 match, 2p Double == 1 best of 3 match
  -- and grand final rules fail when LB final is R1 (p=1) as GF is then 2*p-1 == 1 ↯
  | np < 4 = error "Need >=4 competitors for an elimination tournament"
  | otherwise = Tourney { size = np, rules = rs, matches = ms, results = Nothing } where
    p = pow np

    -- complete WBR1 by filling in -1 as WO markers for missing (np'-np) players
    markWO (x, y) = map (\a -> if a <= np then a else -1) [x,y]
    makeWbR1 i = (l, Match pl (woScores pl)) where
      l = MID WB (R 1) (G i)
      pl = markWO $ seeds p i

    -- make WBR2 and LBR1 shells by using the paired WBR1 results to propagate winners/WO markers
    propagateWbR1 br ((_, m1), (l2, m2)) = (l, Match pl (woScores pl)) where
      (l, pl)
        | br == WB = (MID WB (R 2) (G g), map winner [m1, m2])
        | br == LB = (MID LB (R 1) (G g), map loser [m1, m2])
      g = gameNum l2 `div` 2

    -- make LBR2 shells by using LBR1 results to propagate WO markers if 2x
    makeLbR2 (l1, m1) = (l, Match pl Nothing) where
      l = MID LB (R 2) (G (gameNum l1))
      plw = winner m1
      pl = if odd (gameNum l) then [0, plw] else [plw, 0]

    -- construct (possibly) non-empty rounds
    wbr1 = map makeWbR1 [1..2^(p-1)]
    wbr1pairs = take (2^(p-2))
      $ filter (even . gameNum . fst . snd) $ zip wbr1 (tail wbr1)
    wbr2 = map (propagateWbR1 WB) wbr1pairs
    lbr1 = map (propagateWbR1 LB) wbr1pairs
    lbr2 = map makeLbR2 lbr1

    -- construct (definitely) empty rounds
    wbRest = concatMap makeRound [3..p] where
      makeRound r = map (MID WB (R r) . G) [1..2^(p-r)]
      --bfm = MID LB (R 1) (G 1) -- bronze final here, exception

    lbRest = map gfms [2*p-1, 2*p] ++ concatMap makeRound [3..2*p-2] where
      makeRound r = map (MID LB (R r) . G) [1..(2^) $ p - 1 - (r+1) `div` 2]
      gfms r = MID LB (R r) (G 1)

    toMap = Map.fromSet (const (Match [0,0] Nothing)) . Set.fromList

    -- finally, union the mappified brackets
    wb = Map.union (toMap wbRest) $ Map.fromList $ wbr1 ++ wbr2
    lb = Map.union (toMap lbRest) $ Map.fromList $ lbr1 ++ lbr2
    ms = if e == Single then wb else wb `Map.union` lb


testcase :: IO ()
testcase = let
  upd :: MatchId -> [Score] -> State Tournament ()
  upd id sc = do
    t <- get
    put $ score id sc t
    return ()

  manipDouble :: State Tournament ()
  manipDouble = do
    --upd (MID WB (R 1) (G 1)) [1,0]
    upd (MID WB (R 1) (G 2)) [0,1]
    --upd (MID WB (R 1) (G 3)) [1,0]
    --upd (MID WB (R 1) (G 4)) [0,1]

    upd (MID WB (R 2) (G 1)) [1,0]
    upd (MID WB (R 2) (G 2)) [0,1]

    upd (MID LB (R 2) (G 1)) [1,0]
    upd (MID LB (R 3) (G 1)) [1,0]

    upd (MID WB (R 3) (G 1)) [1,0]
    upd (MID LB (R 4) (G 1)) [1,0]
    upd (MID LB (R 5) (G 1)) [0,3] -- gf1
    upd (MID LB (R 6) (G 1)) [1,2]

    return ()

  manipSingle :: State Tournament ()
  manipSingle = do
    upd (MID WB (R 1) (G 2)) [2,3]
    upd (MID WB (R 1) (G 3)) [1,2]
    upd (MID WB (R 1) (G 4)) [0,1]

    upd (MID WB (R 2) (G 1)) [1,0]
    upd (MID WB (R 2) (G 2)) [1,0]

    upd (MID WB (R 3) (G 1)) [1,0]

    return ()

  --a <- testor $ execState manipDouble $ tournament (Duel Double) 5
  in testor $ execState manipSingle $ tournament (Duel Single) 7


-- | Score a match in a tournament and propagate winners/losers.
-- TODO: make a strict version of this
-- TODO: documentation absorb the individual functions?
-- TODO: test if MID exists, subfns throw if lookup fail
score :: MatchId -> [Score] -> Tournament -> Tournament
score id sc trn@(Tourney {rules = r, size = np, matches = ms})
  | Duel e <- r
  , Just (Match pls _) <- Map.lookup id ms
  , all (>0) pls
  = let msUpd = execState (scoreDuel (pow np) e id sc pls) ms
        rsUpd = makeResults trn msUpd
    in trn { matches = msUpd, results = rsUpd }

  | FFA gs adv <- r
  , Just (Match pls _) <- Map.lookup id ms
  , any (>0) pls
  = let msUpd = execState (scoreFFA gs adv id sc pls) ms
    in trn { matches = msUpd }

  | otherwise = error "match not scorable"

scoreFFA :: GroupSize -> Advancers -> MatchId -> [Score] -> [Int] -> State Matches (Maybe Match)
scoreFFA (GS _) (Adv _) mid@(MID _ (R r) _) scrs pls = do
  -- 1. score given match
  let m = Match pls $ Just scrs
  modify $ Map.adjust (const m) mid

  -- 2. see if round is over
  currRnd <- gets $ Map.filterWithKey (\(MID _ (R ri) _) _ -> ri == r)
  if all (isJust . scores) $ Map.elems currRnd
    then return Nothing
    else return Nothing

  return $ Just m

-- | Update the scores of a duel in an elimination tournament.
-- Returns an updated tournament with the winner propagated to the next round,
-- and the loser propagated to the loser bracket if applicable.
scoreDuel :: Int -> Elimination -> MatchId -> [Score] -> [Int] -> State Matches (Maybe Match)
scoreDuel p e mid scrs pls = do
  -- 1. score given match
  let m = Match pls $ Just scrs
  modify $ Map.adjust (const m) mid

  -- 2. move winner right
  let nprog = mRight True p mid
  nres <- playerInsert nprog $ winner m

  -- 3. move loser to down if we were in winners
  let dprog = mDown p mid
  dres <- playerInsert dprog $ loser m

  -- 4. check if loser needs WO from LBR1
  let dprog2 = woCheck p dprog dres
  uncurry playerInsert $ fromMaybe (Nothing, 0) dprog2

  -- 5. check if winner needs WO from LBR2
  let nprog2 = woCheck p nprog nres
  uncurry playerInsert $ fromMaybe (Nothing, 0) nprog2

  return $ Just m

  where
    -- insert player x into list index idx of mid's players, and woScore it
    -- progress result determines location and must be passed in as fst arg
    playerInsert :: Maybe (MatchId, Int) -> Int -> State Matches (Maybe Match)
    playerInsert Nothing _ = return Nothing
    playerInsert (Just (mid, idx)) x = do
      tmap <- get
      let (updated, tupd) = Map.updateLookupWithKey updFn mid tmap
      put tupd
      return updated
        where updFn _ (Match plsi _) = Just $ Match plsm (woScores plsm) where
                plsm = if idx == 0 then [x, last plsi] else [head plsi, x]

    -- given tourney power, progress results, and insert results, of previous
    -- if it was woScored in playerInsert, produce new (progress, winner) pair
    woCheck :: Int -> Maybe (MatchId, Int) -> Maybe Match -> Maybe (Maybe (MatchId, Int), Int)
    woCheck p (Just (mid, _)) (Just mi)
      | w <- winner mi, w > 0 = Just (mRight False p mid, w)
      | otherwise = Nothing
    woCheck _ _ _ = Nothing


    -- right progress fn: winner moves right to (MatchId, Position)
    mRight :: Bool -> Int -> MatchId -> Maybe (MatchId, Int)
    mRight gf2Check p (MID br (R r) (G g))
      | r < 1 || g < 1 = error "bad MatchId"
      -- Nothing if last Match. NB: WB ends 1 round faster depending on e
      | r >= 2*p || (br == WB && (r > p || (e == Single && r == p))) = Nothing
      | br == LB  = Just (MID LB (R (r+1)) (G ghalf), pos)   -- standard LB progression
      | r == 2*p-1 && br == LB && gf2Check && maximum scrs == head scrs = Nothing
      | r == p    = Just (MID LB (R (2*p-1)) (G ghalf), 0)   -- WB winner -> GF1 path
      | otherwise = Just (MID WB (R (r+1)) (G ghalf), pos)   -- standard WB progression
        where
          ghalf = (g+1) `div` 2
          pos
            | br == WB = if odd g then 0 else 1         -- WB maintains standard alignment
            | r == 2*p-2 = 1                            -- LB final winner => bottom of GF
            | r == 2*p-1 = 0                            -- GF(1) winnner moves to the top [semantic]
            | (r == 1 && odd g) || (r > 1 && odd r) = 1 -- winner usually takes the bottom position
            | otherwise = if odd g then 0 else 1        -- normal progression only in even rounds + R1
            -- by placing winner on bottom consistently in odd rounds the bracket moves upward each new refill
            -- the GF(1) and LB final are special cases that give opposite results to the advanced rule above

    -- down progress fn : loser moves down to (MatchId, Position)
    mDown :: Int -> MatchId -> Maybe (MatchId, Int)
    mDown p (MID br (R r) (G g))
      -- | e == Single && r == p-1 = Just (MID LB (R 1) (G 1), if odd g then 0 else 1) -- bronze final
      | e == Single = Nothing
      | r == 2*p-1 = Just (MID LB (R (2*p)) (G 1), 1) -- GF(1) loser moves to the bottom
      | br == LB || r > p = Nothing
      | r == 1    = Just (MID LB (R 1) (G ghalf), pos)     -- WBR1 -> r=1 g/2 (LBR1 only gets input from WB)
      | otherwise = Just (MID LB (R ((r-1)*2)) (G g), pos) -- WBRr -> 2x as late per round in WB
        where
          ghalf = (g+1) `div` 2
          -- drop on top >R2, and <=2 for odd g to match bracket movement
          pos = if r > 2 || odd g then 0 else 1


-- | Checks if a Tournament is valid
{-
PERHAPS BETTER:
WB: always has np (rounded to nearest power) - 1 matches -- i.e. np = 2^p some p > 1
LB: always has 2*[num_wb_matches - 2^(p-1) + 1] -- i.e. minus the first round's matches but plus two finals
tournamentValid :: Tournament -> Bool
tournamentValid t =
  let (wb, lb) = partition ((== WB) . brac . locId) r
      roundRightWb k = rightSize && uniquePlayers where
        rightSize = 2^(p-k) == length $ filter ((== k) . rnd . locId) wb
        uniquePlayers =
      rountRightLb k = rightSize && uniquePlayers where
        rightSize = 2^(p - 1 - (k+1) `div` 2) == length $ filter ((== k) . rnd . locId) lb

  in all $ map roundRightWb [1..2^p]
-}
