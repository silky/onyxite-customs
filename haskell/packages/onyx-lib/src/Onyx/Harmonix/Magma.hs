module Onyx.Harmonix.Magma (runMagmaMIDI, runMagma, runMagmaV1, getRBAFile, getRBAFileBS, rbaContents, withWin32Exe) where

import           Control.Monad                (forM_, replicateM)
import           Control.Monad.IO.Class       (MonadIO (liftIO))
import           Control.Monad.Trans.Resource (MonadResource)
import           Data.Binary.Get              (getWord32le)
import qualified Data.ByteString.Lazy         as BL
import           Onyx.Resources               (magmaCommonDir, magmaV1Dir,
                                               magmaV2Dir)
import           Onyx.StackTrace
import           Onyx.Util.Handle             (Readable, byteStringSimpleHandle,
                                               makeHandle)
import           Onyx.Xbox.STFS               (runGetM)
import qualified System.Directory             as Dir
import           System.FilePath              ((</>))
import           System.Info                  (os)
import qualified System.IO                    as IO
import           System.Process

withWin32Exe :: (FilePath -> [String] -> a) -> FilePath -> [String] -> a
withWin32Exe f exe args = if os == "mingw32"
  then f exe args
  else f "wine" $ exe : args

-- | modified from <https://stackoverflow.com/q/6807025>
copyDirContents :: FilePath -> FilePath -> IO ()
copyDirContents src dst = do
  Dir.createDirectoryIfMissing False dst
  xs <- Dir.listDirectory src
  forM_ xs $ \name -> do
    let srcPath = src </> name
    let dstPath = dst </> name
    isDirectory <- Dir.doesDirectoryExist srcPath
    if isDirectory
      then copyDirContents srcPath dstPath
      else Dir.copyFile srcPath dstPath

-- | Runs the MIDI export process. Note that this process will always overwrite
-- the animations and venue with autogenerated versions, which is different from
-- the normal RBA compiler (which only autogenerates them if missing).
runMagmaMIDI :: (MonadResource m) => FilePath -> FilePath -> StackTraceT m String
runMagmaMIDI proj mid = tempDir "magma" $ \tmp -> do
  wd <- liftIO Dir.getCurrentDirectory
  let proj' = wd </> proj
      mid'  = wd </> mid
  liftIO $ forM_ [magmaV2Dir, magmaCommonDir] (>>= \dir -> copyDirContents dir tmp)
  let createProc = withWin32Exe (\exe args -> (proc exe args) { cwd = Just tmp })
        (tmp </> "MagmaCompilerC3.exe") ["-export_midi", proj', mid']
  inside "running Magma v2 to export MIDI" $ stackProcess createProc

runMagma :: (MonadResource m) => FilePath -> FilePath -> StackTraceT m String
runMagma proj rba = tempDir "magma" $ \tmp -> do
  wd <- liftIO Dir.getCurrentDirectory
  let proj' = wd </> proj
      rba'  = wd </> rba
  liftIO $ forM_ [magmaV2Dir, magmaCommonDir] (>>= \dir -> copyDirContents dir tmp)
  let createProc = withWin32Exe (\exe args -> (proc exe args) { cwd = Just tmp })
        (tmp </> "MagmaCompilerC3.exe") [proj', rba']
  inside "running Magma v2" $ stackProcess createProc

runMagmaV1 :: (MonadResource m) => FilePath -> FilePath -> StackTraceT m String
runMagmaV1 proj rba = tempDir "magma-v1" $ \tmp -> do
  wd <- liftIO Dir.getCurrentDirectory
  let proj' = wd </> proj
      rba'  = wd </> rba
  liftIO $ forM_ [magmaV1Dir, magmaCommonDir] (>>= \dir -> copyDirContents dir tmp)
  let createProc = withWin32Exe (\exe args -> (proc exe args) { cwd = Just tmp })
        (tmp </> "MagmaCompiler.exe") [proj', rba']
  inside "running Magma v1" $ stackProcess createProc

getRBAFileBS :: (MonadIO m) => Int -> FilePath -> m BL.ByteString
getRBAFileBS i rba = liftIO $ IO.withBinaryFile rba IO.ReadMode $ \h -> do
  IO.hSeek h IO.AbsoluteSeek 0x08
  let read7words = BL.hGet h (7 * 4) >>= runGetM (replicateM 7 getWord32le)
  offsets <- read7words
  sizes <- read7words
  IO.hSeek h IO.AbsoluteSeek $ fromIntegral $ offsets !! i
  BL.hGet h $ fromIntegral $ sizes !! i

getRBAFile :: (MonadIO m) => Int -> FilePath -> FilePath -> m ()
getRBAFile i rba out = getRBAFileBS i rba >>= liftIO . BL.writeFile out

rbaContents :: FilePath -> [(Int, Readable)]
rbaContents rba =
  -- TODO edit these to not load the whole file in advance, but instead shrink a Handle to a specific subfile
  [ (0, makeHandle (rba <> " | songs.dta") $ getRBAFileBS 0 rba >>= byteStringSimpleHandle)
  , (1, makeHandle (rba <> " | MIDI file") $ getRBAFileBS 1 rba >>= byteStringSimpleHandle)
  , (2, makeHandle (rba <> " | MOGG file") $ getRBAFileBS 2 rba >>= byteStringSimpleHandle)
  , (3, makeHandle (rba <> " | .milo file") $ getRBAFileBS 3 rba >>= byteStringSimpleHandle)
  , (4, makeHandle (rba <> " | album art (.bmp)") $ getRBAFileBS 4 rba >>= byteStringSimpleHandle)
  , (5, makeHandle (rba <> " | unknown file 5") $ getRBAFileBS 5 rba >>= byteStringSimpleHandle)
  , (6, makeHandle (rba <> " | extra info DTA") $ getRBAFileBS 6 rba >>= byteStringSimpleHandle)
  ]
