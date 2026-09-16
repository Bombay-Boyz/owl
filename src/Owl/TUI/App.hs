-- | The brick layer (master spec §23) -- and deliberately the
-- thinnest module in the TUI.
--
-- Everything this module does is translation: vty key -> our own
-- UserInput, call the already-tested pure applyInput, fold the
-- returned domain Events through Owl.Application.Apply.apply, and
-- turn a Doc into brick Widgets. There is no mail logic here, no
-- screen logic, and no decision this module could get wrong that is
-- not already covered by a test in Owl.TUI.CoreSpec or
-- Owl.TUI.ViewSpec. That is the whole point of §23's insistence that
-- "command and view are pure": the untestable part is kept small
-- enough to read in one sitting.
--
-- Verified against brick-2.13's own source rather than memory, since
-- brick 2.x changed appHandleEvent from returning the next state to
-- the state-monadic EventM n s () shape -- writing against the 1.x
-- form from recollection would have failed exactly the way hoauth2's
-- API drift did earlier in this project.
module Owl.TUI.App
  ( AppState (..)
  , ResourceName (..)
  , owlApp
  , runTUI
  ) where

import Brick
  ( App (..)
  , AttrMap
  , AttrName
  , BrickEvent (VtyEvent)
  , EventM
  , Widget
  , attrMap
  , attrName
  , defaultMain
  , hBox
  , halt
  , padBottom
  , txt
  , vBox
  , withAttr
  )
import Brick.Util (on)
import Brick.Widgets.Core (Padding (Max))
import Control.Monad.State.Class (get, put)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as V

import Owl.Application (Application)
import Owl.Application.Apply (apply)
import Owl.TUI.Core
import Owl.TUI.View

-- | brick requires an Ord instance for resource names. One pane is
-- enough today; adding more is a one-line change when the thread and
-- compose screens grow their own scrollable regions.
data ResourceName = InboxPane
  deriving stock (Eq, Ord, Show)

-- | The domain state and the UI state, side by side and never merged
-- -- §11/§23's own separation, preserved right up to the top level.
data AppState = AppState
  { stateApplication :: !Application
  , stateUI          :: !UIState
  }

owlApp :: App AppState e ResourceName
owlApp = App
  { appDraw         = drawApp
  , appChooseCursor = \_ _ -> Nothing
  , appHandleEvent  = handleEvent
  , appStartEvent   = pure ()
  , appAttrMap      = const owlAttrMap
  }

runTUI :: Application -> IO AppState
runTUI app = defaultMain owlApp (AppState app initialUIState)

-- ---------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------

drawApp :: AppState -> [Widget ResourceName]
drawApp st = [body <=> statusBar]
  where
    (<=>) a b = vBox [padBottom Max a, b]

    ui  = stateUI st
    app = stateApplication st

    body = case uiScreen ui of
      InboxScreen  -> docToWidget (renderInbox (inboxViewOf st))
      SearchScreen -> docToWidget (renderInbox (inboxViewOf st))
      HelpScreen   -> docToWidget (renderHelp helpSubject)
      ThreadScreen tid -> docToWidget (renderThread (buildThreadView app tid (uiCursor ui)))
      ComposeScreen  -> placeholder "Compose is not built yet."
      ContactScreen  -> placeholder "Contacts are not built yet."

    -- §23 says "? renders only the bindings valid for the current
    -- screen". Read literally on the help screen itself that would
    -- list only "back" -- true, but useless. The bindings a reader
    -- actually wants are those of the screen they pressed ? on, which
    -- is precisely what uiPreviousScreen holds.
    helpSubject = fromMaybe (uiScreen ui) (uiPreviousScreen ui)

    placeholder t = withAttr dimAttr (txt t)

    -- While a buffer is open the status line IS the input line: it
    -- shows what has been typed so far, so there is never a moment
    -- where keystrokes are being captured with no visible evidence.
    statusBar = case uiTextEntry ui of
      Just entry -> withAttr selectedAttr (txt (promptFor entry <> entryText entry <> "_"))
      Nothing    -> withAttr dimAttr (txt (fromMaybe defaultStatus (uiStatusMessage ui)))

    promptFor entry = case entryPurpose entry of
      SearchEntry  -> "Search: "
      ComposeEntry -> "Compose: "

    defaultStatus = "? help   s search   q back/quit   j/k move   Enter open"

inboxViewOf :: AppState -> InboxView
inboxViewOf st = buildInboxView
  (stateApplication st)
  (uiScrollOffset (stateUI st))
  defaultViewportRows
  (uiCursor (stateUI st))

docToWidget :: Doc -> Widget ResourceName
docToWidget d = vBox (map lineToWidget (docLines d))
  where
    lineToWidget (DocLine spans) = hBox (map spanToWidget spans)
    spanToWidget (DocSpan t e)   = withAttr (emphasisAttr e) (txt t)

emphasisAttr :: Emphasis -> AttrName
emphasisAttr = \case
  Normal   -> attrName "normal"
  Unread   -> unreadAttr
  Selected -> selectedAttr
  Dim      -> dimAttr

unreadAttr, selectedAttr, dimAttr :: AttrName
unreadAttr   = attrName "unread"
selectedAttr = attrName "selected"
dimAttr      = attrName "dim"

owlAttrMap :: AttrMap
owlAttrMap = attrMap V.defAttr
  [ (unreadAttr,        V.defAttr `V.withStyle` V.bold)
  , (selectedAttr,      V.black `on` V.white)
  , (dimAttr,           V.defAttr `V.withStyle` V.dim)
  , (attrName "normal", V.defAttr)
  ]

-- ---------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------

handleEvent :: BrickEvent ResourceName e -> EventM ResourceName AppState ()
handleEvent (VtyEvent (V.EvKey key _modifiers)) =
  case translateKey key of
    Nothing    -> pure ()   -- a key we have no vocabulary for: ignore.
    Just input -> do
      st <- get
      case applyInput (stateApplication st) (stateUI st) input of
        Left err -> put st { stateUI = (stateUI st)
                              { uiStatusMessage = Just (describeCommandError err) } }
        Right Exit -> halt
        Right (Continue nextUI events) ->
          -- Domain events are applied in order, and a DomainError
          -- stops the fold rather than being swallowed: a keypress
          -- that the domain rejects must say so, not silently appear
          -- to work. The UI state still advances, so the message is
          -- visible rather than the screen freezing.
          case foldl' step (Right (stateApplication st)) events of
            Left domainErr -> put st
              { stateUI = nextUI { uiStatusMessage = Just (Text.pack (show domainErr)) } }
            Right nextApp -> put AppState
              { stateApplication = nextApp
              , stateUI          = nextUI
              }
  where
    step acc ev = acc >>= apply ev
handleEvent _ = pure ()

translateKey :: V.Key -> Maybe UserInput
translateKey = \case
  V.KChar c -> Just (KeyChar c)
  V.KEnter  -> Just KeyEnter
  V.KEsc    -> Just KeyEsc
  V.KUp     -> Just KeyUp
  V.KDown   -> Just KeyDown
  V.KBS     -> Just KeyBackspace
  _         -> Nothing

-- | Errors are shown to the reader, never swallowed -- §23: a command
-- outside the current screen's vocabulary is "never silently ignored".
describeCommandError :: CommandError -> Text
describeCommandError = \case
  UnboundInput input _ -> "No binding for " <> Text.pack (show input) <> " on this screen."
  CommandRejected (CommandNotValidForScreen tag _) ->
    Text.pack (show tag) <> " is not available on this screen."
  CommandRejected NoScreenToReturnTo -> "Nowhere to go back to."
  NoSelectionUnderCursor -> "Nothing selected."
