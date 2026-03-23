module Main (main) where

import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Test.Hspec
import Test.QuickCheck

import HaSQLite.Storage.Varint (encodeVarint, decodeVarint)

main :: IO ()
main = hspec $ do
  describe "Varint" $ do
    it "round-trips arbitrary Int64 values" $
      property $ \n ->
        decodeVarint (encodeVarint n) === (n :: Int64)

    it "encodes 0 as a single zero byte" $
      encodeVarint 0 `shouldBe` BL.pack [0x00]

    it "encodes 1 as a single byte" $
      encodeVarint 1 `shouldBe` BL.pack [0x01]

    it "encodes 127 as a single byte" $
      encodeVarint 127 `shouldBe` BL.pack [0x7F]

    it "encodes 128 as two bytes" $
      encodeVarint 128 `shouldBe` BL.pack [0x81, 0x00]

    it "encodes 16383 as two bytes" $
      encodeVarint 16383 `shouldBe` BL.pack [0xFF, 0x7F]

    it "encodes 16384 as three bytes" $
      encodeVarint 16384 `shouldBe` BL.pack [0x81, 0x80, 0x00]

    it "round-trips maxBound :: Int64" $
      decodeVarint (encodeVarint maxBound) `shouldBe` (maxBound :: Int64)

    it "round-trips minBound :: Int64" $
      decodeVarint (encodeVarint minBound) `shouldBe` (minBound :: Int64)

    it "round-trips -1" $
      decodeVarint (encodeVarint (-1)) `shouldBe` (-1 :: Int64)

    it "uses at most 9 bytes" $
      property $ \n ->
        BL.length (encodeVarint (n :: Int64)) <= 9
