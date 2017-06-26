-- |
-- Module      :  Text.Megaparsec.Error
-- Copyright   :  © 2015–2017 Megaparsec contributors
-- License     :  FreeBSD
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- Parse errors. Current version of Megaparsec supports well-typed errors
-- instead of 'String'-based ones. This gives a lot of flexibility in
-- describing what exactly went wrong as well as a way to return arbitrary
-- data in case of failure.
--
-- You probably do not want to import this module because "Text.Megaparsec"
-- re-exports it anyway.

{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances  #-}

module Text.Megaparsec.Error
  ( ErrorItem (..)
  , ErrorComponent (..)
  , Dec (..)
  , ParseError (..)
  , ShowToken (..)
  , ShowErrorComponent (..)
  , parseErrorPretty
  , sourcePosStackPretty
  , parseErrorTextPretty )
where

import Control.DeepSeq
import Control.Monad.Catch
import Data.Data (Data)
import Data.Foldable (concat)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Semigroup
import Data.Set (Set)
import Data.Typeable (Typeable)
import GHC.Generics
import Prelude hiding (concat)
import Test.QuickCheck hiding (label)
import qualified Data.List.NonEmpty as NE
import qualified Data.Set           as E

import Text.Megaparsec.Pos

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif

-- | Data type that is used to represent “unexpected\/expected” items in
-- 'ParseError'. The data type is parametrized over the token type @t@.
--
-- @since 5.0.0

data ErrorItem t
  = Tokens (NonEmpty t)      -- ^ Non-empty stream of tokens
  | Label (NonEmpty Char)    -- ^ Label (cannot be empty)
  | EndOfInput               -- ^ End of input
  deriving (Show, Read, Eq, Ord, Data, Typeable, Generic)

instance NFData t => NFData (ErrorItem t)

instance Arbitrary t => Arbitrary (ErrorItem t) where
  arbitrary = oneof
    [
#if !MIN_VERSION_QuickCheck(2,9,0)
      Tokens <$> (NE.fromList . getNonEmpty <$> arbitrary)
    , Label  <$> (NE.fromList . getNonEmpty <$> arbitrary)
#else
      Tokens <$> arbitrary
    , Label  <$> arbitrary
#endif
    , return EndOfInput ]

-- | The type class defines how to represent information about various
-- exceptional situations. Data types that are used as custom data component
-- in 'ParseError' must be instances of this type class.
--
-- @since 5.0.0

class Ord e => ErrorComponent e where

  -- | Represent the message passed to 'fail' in parser monad.
  --
  -- @since 5.0.0

  representFail :: String -> e

  -- | Represent information about incorrect indentation.
  --
  -- @since 5.0.0

  representIndentation
    :: Ordering -- ^ Desired ordering between reference level and actual level
    -> Pos             -- ^ Reference indentation level
    -> Pos             -- ^ Actual indentation level
    -> e

instance ErrorComponent () where
  representFail _ = ()
  representIndentation _ _ _ = ()

-- | “Default error component”. This is our instance of 'ErrorComponent'
-- provided out-of-box.
--
-- @since 5.0.0

data Dec
  = DecFail String         -- ^ 'fail' has been used in parser monad
  | DecIndentation Ordering Pos Pos
    -- ^ Incorrect indentation error: desired ordering between reference
    -- level and actual level, reference indentation level, actual
    -- indentation level
  deriving (Show, Read, Eq, Ord, Data, Typeable)

instance NFData Dec where
  rnf (DecFail str) = rnf str
  rnf (DecIndentation ord ref act) = ord `seq` rnf ref `seq` rnf act

instance Arbitrary Dec where
  arbitrary = oneof
    [ sized (\n -> do
        k <- choose (0, n `div` 2)
        DecFail <$> vectorOf k arbitrary)
    , DecIndentation <$> arbitrary <*> arbitrary <*> arbitrary ]

instance ErrorComponent Dec where
  representFail        = DecFail
  representIndentation = DecIndentation

-- | 'ParseError' represents… parse errors. It provides the stack of source
-- positions, a set of expected and unexpected tokens as well as a set of
-- custom associated data. The data type is parametrized over the token type
-- @t@ and the custom data @e@.
--
-- Note that the stack of source positions contains current position as its
-- head, and the rest of positions allows to track full sequence of include
-- files with topmost source file at the end of the list.
--
-- 'Semigroup' (and 'Monoid') instance of the data type allows to merge
-- parse errors from different branches of parsing. When merging two
-- 'ParseError's, the longest match is preferred; if positions are the same,
-- custom data sets and collections of message items are combined.

data ParseError t e = ParseError
  { errorPos        :: NonEmpty SourcePos -- ^ Stack of source positions
  , errorUnexpected :: Set (ErrorItem t)  -- ^ Unexpected items
  , errorExpected   :: Set (ErrorItem t)  -- ^ Expected items
  , errorCustom     :: Set e              -- ^ Associated data, if any
  } deriving (Show, Read, Eq, Data, Typeable, Generic)

instance (NFData t, NFData e) => NFData (ParseError t e)

instance (Ord t, Ord e) => Semigroup (ParseError t e) where
  (<>) = mergeError
  {-# INLINE (<>) #-}

instance (Ord t, Ord e) => Monoid (ParseError t e) where
  mempty  = ParseError (initialPos "" :| []) E.empty E.empty E.empty
  mappend = (<>)
  {-# INLINE mappend #-}

instance ( Show t
         , Typeable t
         , Ord t
         , ShowToken t
         , Show e
         , Typeable e
         , ShowErrorComponent e )
  => Exception (ParseError t e) where
#if MIN_VERSION_base(4,8,0)
  displayException = parseErrorPretty
#endif

instance (Arbitrary t, Ord t, Arbitrary e, Ord e)
    => Arbitrary (ParseError t e) where
  arbitrary = ParseError
#if MIN_VERSION_QuickCheck(2,9,0)
    <$> arbitrary
#else
    <$> (NE.fromList . getNonEmpty <$> arbitrary)
#endif
#if MIN_VERSION_QuickCheck(2,8,2)
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
#else
    <*> (E.fromList <$> arbitrary)
    <*> (E.fromList <$> arbitrary)
    <*> (E.fromList <$> arbitrary)
#endif

-- | Merge two error data structures into one joining their collections of
-- message items and preferring the longest match. In other words, earlier
-- error message is discarded. This may seem counter-intuitive, but
-- 'mergeError' is only used to merge error messages of alternative branches
-- of parsing and in this case longest match should be preferred.

mergeError :: (Ord t, Ord e)
  => ParseError t e
  -> ParseError t e
  -> ParseError t e
mergeError e1@(ParseError pos1 u1 p1 x1) e2@(ParseError pos2 u2 p2 x2) =
  case pos1 `compare` pos2 of
    LT -> e2
    EQ -> ParseError pos1 (E.union u1 u2) (E.union p1 p2) (E.union x1 x2)
    GT -> e1
{-# INLINE mergeError #-}

-- | Type class 'ShowToken' includes methods that allow to pretty-print
-- single token as well as stream of tokens. This is used for rendering of
-- error messages.

class ShowToken a where

  -- | Pretty-print non-empty stream of tokens. This function is also used
  -- to print single tokens (represented as singleton lists).
  --
  -- @since 5.0.0

  showTokens :: NonEmpty a -> String

instance ShowToken Char where
  showTokens = stringPretty

-- | @stringPretty s@ returns pretty representation of string @s@. This is
-- used when printing string tokens in error messages.

stringPretty :: NonEmpty Char -> String
stringPretty (x:|[])      = charPretty x
stringPretty ('\r':|"\n") = "crlf newline"
stringPretty xs           = "\"" ++ concatMap f (NE.toList xs) ++ "\""
  where
    f ch =
      case charPretty' ch of
        Nothing -> [ch]
        Just pretty -> "<" ++ pretty ++ ">"

-- | @charPretty ch@ returns user-friendly string representation of given
-- character @ch@, suitable for using in error messages.

charPretty :: Char -> String
charPretty ' ' = "space"
charPretty ch = fromMaybe ("'" ++ [ch] ++ "'") (charPretty' ch)

-- | If the given character has a pretty representation, return that,
-- otherwise 'Nothing'. This is an internal helper.

charPretty' :: Char -> Maybe String
charPretty' '\NUL' = pure "null (control character)"
charPretty' '\SOH' = pure "start of heading (control character)"
charPretty' '\STX' = pure "start of text (control character)"
charPretty' '\ETX' = pure "end of text (control character)"
charPretty' '\EOT' = pure "end of transmission (control character)"
charPretty' '\ENQ' = pure "enquiry (control character)"
charPretty' '\ACK' = pure "acknowledge (control character)"
charPretty' '\BEL' = pure "bell (control character)"
charPretty' '\BS'  = pure "backspace"
charPretty' '\t'   = pure "tab"
charPretty' '\n'   = pure "newline"
charPretty' '\v'   = pure "vertical tab"
charPretty' '\f'   = pure "form feed (control character)"
charPretty' '\r'   = pure "carriage return"
charPretty' '\SO'  = pure "shift out (control character)"
charPretty' '\SI'  = pure "shift in (control character)"
charPretty' '\DLE' = pure "data link escape (control character)"
charPretty' '\DC1' = pure "device control one (control character)"
charPretty' '\DC2' = pure "device control two (control character)"
charPretty' '\DC3' = pure "device control three (control character)"
charPretty' '\DC4' = pure "device control four (control character)"
charPretty' '\NAK' = pure "negative acknowledge (control character)"
charPretty' '\SYN' = pure "synchronous idle (control character)"
charPretty' '\ETB' = pure "end of transmission block (control character)"
charPretty' '\CAN' = pure "cancel (control character)"
charPretty' '\EM'  = pure "end of medium (control character)"
charPretty' '\SUB' = pure "substitute (control character)"
charPretty' '\ESC' = pure "escape (control character)"
charPretty' '\FS'  = pure "file separator (control character)"
charPretty' '\GS'  = pure "group separator (control character)"
charPretty' '\RS'  = pure "record separator (control character)"
charPretty' '\US'  = pure "unit separator (control character)"
charPretty' '\DEL' = pure "delete (control character)"
charPretty' '\160' = pure "non-breaking space"
charPretty' _      = Nothing

-- | The type class defines how to print custom data component of
-- 'ParseError'.
--
-- @since 5.0.0

class Ord a => ShowErrorComponent a where

  -- | Pretty-print custom data component of 'ParseError'.

  showErrorComponent :: a -> String

instance (Ord t, ShowToken t) => ShowErrorComponent (ErrorItem t) where
  showErrorComponent (Tokens   ts) = showTokens ts
  showErrorComponent (Label label) = NE.toList label
  showErrorComponent EndOfInput    = "end of input"

instance ShowErrorComponent Dec where
  showErrorComponent (DecFail msg) = msg
  showErrorComponent (DecIndentation ord ref actual) =
    "incorrect indentation (got " ++ show (unPos actual) ++
    ", should be " ++ p ++ show (unPos ref) ++ ")"
    where p = case ord of
                LT -> "less than "
                EQ -> "equal to "
                GT -> "greater than "

-- | Pretty-print a 'ParseError'. The rendered 'String' always ends with a
-- newline.
--
-- The function is defined as:
--
-- > parseErrorPretty e =
-- >   sourcePosStackPretty (errorPos e) ++ ":\n" ++ parseErrorTextPretty e
--
-- @since 5.0.0

parseErrorPretty :: ( Ord t
                    , ShowToken t
                    , ShowErrorComponent e )
  => ParseError t e    -- ^ Parse error to render
  -> String            -- ^ Result of rendering
parseErrorPretty e =
  sourcePosStackPretty (errorPos e) ++ ":\n" ++ parseErrorTextPretty e

-- | Pretty-print a stack of source positions.
--
-- @since 5.0.0

sourcePosStackPretty :: NonEmpty SourcePos -> String
sourcePosStackPretty ms = concatMap f rest ++ sourcePosPretty pos
  where (pos :| rest') = ms
        rest           = reverse rest'
        f p = "in file included from " ++ sourcePosPretty p ++ ",\n"

-- | Transforms a list of error messages into their textual representation.

messageItemsPretty :: ShowErrorComponent a
  => String            -- ^ Prefix to prepend
  -> Set a             -- ^ Collection of messages
  -> String            -- ^ Result of rendering
messageItemsPretty prefix ts
  | E.null ts = ""
  | otherwise =
    let f = orList . NE.fromList . E.toAscList . E.map showErrorComponent
    in prefix ++ f ts ++ "\n"

-- | Print a pretty list where items are separated with commas and the word
-- “or” according to the rules of English punctuation.

orList :: NonEmpty String -> String
orList (x:|[])  = x
orList (x:|[y]) = x ++ " or " ++ y
orList xs       = intercalate ", " (NE.init xs) ++ ", or " ++ NE.last xs

-- | Pretty-print a textual part of a 'ParseError', that is, everything
-- except stack of source positions. The rendered staring always ends with a
-- new line.
--
-- @since 5.1.0

parseErrorTextPretty :: ( Ord t
                        , ShowToken t
                        , ShowErrorComponent e )
  => ParseError t e    -- ^ Parse error to render
  -> String            -- ^ Result of rendering
parseErrorTextPretty (ParseError _ us ps xs) =
  if E.null us && E.null ps && E.null xs
    then "unknown parse error\n"
    else concat
      [ messageItemsPretty "unexpected " us
      , messageItemsPretty "expecting "  ps
      , unlines (showErrorComponent <$> E.toAscList xs) ]
