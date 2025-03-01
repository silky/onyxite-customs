{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedRecordDot       #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TupleSections             #-}
module Onyx.Audio.Render
( checkDefined
, jammitPath
, manualLeaf
, computeSimplePart, computeDrumsPart
, computeChannelsPlan
, completePlanAudio
, buildAudioToSpec
, buildPartAudioToSpec
, channelsToSpec
, loadSamplesFromBuildDir
, loadSamplesFromBuildDirShake
) where

import           Control.Monad                (forM, forM_, join)
import           Control.Monad.IO.Class       (MonadIO)
import           Control.Monad.Trans.Class    (lift)
import           Control.Monad.Trans.Resource (MonadResource)
import           Data.Char                    (toLower)
import           Data.Conduit.Audio
import           Data.Foldable                (toList)
import qualified Data.HashMap.Strict          as HM
import           Data.List.Extra              (nubOrd)
import qualified Data.List.NonEmpty           as NE
import           Data.Maybe                   (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text                    as T
import           Development.Shake            (getShakeOptions, need,
                                               shakeFiles)
import           Development.Shake.FilePath
import           Onyx.Audio
import           Onyx.Audio.Search
import qualified Onyx.MIDI.Track.Drums        as Drums
import           Onyx.MIDI.Track.File         (FlexPartName)
import           Onyx.Project
import           Onyx.StackTrace              (SendMessage, StackTraceT,
                                               Staction, fatal, inside, lg,
                                               stackIO, warn)
import qualified Sound.Jammit.Base            as J

computeChannels :: Audio Duration Int -> Int
computeChannels = \case
  Silence n _         -> n
  Input n             -> n
  Mix auds            -> foldr max 0 $ fmap computeChannels auds
  Merge auds          -> sum $ fmap computeChannels auds
  Concatenate auds    -> foldr max 0 $ fmap computeChannels auds
  Gain _ aud          -> computeChannels aud
  Take _ _ aud        -> computeChannels aud
  Drop _ _ aud        -> computeChannels aud
  Fade _ _ aud        -> computeChannels aud
  Pad _ _ aud         -> computeChannels aud
  Resample aud        -> computeChannels aud
  Channels chans _    -> length chans
  StretchSimple _ aud -> computeChannels aud
  StretchFull _ _ aud -> computeChannels aud
  Mask _ _ aud        -> computeChannels aud
  Samples _ _         -> 2

-- | make sure all audio leaves are defined, catch typos
checkDefined :: (Monad m) => SongYaml f -> StackTraceT m ()
checkDefined songYaml = do
  let definedLeaves = HM.keys songYaml.audio ++ HM.keys songYaml.jammit
  forM_ (HM.toList songYaml.plans) $ \(planName, plan) -> do
    let leaves = case plan of
          MoggPlan _ -> []
          StandardPlan x -> let
            getLeaves = \case
              Named t          -> t
              JammitSelect _ t -> t
            in map getLeaves $ concat
              [ maybe [] toList x.song
              , maybe [] toList x.crowd
              , toList x.parts.getParts >>= toList >>= toList
              ]
    case filter (not . (`elem` definedLeaves)) leaves of
      [] -> return ()
      undefinedLeaves -> fatal $
        "Undefined leaves in plan " ++ show planName ++ " audio expression: " ++ show undefinedLeaves

computeChannelsPlan :: SongYaml f -> Audio Duration AudioInput -> Int
computeChannelsPlan songYaml = let
  toChannels ai = case ai of
    Named name -> case HM.lookup name songYaml.audio of
      Nothing                  -> error
        "panic! audio leaf not found, after it should've been checked"
      Just (AudioFile    info) -> info.channels
      Just (AudioSnippet expr) -> computeChannelsPlan songYaml expr
      Just AudioSamples{}      -> 2
    JammitSelect _ _ -> 2
  in computeChannels . fmap toChannels

jammitPath :: T.Text -> J.AudioPart -> FilePath
jammitPath name (J.Only part)
  = "gen/jammit" </> T.unpack name </> "only" </> map toLower (drop 4 $ show part) <.> "wav"
jammitPath name (J.Without inst)
  = "gen/jammit" </> T.unpack name </> "without" </> map toLower (show inst) <.> "wav"

-- | Looking up single audio files and Jammit parts in the work directory
manualLeaf
  :: (SendMessage m, MonadIO m)
  => FilePath
  -> AudioLibrary
  -> (T.Text -> StackTraceT m FilePath) -- build audio object by name, return path to file
  -> StackTraceT m [(T.Text, [(Double, T.Text, T.Text)])] -- get sample triggers list
  -> SongYaml FilePath
  -> AudioInput
  -> StackTraceT m (Audio Duration FilePath)
manualLeaf rel alib buildDependency getSamples songYaml (Named name) = case HM.lookup name songYaml.audio of
  Just audioQuery -> case audioQuery of
    AudioFile ainfo -> inside ("Looking for the audio file named " ++ show name) $ do
      aud <- searchInfo rel alib buildDependency ainfo
      -- lg $ "Found audio file " ++ show name ++ " at: " ++ show (toList aud)
      return aud
    AudioSnippet expr -> join <$> mapM (manualLeaf rel alib buildDependency getSamples songYaml) expr
    AudioSamples info -> do
      triggers <- fromMaybe [] . lookup name <$> getSamples
      let polyphony = case info.groupPolyphony of
            Nothing -> Nothing
            Just p  -> Just (p, realToFrac info.groupCrossfade)
          uniqueSamples = nubOrd [ sample | (_, _, sample) <- triggers ]
      -- only locate each sample once
      sampleToAudio <- fmap HM.fromList $ forM uniqueSamples $ \sample -> do
        audio <- manualLeaf rel alib buildDependency getSamples songYaml $ Named sample
        return (sample, audio)
      return $ Samples polyphony $ flip mapMaybe triggers $ \(secs, group, sample) -> do
        audio <- HM.lookup sample sampleToAudio
        return (Seconds secs, (group, audio))
  Nothing -> fatal $ "Couldn't find an audio source named " ++ show name
manualLeaf rel _alib _buildDependency _getSamples songYaml (JammitSelect audpart name) = case HM.lookup name songYaml.jammit of
  Just _  -> return $ Input $ rel </> jammitPath name audpart
  Nothing -> fatal $ "Couldn't find a Jammit source named " ++ show name

-- | Computing a non-drums instrument's audio for CON/Magma.
-- Always returns 1 or 2 channels, with all volumes 0.
computeSimplePart :: FlexPartName -> Plan f -> SongYaml f -> [(Double, Double)]
computeSimplePart fpart plan songYaml = case plan of
  MoggPlan x -> let
    inds = maybe [] (concat . toList) $ HM.lookup fpart x.parts.getParts
    in case inds of
      [] -> [(0, 0)] -- this is only used for Magma
      _  -> map (\i -> (x.pans !! i, x.vols !! i)) inds
  StandardPlan x -> case HM.lookup fpart x.parts.getParts of
    Nothing -> [(0, 0)]
    Just (PartSingle pa) -> case computeChannelsPlan songYaml pa.expr of
      1 -> [(fromMaybe 0 $ listToMaybe pa.pans, 0)]
      _ -> [(-1, 0), (1, 0)]
    Just (PartDrumKit _ _ _) -> [(-1, 0), (1, 0)]

completePlanAudio :: (Monad m) => SongYaml f -> PlanAudio Duration AudioInput -> StackTraceT m (Audio Duration AudioInput, [Double], [Double])
completePlanAudio songYaml pa = do
  let chans = computeChannelsPlan songYaml pa.expr
      vols = map realToFrac $ case pa.vols of
        []  -> replicate chans 0
        [x] -> replicate chans x
        xs  -> xs
  pans <- case pa.pans of
    [] -> case chans of
      0 -> return []
      1 -> return [0]
      2 -> return [-1, 1]
      n -> fatal $ "No automatic pan choice for " ++ show n ++ " channels"
    xs -> return $ map realToFrac xs
  return (pa.expr, pans, vols)

fitToSpec
  :: (Monad m, MonadResource r)
  => [(Double, Double)]
  -> [(Double, Double)]
  -> AudioSource r Float
  -> StackTraceT m (AudioSource r Float)
fitToSpec pvIn pvOut src = let
  pans = map fst pvIn
  vols = map snd pvIn
  in case pvOut of
    [(pan, 0)] -> if [pan] == pans
      then return $ case fromMaybe 0 $ listToMaybe vols of
        0   -> src
        vol -> gain (10 ** (realToFrac vol / 20)) src -- just apply vol to single channel and we're done
      else fatal $ "Mono output (" ++ show pvOut ++ ") does not match input pans: " ++ show pans
    [(-1, 0), (1, 0)] -> return
      $ applyPansVols (map realToFrac pans) (map realToFrac vols) src -- simple stereo remix
    _ -> if pvIn == pvOut
      then return src -- input == output, we're good
      else fatal $ "Unrecognized audio spec: " ++ show pvOut

channelsToSpec
  :: (MonadResource m)
  => [(Double, Double)]
  -> (Int -> FilePath)
  -> [(Double, Double)]
  -> [Int]
  -> Staction (AudioSource m Float)
channelsToSpec pvOut pathChannel pvIn chans = inside "conforming MOGG channels to output spec" $ do
  let partPVIn = map (pvIn !!) chans
  src <- case NE.nonEmpty chans of
    Nothing -> do
      let chan0 = pathChannel 0
      lift $ lift $ need [chan0]
      rate <- audioRate chan0 >>= \case
        Just rate -> return $ fromIntegral rate
        Nothing -> do
          lg "Couldn't detect sample rate of input OGG; assuming 44100 Hz."
          return 44100
      return $ silent (Frames 0) rate 1
    Just ne -> lift $ lift $ buildSource $ Merge $ fmap (Input . pathChannel) ne
  fitToSpec partPVIn pvOut src

loadSamplesFromBuildDir
  :: (MonadIO m)
  => (FilePath -> StackTraceT m FilePath)
  -> T.Text -- plan
  -> StackTraceT m [(T.Text, [(Double, T.Text, T.Text)])]
loadSamplesFromBuildDir builder planName = do
  txt <- builder $ "gen/plan" </> T.unpack planName </> "samples.txt"
  fmap read $ stackIO $ readFile txt

loadSamplesFromBuildDirShake
  :: FilePath
  -> T.Text -- plan
  -> Staction [(T.Text, [(Double, T.Text, T.Text)])]
loadSamplesFromBuildDirShake rel = loadSamplesFromBuildDir $ \f -> do
  opts <- lift $ lift getShakeOptions
  let isSlash c = c == '/' || c == '\\'
      realPath = rel </> case break isSlash f of
        ("gen", rest) -> shakeFiles opts </> dropWhile isSlash rest
        _             -> f
  lift $ lift $ need [realPath]
  return realPath

buildAudioToSpec
  :: (MonadResource m)
  => FilePath
  -> AudioLibrary
  -> (T.Text -> Staction FilePath)
  -> SongYaml FilePath
  -> [(Double, Double)]
  -> T.Text -- plan
  -> Maybe (PlanAudio Duration AudioInput)
  -> Staction (AudioSource m Float)
buildAudioToSpec rel alib buildDependency songYaml pvOut planName mpa = inside "conforming audio file to output spec" $ do
  (expr, pans, vols) <- completePlanAudio songYaml
    $ fromMaybe (PlanAudio (Silence 1 $ Frames 0) [] []) mpa
  let loadSamples = loadSamplesFromBuildDirShake rel planName
  src <- mapM (manualLeaf rel alib buildDependency loadSamples songYaml) expr >>= lift . lift . buildSource . join
  fitToSpec (zip pans vols) pvOut src

buildPartAudioToSpec
  :: (MonadResource m)
  => FilePath
  -> AudioLibrary
  -> (T.Text -> Staction FilePath)
  -> SongYaml FilePath
  -> [(Double, Double)]
  -> T.Text -- plan
  -> Maybe (PartAudio (PlanAudio Duration AudioInput))
  -> Staction (AudioSource m Float)
buildPartAudioToSpec rel alib buildDependency songYaml specPV planName = \case
  Nothing -> buildAudioToSpec rel alib buildDependency songYaml specPV planName Nothing
  Just (PartSingle pa) -> buildAudioToSpec rel alib buildDependency songYaml specPV planName $ Just pa
  Just (PartDrumKit kick snare kit) -> do
    kickSrc  <- buildAudioToSpec rel alib buildDependency songYaml specPV planName kick
    snareSrc <- buildAudioToSpec rel alib buildDependency songYaml specPV planName snare
    kitSrc   <- buildAudioToSpec rel alib buildDependency songYaml specPV planName $ Just kit
    return $ mix kickSrc $ mix snareSrc kitSrc

-- | Computing a drums instrument's audio for CON/Magma.
-- Always returns a valid drum mix configuration, with all volumes 0.
computeDrumsPart
  :: (SendMessage m)
  => FlexPartName
  -> Plan f
  -> SongYaml f
  -> StackTraceT m (([(Double, Double)], [(Double, Double)], [(Double, Double)]), Drums.Audio)
computeDrumsPart fpart plan songYaml = inside "Computing drums audio mix" $ case plan of
  MoggPlan x -> case HM.lookup fpart x.parts.getParts of
    Nothing -> return stereo
    Just (PartSingle _) -> return stereo
    Just (PartDrumKit kick snare kit) -> do
      maybeMix <- lookupSplit (maybe 0 length kick, maybe 0 length snare, length kit)
      case maybeMix of
        Nothing -> return stereo
        Just mixMode -> return
          ( ( standardIndexes x.pans $ fromMaybe [] kick
            , standardIndexes x.pans $ fromMaybe [] snare
            , standardIndexes x.pans kit
            )
          , mixMode
          )
  StandardPlan x -> case HM.lookup fpart x.parts.getParts of
    Nothing -> return stereo
    Just (PartSingle _) -> return stereo -- any number will be remixed to stereo
    Just (PartDrumKit kick snare kit) -> do
      maybeMix <- lookupSplit
        ( maybe 0 (computeChannelsPlan songYaml . (.expr)) kick
        , maybe 0 (computeChannelsPlan songYaml . (.expr)) snare
        , computeChannelsPlan songYaml kit.expr
        )
      case maybeMix of
        Nothing -> return stereo
        Just mixMode -> do
          kickPV <- case kick of
            Nothing -> return []
            Just pa -> (\(_, pans, _) -> map (, 0) pans) <$> completePlanAudio songYaml pa
          snarePV <- case snare of
            Nothing -> return []
            Just pa -> (\(_, pans, _) -> map (, 0) pans) <$> completePlanAudio songYaml pa
          kitPV <- (\(_, pans, _) -> map (, 0) pans) <$> completePlanAudio songYaml kit
          return ((kickPV, snarePV, kitPV), mixMode)
  where lookupSplit = \case
          (0, 0, 2) -> return $ Just Drums.D0
          (1, 1, 2) -> return $ Just Drums.D1
          (1, 2, 2) -> return $ Just Drums.D2
          (2, 2, 2) -> return $ Just Drums.D3
          (1, 0, 2) -> return $ Just Drums.D4
          trio -> do
            warn $ "Split drum kit audio will be mixed down due to a non-RB channel configuration: (kick,snare,kit) = " ++ show trio
            return Nothing
        stereo = (([], [], [(-1, 0), (1, 0)]), Drums.D0)
        standardIndexes pans = \case
          []  -> []
          [i] -> [(pans !! i, 0)]
          _   -> [(-1, 0), (1, 0)]
