{
-- | Generated lexer for text @.dta@ files.
{-# OPTIONS_GHC -w #-}
module Onyx.Harmonix.DTA.Scan (scan, scanEither, scanStack, Token(..), AlexPosn(..)) where

import Data.Int (Int32)
import qualified Data.Text as T
import Onyx.StackTrace (StackTraceT, fatal)
}

%wrapper "monad"

$digit = 0-9

tokens :-

-- Whitespace and line comments.
-- TODO ignore BOM!
$white+ ;
\; [^\n]* ;

-- Preprocessor commands.
\#ifdef { emit $ const IfDef }
\#else { emit $ const Else }
\#endif { emit $ const EndIf }
\#define { emit $ const Define }
\#include { emit $ const Include }
\#merge { emit $ const Merge }
\#ifndef { emit $ const IfNDef }
\#autorun { emit $ const Autorun }
\#undef { emit $ const Undef }

-- Numbers. Longest match rule means N.N is float, not int.
(\+ | \-)? $digit+ { emit $ Int . read . dropWhile (== '+') }
(\+ | \-)? $digit+ (\. $digit+)? (e \-? $digit+)? { emit $ Float . read . dropWhile (== '+') }
(\+ | \-)? \. $digit+ (e \-? $digit+)? { emit $ \s -> Float $ read $ case dropWhile (== '+') s of
  '-' : rest -> '-' : '0' : rest
  str        -> '0' : str
}

-- Variable names.
\$ (. # $white # [ \( \) \{ \} \[ \] ])+ { emit $ Var . T.pack . tail }

-- This reserved word needs to come before the general symbol rule.
"kDataUnhandled" { emit $ const Unhandled }
-- Quoted strings.
\" ([^\"] | \n)* \" { emit $ String . T.pack . readString }
-- Quoted symbols.
' ([^'] | \\')* ' { emit $ Sym . T.pack . readSym }
-- Raw symbols. Note: these can start with digits, like "3sand7s", as long as
-- they also have letters in them.
(. # $white # [ \( \) \{ \} \[ \] ])+ { emit $ Sym . T.pack }

-- Subtrees.
\( { emit $ const LParen }
\) { emit $ const RParen }
\{ { emit $ const LBrace }
\} { emit $ const RBrace }
\[ { emit $ const LBracket }
\] { emit $ const RBracket }

{

emit :: (String -> a) -> AlexInput -> Int -> Alex (Maybe (AlexPosn, a))
emit f (pn, _, _, str) len = return $ Just $ (pn, f $ take len str)

data Token s
  = Int Int32
  | Float Float
  | Var s
  | Sym s
  | Unhandled
  | IfDef
  | Else
  | EndIf
  | LParen
  | RParen
  | LBrace
  | RBrace
  | String s
  | LBracket
  | RBracket
  | Define
  | Include
  | Merge
  | IfNDef
  | Autorun
  | Undef
  deriving (Eq, Ord, Show, Read)

-- | Reads a single-quoted string, by converting it to a double-quoted one.
readSym :: String -> String
readSym = readString . go where
  go ('\'':xs) = '"' : go xs        -- string begin/end -> double-quote
  go ('"':xs) = '\\' : 'q' : go xs  -- double-quote gets encoded as \q
  go ('\\':x:xs) = '\\' : x : go xs -- any escaped char can remain escaped
  go (x:xs) = x : go xs             -- all other chars are unchanged
  go [] = []

-- | Reads the special format for double-quoted strings.
readString :: String -> String
readString = read . go where
  go ('\\' : 'q' : rest) = '\\' : '"' : go rest
  go ""                  = ""
  go (c : rest)          = c : go rest

scanAll :: Alex [(AlexPosn, Token T.Text)]
scanAll = do
  res <- alexMonadScan
  case res of
    Nothing   -> return []
    Just pair -> (pair :) <$> scanAll

scanEither :: T.Text -> Either String [(AlexPosn, Token T.Text)]
scanEither t = runAlex (T.unpack t) scanAll

scan :: T.Text -> [(AlexPosn, Token T.Text)]
scan = either error id . scanEither

scanStack :: (Monad m) => T.Text -> StackTraceT m [(AlexPosn, Token T.Text)]
scanStack = either fatal return . scanEither

alexEOF :: Alex (Maybe (AlexPosn, Token T.Text))
alexEOF = return Nothing

}
