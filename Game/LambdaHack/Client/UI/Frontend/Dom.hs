{-# LANGUAGE CPP #-}
-- | Text frontend running in Browser or in Webkit.
module Game.LambdaHack.Client.UI.Frontend.Dom
  ( -- * Session data type for the frontend
    FrontendSession(sescMVar)
    -- * The output and input operations
  , fdisplay, fpromptGetKey, fsyncFrames
    -- * Frontend administration tools
  , frontendName, startup
  ) where

import Control.Concurrent
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import qualified Control.Exception as Ex hiding (handle)
import Control.Monad
import Control.Monad.Reader (ask, liftIO)
import Data.Bits ((.|.))
import Data.Char (chr, isUpper, toLower)
import Data.Maybe
import Data.String (IsString (..))
import GHCJS.DOM (WebView, enableInspector, postGUISync, runWebGUI,
                  webViewGetDomDocument)
import GHCJS.DOM.CSSStyleDeclaration (setProperty)
import GHCJS.DOM.Document (click, createElement, getBody, keyDown)
import GHCJS.DOM.Element (getStyle, setInnerHTML)
import GHCJS.DOM.EventM (mouseAltKey, mouseButton, mouseClientXY, mouseCtrlKey,
                         mouseMetaKey, mouseShiftKey, on)
import GHCJS.DOM.HTMLCollection (item)
import GHCJS.DOM.HTMLElement (setInnerText)
import GHCJS.DOM.HTMLTableCellElement (HTMLTableCellElement,
                                       castToHTMLTableCellElement)
import GHCJS.DOM.HTMLTableElement (HTMLTableElement, castToHTMLTableElement,
                                   getRows)
import GHCJS.DOM.HTMLTableRowElement (HTMLTableRowElement,
                                      castToHTMLTableRowElement, getCells)
import GHCJS.DOM.KeyboardEvent (getAltGraphKey, getAltKey, getCtrlKey,
                                getKeyIdentifier, getKeyLocation, getMetaKey,
                                getShiftKey)
import GHCJS.DOM.Node (appendChild)
import GHCJS.DOM.UIEvent ()
import GHCJS.DOM.UIEvent (getKeyCode, getWhich)

import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point

-- | Session data maintained by the frontend.
data FrontendSession = FrontendSession
  { swebView   :: !WebView
  , scharTable :: !HTMLTableElement
  , schanKey   :: !(STM.TQueue K.KM)  -- ^ channel for keyboard input
  , sescMVar   :: !(Maybe (MVar ()))
  , sdebugCli  :: !DebugModeCli  -- ^ client configuration
  }

-- | The name of the frontend.
frontendName :: String
#ifdef USE_BROWSER
frontendName = "browser"
#elif USE_WEBKIT
frontendName = "webkit"
#else
terrible error
#endif

-- | Starts the main program loop using the frontend input and output.
startup :: DebugModeCli -> (FrontendSession -> IO ()) -> IO ()
startup sdebugCli k = runWebGUI $ runWeb sdebugCli k

runWeb :: DebugModeCli -> (FrontendSession -> IO ()) -> WebView -> IO ()
runWeb sdebugCli@DebugModeCli{sfont} k swebView = do
  -- Init the document.
  enableInspector swebView  -- enables Inspector in Webkit
  Just doc <- webViewGetDomDocument swebView
  Just body <- getBody doc
  -- Set up the HTML.
  setInnerHTML body (Just ("<h1>LambdaHack</h1>" :: String))
  let lxsize = fst normalLevelBound + 1  -- TODO
      lysize = snd normalLevelBound + 1
      cell = "<td>."
      row = "<tr>" ++ concat (replicate lxsize cell)
      rows = concat (replicate lysize row)
  Just scharTable <- fmap castToHTMLTableElement
                     <$> createElement doc (Just ("table" :: String))
  setInnerHTML scharTable (Just (rows :: String))
  Just style <- getStyle scharTable
  let setProp :: String -> String -> IO ()
      setProp propRef propValue =
        setProperty style propRef (Just propValue) ("" :: String)
  -- Set the font specified in config, if any.
  let font = "Monospace normal normal normal normal 14" -- fromMaybe "" sfont
  -- setProp "font" font
      {-
font-family: 'Times New Roman';
font-kerning: auto;
font-size: 16px;
font-style: normal;
font-variant: normal;
font-variant-ligatures: normal;
font-weight: normal;
      -}
  setProp "font-family" "Monospace"
  -- Modify default colours.
  setProp "background-color" (Color.colorToRGB Color.Black)
  setProp "color" (Color.colorToRGB Color.White)
  void $ appendChild body (Just scharTable)
  -- Create the session record.
  schanKey <- STM.atomically STM.newTQueue
  escMVar <- newEmptyMVar
  let sess = FrontendSession{sescMVar = Just escMVar, ..}
  -- Fork the game logic thread. When logic ends, game exits.
  aCont <- async $ k sess `Ex.finally` return ()  --- TODO: close webkit window?
  link aCont
  -- Fill the keyboard channel.
  let flushChanKey = do
        res <- STM.atomically $ STM.tryReadTQueue schanKey
        when (isJust res) flushChanKey
  -- A bunch of fauity hacks; @keyPress@ doesn't handle non-character keys and
  -- @getKeyCode@ then returns wrong characters anyway.
  -- Regardless, it doesn't work: https://bugs.webkit.org/show_bug.cgi?id=20027
  void $ doc `on` keyDown $ do
    -- https://hackage.haskell.org/package/webkitgtk3-0.14.1.0/docs/Graphics-UI-Gtk-WebKit-DOM-KeyboardEvent.html
    -- though: https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/keyIdentifier
    keyId <- ask >>= getKeyIdentifier
    _keyLoc <- ask >>= getKeyLocation
    modCtrl <- ask >>= getCtrlKey
    modShift <- ask >>= getShiftKey
    modAlt <- ask >>= getAltKey
    modMeta <- ask >>= getMetaKey
    modAltG <- ask >>= getAltGraphKey
    which <- ask >>= getWhich
    keyCode <- ask >>= getKeyCode
    let keyIdBogus = keyId `elem` ["", "Unidentified"]
                     || take 2 keyId == "U+"
        -- Handle browser quirks and webkit non-conformance to standards,
        -- especially for ESC, etc. This is still not nearly enough.
        -- Webkit DOM is just too old.
        -- http://www.w3schools.com/jsref/event_key_keycode.asp
        quirksN | not keyIdBogus = keyId
                | otherwise = let c = chr $ which .|. keyCode
                              in [if isUpper c && not modShift
                                  then toLower c
                                  else c]
        !key = K.keyTranslateWeb quirksN
        !modifier = let md = modifierTranslate
                               modCtrl modShift (modAlt || modAltG) modMeta
                    in if md == K.Shift then K.NoModifier else md
        !pointer = Nothing
    liftIO $ do
      {-
      putStrLn keyId
      putStrLn quirksN
      putStrLn $ T.unpack $ K.showKey key
      putStrLn $ show which
      putStrLn $ show keyCode
      -}
      unless (deadKey keyId) $ do
        -- If ESC, also mark it specially and reset the key channel.
        when (key == K.Esc) $ do
          void $ tryPutMVar escMVar ()
          flushChanKey
        -- Store the key in the channel.
        STM.atomically $ STM.writeTQueue schanKey K.KM{..}
  -- Take care of the mouse events.
  void $ doc `on` click $ do
    -- https://hackage.haskell.org/package/ghcjs-dom-0.2.1.0/docs/GHCJS-DOM-EventM.html
    liftIO flushChanKey
    but <- mouseButton
    (wx, wy) <- mouseClientXY
    modCtrl <- mouseCtrlKey
    modShift <- mouseShiftKey
    modAlt <- mouseAltKey
    modMeta <- mouseMetaKey
    let !modifier = modifierTranslate modCtrl modShift modAlt modMeta
    liftIO $ do
      -- TODO: Graphics.UI.Gtk.WebKit.DOM.Selection? ClipboardEvent?
      -- hasSelection <- textBufferHasSelection tb
      -- unless hasSelection $ do
      -- TODO: mdrawWin <- displayGetWindowAtPointer display
      -- let setCursor (drawWin, _, _) =
      --       drawWindowSetCursor drawWin (Just cursor)
      -- maybe (return ()) setCursor mdrawWin
      let (cx, cy) = windowToTextCoords (wx, wy)
          !key = case but of
            0 -> K.LeftButtonPress
            1 -> K.MiddleButtonPress
            2 -> K.RightButtonPress
            _ -> K.LeftButtonPress
          !pointer = Just $! Point cx (cy - 1)
      -- Store the mouse event coords in the keypress channel.
      STM.atomically $ STM.writeTQueue schanKey K.KM{..}
  return ()  -- nothing to clean up

windowToTextCoords :: (Int, Int) -> (Int, Int)
windowToTextCoords (x, y) = (x, y)  -- TODO

-- | Output to the screen via the frontend.
fdisplay :: FrontendSession    -- ^ frontend session data
         -> Maybe SingleFrame  -- ^ the screen frame to draw
         -> IO ()
fdisplay _ Nothing = return ()
fdisplay FrontendSession{scharTable} (Just rawSF) = postGUISync $ do
  let SingleFrame{sfLevel} = overlayOverlay rawSF
      ls = map (map Color.acChar . decodeLine) sfLevel
      lxsize = fromIntegral $ fst normalLevelBound + 1  -- TODO
      lysize = fromIntegral $ snd normalLevelBound + 1
  Just rows <- getRows scharTable
  lmrow <- mapM (item rows) [0..lysize-1]
  let lrow = map (castToHTMLTableRowElement . fromJust) lmrow
      getC :: HTMLTableRowElement -> IO [HTMLTableCellElement]
      getC row = do
        Just cells <- getCells row
        lmcell <- mapM (item cells) [0..lxsize-1]
        return $! map (castToHTMLTableCellElement . fromJust) lmcell
  lrc <- mapM getC lrow
  let setChar :: (HTMLTableCellElement, Char) -> IO ()
      setChar (cell, c) = do
        let s = if c == ' ' then [chr 160] else [c]
        setInnerText cell $ Just s
  mapM_ setChar $ zip (concat lrc) (concat ls)

fsyncFrames :: FrontendSession -> IO ()
fsyncFrames _ = return ()

-- | Display a prompt, wait for any key.
fpromptGetKey :: FrontendSession -> SingleFrame -> IO K.KM
fpromptGetKey sess@FrontendSession{schanKey} frame = do
  fdisplay sess $ Just frame
  STM.atomically $ STM.readTQueue schanKey

-- | Tells a dead key.
deadKey :: (Eq t, IsString t) => t -> Bool
deadKey x = case x of   -- ??? x == "Dead"
  "Dead"        -> True
  "Shift"       -> True
  "Control"     -> True
  "Meta"        -> True
  "Menu"        -> True
  "ContextMenu" -> True
  "Alt"         -> True
  "AltGraph"    -> True
  "Num_Lock"    -> True
  "CapsLock"    -> True
  _             -> False

-- | Translates modifiers to our own encoding.
modifierTranslate :: Bool -> Bool -> Bool -> Bool -> K.Modifier
modifierTranslate modCtrl modShift modAlt modMeta
  | modCtrl = K.Control
  | modAlt || modMeta = K.Alt
  | modShift = K.Shift
  | otherwise = K.NoModifier
