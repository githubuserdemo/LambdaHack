-- | A set of widgets for UI clients.
module Game.LambdaHack.Client.UI.WidgetClient
  ( displayMore, displayYesNo, displayChoiceScreen, displayChoiceLine
  , displayPush, describeMainKeys
  , promptToSlideshow, overlayToSlideshow, overlayToBlankSlideshow
  , animate, fadeOutOrIn, msgPromptAI
  ) where

import Prelude ()
import Prelude.Compat

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Strict as EM
import Data.List (find)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Monoid
import qualified Data.Text as T

import Game.LambdaHack.Client.BfsClient
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient hiding (liftIO)
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.Content.KeyKind
import Game.LambdaHack.Client.UI.DrawClient
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State

-- | A yes-no confirmation.
getYesNo :: MonadClientUI m => SingleFrame -> m Bool
getYesNo frame = do
  let keys = [ K.toKM K.NoModifier (K.Char 'y')
             , K.toKM K.NoModifier (K.Char 'n')
             , K.escKM
             ]
  K.KM {key} <- promptGetKey keys frame
  case key of
    K.Char 'y' -> return True
    _          -> return False

-- | Display a message with a @-more-@ prompt.
-- Return value indicates if the player tried to cancel/escape.
displayMore :: MonadClientUI m => ColorMode -> Msg -> m Bool
displayMore dm prompt = do
  slides <- promptToSlideshow $ prompt <+> moreMsg
  -- Two frames drawn total (unless 'prompt' very long).
  getInitConfirms dm [] $ slides <> toSlideshow Nothing [[]]

-- | Print a yes/no question and return the player's answer. Use black
-- and white colours to turn player's attention to the choice.
displayYesNo :: MonadClientUI m => ColorMode -> Msg -> m Bool
displayYesNo dm prompt = do
  sli <- promptToSlideshow $ prompt <+> yesnoMsg
  frame <- drawOverlay False dm $ head . snd $ slideshow sli
  getYesNo frame

displayChoiceScreen :: forall m . MonadClientUI m
                    => Bool -> [K.OKX] -> [K.KM] -> m K.KM
displayChoiceScreen _ [] _ = assert `failure` "no menu pages" `twith` ()
displayChoiceScreen sfBlank (ok : oks) extraKeys = do
  let keys = concatMap (map fst . snd) (ok : oks) ++ extraKeys
      scrollKeys = [K.leftButtonKM, K.returnKM, K.upKM, K.downKM]
      pageKeys = [K.spaceKM, K.pgupKM, K.pgdnKM]
      legalKeys = keys ++ scrollKeys ++ pageKeys
      -- The arguments go from first menu line and menu page to the last,
      -- in order. The middle ones are where the focus is.
      page :: [K.OKX] -> K.OKX -> [K.OKX] -> m K.KM
      page srf f@(ov0, kyxs0) frs =
        let scroll :: [K.KYX] -> K.KYX -> [K.KYX] -> m K.KM
            scroll sxyk k@(km4, (y, x1, x2)) kyxs = do
              let prevPage = case srf of
                    [] -> startScroll  -- no wrap
                    g : gs -> page gs g (f : frs)
                  nextPage = case frs of
                    [] -> endScroll  -- no wrap
                    g : gs -> page (f : srf) g gs
                  greyBG x = x{Color.acAttr =
                                 (Color.acAttr x){Color.fg = Color.BrWhite}}
                  drawHighlight xs =
                    let (xs1, xsRest) = splitAt x1 xs
                        (xs2, xs3) = splitAt (x2 - x1) xsRest
                    in xs1 ++ map greyBG xs2 ++ xs3
                  ov1 = updateOverlayLine y drawHighlight ov0
                  interpretKey ikm =
                    case K.key ikm of
                      K.Return | K.key km4 /= K.Return -> interpretKey km4
                      K.LeftButtonPress -> case K.pointer ikm of
                        Nothing -> scroll sxyk k kyxs
                        Just Point{..} ->
                          let onChoice (_, (cy, cx1, cx2)) =
                                cy == py + 1 && cx1 <= px && cx2 > px
                          in case find onChoice kyxs0 of
                            Nothing -> scroll sxyk k kyxs
                            Just (ckm, _) -> interpretKey ckm
                      K.Up -> case sxyk of
                        [] | null oks -> endScroll  -- single page, wrap keys
                        [] -> prevPage
                        l : ls -> scroll ls l (k : kyxs)
                      K.Down -> case kyxs of
                        [] | null oks -> startScroll  -- single page, wrap keys
                        [] -> nextPage
                        l : ls -> scroll (k : sxyk) l ls
                      K.PgUp -> prevPage
                      K.PgDn -> nextPage
                      K.Space -> nextPage
                      _ | ikm `elem` keys -> return ikm  -- km can be PgUp, etc.
                      _ -> assert `failure` "unknown key" `twith` ikm
              frame <- drawOverlay sfBlank ColorFull ov1
              pkm <- promptGetKey legalKeys frame
              interpretKey pkm
            startScroll = case kyxs0 of
              [] -> assert `failure` "no menu keys" `twith` keys
              k : ks -> scroll [] k ks
            endScroll = case reverse kyxs0 of
              [] -> assert `failure` "no menu keys" `twith` keys
              k : ks -> scroll ks k []
        in startScroll
  page [] ok oks

-- TODO: generalize displayChoiceLine and getInitConfirms to a single op?
--       but don't enable SPACE, etc. if only one screen (or only prompt)
--       don't truncate then, but
-- If many overlays, scroll screenfuls with SPACE, etc.
-- | Print a prompt and an overlay and wait for a player keypress.
displayChoiceLine :: MonadClientUI m => Msg -> Overlay -> [K.KM] -> m K.KM
displayChoiceLine prompt ov0 keys = do
  -- If the prompt and overlay don't fit on the screen, they are truncated.
  (_, ov : _) <- slideshow <$> overlayToSlideshow prompt ov0
  frame <- drawOverlay False ColorFull ov
  pkm <- promptGetKey keys frame
  let !_A = assert (pkm `elem` keys) ()
  return pkm

-- TODO: if more slides, don't take head, but do as in getInitConfirms,
-- but then we have to clear the messages or they get redisplayed
-- each time screen is refreshed.
-- | Push the frame depicting the current level to the frame queue.
-- Only one screenful of the report is shown, the rest is ignored.
displayPush :: MonadClientUI m => Msg -> m ()
displayPush prompt = do
  sls <- promptToSlideshow prompt
  let slide = head . snd $ slideshow sls
  frame <- drawOverlay False ColorFull slide
  displayFrame (Just frame)

describeMainKeys :: MonadClientUI m => m Msg
describeMainKeys = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let underAI = isAIFact fact
  stgtMode <- getsClient stgtMode
  Binding{brevMap} <- askBinding
  Config{configVi, configLaptop} <- askConfig
  cursor <- getsClient scursor
  let kmLeftButtonPress =
        M.findWithDefault (K.toKM K.NoModifier K.LeftButtonPress)
                          macroLeftButtonPress brevMap
      kmEscape =
        M.findWithDefault (K.toKM K.NoModifier K.Esc) Cancel brevMap
      kmRightButtonPress =
        M.findWithDefault (K.toKM K.NoModifier K.RightButtonPress)
                          TgtPointerEnemy brevMap
      kmReturn =
        M.findWithDefault (K.toKM K.NoModifier K.Return) Accept brevMap
      moveKeys | configVi = "hjklyubn, "
               | configLaptop = "uk8o79jl, "
               | otherwise = ""
      tgtKind = case cursor of
        TEnemy _ True -> "at actor"
        TEnemy _ False -> "at enemy"
        TEnemyPos _ _ _ True -> "at actor"
        TEnemyPos _ _ _ False -> "at enemy"
        TPoint{} -> "at position"
        TVector{} -> "with a vector"
      keys | underAI = ""
           | isNothing stgtMode =
        "Explore with keypad or keys or mouse: ["
        <> moveKeys
        <> T.intercalate ", "
             (map K.showKM [kmLeftButtonPress, kmEscape])
        <> "]"
           | otherwise =
        "Aim" <+> tgtKind <+> "with keypad or keys or mouse: ["
        <> moveKeys
        <> T.intercalate ", "
             (map K.showKM [kmRightButtonPress, kmReturn, kmEscape])
        <> "]"
  report <- getsClient sreport
  return $! if nullReport report then keys else ""

-- | The prompt is shown after the current message, but not added to history.
-- This is useful, e.g., in targeting mode, not to spam history.
promptToSlideshow :: MonadClientUI m => Msg -> m Slideshow
promptToSlideshow prompt = overlayToSlideshow prompt emptyOverlay

-- | The prompt is shown after the current message at the top of each slide.
-- Together they may take more than one line. The prompt is not added
-- to history. The portions of overlay that fit on the the rest
-- of the screen are displayed below. As many slides as needed are shown.
overlayToSlideshow :: MonadClientUI m => Msg -> Overlay -> m Slideshow
overlayToSlideshow prompt overlay = do
  promptAI <- msgPromptAI
  lid <- getArenaUI
  Level{lxsize, lysize} <- getLevel lid  -- TODO: screen length or viewLevel
  sreport <- getsClient sreport
  let msg = splitReport lxsize (prependMsg promptAI (addMsg sreport prompt))
  return $! splitOverlay Nothing (lysize + 1) msg overlay

msgPromptAI :: MonadClientUI m => m Msg
msgPromptAI = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let underAI = isAIFact fact
  return $! if underAI then "[press ESC for Main Menu]" else ""

overlayToBlankSlideshow :: MonadClientUI m
                        => Bool -> Msg -> Overlay -> m Slideshow
overlayToBlankSlideshow startAtTop prompt overlay = do
  lid <- getArenaUI
  Level{lysize} <- getLevel lid  -- TODO: screen length or viewLevel
  return $! splitOverlay (Just startAtTop) (lysize + 3)
                         (toOverlay [prompt]) overlay

-- TODO: restrict the animation to 'per' before drawing.
-- | Render animations on top of the current screen frame.
animate :: MonadClientUI m => LevelId -> Animation -> m Frames
animate arena anim = do
  sreport <- getsClient sreport
  mleader <- getsClient _sleader
  Level{lxsize, lysize} <- getLevel arena
  tgtPos <- leaderTgtToPos
  cursorPos <- cursorToPos
  let anyPos = fromMaybe (Point 0 0) cursorPos
        -- if cursor invalid, e.g., on a wrong level; @draw@ ignores it later on
      pathFromLeader leader = Just <$> getCacheBfsAndPath leader anyPos
  bfsmpath <- maybe (return Nothing) pathFromLeader mleader
  tgtDesc <- maybe (return ("------", Nothing)) targetDescLeader mleader
  cursorDesc <- targetDescCursor
  promptAI <- msgPromptAI
  let over = renderReport (prependMsg promptAI sreport)
      topLineOnly = truncateToOverlay over
  basicFrame <-
    draw ColorFull arena cursorPos tgtPos
         bfsmpath cursorDesc tgtDesc topLineOnly
  snoAnim <- getsClient $ snoAnim . sdebugCli
  return $! if fromMaybe False snoAnim
            then [Just basicFrame]
            else renderAnim lxsize lysize basicFrame anim

fadeOutOrIn :: MonadClientUI m => Bool -> m ()
fadeOutOrIn out = do
  let topRight = True
  lid <- getArenaUI
  Level{lxsize, lysize} <- getLevel lid
  animMap <- rndToAction $ fadeout out topRight 2 lxsize lysize
  animFrs <- animate lid animMap
  mapM_ displayFrame animFrs
