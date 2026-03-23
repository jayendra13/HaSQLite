-- | SQLite varint encoding/decoding.
-- Reference: https://www.sqlite.org/fileformat2.html#varint
module HaSQLite.Storage.Varint
  ( putVarint
  , getVarint
  , encodeVarint
  , decodeVarint
  ) where

import Data.Binary.Get (Get, getWord8, runGet)
import Data.Binary.Put (Put, putWord8, runPut)
import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit)
import Data.ByteString.Lazy (ByteString)
import Data.Int (Int64)
import Data.Word (Word8, Word64)

-- | Encode an Int64 as a SQLite varint into a Put monad.
--
-- SQLite varints use 1-9 bytes, big-endian, with 7 data bits per byte.
-- The high bit of each byte is a continuation flag (1 = more bytes follow).
-- The 9th byte, if needed, uses all 8 bits for data.
putVarint :: Int64 -> Put
putVarint n = mapM_ putWord8 encoded
  where
    uval = fromIntegral @Int64 @Word64 n

    encoded
      -- 9-byte case: value needs more than 56 bits.
      -- 8 bytes with 7 data bits each (top 56 bits) + 1 byte with 8 data bits (bottom 8).
      | uval > 0x00FFFFFFFFFFFFFF =
          let top56 = shiftR uval 8
              bot8  = fromIntegral @Word64 @Word8 uval
          in [ fromIntegral (shiftR top56 (7 * i) .&. 0x7F) .|. 0x80
             | i <- [7, 6 .. 0] ]
             ++ [bot8]
      -- 1-8 byte case: split into 7-bit groups with continuation bits.
      | otherwise = addCont (reverse (split7 uval))

    split7 :: Word64 -> [Word8]
    split7 val
      | val <= 0x7F = [fromIntegral val]
      | otherwise   = fromIntegral (val .&. 0x7F) : split7 (shiftR val 7)

    addCont :: [Word8] -> [Word8]
    addCont []     = []
    addCont [x]    = [x]
    addCont (x:xs) = (x .|. 0x80) : addCont xs

-- | Decode a SQLite varint from a Get monad.
getVarint :: Get Int64
getVarint = fromIntegral <$> go 0 0
  where
    go :: Int -> Word64 -> Get Word64
    go byteCount acc = do
      byte <- getWord8
      if byteCount == 8
        then pure (shiftL acc 8 .|. fromIntegral byte)
        else do
          let value = fromIntegral (byte .&. 0x7F)
              acc' = shiftL acc 7 .|. value
          if testBit byte 7
            then go (byteCount + 1) acc'
            else pure acc'

-- | Convenience: encode an Int64 to a lazy ByteString.
encodeVarint :: Int64 -> ByteString
encodeVarint = runPut . putVarint

-- | Convenience: decode an Int64 from a lazy ByteString.
decodeVarint :: ByteString -> Int64
decodeVarint = runGet getVarint
