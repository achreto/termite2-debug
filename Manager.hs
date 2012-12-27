module Manager(debugGUI) where

import qualified Graphics.UI.Gtk as G
import Control.Concurrent
import Data.IORef
import System.Glib.MainLoop

import DbgTypes
import IDE
import Icon
import VarView
import GraphView

dbgDefaultWidth  = 1024
dbgDefaultHeight = 768

data Debugger = Debugger {
    dbgIDE      :: RIDE,
    dbgViews    :: [DbgView]
}

-- State associated by the debugger with each registered view (visible or invisible)
data DbgView = DbgView {
    dbgViewView     :: View,
    dbgViewPanel    :: IDEPanel,
    dbgViewVisible  :: Bool,
    dbgViewMenuItem :: G.CheckMenuItem
}

type RDebugger = IORef Debugger

dbgGetIDE :: RDebugger -> IO RIDE
dbgGetIDE ref = (liftM dbgIDE) $ readIORef ref

dbgGetView :: RDebugger -> Int -> IO DbgView
dbgGetView ref id = do
    dbg <- readIORef ref
    return $ dbgViews dbg !! id

dbgSetView :: RDebugger -> Int -> DbgView -> IO ()
dbgSetView ref id view = do
    dbg <- readIORef ref
    writeIORef ref $ dbg {dbgViews = (take id (dbgViews dbg)) ++ [view] ++ drop (id+1) (dbgViews dbg)}

-- List of available views
viewFactories :: [(D.RModel c a -> IO View)]
viewFactories = [ varViewNew
                , graphViewNew]

--------------------------------------------------
---- Transition graph view
---------------------------------------------------
--
--data GraphView = GraphView
--type RGraphView = IORef GraphView
--
--graphViewNew :: String -> IDEAlign -> IO View
--graphViewNew name align = do
--    layout <- G.layoutNew Nothing Nothing
--    G.widgetShow layout
--    ref <- newIORef GraphView
--    return $ View { viewName      = name 
--                  , viewDefAlign  = align
--                  , viewShow      = (\_ -> return ())
--                  , viewHide      = (\_ -> return ())
--                  , viewGetWidget = return $ G.toWidget layout}

-- GUI manager
debugGUI :: D.Model c a -> IO ()
debugGUI model = do
    rmodel <- newIORef model

    -- Initialize GTK+ engine
    G.initGUI 
    -- Every so often, we try to run other threads.
    timeoutAddFull (yield >> return True) priorityDefaultIdle 100

    -- main window
    wmain <- G.windowNew
    G.widgetSetSizeRequest wmain dbgDefaultWidth dbgDefaultHeight

    -- use the same icon for all debugger windows
    icon <- G.pixbufNewFromXPMData ladyBugIcon
    G.windowSetTitle wmain "Termite debugger"
    G.windowSetIcon wmain (Just icon)
    G.windowSetDefaultIcon (Just icon)

    -- vbox to hold window content
    vbox <- G.vBoxNew False 0
    G.containerAdd wmain vbox

    -- main menu
    mmain <- G.menuBarNew
    G.boxPackStart vbox mmain G.PackNatural 3

    -- view selection menu
    mview <- G.menuNew
    iview <- G.menuItemNewWithLabel "View"
    G.menuItemSetSubmenu iview mview
    G.menuShellAppend mmain iview

    -- IDE manager
    ide <- ideNew
    idew <- ideWidget ide

    -- Create debugger state
    ref <- newIORef $ Debugger { dbgIDE   = ide
                               , dbgViews = []}

    G.boxPackStart vbox idew G.PackGrow 0

    views <- mapIdxM (\f id -> do view <- f rmodel
                                  mitem <- G.checkMenuItemNewWithLabel (viewName view)
                                  G.menuShellAppend mview mitem
                                  G.on mitem G.checkMenuItemToggled (dbgViewToggle ref id mitem)
                                  G.widgetShow mitem                                 
                                  w <- viewGetWidget view
                                  panel <- framePanelNew w (viewName view) (dbgViewHideCB ref id)
                                  return $ DbgView { dbgViewView     = view
                                                   , dbgViewPanel    = panel
                                                   , dbgViewVisible  = False
                                                   , dbgViewMenuItem = mitem})
                  viewFactories

    dbg <- readIORef ref
    writeIORef ref $ dbg {dbgViews = views}

    G.widgetShowAll wmain
    G.mainGUI


dbgViewToggle :: RDebugger -> Int -> G.CheckMenuItem -> IO ()
dbgViewToggle ref id item = do
    active <- G.checkMenuItemGetActive item
    view <- dbgGetView ref id
    if active && (not $ dbgViewVisible view)
       then dbgViewShow ref id
       else if (not active) && (dbgViewVisible view)
               then dbgViewHide ref id
               else return ()


dbgViewShow :: RDebugger -> Int  -> IO ()
dbgViewShow ref id = do
    view <- dbgGetView ref id
    (viewShow $ dbgViewView view) ref
    ide  <- dbgGetIDE ref
    let align = viewDefAlign $ dbgViewView view
        panel = dbgViewPanel view
    case align of
         AlignLeft   -> ideAddLeft   ide panel
         AlignCenter -> ideAddCenter ide panel
         AlignRight  -> ideAddRight  ide panel
         AlignBottom -> ideAddBottom ide panel
    dbgSetView ref id $ view {dbgViewVisible = True}


dbgViewHide :: RDebugger -> Int  -> IO ()
dbgViewHide ref id = do
    view <- dbgGetView ref id
    (viewHide $ dbgViewView view) ref
    ide  <- dbgGetIDE ref
    let panel = dbgViewPanel view
    ideRemove ide panel
    dbgSetView ref id $ view {dbgViewVisible = False}

-- Callback triggered by a view when it wants to hide itself.
-- Simply toggle the menu item to unchecked state.  Do the actual
-- deletion in the event handler.
dbgViewHideCB :: RDebugger -> Int -> IO ()
dbgViewHideCB ref id = do
    view <- dbgGetView ref id
    G.checkMenuItemSetActive (dbgViewMenuItem view) False
