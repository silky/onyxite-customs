{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}
module Onyx.GUI.Song where

import           Onyx.GUI.Core

import           Control.Monad                             (forM_, void)
import           Control.Monad.IO.Class                    (MonadIO (..),
                                                            liftIO)
import           Control.Monad.Trans.Writer                (execWriterT, tell)
import           Data.Char                                 (toLower)
import           Data.Default.Class                        (def)
import           Data.IORef                                (modifyIORef,
                                                            newIORef, readIORef)
import           Data.Maybe                                (fromMaybe, isJust)
import           Data.Monoid                               (Endo (..))
import qualified Data.Text                                 as T
import qualified Graphics.UI.FLTK.LowLevel.Fl_Enumerations as FLE
import           Graphics.UI.FLTK.LowLevel.FLTKHS          (Height (..),
                                                            Rectangle (..),
                                                            Size (..),
                                                            Width (..))
import qualified Graphics.UI.FLTK.LowLevel.FLTKHS          as FL
import           Onyx.Build                                (targetTitle)
import           Onyx.Harmonix.Ark.GH2                     (GH2InstallLocation (..))
import           Onyx.Import
import           Onyx.Mode                                 (anyDrums,
                                                            anyFiveFret)
import           Onyx.Preferences                          (Preferences (..),
                                                            readPreferences)
import           Onyx.Project
import           Onyx.StackTrace
import           System.FilePath                           (takeDirectory,
                                                            takeExtension,
                                                            (<.>))

songPageRB3
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetRB3 -> RB3Create -> IO ())
  -> IO ()
songPageRB3 sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \rb3 ->
        (rb3 :: TargetRB3) { common = rb3.common { speed = Just speed } }
      return counter
    box2x <- fullWidth 35 $ \rect' -> do
      box <- liftIO $ FL.checkButtonNew rect' (Just "2x Bass Pedal drums")
      tell $ FL.getValue box >>= \b -> return $ Endo $ \rb3 ->
        rb3 { is2xBassPedal = b }
      return box
    fullWidth 35 $ \rect' -> songIDBox rect' $ \sid rb3 ->
      rb3 { songID = sid }
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v rb3 -> (rb3 :: TargetRB3) { guitar = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.proGuitar) -- technically pro guitar can make five fret. but good to be safe
        )
      , ( "Bass"  , (.bass  ), (\v rb3 -> (rb3 :: TargetRB3) { bass   = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.proGuitar)
        )
      , ( "Keys"  , (.keys  ), (\v rb3 -> (rb3 :: TargetRB3) { keys   = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.proKeys) -- similarly pro keys can make five fret
        )
      , ( "Drums" , (.drums ), (\v rb3 -> (rb3 :: TargetRB3) { drums  = v })
        , (\p -> isJust $ anyDrums p)
        )
      , ( "Vocal" , (.vocal ), (\v rb3 -> (rb3 :: TargetRB3) { vocal  = v })
        , (\p -> isJust p.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget ?preferences >>= \rb3 -> return $ targetTitle
          (projectSongYaml proj)
          (RB3 rb3 { common = rb3.common { title = Just "" } })
        )
        (\msfx rb3 -> (rb3 :: TargetRB3)
          { common = rb3.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
      liftIO $ FL.setCallback box2x $ \_ -> controlInput
  let makeTarget newPreferences = do
        modifier <- targetModifier
        return $ modifier def
          { magma = prefMagma newPreferences
          , legalTempos = prefLegalTempos newPreferences
          , common = def
            { label2x = prefLabel2x newPreferences
            }
          }
      makeFinalTarget = readPreferences >>= stackIO . makeTarget
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Create Xbox 360 CON file"
    FL.setCallback btn1 $ \_ -> sink $ EventOnyx $ makeFinalTarget >>= \tgt -> stackIO $ do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save RB3 CON file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_rb3con" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> sink $ EventOnyx $ do
            newPreferences <- readPreferences
            stackIO $ build tgt $ RB3CON $ trimXbox newPreferences f
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS3 PKG file"
    FL.setCallback btn2 $ \_ -> sink $ EventOnyx $ makeFinalTarget >>= \tgt -> stackIO $ do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save RB3 PKG file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> ".pkg" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ RB3PKG $ if map toLower (takeExtension f) == ".pkg"
            then f
            else f <.> "pkg"
        _ -> return ()
    color <- taskColor
    FL.setColor btn1 color
    FL.setColor btn2 color
  fullWidth 35 $ \rect' -> do
    btn1 <- FL.buttonNew rect' $ Just "Create Magma project"
    FL.setCallback btn1 $ \_ -> sink $ EventOnyx $ makeFinalTarget >>= \tgt -> stackIO $ do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save Magma v2 project"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_project" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ RB3Magma f
        _ -> return ()
    color <- taskColor
    FL.setColor btn1 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPageRB2
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetRB2 -> RB2Create -> IO ())
  -> IO ()
songPageRB2 sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \rb2 ->
        (rb2 :: TargetRB2) { common = rb2.common { speed = Just speed } }
      return counter
    box2x <- fullWidth 35 $ \rect' -> do
      box <- liftIO $ FL.checkButtonNew rect' (Just "2x Bass Pedal drums")
      tell $ FL.getValue box >>= \b -> return $ Endo $ \rb2 ->
        rb2 { is2xBassPedal = b }
      return box
    fullWidth 35 $ \rect' -> songIDBox rect' $ \sid rb2 ->
      rb2 { songID = sid }
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v rb2 -> (rb2 :: TargetRB2) { guitar = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      , ( "Bass"  , (.bass  ), (\v rb2 -> (rb2 :: TargetRB2) { bass   = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      , ( "Drums" , (.drums ), (\v rb2 -> (rb2 :: TargetRB2) { drums  = v })
        , (\p -> isJust $ anyDrums p)
        )
      , ( "Vocal" , (.vocal ), (\v rb2 -> (rb2 :: TargetRB2) { vocal  = v })
        , (\p -> isJust p.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget ?preferences >>= \rb2 -> return $ targetTitle
          (projectSongYaml proj)
          (RB2 rb2 { common = rb2.common { title = Just "" } })
        )
        (\msfx rb2 -> (rb2 :: TargetRB2)
          { common = rb2.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
      liftIO $ FL.setCallback box2x $ \_ -> controlInput
  let makeTarget newPreferences = do
        modifier <- targetModifier
        return $ modifier def
          { magma = prefMagma newPreferences
          , legalTempos = prefLegalTempos newPreferences
          , common = def
            { label2x = prefLabel2x newPreferences
            }
          , ps3Encrypt = prefPS3Encrypt newPreferences
          }
      makeFinalTarget = readPreferences >>= stackIO . makeTarget

  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Create Xbox 360 CON file"
    FL.setCallback btn1 $ \_ -> sink $ EventOnyx $ makeFinalTarget >>= \tgt -> stackIO $ do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save RB2 CON file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_rb2con" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> sink $ EventOnyx $ do
            newPreferences <- readPreferences
            stackIO $ build tgt $ RB2CON $ trimXbox newPreferences f
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS3 PKG file"
    FL.setCallback btn2 $ \_ -> sink $ EventOnyx $ makeFinalTarget >>= \tgt -> stackIO $ do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save RB2 PKG file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> ".pkg" -- TODO add modifiers
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ RB2PKG $ if map toLower (takeExtension f) == ".pkg"
            then f
            else f <.> "pkg"
        _ -> return ()
    color <- taskColor
    FL.setColor btn1 color
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPageGHWOR
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetGH5 -> GHWORCreate -> IO ())
  -> IO ()
songPageGHWOR sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \gh5 ->
        (gh5 :: TargetGH5) { common = gh5.common { speed = Just speed } }
      return counter
    fullWidth 35 $ \rect' -> do
      getProTo4 <- liftIO $ horizRadio rect'
        [ ("Pro Drums to 5 lane", False, not $ prefGH4Lane ?preferences)
        , ("Pro Drums to 4 lane", True, prefGH4Lane ?preferences)
        ]
      tell $ do
        b <- getProTo4
        return $ Endo $ \gh5 -> gh5 { proTo4 = fromMaybe False b }
    fullWidth 35 $ \rect' -> numberBox rect' "Custom Song ID (dlc)" $ \sid gh5 ->
      gh5 { songID = sid }
    fullWidth 35 $ \rect' -> numberBox rect' "Custom Package ID (cdl)" $ \sid gh5 ->
      gh5 { cdl = sid }
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v gh5 -> (gh5 :: TargetGH5) { guitar = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      , ( "Bass"  , (.bass  ), (\v gh5 -> (gh5 :: TargetGH5) { bass   = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      , ( "Drums" , (.drums ), (\v gh5 -> (gh5 :: TargetGH5) { drums  = v })
        , (\p -> isJust $ anyDrums p)
        )
      , ( "Vocal" , (.vocal ), (\v gh5 -> (gh5 :: TargetGH5) { vocal  = v })
        , (\p -> isJust p.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget >>= \gh5 -> return $ targetTitle
          (projectSongYaml proj)
          (GH5 gh5 { common = gh5.common { title = Just "" } })
        )
        (\msfx gh5 -> (gh5 :: TargetGH5)
          { common = gh5.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
  let initTarget = def
      makeTarget = fmap ($ initTarget) targetModifier
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Create Xbox 360 LIVE file"
    FL.setCallback btn1 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save GH:WoR LIVE file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_ghwor" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> sink $ EventOnyx $ do
            newPreferences <- readPreferences
            stackIO $ warnXboxGHWoR sink $ stackIO $ build tgt $ GHWORLIVE $ trimXbox newPreferences f
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS3 PKG file"
    FL.setCallback btn2 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save GH:WoR PKG file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> ".pkg" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> warnXboxGHWoR sink $ stackIO $ build tgt $ GHWORPKG f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn1 color
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPagePS
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetPS -> PSCreate -> IO ())
  -> IO ()
songPagePS sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \ps ->
        (ps :: TargetPS) { common = ps.common { speed = Just speed } }
      return counter
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar"     , (.guitar    ), (\v ps -> (ps :: TargetPS) { guitar     = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.ghl || isJust p.proGuitar) -- pro guitar redundant since it can make five fret
        )
      , ( "Bass"       , (.bass      ), (\v ps -> (ps :: TargetPS) { bass       = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.ghl || isJust p.proGuitar)
        )
      , ( "Keys"       , (.keys      ), (\v ps -> (ps :: TargetPS) { keys       = v })
        , (\p -> isJust (anyFiveFret p) || isJust p.proKeys) -- pro keys redundant since it can make five fret
        )
      , ( "Drums"      , (.drums     ), (\v ps -> (ps :: TargetPS) { drums      = v })
        , (\p -> isJust $ anyDrums p)
        )
      , ( "Vocal"      , (.vocal     ), (\v ps -> (ps :: TargetPS) { vocal      = v })
        , (\p -> isJust p.vocal)
        )
      , ( "Rhythm"     , (.rhythm    ), (\v ps -> (ps :: TargetPS) { rhythm     = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      , ( "Guitar Coop", (.guitarCoop), (\v ps -> (ps :: TargetPS) { guitarCoop = v })
        , (\p -> isJust $ anyFiveFret p)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget >>= \ps -> return $ targetTitle
          (projectSongYaml proj)
          (PS ps { common = ps.common { title = Just "" } })
        )
        (\msfx ps -> (ps :: TargetPS)
          { common = ps.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
  let makeTarget = fmap ($ def) targetModifier
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Create CH/PS song folder"
    FL.setCallback btn1 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save CH/PS song folder"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_chps" -- TODO add modifiers
      forM_ (prefDirCH ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ PSDir f
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create CH/PS zip file"
    FL.setCallback btn2 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save CH/PS zip file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_chps.zip" -- TODO add modifiers
      forM_ (prefDirCH ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ PSZip f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn1 color
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPageGH3
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetGH3 -> GH3Create -> IO ())
  -> IO ()
songPageGH3 sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \gh3 ->
        (gh3 :: TargetGH3) { common = gh3.common { speed = Just speed } }
      return counter
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v gh3 -> (gh3 :: TargetGH3) { guitar = v })
        , isJust . anyFiveFret
        )
      ]
    fullWidth 50 $ \rect' -> do
      let [bassArea, coopArea, rhythmArea] = splitHorizN 3 rect'
      void $ partSelectors bassArea proj
        [ ( "Bass"  , (.bass  ), (\v gh3 -> (gh3 :: TargetGH3) { bass   = v })
          , isJust . anyFiveFret
          )
        ]
      controlRhythm <- partSelectors rhythmArea proj
        [ ( "Rhythm", (.rhythm), (\v gh3 -> (gh3 :: TargetGH3) { rhythm = v })
          , isJust . anyFiveFret
          )
        ]
      coopPart <- liftIO $ newIORef GH2Bass
      liftIO $ do
        coopButton <- FL.buttonNew coopArea Nothing
        let updateCoopButton = do
              coop <- readIORef coopPart
              FL.setLabel coopButton $ case coop of
                GH2Bass   -> "Coop: Bass"
                GH2Rhythm -> "Coop: Rhythm"
              controlRhythm $ coop == GH2Rhythm
        updateCoopButton
        FL.setCallback coopButton $ \_ -> sink $ EventIO $ do
          modifyIORef coopPart $ \case
            GH2Bass   -> GH2Rhythm
            GH2Rhythm -> GH2Bass
          updateCoopButton
      tell $ readIORef coopPart >>= \coop -> return $ Endo $ \gh3 -> gh3 { coop = coop }
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Keys" , (.keys ), (\v gh3 -> (gh3 :: TargetGH3) { keys  = v })
        , isJust . anyFiveFret
        )
      , ( "Drums", (.drums), (\v gh3 -> (gh3 :: TargetGH3) { drums = v })
        , isJust . (.drums)
        )
      , ( "Vocal", (.vocal), (\v gh3 -> (gh3 :: TargetGH3) { vocal = v })
        , isJust . (.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget >>= \gh3 -> return $ targetTitle
          (projectSongYaml proj)
          (GH3 gh3 { common = gh3.common { title = Just "" } })
        )
        (\msfx gh3 -> (gh3 :: TargetGH3)
          { common = gh3.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
  let initTarget = def :: TargetGH3
      makeTarget = fmap ($ initTarget) targetModifier
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Create Xbox 360 LIVE file"
    FL.setCallback btn1 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save GH3 LIVE file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_gh3live" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> sink $ EventOnyx $ do
            newPreferences <- readPreferences
            stackIO $ build tgt $ GH3LIVE $ trimXbox newPreferences f
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS3 PKG file"
    FL.setCallback btn2 $ \_ -> do
      tgt <- makeTarget
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save GH3 PKG file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> ".pkg" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ GH3PKG f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn1 color
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPageGH1
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetGH1 -> GH1Create -> IO ())
  -> IO ()
songPageGH1 sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \gh1 ->
        (gh1 :: TargetGH1) { common = gh1.common { speed = Just speed } }
      return counter
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v gh1 -> (gh1 :: TargetGH1) { guitar = v })
        , isJust . anyFiveFret
        )
      ]
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Bass" , (.bass ), (\v gh1 -> (gh1 :: TargetGH1) { bass  = v })
        , isJust . anyFiveFret
        )
      , ( "Keys" , (.keys ), (\v gh1 -> (gh1 :: TargetGH1) { keys  = v })
        , isJust . anyFiveFret
        )
      , ( "Drums", (.drums), (\v gh1 -> (gh1 :: TargetGH1) { drums = v })
        , isJust . (.drums)
        )
      , ( "Vocal", (.vocal), (\v gh1 -> (gh1 :: TargetGH1) { vocal = v })
        , isJust . (.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget >>= \gh1 -> return $ targetTitle
          (projectSongYaml proj)
          (GH1 gh1 { common = gh1.common { title = Just "" } })
        )
        (\msfx gh1 -> (gh1 :: TargetGH1)
          { common = gh1.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
  let initTarget prefs = (def :: TargetGH1)
        { offset = prefGH2Offset prefs
        , loadingPhrase = loadingPhraseCHtoGH2 proj
        }
      makeTarget = fmap ($ initTarget ?preferences) targetModifier
      -- make sure we reload offset before compiling
      makeTargetUpdatePrefs go = targetModifier >>= \modifier -> sink $ EventOnyx $ do
        newPrefs <- readPreferences
        stackIO $ go $ modifier $ initTarget newPrefs
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Add to PS2 ARK as Bonus Song"
    FL.setCallback btn1 $ \_ -> makeTargetUpdatePrefs $ \tgt -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseFile
      FL.setTitle picker "Select .HDR file"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> let
            gen = takeDirectory f
            in build tgt $ GH1ARK gen
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS2 DIY folder"
    FL.setCallback btn2 $ \_ -> makeTargetUpdatePrefs $ \tgt -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Create DIY folder"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_gh1"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ GH1DIYPS2 f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn1 color
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

songPageGH2
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> Project
  -> (TargetGH2 -> GH2Create -> IO ())
  -> IO ()
songPageGH2 sink rect tab proj build = mdo
  pack <- FL.packNew rect Nothing
  let fullWidth h = padded 5 10 5 10 (Size (Width 800) (Height h))
  targetModifier <- fmap (fmap appEndo) $ execWriterT $ do
    counterSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> do
      let centerRect = trimClock 0 250 0 250 rect'
      (getSpeed, counter) <- liftIO $
        centerFixed rect' $ speedPercent' True centerRect
      tell $ getSpeed >>= \speed -> return $ Endo $ \gh2 ->
        (gh2 :: TargetGH2) { common = gh2.common { speed = Just speed } }
      return counter
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Guitar", (.guitar), (\v gh2 -> (gh2 :: TargetGH2) { guitar = v })
        , isJust . anyFiveFret
        )
      ]
    fullWidth 50 $ \rect' -> do
      let [bassArea, coopArea, rhythmArea] = splitHorizN 3 rect'
      void $ partSelectors bassArea proj
        [ ( "Bass"  , (.bass  ), (\v gh2 -> (gh2 :: TargetGH2) { bass = v })
          , isJust . anyFiveFret
          )
        ]
      controlRhythm <- partSelectors rhythmArea proj
        [ ( "Rhythm", (.rhythm), (\v gh2 -> (gh2 :: TargetGH2) { rhythm = v })
          , isJust . anyFiveFret
          )
        ]
      coopPart <- liftIO $ newIORef GH2Bass
      liftIO $ do
        coopButton <- FL.buttonNew coopArea Nothing
        let updateCoopButton = do
              coop <- readIORef coopPart
              FL.setLabel coopButton $ case coop of
                GH2Bass   -> "Coop: Bass"
                GH2Rhythm -> "Coop: Rhythm"
              controlRhythm $ coop == GH2Rhythm
        updateCoopButton
        FL.setCallback coopButton $ \_ -> sink $ EventIO $ do
          modifyIORef coopPart $ \case
            GH2Bass   -> GH2Rhythm
            GH2Rhythm -> GH2Bass
          updateCoopButton
      tell $ readIORef coopPart >>= \coop -> return $ Endo $ \gh2 -> gh2 { coop = coop }
    fullWidth 50 $ \rect' -> void $ partSelectors rect' proj
      [ ( "Keys" , (.keys ), (\v gh2 -> (gh2 :: TargetGH2) { keys  = v })
        , isJust . anyFiveFret
        )
      , ( "Drums", (.drums), (\v gh2 -> (gh2 :: TargetGH2) { drums = v })
        , isJust . anyDrums
        )
      , ( "Vocal", (.vocal), (\v gh2 -> (gh2 :: TargetGH2) { vocal = v })
        , isJust . (.vocal)
        )
      ]
    fullWidth 35 $ \rect' -> do
      controlInput <- customTitleSuffix sink rect'
        (makeTarget >>= \gh2 -> return $ targetTitle
          (projectSongYaml proj)
          (GH2 gh2 { common = gh2.common { title = Just "" } })
        )
        (\msfx gh2 -> (gh2 :: TargetGH2)
          { common = gh2.common
            { label_ = msfx
            }
          }
        )
      liftIO $ FL.setCallback counterSpeed $ \_ -> controlInput
    fullWidth 35 $ \rect' -> do
      let [rectA, rectB] = splitHorizN 2 rect'
      boxA <- liftIO $ FL.checkButtonNew rectA (Just "Make practice mode audio for PS2")
      tell $ FL.getValue boxA >>= \b -> return $ Endo $ \gh2 ->
        gh2 { practiceAudio = b }
      getDeluxe <- liftIO $ gh2DeluxeSelector sink rectB
      tell $ getDeluxe >>= \opt -> return $ Endo $ \gh2 -> case opt of
        Nothing   -> gh2 { gh2Deluxe = False, is2xBassPedal = False }
        Just is2x -> gh2 { gh2Deluxe = True , is2xBassPedal = is2x  }
  let initTarget prefs = (def :: TargetGH2)
        { offset = prefGH2Offset prefs
        , loadingPhrase = loadingPhraseCHtoGH2 proj
        }
      makeTarget = fmap ($ initTarget ?preferences) targetModifier
      -- make sure we reload offset before compiling
      makeTargetUpdatePrefs go = targetModifier >>= \modifier -> sink $ EventOnyx $ do
        newPrefs <- readPreferences
        stackIO $ go $ modifier $ initTarget newPrefs
  fullWidth 35 $ \rect' -> do
    let [trimClock 0 5 0 0 -> r1, trimClock 0 0 0 5 -> r2] = splitHorizN 2 rect'
    btn1 <- FL.buttonNew r1 $ Just "Add to PS2 ARK as Bonus Song"
    FL.setCallback btn1 $ \_ -> makeTargetUpdatePrefs $ \tgt -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseFile
      FL.setTitle picker "Select .HDR file"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> let
            gen = takeDirectory f
            in build tgt $ GH2ARK gen GH2AddBonus
        _ -> return ()
    btn2 <- FL.buttonNew r2 $ Just "Create PS2 DIY folder"
    FL.setCallback btn2 $ \_ -> makeTargetUpdatePrefs $ \tgt -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Create DIY folder"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_gh2"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> build tgt $ GH2DIYPS2 f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn1 color
    FL.setColor btn2 color
  fullWidth 35 $ \rect' -> do
    btn2 <- FL.buttonNew rect' $ Just "Create Xbox 360 LIVE file"
    FL.setCallback btn2 $ \_ -> makeTargetUpdatePrefs $ \tgt -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseSaveFile
      FL.setTitle picker "Save GH2 LIVE file"
      FL.setPresetFile picker $ T.pack $ projectTemplate proj <> "_gh2live" -- TODO add modifiers
      forM_ (prefDirRB ?preferences) $ FL.setDirectory picker . T.pack
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> sink $ EventOnyx $ do
            newPreferences <- readPreferences
            stackIO $ warnCombineXboxGH2 sink $ build tgt $ GH2LIVE $ trimXbox newPreferences f
        _ -> return ()
    color <- FLE.rgbColorWithRgb (179,221,187)
    FL.setColor btn2 color
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()
