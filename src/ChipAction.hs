{-# LANGUAGE OverloadedStrings #-}

module ChipAction where

import           Control.Applicative ((<$>), (<|>))
import           Control.Monad       (mzero)
import           Data.Aeson          (FromJSON, parseJSON)
import           Data.Aeson.Types    (Parser, Value (..), (.:))
import qualified Data.HashMap.Lazy   as HM (lookup)
import qualified Data.Vector         as V (toList)

data ChipAction
    = Blind Integer
    | Allin Integer
    | Raise Integer
    | Call Integer
    | Check
    | Fold
    deriving (Eq, Show)

showStreetChipActions :: [(String, ChipAction)] -> String
showStreetChipActions = foldl (\str tuple -> str ++ showChipActionWithScreenName tuple ++ "\n") ""

showChipActionWithScreenName :: (String, ChipAction) -> String
showChipActionWithScreenName (s, action) = s ++ " " ++ showChipAction action

showChipAction :: ChipAction -> String
showChipAction (Blind 50)  = "posts the small blind of 50€"
showChipAction (Blind 100) = "posts the big blind of 100€"
showChipAction (Blind 200) = "posts the small blind of 20€"
showChipAction (Blind 40)  = "posts the big blind of 40€"
showChipAction (Allin n)   = "raises to " ++ show n ++ "€"
showChipAction (Raise n)   = "raises to " ++ show n ++ "€"
showChipAction (Call n)    = "calls " ++ show n ++ "€"
showChipAction Check       = "checks"
showChipAction Fold        = "folds"
showChipAction (Blind b)   = "ERROR: Blind " ++ show b ++ " not supported"

parseChipActions :: Maybe Value -> Parser [ChipAction]
parseChipActions (Just (Array arr)) = mapM parseJSON (V.toList arr)
parseChipActions _                  = fail "expected an array of ChipActions"

parseChipString :: String -> Integer
parseChipString "" = 0
parseChipString s =
    let amt = init (init s)
    in case last s of
           'B' -> floor $ (read amt :: Double) * 1000
           'M' -> floor (read amt :: Double)
           _   -> 1

showInt :: Int -> String
showInt = show

instance FromJSON ChipAction where
    parseJSON (Object o) =
        case HM.lookup "type" o of
            Just (String "BLIND") ->
                (Blind . parseChipString . showInt) <$> o .: "chip" <|>
                (Blind . parseChipString <$> o .: "chip")
            Just (String "RAISE") ->
                (Raise . parseChipString . showInt) <$> o .: "chip" <|>
                (Raise . parseChipString <$> o .: "chip")
            Just (String "ALLIN") ->
                (Allin . parseChipString . showInt) <$> o .: "chip" <|>
                (Allin . parseChipString <$> o .: "chip")
            Just (String "CALL") ->
                (Call . parseChipString . showInt) <$> o .: "chip" <|>
                (Call . parseChipString <$> o .: "chip")
            Just (String "CHECK") -> return Check
            Just (String "FOLD") -> return ChipAction.Fold
            _ -> mzero
    parseJSON _ = mzero

fixCalls :: [ChipAction] -> [ChipAction]
fixCalls [] = []
fixCalls [Blind 100, Call _, Call c] = [Blind 100, Check, Call (c - 100)]
fixCalls [Blind 40, Call _, Call c] = [Blind 40, Check, Call (c - 40)]
fixCalls [Blind sb, Call limp, Call c] =
    case limp - 50 of
        0 -> [Blind sb, Check, Call (c - 2 * sb)]
        d -> [Blind sb, Call d, Call (c - 2 * sb)]
fixCalls (x1:Call c:xs) =
    case x1 of
        (Blind b) ->
            case c - b of
                0 -> x1 : Check : fixCalls xs
                d -> x1 : Call d : fixCalls xs
        (Raise b) ->
            case c - b -- call difference
                  of
                0 -> x1 : Check : fixCalls xs
                d -> x1 : Call d : fixCalls xs
        (Allin b) ->
            case c - b -- call difference
                  of
                0 -> x1 : Check : fixCalls xs
                d -> x1 : Call d : fixCalls xs
        _ -> x1 : Call c : fixCalls xs
fixCalls (x1:x2) = x1 : fixCalls x2

removeExtraStartingFolds :: [(String, ChipAction)] -> [(String, ChipAction)]
removeExtraStartingFolds ((_, Fold):(p2, Fold):xs) = removeExtraStartingFolds ((p2, Fold) : xs)
removeExtraStartingFolds xs = xs

--     Blind Integer
--   | Allin Integer
--   | Raise Integer
--   | Call Integer
--   | Check
--   | Fold
-- 1 single action can be:
--  check, fold
-- last action can be:
-- call, check, fold
-- 2 actions can be:
-- post-flop:
-- raise-call, allin-call, raise-fold, allin-fold,check-check, check-fold, fold-fold (bug - when both players leave table before hand is over)
-- can't be pre-flop because 2 blinds plus fold is minimum (3) for pre-flop
-- actions can be:
-- (sb)blind-fold,
--
-- sb -> bb -> raise-> call =>0
-- sb -> bb ->  =>0
-- sb -> bb -> call -> raise -> fold
potTotal :: Maybe [(String, ChipAction)] -> Integer
potTotal Nothing  = 0
potTotal (Just c) = (potTotal_ . fmap snd) c

potTotal_ :: [ChipAction] -> Integer
potTotal_ [] = 0
potTotal_ [_] = 0
potTotal_ (Fold:_) = 0
potTotal_ [Raise r, Fold] = r
potTotal_ [Allin r, Fold] = r
potTotal_ cs =
    case reverse cs of
        (Fold:Fold:Raise r2:Raise r1:_) -> r1 + r2
        (Fold:Fold:Allin r2:Raise r1:_) -> r1 + r2
        (Fold:Fold:Raise r:_)           -> r
        (Fold:Fold:Allin r:_)           -> r
        (Fold:Fold:xs)                  -> potTotal_ (reverse xs)
        (Fold:Call c:_)                 -> c * 2 -- BUG when leaving table after calling
        (Fold:Raise r:Check:Blind b:_)  -> r + b
        (Fold:Allin r:Check:Blind b:_)  -> r + b
        (Fold:Raise r:Call _:Blind b:_) -> r + b
        (Fold:Allin r:Call _:Blind b:_) -> r + b
        (Fold:Raise r:Check:_)          -> r
        (Fold:Allin r:Check:_)          -> r
        (Fold:Raise r2:Raise r1:_)      -> r1 + r2
        (Fold:Allin r2:Raise r1:_)      -> r1 + r2
        (Fold:Blind bb:Blind sb:_)      -> sb + bb
        (Fold:Raise r:Blind bb:_)       -> r + bb
        (Fold:Allin r:Blind bb:_)       -> r + bb
        (Fold:Raise r:Call 50:_)        -> r + 100
        (Fold:Raise r:Call 20:_)        -> r + 40
        (Fold:Raise r:Call posted:_)    -> r + posted
        (Fold:Allin r:Call posted:_)    -> r + posted
        (Call _:Allin r:_)              -> r * 2
        (Call _:Raise r:_)              -> r * 2
        (Fold:_:Check:_)                -> 0
        (Fold:_:Blind b:_)              -> b * 2
        (Fold:_:Raise r:_)              -> r * 2
        (Fold:_:Allin r:_)              -> r * 2
        (Check:_:Blind b:_)             -> b * 2
        (Check:_)                       -> 0
        _                               -> 9999999 -- should never reach here
