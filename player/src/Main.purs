module Main where

import           Prelude

import           Control.Monad.Except  (runExcept)
import           Data.Array            (uncons, (:), concat, take, drop, concatMap)
import           Data.Either           (Either (..))
import           Data.Int              (round, toNumber)
import           Data.Maybe            (Maybe (..))
import           Data.Time.Duration    (Milliseconds (..), Seconds (..),
                                        convertDuration, negateDuration)
import           Data.Tuple            (Tuple (..), fst, snd)
import           Effect                (Effect)
import           Effect.Exception      (catchException, error, throwException)
import           Effect.Ref            as Ref
import           Foreign               (Foreign, isUndefined)
import           Graphics.Canvas       as C
import           RequestAnimationFrame (requestAnimationFrame)

import           Audio                 (loadAudio, playFrom, stop)
import           Draw                  (draw, getWindowDims, numMod, _B, _M)
import           Draw.Common           (AppTime (..), Settings, Drawer (..))
import           Images
import           Song                  (Flex (..), Song (..), isForeignSong, vocalCount, DrumMode (..), Drums (..), drumsProTo4)
import           Style                 (customize)
import           Draw.Drums         (drawDrums)
import           Draw.Five          (drawFiveFast)
import           Draw.ProKeys       (drawProKeysFast)
import           Draw.Protar        (drawProtar, eachChordsWidth)
import           Draw.Six           (drawSix)
import           Draw.Vocal         (drawVocal)
import           Draw.Amplitude     (drawAmplitude)
import           Draw.Dance         (drawDance)

foreign import onyxSong :: Foreign

foreign import onPoint
  :: ({x :: Int, y :: Int} -> Effect Unit)
  -> Effect Unit

foreign import displayError :: String -> Effect Unit

foreign import setTitle :: String -> Effect Unit

foreign import openMenu :: Effect Unit
foreign import closeMenu :: Effect Unit
foreign import fillMenu
  :: forall o
  .  {title :: String, artist :: String, author :: String | o}
  -> Settings
  -> Effect Unit
foreign import readMenu :: Effect Settings

foreign import performanceNow :: Effect Number

drawLoading :: C.CanvasElement -> Effect Unit
drawLoading canvas = do
  ctx <- C.getContext2D canvas
  dims@{width: windowW, height: windowH} <- getWindowDims
  cdims <- C.getCanvasDimensions canvas
  when (cdims /= dims) (C.setCanvasDimensions canvas dims)

  void $ C.setFillStyle ctx customize.loadingBackground
  void $ C.fillRect ctx { x: 0.0, y: 0.0, width: windowW, height: windowH }

  ms <- performanceNow
  let loopTime = customize.loadingLoopTime_ms
      loopTime8 = customize.loadingLoopTime_ms / 8.0
      t = numMod ms loopTime
      smallSide = customize.loadingSmallSquareSize
      bigX = windowW / 2.0 - smallSide
      bigY = windowH / 2.0 - smallSide
      bigSide = smallSide * 2.0
      smallDraw x y = void $
        C.fillRect ctx { x: x, y: y, width: smallSide, height: smallSide }
  void $ C.setFillStyle ctx customize.loadingBigSquare
  void $ C.fillRect ctx { x: bigX, y: bigY, width: bigSide, height: bigSide }
  void $ C.setFillStyle ctx customize.loadingSmallSquares
  let smalls
        | t < loopTime8 = do
          smallDraw bigX bigY
          smallDraw (bigX + smallSide) (bigY + smallSide)
        | t < loopTime8 * 4.0 = do
          let moved = ((t - loopTime8) / (loopTime8 * 3.0)) * smallSide
          smallDraw (bigX + moved) bigY
          smallDraw (bigX + smallSide - moved) (bigY + smallSide)
        | t < loopTime8 * 5.0 = do
          smallDraw (bigX + smallSide) bigY
          smallDraw bigX (bigY + smallSide)
        | otherwise = do
          let moved = ((t - loopTime8 * 5.0) / (loopTime8 * 3.0)) * smallSide
          smallDraw bigX (bigY + smallSide - moved)
          smallDraw (bigX + smallSide) (bigY + moved)
  smalls

main :: Effect Unit
main = catchException (\e -> displayError (show e) *> throwException e) do
  canvas <- C.getCanvasElementById "the-canvas" >>= \mc -> case mc of
    Just canvas -> pure canvas
    Nothing     -> throwException $ error "Canvas element not found"
  ctx <- C.getContext2D canvas
  clicks <- Ref.new []
  onPoint \e -> Ref.modify_ (e : _) clicks
  song <- case runExcept $ isForeignSong onyxSong of
    Left  e    -> throwException $ error $ if isUndefined onyxSong
      then "No song data was found. Is there a song.js present?"
      else show e
    Right song -> eachChordsWidth ctx song
  setTitle $ case song of Song o -> o.title <> " (" <> o.artist <> ") Onyx Web Player"
  imageGetterRef <- Ref.new Nothing
  withImages \imgs -> Ref.write (Just imgs) imageGetterRef
  audioRef <- Ref.new Nothing
  loadAudio \aud -> Ref.write (Just aud) audioRef
  let initialSettings =
        { parts: map
          (\(Tuple key (Flex flex)) ->
            { partName: case key of
              "vocal"  -> "vocals"
              "global" -> "…"
              _        -> key
            , flexParts: let
              inst enabled o = let
                diff enabled' d = { enabled: enabled', diffName: fst d, draw: Drawer $ snd d }
                in { typeName: o.typeName
                   , typeIcon: o.typeIcon
                   , typeIconURL: imageURL o.typeIcon
                   , typeVertical: o.typeVertical
                   , difficulties: map (diff enabled) (take 1 o.diffs) <> map (diff false) (drop 1 o.diffs)
                   }
              insts = concat
                [ case flex.five of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "5-Fret"
                    , typeIcon: case key of
                      "bass" -> image_icon_bass
                      "keys" -> image_icon_keys
                      _      -> image_icon_guitar
                    , typeVertical: true
                    , diffs: map (map drawFiveFast) ds
                    , count: 1
                    }
                , case flex.six of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "6-Fret (GHL)"
                    , typeIcon: image_icon_ghl
                    , typeVertical: true
                    , diffs: map (map drawSix) ds
                    , count: 1
                    }
                , flip concatMap flex.drums $ \ds -> let
                  dtype = case uncons ds of
                    Nothing -> Drums4 -- shouldn't happen
                    Just {head: h} -> case snd h of
                      Drums d -> d.mode
                  normal =
                    { typeName: case dtype of
                      Drums4    -> "Drums (4)"
                      Drums5    -> "Drums (5)"
                      DrumsPro  -> "Pro Drums"
                      DrumsReal -> "Real Drums"
                    , typeIcon: case dtype of
                      DrumsPro  -> image_icon_pro_drums
                      DrumsReal -> image_icon_real_drums
                      _         -> image_icon_drums
                    , typeVertical: true
                    , diffs: map (map drawDrums) ds
                    , count: 1
                    }
                  in case dtype of
                    DrumsPro -> let
                      unpro = map (map drumsProTo4) ds
                      basic =
                        { typeName: "Drums (4)"
                        , typeIcon: image_icon_drums
                        , typeVertical: true
                        , diffs: map (map drawDrums) unpro
                        , count: 1
                        }
                      in [normal, basic]
                    _ -> [normal]
                , case flex.prokeys of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "Pro Keys"
                    , typeIcon: image_icon_pro_keys
                    , typeVertical: true
                    , diffs: map (map drawProKeysFast) ds
                    , count: 1
                    }
                , case flex.protar of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: case key of
                      "bass" -> "Pro Bass"
                      _      -> "Pro Guitar"
                    , typeIcon: case key of
                      "bass" -> image_icon_pro_bass
                      _      -> image_icon_pro_guitar
                    , typeVertical: true
                    , diffs: map (map drawProtar) ds
                    , count: 1
                    }
                , case flex.dance of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "Dance"
                    , typeIcon: image_icon_dance
                    , typeVertical: true
                    , diffs: map (map drawDance) ds
                    , count: 1
                    }
                , case flex.amplitude of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "Amplitude"
                    , typeIcon: image_icon_amplitude
                    , typeVertical: true
                    , diffs: map (map drawAmplitude) ds
                    , count: 1
                    }
                , case flex.vocal of
                  Nothing -> []
                  Just ds -> pure
                    { typeName: "Vocals"
                    , typeIcon: case vocalCount ds of
                      3 -> image_icon_vocal_3
                      2 -> image_icon_vocal_2
                      _ -> image_icon_vocal_1
                    , typeVertical: false
                    , diffs: map (map drawVocal) ds
                    , count: vocalCount ds
                    }
                ]
              in map (inst true) (take 1 insts) <> map (inst false) (drop 1 insts)
            }
          ) (case song of Song obj -> obj.parts)
        , autoplay: true
        , leftyFlip: false
        , staticVert: false
        }
  fillMenu (case song of Song obj -> obj) initialSettings
  let continueLoading = do
        drawLoading canvas
        imageGetterMaybe <- Ref.read imageGetterRef
        audioMaybe <- Ref.read audioRef
        case imageGetterMaybe of
          Just imageGetter -> case audioMaybe of
            Just audio -> requestAnimationFrame $ makeLoop imageGetter audio
            Nothing -> requestAnimationFrame continueLoading
          Nothing -> requestAnimationFrame continueLoading
      makeLoop imageGetter audio = let
        loop app = do
          ms <- Milliseconds <$> performanceNow
          let nowTheory = case app.time of
                Paused  o -> o.pausedSongTime
                -- Calculate what time should be so it moves nice and smooth
                Playing o -> o.startedSongTime <> convertDuration ms <> negateDuration o.startedPageTime
              continue app' = do
                {height: windowH'} <- getWindowDims
                let windowH = round windowH'
                draw
                  { time: nowTheory
                  , app: app'
                  , song: song
                  , getImage: imageGetter
                  , canvas: canvas
                  , context: ctx
                  , pxToSecsVert: \px -> Seconds $ toNumber (px - customize.targetPositionVert) / customize.trackSpeed
                  , secsToPxVert: \(Seconds secs) -> round (secs * customize.trackSpeed) + customize.targetPositionVert
                  , pxToSecsHoriz: \px -> Seconds $ toNumber (px - customize.targetPositionHoriz) / customize.trackSpeed
                  , secsToPxHoriz: \(Seconds secs) -> round (secs * customize.trackSpeed) + customize.targetPositionHoriz
                  , minY: 0
                  , maxY: windowH
                  }
                evts <- Ref.modify' (\evts -> {state: [], value: evts}) clicks
                let endTime = case song of Song obj -> obj.end
                    handle es app_ = case uncons es of
                      Nothing -> requestAnimationFrame $ loop app_
                      Just {head: {x: x, y: y}, tail: et} -> do
                        if app_.menuOpen
                          then do
                            closeMenu
                            handle et app_ { menuOpen = false }
                          else if _M <= x && x <= _M + _B
                            then if windowH - _M * 2 - _B * 2 <= y && y <= windowH - _M * 2 - _B
                              then case app_.time of -- play/pause button
                                Paused o -> do
                                  ms' <- Milliseconds <$> performanceNow
                                  playFrom audio nowTheory do
                                    handle et app_
                                      { time = Playing
                                        { startedPageTime: convertDuration ms'
                                        , startedSongTime: nowTheory
                                        }
                                      }
                                Playing o -> do
                                  stop audio
                                  handle et app_
                                    { time = Paused
                                      { pausedSongTime: nowTheory
                                      }
                                    }
                              else if windowH - _M - _B <= y && y <= windowH - _M
                                then do -- gear button
                                  openMenu
                                  handle et app_ { menuOpen = true }
                                else if _M <= y && y <= windowH - 3 * _M - 2 * _B
                                  then let -- progress bar
                                    frac = 1.0 - toNumber (y - _M) / toNumber (windowH - 4 * _M - 2 * _B)
                                    t = Seconds $ frac * case endTime of Seconds e -> e
                                    in case app_.time of
                                      Paused o -> handle et app_
                                        { time = Paused
                                          { pausedSongTime: t
                                          }
                                        }
                                      Playing o -> do
                                        ms' <- Milliseconds <$> performanceNow
                                        stop audio
                                        playFrom audio t do
                                          handle et app_
                                            { time = Playing
                                              { startedPageTime: convertDuration ms'
                                              , startedSongTime: t
                                              }
                                            }
                                  else handle et app_
                            else handle et app_
                case app'.time of
                  Playing _ | nowTheory >= endTime -> do
                    stop audio
                    handle evts app'
                      { time = Paused
                        { pausedSongTime: endTime
                        }
                      }
                  _ -> handle evts app'
          settings <- readMenu
          continue app { settings = settings }
        in loop
          { settings: initialSettings
          , time: Paused { pausedSongTime: Seconds 0.0 }
          , menuOpen: false
          }
  continueLoading
