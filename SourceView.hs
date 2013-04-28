{-# LANGUAGE ImplicitParams, RecordWildCards #-}

module SourceView(sourceViewNew) where

import Data.Maybe
import Data.List
import Data.Tree
import Data.String.Utils
import qualified Data.Map                   as M
import qualified Data.Set                   as S
import Data.IORef
import qualified Data.Graph.Inductive.Graph as Graph
import qualified Graphics.UI.Gtk            as G
import Control.Monad
import Control.Monad.State
import Control.Monad.Error
import System.IO.Error
import Text.Parsec
import Data.Hashable

import Name
import Pos
import qualified Parse
import Util hiding (name)
import TSLUtil
import qualified DbgTypes    as D
import qualified IDE         as D
import qualified DbgAbstract as D
import ISpec
import TranSpec
import IExpr
import IVar
import IType
import CFA
import Inline
import Predicate
import Store
import SMTSolver
import TSLAbsGame

import qualified NS              as Front
import qualified Method          as Front
import qualified Process         as Front
import qualified InstTree        as Front
import qualified TemplateOps     as Front
import qualified ExprInline      as Front
import qualified Spec            as Front
import qualified ExprFlatten     as Front
import qualified ExprOps         as Front
import qualified ExprValidate    as Front
import qualified Statement       as Front
import qualified StatementOps    as Front
import qualified StatementInline as Front

--------------------------------------------------------------
-- Data structures
--------------------------------------------------------------

instance D.Vals Store

data TraceEntry = TraceEntry {
    teStack :: Stack,
    teStore :: Store
}

type Trace = [TraceEntry]


data SourceView c a = SourceView {
    svModel          :: D.RModel c a Store,
    svSpec           :: Spec,
    svInputSpec      :: Front.Spec,
    svFlatSpec       :: Front.Spec,
    svAbsVars        :: M.Map String AbsVar,
    svState          :: D.State a Store,            -- current state set via view callback
    svTmp            :: Store,                      -- temporary variables store
    svTranPID        :: Maybe PID,                  -- set by transitionSelected, restricts enabled processes to PID

    -- Command buttons
    svStepButton     :: G.ToolButton,
    svRunButton      :: G.ToolButton,

    -- Trace
    svTrace          :: Trace,                      -- steps from the current state
    svTracePos       :: Int,                        -- current position in the trace
    svTraceCombo     :: G.ComboBox,                 -- trace combo box
    svTraceStore     :: G.ListStore Int,            -- indices in the trace that correspond to visible locations
    svTraceUndo      :: G.ToolButton,               -- back button
    svTraceRedo      :: G.ToolButton,               -- forward button

    -- Process selector
    svPID            :: PID,                        -- PID set in the process selection menu
    svProcessCombo   :: G.ComboBox,                 -- process selection combo box
    svProcessStore   :: G.TreeStore (PID, Bool),    -- tree store that backs the process selector

    -- Stack view
    svStackView      :: G.TreeView,                 -- stack view
    svStackStore     :: G.ListStore Frame,          -- store containing list of stack frames
    svStackFrame     :: Int,                        -- selected stack frame (0 = top)

    -- Watch
    svWatchView      :: G.TreeView,
    svWatchStore     :: G.ListStore (Maybe String), -- store containing watch expressions

    -- Source window
    svSourceView     :: G.TextView,
    svSourceTag      :: G.TextTag,                  -- tag to mark current selection current selection

    -- Resolve view
    svResolveStore   :: G.TreeStore Expr,           -- tmp variables in the scope of the current expression

    -- Action selector
    svActSelectText  :: G.TextView,                 -- user-edited controllable action
    svActSelectBExit :: G.Button,                   -- exit magic block button
    svActSelectBAdd  :: G.Button                    -- perform controllable action button
}

type RSourceView c a = IORef (SourceView c a)

--------------------------------------------------------------
-- View callbacks
--------------------------------------------------------------

sourceViewNew :: (D.Rel c v a s) => Front.Spec -> Front.Spec -> Spec -> [AbsVar] -> SMTSolver -> D.RModel c a Store -> IO (D.View a Store)
sourceViewNew inspec flatspec spec avars solver rmodel = do
    let absvars = M.fromList $ map (\v -> (show v, v)) avars
    -- HACK: create an initial state
    model <- readIORef rmodel
    let ?spec    = spec
        ?absvars = absvars
        ?model   = model
        ?m       = D.mCtx model
    initstore <- case smtGetModel solver [let ?pred = [] in bexprToFormula $ snd $ tsInit $ specTran spec] of
                      Just (Right store) -> return store                      
                      _                  -> fail "Unsatisfiable initial condition"
    D.modelSelectState rmodel (Just $ D.abstractState initstore)
    -- END HACK

    ref <- newIORef $ SourceView { svModel          = rmodel
                                 , svInputSpec      = inspec
                                 , svFlatSpec       = flatspec
                                 , svSpec           = specInlineWireAlways spec
                                 , svAbsVars        = absvars
                                 , svState          = error "SourceView: svState undefined"
                                 , svTmp            = error "SourceView: svTmp undefined"
                                 , svTranPID        = Nothing
                                 , svStepButton     = error "SourceView: svStepButton undefined"
                                 , svRunButton      = error "SourceView: svRunButton undefined"
                                 , svTrace          = []
                                 , svTracePos       = 0
                                 , svTraceCombo     = error "SourceView: svTraceCombo undefined"
                                 , svTraceStore     = error "SourceView: svTraceStore undefined"
                                 , svTraceUndo      = error "SourceView: svTraceUndo undefined"
                                 , svTraceRedo      = error "SourceView: svTraceRedo undefined"
                                 , svPID            = error "SourceView: PID undefined"
                                 , svProcessCombo   = error "SourceView: svProcessCombo undefined"
                                 , svProcessStore   = error "SourceView: svProcessStore undefined"
                                 , svStackView      = error "SourceView: svStackView undefined"
                                 , svStackStore     = error "SourceView: svStackStore undefined"
                                 , svStackFrame     = error "SourceView: svStackFrame undefined"
                                 , svWatchView      = error "SourceView: scWatchView undefined"
                                 , svWatchStore     = error "SourceView: svWatchStore undefined"
                                 , svSourceView     = error "SourceView: svSourceView undefined"
                                 , svSourceTag      = error "SourceView: svSourceTag undefined"
                                 , svResolveStore   = error "SourceView: svResolveStore undefined"
                                 , svActSelectText  = error "SourceView: svActSelectText undefined"
                                 , svActSelectBExit = error "SourceView: svActSelectBExit undefined"
                                 , svActSelectBAdd  = error "SourceView: svActSelectBAdd undefined"
                                 }

    vbox <- G.vBoxNew False 0
    G.widgetShow vbox

    -- toolbar at the top
    tbar <- G.toolbarNew
    G.boxPackStart vbox tbar G.PackNatural 0
    G.widgetShow tbar

    -- process selector
    sel <- processSelectorCreate ref
    selitem <- G.toolItemNew
    G.widgetShow selitem
    G.containerAdd selitem sel
    G.toolbarInsert tbar selitem (-1)

    -- command buttons
    butstep <- G.toolButtonNewFromStock G.stockGoForward
    _ <- G.onToolButtonClicked butstep (do {_ <- step ref; return ()})
    G.widgetShow butstep
    G.toolbarInsert tbar butstep (-1)

    butrun <- G.toolButtonNewFromStock G.stockMediaPlay
    _ <- G.onToolButtonClicked butrun (run ref)
    G.widgetShow butrun
    G.toolbarInsert tbar butrun (-1)
    modifyIORef ref (\sv -> sv { svRunButton  = butrun
                               , svStepButton = butstep
                               })

    -- trace
    tr <- traceViewCreate ref
    tritem <- G.toolItemNew
    G.widgetShow tritem
    G.containerAdd tritem tr
    G.toolbarInsert tbar tritem (-1)

    -- horizontal PanedPanels
    hpanes <- D.panedPanelsNew (liftM G.toPaned $ G.hPanedNew)
    w <- D.panelsGetWidget hpanes
    G.boxPackStart vbox w G.PackGrow 0

    -- source window and controllable action selector on the left
    lvpanes  <- D.panedPanelsNew (liftM G.toPaned $ G.vPanedNew)
    wlvpanes <- D.panelsGetWidget lvpanes
    D.panelsAppend hpanes wlvpanes ""

    src <- sourceWindowCreate ref
    D.panelsAppend lvpanes src "Source Code"

    act <- actionSelectorCreate ref
    D.panelsAppend lvpanes act "Controllable action"

    -- stack, watch, resolve on the right
    rvpanes <- D.panedPanelsNew (liftM G.toPaned $ G.vPanedNew)
    wrvpanes <- D.panelsGetWidget rvpanes
    D.panelsAppend hpanes wrvpanes ""
    stack <- stackViewCreate ref
    watch <- watchCreate ref
    resolve <- resolveViewCreate ref
    D.panelsAppend rvpanes stack "Stack"
    D.panelsAppend rvpanes watch "Watch"
    D.panelsAppend rvpanes resolve "Resolve non-determinism"

    let cb = D.ViewEvents { D.evtStateSelected      = sourceViewStateSelected      ref 
                          , D.evtTransitionSelected = sourceViewTransitionSelected ref
                          }

    -- disable everything until we get a state to start from
    disable ref

    return $ D.View { D.viewName      = "Source"
                    , D.viewDefAlign  = D.AlignCenter
                    , D.viewShow      = return ()
                    , D.viewHide      = return ()
                    , D.viewGetWidget = return $ G.toWidget vbox
                    , D.viewCB        = cb
                    }
    

sourceViewStateSelected :: (D.Rel c v a s) => RSourceView c a -> Maybe (D.State a Store) -> IO ()
sourceViewStateSelected ref Nothing                              = disable ref
sourceViewStateSelected ref (Just s) | isNothing (D.sConcrete s) = disable ref
                                     | otherwise                 = do
    modifyIORef ref (\sv -> sv { svState   = s
                               , svTmp     = SStruct $ M.empty
                               , svTranPID = Nothing})
    reset ref

sourceViewTransitionSelected :: (D.Rel c v a s) => RSourceView c a -> D.Transition a Store -> IO ()
sourceViewTransitionSelected ref tran | isNothing (D.sConcrete $ D.tranFrom tran) = disable ref
                                      | otherwise                                 = do
    modifyIORef ref (\sv -> sv { svState   = D.tranFrom tran
                               , svTmp     = tranTmpStore sv tran
                               , svTranPID = Just $ parsePIDEnumerator $ storeEvalEnum (fromJust $ D.sConcrete $ D.tranTo tran) mkPIDVar})
    reset ref

--------------------------------------------------------------
-- Actions
--------------------------------------------------------------

-- Execute one statement
step :: (D.Rel c v a s) => RSourceView c a -> IO Bool
step ref = do
    modifyIORef ref (\sv -> sv{svStackFrame = 0})
    -- save current state
    backup <- readIORef ref
    ok <- microstep ref
    if ok
       then do -- did we reach the next statement?
               action <- getIORef (locAct . currentLocLabel) ref
               case action of
                    ActNone -> step ref
                    _       -> do -- if we reached a pause statement, update PC and PID variables
                                  lab <- getIORef currentLocLabel ref
                                  when (isDelayLabel lab) $ completeTransition ref
                                  updateDisplays ref
                                  return True 
       else do -- rollback changes
               writeIORef ref backup
               updateDisplays ref
               return False



-- run until pause or nondeterministic choice
run :: (D.Rel c v a s) => RSourceView c a -> IO ()
run ref = do
    ok <- step ref
    lab <- getIORef currentLocLabel ref
    when (ok && (not $ isDelayLabel lab)) $ run ref


--------------------------------------------------------------
-- GUI components
--------------------------------------------------------------

-- Process selector --
processSelectorCreate :: RSourceView c a -> IO G.Widget
processSelectorCreate ref = do
    sv <- readIORef ref
    combo <- G.comboBoxNew
    G.widgetShow combo
    store <- G.treeStoreNew []
    rend <- G.cellRendererTextNew
    G.cellLayoutPackStart combo rend True
    G.cellLayoutSetAttributeFunc combo rend store $ 
        (\iter -> do path <- G.treeModelGetPath store iter
                     (pid, en) <- G.treeStoreGetValue store path
                     G.set rend [G.cellTextMarkup G.:= Just $ "<span weight=" ++ if en then "bold" else "normal" ++ ">" ++ last pid ++ "</span>"])
    writeIORef ref sv {svProcessCombo = combo, svProcessStore = store}
    _ <- G.on combo G.changed (processSelectorChanged ref)
    return $ G.toWidget combo

processSelectorChanged :: RSourceView c a -> IO ()
processSelectorChanged ref = do
    sv <- readIORef ref
    miter <- G.comboBoxGetActiveIter $ svProcessCombo sv
    when (isJust miter) $ 
        do path <- G.treeModelGetPath (svProcessStore sv) (fromJust miter)
           (pid, _) <- G.treeStoreGetValue (svProcessStore sv) path
           modifyIORef ref (\_sv -> _sv{svPID = pid})
           reset ref

processSelectorDisable :: RSourceView c a -> IO ()
processSelectorDisable ref = do
    combo <- getIORef svProcessCombo ref
    G.widgetSetSensitive combo False

processSelectorUpdate :: RSourceView c a -> IO ()
processSelectorUpdate ref = do
    sv <- readIORef ref
    let combo = svProcessCombo sv
        store = svProcessStore sv
        pidtree = map (procTree []) (specProc $ svSpec sv)
                  where procTree parpid p = Node { rootLabel = (pid, isProcEnabled sv pid)
                                                 , subForest = map (procTree pid) (procChildren p)}
                                            where pid = parpid ++ [procName p]
    G.treeStoreClear store
    G.treeStoreInsertForest store [] 0 pidtree 
    G.widgetSetSensitive combo True


-- Stack --
stackViewCreate :: RSourceView c a -> IO G.Widget
stackViewCreate ref = do
    view <- G.treeViewNew
    G.widgetShow view
    store <- G.listStoreNew []

    col <- G.treeViewColumnNew
    G.treeViewColumnSetTitle col "Stack frames"

    rend <- G.cellRendererTextNew
    G.cellLayoutPackStart col rend True
    G.cellLayoutSetAttributeFunc col rend store $ 
        (\iter -> do let idx = G.listStoreIterToIndex iter
                     frame <- G.listStoreGetValue store idx
                     G.set rend [G.cellTextMarkup G.:= Just $ show $ fScope frame])
    _ <- G.treeViewAppendColumn view col

    modifyIORef ref (\sv -> sv{svStackView = view, svStackStore = store, svStackFrame = 0})
    G.treeViewSetModel view store
    _ <- G.on view G.rowActivated (stackViewFrameSelected ref)
    return $ G.toWidget view

stackViewFrameSelected :: RSourceView c a -> G.TreePath -> G.TreeViewColumn -> IO ()
stackViewFrameSelected ref (idx:_) _ = do
    modifyIORef ref (\sv -> sv{svStackFrame = idx})
    sourceWindowUpdate ref
    watchUpdate ref

stackViewUpdate :: RSourceView c a -> IO ()
stackViewUpdate ref = do
    sv <- readIORef ref
    let store = svStackStore sv
    G.listStoreClear store
    _ <- mapM (G.listStoreAppend store) $ currentStack sv
    return ()

stackViewDisable :: RSourceView c a -> IO ()
stackViewDisable ref = do
    sv <- readIORef ref
    G.listStoreClear $ svStackStore sv

-- Trace --
traceViewCreate :: RSourceView c a -> IO G.Widget
traceViewCreate ref = do
    hbox <- G.hBoxNew False 0
    G.widgetShow hbox

    -- undo button
    undo <- G.toolButtonNewFromStock G.stockUndo
    G.widgetShow undo
    G.boxPackStart hbox undo G.PackNatural 0
    _ <- G.onToolButtonClicked undo (do modifyIORef ref (\sv -> traceSetPos sv (svTracePos sv - 1))
                                        updateDisplays ref)

    -- trace
    combo <- G.comboBoxNew
    G.widgetShow combo
    store <- G.listStoreNew []
    rend <- G.cellRendererTextNew
    G.cellLayoutPackStart combo rend True
    G.cellLayoutSetAttributeFunc combo rend store $ 
        (\iter -> do let storeidx = G.listStoreIterToIndex iter
                     idx  <- G.listStoreGetValue store storeidx
                     sv   <- readIORef ref
                     let txt = take 48 $ show $ replace "\n" " " $
                               case locAct $ getLocLabel sv idx of
                                    ActStat s -> show s
                                    ActExpr e -> show e
                                    _         -> "?"
                     G.set rend [G.cellTextMarkup G.:= Just $ "<span weight=" ++ if idx == svTracePos sv then "bold" else "normal" ++ ">" ++ txt ++ "</span>"])
    _ <- G.on combo G.changed (tracePosChanged ref)

    -- redo button
    redo <- G.toolButtonNewFromStock G.stockRedo
    G.widgetShow redo
    G.boxPackStart hbox redo G.PackNatural 0
    _ <- G.onToolButtonClicked redo (do modifyIORef ref (\sv -> traceSetPos sv (svTracePos sv + 1))
                                        updateDisplays ref)

    modifyIORef ref $ (\sv -> sv { svTraceStore = store
                                 , svTraceCombo = combo
                                 , svTraceUndo  = undo
                                 , svTraceRedo  = redo})

    return $ G.toWidget hbox

tracePosChanged :: RSourceView c a -> IO ()
tracePosChanged ref = do
    sv <- readIORef ref
    miter <- G.comboBoxGetActiveIter $ svTraceCombo sv
    when (isJust miter) $ 
        do let storeidx = G.listStoreIterToIndex $ fromJust miter
           p <- G.listStoreGetValue (svTraceStore sv) storeidx
           modifyIORef ref (\_sv -> traceSetPos _sv p)
           updateDisplays ref


traceViewDisable :: RSourceView c a -> IO ()
traceViewDisable ref = do
    sv <- readIORef ref
    G.listStoreClear $ svTraceStore sv
    G.widgetSetSensitive (svTraceUndo sv) False
    G.widgetSetSensitive (svTraceRedo sv) False
    G.widgetSetSensitive (svTraceCombo sv) False

traceViewUpdate :: RSourceView c a -> IO ()
traceViewUpdate ref = do
    sv <- readIORef ref
    -- update store
    G.listStoreClear $ svTraceStore sv
    _ <- mapM (G.listStoreAppend (svTraceStore sv) . snd) 
         $ filter (\(_,i) -> case locAct $ getLocLabel sv i of
                                  ActNone -> False
                                  _       -> True)
         $ zip (svTrace sv) [0..]

    -- set selection
    items <- G.listStoreToList (svTraceStore sv)
    case findIndex (svTracePos sv ==) items of
         Nothing -> G.comboBoxSetActive (svTraceCombo sv) (-1)
         Just i  -> G.comboBoxSetActive (svTraceCombo sv) i

    -- enable/disable buttons
    G.widgetSetSensitive (svTraceUndo sv) (svTracePos sv /= 0)
    G.widgetSetSensitive (svTraceRedo sv) (svTracePos sv /= length (svTrace sv) - 1)


traceAppend :: SourceView c a -> Store -> Stack -> SourceView c a
traceAppend sv store stack = sv {svTrace = tr, svTracePos = p}
    where tr = take (svTracePos sv + 1) (svTrace sv) ++ [TraceEntry stack store]
          p  = length tr - 1

traceSetPos :: SourceView c a -> Int -> SourceView c a
traceSetPos sv i | (i >= (length $ svTrace sv)) || (i < 0) = sv
                 | otherwise = sv {svTracePos = i}


-- Watch --

watchCreate :: RSourceView c a -> IO G.Widget
watchCreate ref = do
    view <- G.treeViewNew
    G.widgetShow view

    store <- G.listStoreNew [Nothing]

    namecol <- G.treeViewColumnNew
    G.treeViewColumnSetTitle namecol "Watch expression"

    exprend <- G.cellRendererTextNew
    G.cellLayoutPackStart namecol exprend False
    G.cellLayoutSetAttributeFunc namecol exprend store $ 
        (\iter -> do let idx = G.listStoreIterToIndex iter
                     mexp <- G.listStoreGetValue store idx
                     G.set exprend [ G.cellTextEditable G.:= True
                                   , G.cellTextMarkup   G.:= Just 
                                                             $ case mexp of 
                                                                    Nothing -> "<i>Add watch</i>"
                                                                    Just e  -> e])
    _ <- G.on exprend G.edited (\_ _ -> watchUpdate ref)
    _ <- G.treeViewAppendColumn view namecol

    valcol <- G.treeViewColumnNew
    G.treeViewColumnSetTitle valcol "Value"

    valrend <- G.cellRendererTextNew
    G.cellLayoutPackStart valcol valrend True
    G.cellLayoutSetAttributeFunc valcol valrend store $ 
        (\iter -> do sv@SourceView{..} <- readIORef ref
                     let idx = G.listStoreIterToIndex iter
                     mexp <- G.listStoreGetValue store idx
                     G.set valrend [G.cellTextMarkup G.:= Just 
                                                          $ case mexp of 
                                                                 Nothing  -> ""
                                                                 Just e -> case storeEvalStr svInputSpec svFlatSpec  
                                                                                             (currentStore sv) svPID (fScope $ currentStack sv !! svStackFrame) e of
                                                                                  Left er -> er
                                                                                  Right v -> show v])
    _ <- G.treeViewAppendColumn view valcol

    _ <- G.on view G.keyPressEvent (do key <- G.eventKeyVal
                                       when (key == G.keyFromName "Delete") $ liftIO $ watchDelete ref
                                       return True)
    modifyIORef ref (\sv -> sv{svWatchView = view, svWatchStore = store})

    G.treeViewSetModel view store
    return $ G.toWidget view

watchDelete :: RSourceView c a -> IO ()
watchDelete ref = do
    sv <- readIORef ref
    (idx:_, _) <- G.treeViewGetCursor (svWatchView sv)
    G.listStoreRemove (svWatchStore sv) idx
    watchUpdate ref

watchUpdate :: RSourceView c a -> IO ()
watchUpdate ref = do
    store <- getIORef svWatchStore ref
    items <- G.listStoreToList store
    -- make sure that there is an empty slot in the end
    let items' = (filter isJust items) ++ [Nothing]
    -- refill the list to force watch update
    G.listStoreClear store
    _ <- mapM (G.listStoreAppend store) items'
    return ()

watchDisable :: RSourceView c a -> IO ()
watchDisable _ = return ()


-- Source --
sourceWindowCreate :: RSourceView c a -> IO G.Widget
sourceWindowCreate ref = do
    view <- G.textViewNew
    G.widgetShow view
    tag <- G.textTagNew Nothing
    G.set tag [G.textTagBackground G.:= "grey"]
    modifyIORef ref (\sv -> sv {svSourceView = view, svSourceTag = tag})
    return $ G.toWidget view


sourceWindowUpdate :: RSourceView c a -> IO ()
sourceWindowUpdate ref = do
    sv <- readIORef ref
    let cfa = cfaAtFrame sv (svStackFrame sv)
        loc = fLoc $ (currentStack sv) !! (svStackFrame sv)
    case locAct $ cfaLocLabel loc cfa of
         ActNone   -> return ()
         ActExpr e -> sourceSetPos sv $ pos e
         ActStat s -> sourceSetPos sv $ pos s

sourceWindowDisable :: RSourceView c a -> IO ()
sourceWindowDisable _ = return ()

sourceSetPos :: SourceView c a -> Pos -> IO ()
sourceSetPos sv (from, to) = do
    let fname = sourceName from
    do src <- readFile fname
       buf <- G.textBufferNew Nothing
       G.textBufferSetText buf src
       G.textViewSetBuffer (svSourceView sv) buf
       istart <- G.textBufferGetStartIter buf
       iend <- G.textBufferGetEndIter buf
       ifrom <- G.textBufferGetIterAtLineOffset buf (sourceLine from) (sourceColumn from)
       ito <- G.textBufferGetIterAtLineOffset buf (sourceLine to) (sourceColumn to)
       G.textBufferRemoveTag buf (svSourceTag sv) istart iend
       G.textBufferApplyTag buf (svSourceTag sv) ifrom ito
       _ <- G.textViewScrollToIter (svSourceView sv) ifrom 0.5 Nothing
       return ()
    `catchIOError` (\_ -> return ())



-- Command buttons --
commandButtonsUpdate :: RSourceView c a -> IO ()
commandButtonsUpdate ref = do
    sv <- readIORef ref
    -- enable step and run buttons if we are not at a pause location or
    -- if we are in a pause location and the wait condition is true
    let lab = currentLocLabel sv
        en = case lab of
                  LInst _      -> True
                  LPause _ _ c -> storeEvalBool (currentStore sv) c == True
                  LFinal _ _   -> True
    G.widgetSetSensitive (svStepButton sv) en
    G.widgetSetSensitive (svRunButton sv) en

commandButtonsDisable :: RSourceView c a -> IO ()
commandButtonsDisable ref = do
    sv <- readIORef ref
    -- disable command buttons
    G.widgetSetSensitive (svStepButton sv) False
    G.widgetSetSensitive (svRunButton sv) False

-- Resolve --

resolveViewCreate :: RSourceView c a -> IO G.Widget
resolveViewCreate ref = do
    spec <- getIORef svSpec ref
    let ?spec = spec

    view <- G.treeViewNew
    G.widgetShow view
    store <- G.treeStoreNew []

    -- Variable name column
    namecol <- G.treeViewColumnNew
    G.treeViewColumnSetTitle namecol "Variables"

    namerend <- G.cellRendererTextNew
    G.cellLayoutPackStart namecol namerend False
    G.cellLayoutSetAttributeFunc namecol namerend store $ 
        (\iter -> do sv   <- readIORef ref
                     path <- G.treeModelGetPath store iter
                     e    <- G.treeStoreGetValue store path
                     let hl = isNothing $ storeTryEval (currentStore sv) e
                     G.set namerend [G.cellTextMarkup G.:= Just $ if' hl ("<span background=\"red\">" ++ show e ++ "</span>") (show e)])
    _ <- G.treeViewAppendColumn view namecol

    -- Variable assignment column
    valcol <- G.treeViewColumnNew
    G.treeViewColumnSetTitle valcol "Value"

    textrend <- G.cellRendererTextNew
    G.cellLayoutPackStart valcol textrend True
    G.cellLayoutSetAttributeFunc valcol textrend store $ 
        (\iter -> do sv   <- readIORef ref
                     path <- G.treeModelGetPath store iter
                     e    <- G.treeStoreGetValue store path
                     G.set textrend [ G.cellVisible      G.:= isTypeInt e
                                    , G.cellTextEditable G.:= True
                                    , G.cellText         G.:= show $ storeEval (currentStore sv) e])
    _ <- G.on textrend G.edited (textAsnChanged ref)

    combrend <- G.cellRendererComboNew
    G.cellLayoutPackStart valcol combrend True
    G.cellLayoutSetAttributeFunc valcol combrend store $ 
        (\iter -> do sv     <- readIORef ref
                     path   <- G.treeModelGetPath store iter
                     e      <- G.treeStoreGetValue store path
                     tmodel <- comboTextModel $ typ e
                     G.set combrend [ G.cellVisible        G.:= isTypeScalar e && not (isTypeInt e)
                                    , G.cellComboTextModel G.:= (tmodel, G.makeColumnIdString 0)
                                    , G.cellTextEditable   G.:= True
                                    , G.cellText           G.:= show $ storeEval (currentStore sv) e])
    _ <- G.on combrend G.edited (textAsnChanged ref) 

    _ <- G.treeViewAppendColumn view valcol
    modifyIORef ref (\sv -> sv {svResolveStore = store})
    return $ G.toWidget view

comboTextModel :: (?spec::Spec) => Type -> IO (G.ListStore String)
comboTextModel Bool     = G.listStoreNew ["*", "True", "False"]
comboTextModel (Enum n) = G.listStoreNew ("*": (enumEnums $ getEnumeration n))

textAsnChanged :: RSourceView c a -> G.TreePath -> String -> IO ()
textAsnChanged ref path valstr = do
    sv  <- readIORef ref
    let ?spec = svSpec sv
    e   <- G.treeStoreGetValue (svResolveStore sv) path
    val <- if valstr == "*"
              then return Nothing
              else case parseVal (typ e) valstr of
                        Left er -> do showMessage ref G.MessageError er
                                      return Nothing
                        Right v -> return $ Just $ SVal v
    writeIORef ref $ modifyCurrentStore sv (\store -> storeSet store e val)
    resolveViewUpdate ref

resolveViewUpdate :: RSourceView c a -> IO ()
resolveViewUpdate ref = do
    sv <- readIORef ref
    let ?spec = svSpec sv
    let -- collect tmp variables from all transitions from the current location
        trans = map snd $ Graph.lsuc (currentCFA sv) (currentLoc sv)
        exprs = map (mkTree . EVar . varName)
                $ filter ((== VarTmp) . varCat)
                $ nub        
                $ concatMap (\t -> case t of
                                        TranStat (SAssume e)   -> exprVars e
                                        TranStat (SAssign _ e) -> exprVars e
                                        _                      -> []) 
                $ trans
        -- expand expression into a tree of scalars
        mkTree e = Node { rootLabel = e
                        , subForest = map mkTree 
                                      $ case typ e of
                                             Struct fs  -> map (\(Field n _) -> EField e n) fs
                                             Array _ sz -> map (EIndex e . EConst . UIntVal 32 . fromIntegral) [0..sz-1]
                                             _            -> []
                          }
    let store = svResolveStore sv
    G.treeStoreClear store
    G.treeStoreInsertForest store [] 0 exprs


resolveViewDisable :: RSourceView c a -> IO ()
resolveViewDisable ref = do
    sv <- readIORef ref
    G.treeStoreClear $ svResolveStore sv

-- Controllable action selector --

actionSelectorCreate :: (D.Rel c v a s) => RSourceView c a -> IO G.Widget
actionSelectorCreate ref = do
    vbox <- G.vBoxNew False 0
    G.widgetShow vbox

    -- Text view for specifying controllable action
    tview <- G.textViewNew
    G.textViewSetEditable tview True
    G.widgetShow tview
    G.boxPackStart vbox tview G.PackGrow 0

    bbox <- G.hButtonBoxNew
    G.widgetShow bbox
    G.boxPackStart vbox bbox G.PackNatural 0

    -- Exit magic block button
    bexit <- G.buttonNewWithLabel "Exit Magic Block"
    G.widgetShow bexit
    G.containerAdd bbox bexit
    _ <- G.on bexit G.buttonActivated (actionSelectorExit ref)

    -- Add transition button
    badd <- G.buttonNewWithLabel "Perform controllable action"
    G.widgetShow badd
    G.containerAdd bbox badd
    _ <- G.on badd G.buttonActivated (actionSelectorRun ref)

    modifyIORef ref (\sv -> sv { svActSelectText  = tview
                               , svActSelectBExit = bexit
                               , svActSelectBAdd  = badd})
    actionSelectorDisable ref
    return $ G.toWidget vbox

actionSelectorRun :: RSourceView c a -> IO ()
actionSelectorRun ref = do
    sv@SourceView{..} <- readIORef ref
    buf <- G.textViewGetBuffer svActSelectText
    text <- G.get buf G.textBufferText
    let fname = hash text
        fpath = "/tmp/" ++ show fname
    case compileControllableAction svInputSpec svFlatSpec svPID (fScope $ head $ currentStack sv) text fpath of
         Left e    -> showMessage ref G.MessageError e
         Right cfa -> do writeFile fpath text
                         runControllableCFA ref cfa

actionSelectorExit :: (D.Rel c v a s) => RSourceView c a -> IO ()
actionSelectorExit ref = do
    modifyIORef ref (\sv -> modifyCurrentStore sv (\st0 -> let st1 = storeSet st0 mkMagicVar (Just $ SVal $ BoolVal False)
                                                               st2 = storeSet st1 mkContVar  (Just $ SVal $ BoolVal False)
                                                           in st2))
    completeTransition ref

runControllableCFA :: RSourceView c a -> CFA -> IO ()
runControllableCFA ref cfa = do
    -- Push controllable cfa on the stack
    modifyIORef ref (\sv -> let stack = currentStack sv
                                stack' = (FrameInteractive (fScope $ head stack) cfaInitLoc cfa) : stack
                            in traceAppend sv (currentStore sv) stack')
    updateDisplays ref

actionSelectorUpdate :: RSourceView c a -> IO ()
actionSelectorUpdate ref = do
    sv <- readIORef ref
    if currentControllable sv && (isWaitForMagicLabel $ currentLocLabel sv)
       then actionSelectorEnable ref
       else actionSelectorDisable ref

actionSelectorDisable :: RSourceView c a -> IO ()
actionSelectorDisable ref = do
    SourceView{..} <- readIORef ref
    G.widgetSetSensitive svActSelectBExit False
    G.widgetSetSensitive svActSelectBAdd  False

actionSelectorEnable :: RSourceView c a -> IO ()
actionSelectorEnable ref = do
    SourceView{..} <- readIORef ref
    G.widgetSetSensitive svActSelectBExit True
    G.widgetSetSensitive svActSelectBAdd  True


--------------------------------------------------------------
-- Private helpers
--------------------------------------------------------------

isWaitForMagicLabel :: LocLabel -> Bool
isWaitForMagicLabel (LPause _ _ e) = isWaitForMagic e
isWaitForMagicLabel _              = False

-- Given a snapshot of the store at a pause location, compute
-- process stack.
stackFromStore :: SourceView c a -> Store -> PID -> Stack
stackFromStore sv s pid = stackFromStore' sv s pid Nothing

stackFromStore' :: SourceView c a -> Store -> PID -> Maybe String -> Stack
stackFromStore' sv s pid methname = stack' ++ stack
    where cfa   = specGetCFA (svSpec sv) pid methname
          loc   = storeGetLoc s pid methname
          lab   = cfaLocLabel loc cfa
          stack = locStack lab
          -- If this location corresponds to a task call, recurse into task's CFA
          stack' = case lab of 
                        LPause _ _ e -> case isWaitForTask e of
                                             Nothing  -> if isWaitForMagic e
                                                            then let t = getTag s
                                                                 in if' (t==mkTagIdle) []
                                                                    $ stackFromStore' sv s [] (Just t)
                                                            else []
                                             Just nam -> stackFromStore' sv s pid (Just nam)
                        _            -> []

-- Extract the last controllable or uncontrollable task call 
-- from the stack or return Nothing if the stack does not 
-- contain a task call
stackTask :: Stack -> Int -> Maybe Front.Method
stackTask stack frame = stackTask' $ drop frame stack

stackTask' :: Stack -> Maybe Front.Method
stackTask' []      = Nothing
stackTask' (fr:st) = case fScope fr of
                          Front.ScopeMethod _ m -> if Front.methCat m == Front.Task Front.Uncontrollable 
                                                      then Just m
                                                      else stackTask' st
                          _               -> stackTask' st

storeGetLoc :: Store -> PID -> Maybe String -> Loc
storeGetLoc s pid methname = pcEnumToLoc pc
    where pcvar = mkPCVar $ pid ++ maybeToList methname
          pc    = storeEvalEnum s pcvar

getTag :: Store -> String
getTag s = storeEvalEnum s mkTagVar

isProcEnabled :: SourceView c a -> PID -> Bool
isProcEnabled sv pid = 
    let store = fromJust $ D.sConcrete $ svState sv
        stack = stackFromStore sv store pid
        frame = head stack
        cfa   = stackGetCFA sv pid stack
        lab   = cfaLocLabel (fLoc frame) cfa
    in case svTranPID sv of
            Just pid' -> pid' == pid
            _         -> -- In a controllable state, the process is enabled if it is
                         -- currently inside a magic block
                         -- In an uncontrollable state, the process is enabled if its
                         -- pause condition holds
                         if currentControllable sv
                            then case lab of
                                      LPause _ _ cond -> cond == mkMagicDoneCond
                                      _               -> False
                            else case lab of
                                      LPause _ _ cond -> storeEvalBool store cond == True
                                      _               -> True

-- update all displays
updateDisplays :: RSourceView c a -> IO ()
updateDisplays ref = do
    commandButtonsUpdate ref
    stackViewUpdate      ref
    traceViewUpdate      ref
    watchUpdate          ref
    sourceWindowUpdate   ref
    resolveViewUpdate    ref
    actionSelectorUpdate ref

-- Reset all components
reset :: RSourceView c a -> IO ()
reset ref = do
    processSelectorUpdate ref
    sv <- readIORef ref
    -- initialise stack and trace
    let tr = [TraceEntry { teStack = stackFromStore sv (fromJust $ D.sConcrete $ svState sv) (svPID sv)
                         , teStore = storeUnion (fromJust $ D.sConcrete $ svState sv) (svTmp sv)}]
    writeIORef ref sv{svTrace = tr, svTracePos = 0, svStackFrame = 0}
    updateDisplays ref

-- Disable all controls
disable :: RSourceView c a -> IO ()
disable ref = do
    -- disable process selector
    processSelectorDisable ref
    -- disable other displays
    commandButtonsDisable  ref
    sourceWindowDisable    ref
    stackViewDisable       ref
    traceViewDisable       ref
    watchDisable           ref
    resolveViewDisable     ref
    actionSelectorDisable  ref

-- Access current location in the trace 

currentCFA :: SourceView c a -> CFA
currentCFA sv = getCFA sv (svTracePos sv)

currentLoc :: SourceView c a -> Loc
currentLoc sv = getLoc sv (svTracePos sv)

currentLocLabel :: SourceView c a -> LocLabel
currentLocLabel sv = getLocLabel sv (svTracePos sv)

currentStore :: SourceView c a -> Store
currentStore sv = getStore sv (svTracePos sv)

modifyStore :: SourceView c a -> Int -> (Store -> Store) -> SourceView c a
modifyStore sv idx f = sv {svTrace = tr'}
    where tr     = svTrace sv
          entry  = tr !! idx
          entry' = entry {teStore = (f $ teStore entry)}
          tr'    = take idx tr ++ [entry'] ++ drop (idx+1) tr

modifyCurrentStore :: SourceView c a -> (Store -> Store) -> SourceView c a
modifyCurrentStore sv f = modifyStore sv (svTracePos sv) f

currentStack :: SourceView c a -> Stack
currentStack sv = getStack sv (svTracePos sv)

currentControllable :: SourceView c a -> Bool
currentControllable sv = storeEvalBool (currentStore sv) (EVar mkContVarName)

cfaAtFrame :: SourceView c a -> Int -> CFA
cfaAtFrame sv frame = stackGetCFA sv (svPID sv) (drop frame $ currentStack sv)

-- Access arbitrary location in the trace 

getCFA :: SourceView c a -> Int -> CFA
getCFA sv p = stackGetCFA sv (svPID sv) (getStack sv p)

stackGetCFA :: SourceView c a -> PID -> Stack -> CFA
stackGetCFA sv pid ((FrameStatic (Front.ScopeMethod _ m) _):_) | Front.methCat m == Front.Task Front.Controllable   = specGetCFA (svSpec sv) pid (Just $ sname m)
                                                               | Front.methCat m == Front.Task Front.Uncontrollable = specGetCFA (svSpec sv) pid (Just $ sname m) 
stackGetCFA _  _   ((FrameInteractive _ _ cfa):_)                                                                   = cfa
stackGetCFA sv pid (_:stack)                                                                                        = stackGetCFA sv pid stack
        

getLoc :: SourceView c a -> Int -> Loc
getLoc sv p = fLoc $ head $ getStack sv p

getLocLabel :: SourceView c a -> Int -> LocLabel
getLocLabel sv p = cfaLocLabel (getLoc sv p) (getCFA sv p)

getStore :: SourceView c a -> Int -> Store
getStore sv p = teStore $ svTrace sv !! p

getStack :: SourceView c a -> Int -> Stack
getStack sv p = teStack $ svTrace sv !! p

-- Execute one CFA transition
-- Returns True if the step was performed successfully and
-- False otherwise (i.e., the user did not provide values
-- for nondeterministic arguments)
microstep :: RSourceView c a -> IO Bool
microstep ref = do
    sv <- readIORef ref
    -- Try all transitions from the current location; choose the first successful one
    let transitions = Graph.lsuc (currentCFA sv) (currentLoc sv)
    case mapMaybe (microstep' sv) transitions of
         []               -> return False
         (store, stack):_ -> do writeIORef ref $ traceAppend sv store stack
                                return True

microstep' :: SourceView c a -> (Loc, TranLabel) -> Maybe (Store, Stack)
microstep' sv (to, TranCall meth)          = let ?spec = svFlatSpec sv
                                             in Just (currentStore sv, (FrameStatic (Front.ScopeMethod tmMain meth) to) : currentStack sv)
microstep' sv (_ , TranReturn)             = Just (currentStore sv, tail $ currentStack sv)
microstep' sv (to, TranNop)                = Just (currentStore sv, (head $ currentStack sv){fLoc = to} : (tail $ currentStack sv))
microstep' sv (to, TranStat (SAssume e))   = if storeEvalBool (currentStore sv) e == True
                                                then Just (currentStore sv, (head $ currentStack sv){fLoc = to} : (tail $ currentStack sv))
                                                else Nothing
microstep' sv (to, TranStat (SAssign l r)) = Just (store', (head $ currentStack sv){fLoc = to} : (tail $ currentStack sv))
                                             where store' = storeSet (currentStore sv) l (storeTryEval (currentStore sv) r)

-- Actions taken upon reaching a delay location
completeTransition :: (D.Rel c v a s) => RSourceView c a -> IO ()
completeTransition ref = do
    sv    <- readIORef ref
    model <- readIORef $ svModel sv
    let ?spec    = svSpec sv
        ?absvars = svAbsVars sv
        ?model   = model
        ?m       = D.mCtx model
    -- update PC and PID variables
    let pc = currentLoc sv
        mmeth = fmap sname $ stackTask (currentStack sv) 0
        pid = svPID sv ++ (maybeToList mmeth)
        sv' = setPC pid pc $ setPID pid sv
    writeIORef ref sv'
    -- abstract final state
    let trans = D.abstractTransition (svState sv') (currentStore sv')
    -- add transition
    D.modelSelectTransition (svModel sv') trans
    D.modelSelectState (svModel sv') (Just $ D.tranTo trans)

setPID :: PID -> SourceView c a -> SourceView c a
setPID pid sv = modifyCurrentStore sv (\s -> storeSet s mkPIDVar (Just $ SVal $ EnumVal $ mkPIDEnumeratorName pid))
    
setPC :: PID -> Loc -> SourceView c a -> SourceView c a
setPC pid pcloc sv = modifyCurrentStore sv (\s -> storeSet s (mkPCVar pid) (Just $ SVal $ EnumVal $ mkPCEnum pid pcloc))

-- Evaluate expression written in terms of variables in the original input spec.
storeEvalStr :: Front.Spec -> Front.Spec -> Store -> PID -> Front.Scope -> String -> Either String Store
storeEvalStr inspec flatspec store pid sc str = do
    -- Apply all transformations that the input spec goes through to the expression:
    -- 1. parse
    expr <- case parse Parse.detexpr "" str of
                 Left  e  -> Left $ show e
                 Right ex -> Right ex
    let (scope, iid) = flatScopeToScope inspec sc
    -- 2. validate
    let ?spec  = inspec
    Front.validateExpr scope expr
    let ?scope = scope
        in when (not $ Front.exprNoSideEffects expr) $ throwError "Expression has side effects"
    -- 3. flatten
    let flatexpr = Front.exprFlatten iid scope expr
    -- 4. simplify
    let ?spec = flatspec
    let (ss, simpexpr) = let ?scope = sc
                         in evalState (Front.exprSimplify flatexpr) (0,[])
    when (not $ null ss) $ throwError "Expression too complex"
    -- 5. inline
    let lmap = scopeLMap pid sc
    let ctx = CFACtx { ctxPID     = pid
                     , ctxStack   = [(sc, error "evalStr: return", Nothing, lmap)]
                     , ctxCFA     = error "evalStr: CFA undefined"
                     , ctxBrkLocs = []
                     , ctxGNMap   = globalNMap
                     , ctxLastVar = 0
                     , ctxVar     = []}
        iexpr = evalState (Front.exprToIExprDet simpexpr) ctx
    -- 6. evaluate
    return $ storeEval store iexpr

compileControllableAction :: Front.Spec -> Front.Spec -> PID -> Front.Scope -> String -> FilePath -> Either String CFA
compileControllableAction inspec flatspec pid sc str fname = do
    -- Apply all transformations that the input spec goes through to the statement:
    -- 1. parse
    stat <- liftM (Front.sSeq nopos)
            $ case parse Parse.statements fname str of
                   Left  e  -> Left $ show e
                   Right st -> Right st
    let (scope,iid) = flatScopeToScope inspec sc
    -- 2. validate
    let ?spec = inspec
    Front.validateStat scope stat
    validateControllableStat scope stat
    -- 3. flatten
    let flatstat = Front.statFlatten iid scope stat
    -- 4. simplify
    let ?spec = flatspec
    let (simpstat, (_, vars)) = let ?scope = sc
                                in runState (Front.statSimplify flatstat) (0,[])
    assert (null vars) (pos stat) "Statement too complex"
    -- add return after the statement to pop FrameInteractive off the stack
    let simpstat' = Front.sSeq nopos [simpstat, Front.SReturn nopos Nothing]
    -- 5. inline
    let ctx = CFACtx { ctxPID     = pid
                     , ctxStack   = []
                     , ctxCFA     = newCFA sc simpstat true
                     , ctxBrkLocs = []
                     , ctxGNMap   = globalNMap
                     , ctxLastVar = 0
                     , ctxVar     = []}
        ctx' = let ?procs =[] in execState (do -- create final state and make it the return location
                                               retloc <- ctxInsLocLab (LFinal ActNone [])
                                               ctxPushScope sc retloc Nothing (scopeLMap pid sc)
                                               Front.procStatToCFA True simpstat' cfaInitLoc) ctx
    assert (null $ ctxVar ctx') (pos stat) "Cannot perform non-deterministic controllable action"
    -- Prune the resulting CFA beyond the first pause location; add a return transition in the end
    let cfa   = ctxCFA ctx'
        reach = cfaReachInst cfa cfaInitLoc
        cfa'  = cfaPrune cfa (S.insert cfaInitLoc reach)
    assert (Graph.noNodes cfa == Graph.noNodes cfa') (pos stat) "Controllable action must be an instantaneous statement"
    return cfa'
    
-- Check whether statement specifies a valid controllable action:
-- * Function, procedure, and controllable task calls only
-- * No fork statements
-- * No variable declarations
-- * No pause or stop statements
-- * No assert or assume
-- * No magic blocks
validateControllableStat :: (?spec::Front.Spec) => Front.Scope -> Front.Statement -> Either String ()
validateControllableStat sc stat = do
    _ <- mapM (\(p,(_,m)) -> do assert (Front.methCat m /= Front.Task Front.Uncontrollable) p "Uncontrollable task invocations are not allowed inside controllable actions"
                                assert (Front.methCat m /= Front.Task Front.Invisible)      p "Invisible task invocations are not allowed inside controllable actions")
         $ Front.statCallees sc stat
    _ <- Front.mapStatM (\_ st -> case st of
                                       Front.SVarDecl p _ -> err p "Variable declarations are not allowed inside controllable actions"
                                       Front.SReturn  p _ -> err p "Return statements are not allowed inside controllable actions"
                                       Front.SPar     p _ -> err p "Fork statements are not allowed inside controllable actions"
                                       Front.SPause   p   -> err p "Pause statements are not allowed inside controllable actions"
                                       Front.SWait    p _ -> err p "Wait statements are not allowed inside controllable actions"
                                       Front.SStop    p   -> err p "Stop statements are not allowed inside controllable actions"
                                       Front.SAssert  p _ -> err p "Assertions are not allowed inside controllable actions"
                                       Front.SAssume  p _ -> err p "Assume statements are not allowed inside controllable actions"
                                       Front.SMagic   p _ -> err p "Magic blocks are not allowed inside controllable actions"
                                       _                  -> return st) sc stat
    return ()

flatScopeToScope :: Front.Spec -> Front.Scope -> (Front.Scope, Front.IID)
flatScopeToScope inspec sc = 
    let ?spec = inspec in
    case sc of
         Front.ScopeMethod   _ meth -> let (i, mname) = Front.itreeParseName $ name meth
                                           tm = Front.itreeTemplate i
                                           meth' = fromJust $ find ((== mname) . Front.methName) $ Front.tmAllMethod tm
                                       in (Front.ScopeMethod tm meth', i)
         Front.ScopeProcess  _ proc -> let (i, pname) = Front.itreeParseName $ name proc
                                           tm = Front.itreeTemplate i
                                           proc' = fromJust $ find ((== pname) . Front.procName) $ Front.tmAllProcess tm
                                       in (Front.ScopeProcess tm proc', i)
         Front.ScopeTemplate _      -> (Front.ScopeTop, [])

-- Create a store with all tmp variables assigned according to their values 
-- in the transition
tranTmpStore :: SourceView c a -> D.Transition a Store -> Store
tranTmpStore sv tran = 
    storeUnions $ map (\v -> SStruct $ M.singleton (varName v) (storeEval tstore (EVar $ varName v)))
                $ specTmpVar $ svSpec sv
    where tstore = fromJust $ D.tranConcreteLabel tran

-- Message boxes
showMessage :: RSourceView c a -> G.MessageType -> String -> IO ()
showMessage _ mtype mtext = do
    dialog <- G.messageDialogNew Nothing [G.DialogModal] mtype G.ButtonsOk mtext
    _ <- G.onResponse dialog (\_ -> G.widgetDestroy dialog)
    G.windowPresent dialog
