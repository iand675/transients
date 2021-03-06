{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-type-defaults #-}
#ifdef ST_HACK
{-# OPTIONS_GHC -fno-full-laziness #-}
#endif
--------------------------------------------------------------------------------
-- |
-- Copyright   : (c) Edward Kmett 2015
-- License     : BSD-style
-- Maintainer  : Edward Kmett <ekmett@gmail.com>
-- Portability : non-portable
--
-- This module suppose a Word64-based array-mapped PATRICIA Trie.
--
-- The most significant nybble is isolated by using techniques based on
-- <https://www.fpcomplete.com/user/edwardk/revisiting-matrix-multiplication/part-4>
-- but modified to work nybble-by-nybble rather than bit-by-bit.
--
--------------------------------------------------------------------------------
module Data.Transient.WordMap
  ( WordMap
  , singleton
  , empty
  , insert
  , delete
  , lookup
  , member
  , fromList
  ) where

import Control.Applicative hiding (empty)
import Control.DeepSeq
import Control.Lens
import Control.Monad.ST hiding (runST)
import Data.Bits
import Data.Transient.Primitive.SmallArray
import Data.Foldable
import Data.Functor
import Data.Monoid
import Data.Word
import qualified GHC.Exts as Exts
import Prelude hiding (lookup, length, foldr)
import GHC.Exts
import GHC.ST

type Key = Word64
type Mask = Word16
type Offset = Int

ptrEq :: a -> a -> Bool
ptrEq x y = isTrue# (Exts.reallyUnsafePtrEquality# x y Exts.==# 1#)
{-# INLINEABLE ptrEq #-}

ptrNeq :: a -> a -> Bool
ptrNeq x y = isTrue# (Exts.reallyUnsafePtrEquality# x y Exts./=# 1#)
{-# INLINEABLE ptrNeq #-}

data WordMap v
  = Full {-# UNPACK #-} !Key {-# UNPACK #-} !Offset {-# UNPACK #-} !(SmallArray (WordMap v))
  | Node {-# UNPACK #-} !Key {-# UNPACK #-} !Offset {-# UNPACK #-} !Mask {-# UNPACK #-} !(SmallArray (WordMap v))
  | Tip  {-# UNPACK #-} !Key v
  | Nil
  deriving Show

node :: Key -> Offset -> Mask -> SmallArray (WordMap v) -> WordMap v
node k o 0xffff a = Full k o a
node k o m a      = Node k o m a
{-# INLINE node #-}

instance NFData v => NFData (WordMap v) where
  rnf (Full _ _ a)   = rnf a
  rnf (Node _ _ _ a) = rnf a
  rnf (Tip _ v) = rnf v
  rnf Nil = ()

instance Functor WordMap where
  fmap f = go where
    go (Full k o a) = Full k o (fmap go a)
    go (Node k o m a) = Node k o m (fmap go a)
    go (Tip k v) = Tip k (f v)
    go Nil = Nil
  {-# INLINEABLE fmap #-}

instance Foldable WordMap where
  foldMap f = go where
    go (Full _ _ a) = foldMap go a
    go (Node _ _ _ a) = foldMap go a
    go (Tip _ v) = f v
    go Nil = mempty
  null Nil = True
  null _ = False
  {-# INLINEABLE foldMap #-}

instance Traversable WordMap where
  traverse f = go where
    go (Full k o a) = Full k o <$> traverse go a
    go (Node k o m a) = Node k o m <$> traverse go a
    go (Tip k v) = Tip k <$> f v
    go Nil = pure Nil
  {-# INLINEABLE traverse #-}

instance AsEmpty (WordMap a) where
  _Empty = prism (const Nil) $ \s -> case s of
    Nil -> Right ()
    t -> Left t

type instance Index (WordMap a) = Word64
type instance IxValue (WordMap a) = a

instance Ixed (WordMap a) where
  ix i f m = case lookup i m of
    Just a -> f a <&> \a' -> insert i a' m
    Nothing -> pure m

instance At (WordMap a) where
  at i f m = f (lookup i m) <&> \case
    Nothing -> delete i m
    Just a -> insert i a m

-- Note: 'level 0' will return a negative shift, don't use it
level :: Key -> Int
level w = 60 - (countLeadingZeros w .&. 0x7c)
{-# INLINE level #-}

maskBit :: Key -> Offset -> Int
maskBit k o = fromIntegral (unsafeShiftR k o .&. 0xf)
{-# INLINE maskBit #-}

mask :: Key -> Offset -> Word16
mask k o = unsafeShiftL 1 (maskBit k o)
{-# INLINE mask #-}

-- offset :: Int -> Word16 -> Int
-- offset k w = popCount $ w .&. (unsafeShiftL 1 k - 1)
-- {-# INLINE offset #-}

fork :: Int -> Key -> WordMap v -> Key -> WordMap v -> WordMap v
fork o k n ok on = Node (k .&. unsafeShiftL 0xfffffffffffffff0 o) o (mask k o .|. mask ok o) $ runST $ do
  arr <- newSmallArray 2 n
  writeSmallArray arr (fromEnum (k < ok)) on
  unsafeFreezeSmallArray arr

delete :: Key -> WordMap v -> WordMap v
delete !k xs0 = go xs0 where
  go on@(Node ok n m as)
    | wd > 0xf = on
    | m .&. b == 0 = on
    | !oz <- indexSmallArray as odm
    , z <- go oz = case z of
      Nil | las == 2 -> indexSmallArray as (1-odm) -- this level has one inhabitant, remove it
          | otherwise -> Node ok n m' (deleteSmallArray odm as)
        where
          m' = m .&. complement b
          las = length as
      !z' | ptrNeq z' oz -> Node ok n m (updateSmallArray odm z' as)
          | otherwise -> on
    | otherwise = on
    where
      okk = xor ok k
      wd  = unsafeShiftR okk n
      d   = fromIntegral wd
      b   = unsafeShiftL 1 d
      odm = popCount $ m .&. (b - 1)
  go on@(Full ok n as)
    | wd > 0xf = on
    | !oz <- indexSmallArray as d
    , z <- go oz = case z of
      Nil -> Node ok n (clearBit 0xffff d) (deleteSmallArray d as)
      !z' | ptrNeq z' oz -> Full ok n (updateSmallArray d z' as)
          | otherwise -> on
    | otherwise = on
    where
      okk = xor ok k
      wd  = unsafeShiftR okk n
      d   = fromIntegral wd
  go on@(Tip ok _)
    | k == ok   = Nil
    | otherwise = on
  go Nil = Nil

insert :: Key -> v -> WordMap v -> WordMap v
insert !k v xs0 = go xs0 where
  go on@(Node ok n m as)
    | wd > 0xf = fork (level okk) k (Tip k v) ok on
    | m .&. b == 0 = node ok n (m .|. b) (insertSmallArray odm (Tip k v) as)
    | !oz <- indexSmallArray as odm
    , !z <- go oz
    , ptrNeq z oz = Node ok n m (updateSmallArray odm z as)
    | otherwise = on
    where
      okk = xor ok k
      wd  = unsafeShiftR okk n
      d   = fromIntegral wd
      b   = unsafeShiftL 1 d
      odm = popCount $ m .&. (b - 1)
  go on@(Full ok n as)
    | wd > 0xf = fork (level okk) k (Tip k v) ok on
    | !oz <- indexSmallArray as d
    , !z <- go oz
    , ptrNeq z oz = Full ok n (update16 d z as)
    | otherwise = on
    where
      okk = xor ok k
      wd  = unsafeShiftR okk n
      d   = fromIntegral wd
  go on@(Tip ok ov)
    | k /= ok    = fork (level (xor ok k)) k (Tip k v) ok on
    | ptrEq v ov = on
    | otherwise  = Tip k v
  go Nil = Tip k v
{-# INLINEABLE insert #-}

lookup :: Key -> WordMap v -> Maybe v
lookup k0 n0 = go k0 n0 where
  go !_ Nil = Nothing
  go k (Full ok o a)
    | z > 0xf = Nothing
    | otherwise = go k $ indexSmallArray a (fromIntegral z)
    where z = unsafeShiftR (xor k ok) o
  go k (Node ok o m a)
    | z > 0xf      = Nothing
    | m .&. b == 0 = Nothing
    | otherwise = go k (indexSmallArray a (popCount (m .&. (b - 1))))
    where z = unsafeShiftR (xor k ok) o
          b = unsafeShiftL 1 (fromIntegral z)
  go k (Tip ok ov)
    | k == ok   = Just ov
    | otherwise = Nothing
{-# INLINEABLE lookup #-}

member :: Key -> WordMap v -> Bool
member !k (Full ok o a)
  | z <- unsafeShiftR (xor k ok) o = z <= 0xf && member k (indexSmallArray a (fromIntegral z))
member k (Node ok o m a)
  | z <- unsafeShiftR (xor k ok) o
  = z <= 0xf && let b = unsafeShiftL 1 (fromIntegral z) in
    m .&. b /= 0 && member k (indexSmallArray a (popCount (m .&. (b - 1))))
member k (Tip ok _) = k == ok
member _ Nil = False
{-# INLINEABLE member #-}

updateSmallArray :: Int -> a -> SmallArray a -> SmallArray a
updateSmallArray !k a i = runST $ do
  let n = length i
  o <- newSmallArray n undefined
  copySmallArray o 0 i 0 n
  writeSmallArray o k a
  unsafeFreezeSmallArray o
{-# INLINEABLE updateSmallArray #-}

update16 :: Int -> a -> SmallArray a -> SmallArray a
update16 !k a i = runST $ do
  o <- clone16 i
  writeSmallArray o k a
  unsafeFreezeSmallArray o
{-# INLINEABLE update16 #-}

insertSmallArray :: Int -> a -> SmallArray a -> SmallArray a
insertSmallArray !k a i = runST $ do
  let n = length i
  o <- newSmallArray (n + 1) a
  copySmallArray  o 0 i 0 k
  copySmallArray  o (k+1) i k (n-k)
  unsafeFreezeSmallArray o
{-# INLINEABLE insertSmallArray #-}

deleteSmallArray :: Int -> SmallArray a -> SmallArray a
deleteSmallArray !k i = runST $ do
  let n = length i
  o <- newSmallArray (n - 1) undefined
  copySmallArray o 0 i 0 k
  copySmallArray o k i (k+1) (n-k-1)
  unsafeFreezeSmallArray o
{-# INLINEABLE deleteSmallArray #-}

clone16 :: SmallArray a -> ST s (SmallMutableArray s a)
clone16 i = do
  o <- newSmallArray 16 undefined
  indexSmallArrayM i 0 >>= writeSmallArray o 0
  indexSmallArrayM i 1 >>= writeSmallArray o 1
  indexSmallArrayM i 2 >>= writeSmallArray o 2
  indexSmallArrayM i 3 >>= writeSmallArray o 3
  indexSmallArrayM i 4 >>= writeSmallArray o 4
  indexSmallArrayM i 5 >>= writeSmallArray o 5
  indexSmallArrayM i 6 >>= writeSmallArray o 6
  indexSmallArrayM i 7 >>= writeSmallArray o 7
  indexSmallArrayM i 8 >>= writeSmallArray o 8
  indexSmallArrayM i 9 >>= writeSmallArray o 9
  indexSmallArrayM i 10 >>= writeSmallArray o 10
  indexSmallArrayM i 11 >>= writeSmallArray o 11
  indexSmallArrayM i 12 >>= writeSmallArray o 12
  indexSmallArrayM i 13 >>= writeSmallArray o 13
  indexSmallArrayM i 14 >>= writeSmallArray o 14
  indexSmallArrayM i 15 >>= writeSmallArray o 15
  return o
{-# INLINE clone16 #-}

-- | Build a singleton WordMap
singleton :: Key -> v -> WordMap v
singleton !k v = Tip k v
{-# INLINE singleton #-}

instance FunctorWithIndex Word64 WordMap where
  imap f (Node k n m  as) = Node k n m (fmap (imap f) as)
  imap f (Tip k v) = Tip k (f k v)
  imap _ Nil = Nil
  imap f (Full k n as) = Full k n (fmap (imap f) as)

instance FoldableWithIndex Word64 WordMap where
  ifoldMap f (Node _ _ _ as) = foldMap (ifoldMap f) as
  ifoldMap f (Tip k v) = f k v
  ifoldMap _ Nil = mempty
  ifoldMap f (Full _ _ as) = foldMap (ifoldMap f) as

instance TraversableWithIndex Word64 WordMap where
  itraverse f (Node k n m as) = Node k n m <$> traverse (itraverse f) as
  itraverse f (Tip k v) = Tip k <$> f k v
  itraverse _ Nil = pure Nil
  itraverse f (Full k n as) = Full k n <$> traverse (itraverse f) as

instance IsList (WordMap v) where
  type Item (WordMap v) = (Word64, v)

  toList = ifoldr (\i a r -> (i, a): r) []
  {-# INLINE toList #-}

  fromList xs = foldl' (\r (k,v) -> insert k v r) Nil xs
  {-# INLINE fromList #-}

  fromListN _ = fromList
  {-# INLINE fromListN #-}

empty :: WordMap a
empty = Nil
{-# INLINE empty #-}
