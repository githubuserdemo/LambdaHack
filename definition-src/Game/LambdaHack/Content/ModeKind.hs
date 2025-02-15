{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving #-}
-- | The type of kinds of game modes.
module Game.LambdaHack.Content.ModeKind
  ( pattern CAMPAIGN_SCENARIO, pattern INSERT_COIN, pattern NO_CONFIRMS
  , ModeKind(..), makeData
  , Caves, Roster(..), TeamContinuity(..), Outcome(..)
  , HiCondPoly, HiSummand, HiPolynomial, HiIndeterminant(..)
  , Player(..), AutoLeader(..)
  , teamExplorer, victoryOutcomes, deafeatOutcomes, nameOutcomePast
  , nameOutcomeVerb, endMessageOutcome, screensave
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , validateSingle, validateAll
  , validateSingleRoster, validateSinglePlayer, mandatoryGroups
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Data.Binary
import qualified Data.Text as T
import           GHC.Generics (Generic)

import           Game.LambdaHack.Content.CaveKind (CaveKind)
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Core.Dice as Dice
import qualified Game.LambdaHack.Definition.Ability as Ability
import           Game.LambdaHack.Definition.ContentData
import           Game.LambdaHack.Definition.Defs
import           Game.LambdaHack.Definition.DefsInternal

-- | Game mode specification.
data ModeKind = ModeKind
  { msymbol   :: Char            -- ^ a symbol
  , mname     :: Text            -- ^ short description
  , mfreq     :: Freqs ModeKind  -- ^ frequency within groups
  , mtutorial :: Bool            -- ^ whether to show tutorial messages, etc.
  , mroster   :: Roster          -- ^ players taking part in the game
  , mcaves    :: Caves           -- ^ arena of the game
  , mendMsg   :: [(Outcome, Text)]
      -- ^ messages displayed at each particular game ends; if message empty,
      --   the screen is skipped
  , mrules    :: Text            -- ^ rules note
  , mdesc     :: Text            -- ^ description
  , mreason   :: Text            -- ^ why/when the mode should be played
  , mhint     :: Text            -- ^ hints in case player faces difficulties
  }
  deriving Show

-- | Requested cave groups for particular level intervals.
type Caves = [([Int], [GroupName CaveKind])]

-- | The specification of players for the game mode.
data Roster = Roster
  { rosterList  :: [( Player
                    , Maybe TeamContinuity
                    , [(Int, Dice.Dice, GroupName ItemKind)] )]
      -- ^ players in the particular team and levels, numbers and groups
      --   of their initial members
  , rosterEnemy :: [(Text, Text)]  -- ^ the initial enmity matrix
  , rosterAlly  :: [(Text, Text)]  -- ^ the initial aliance matrix
  }
  deriving Show

-- | Team continuity index. Starting with 1, lower than 100.
newtype TeamContinuity = TeamContinuity Int
  deriving (Show, Eq, Ord, Enum, Generic)

instance Binary TeamContinuity

-- | Outcome of a game.
data Outcome =
    Escape    -- ^ the player escaped the dungeon alive
  | Conquer   -- ^ the player won by eliminating all rivals
  | Defeated  -- ^ the faction lost the game in another way
  | Killed    -- ^ the faction was eliminated
  | Restart   -- ^ game is restarted; the quitter quit
  | Camping   -- ^ game is supended
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance Binary Outcome

-- | Conditional polynomial representing score calculation for this player.
type HiCondPoly = [HiSummand]

type HiSummand = (HiPolynomial, [Outcome])

type HiPolynomial = [(HiIndeterminant, Double)]

data HiIndeterminant =
    HiConst
  | HiLoot
  | HiSprint
  | HiBlitz
  | HiSurvival
  | HiKill
  | HiLoss
  deriving (Show, Eq, Generic)

instance Binary HiIndeterminant

-- | Properties of a particular player.
data Player = Player
  { fname        :: Text        -- ^ name of the player
  , fgroups      :: [GroupName ItemKind]
                                -- ^ names of actor groups that may naturally
                                --   fall under player's control, e.g., upon
                                --   spawning or summoning
  , fskillsOther :: Ability.Skills
                                -- ^ fixed skill modifiers to the non-leader
                                --   actors; also summed with skills implied
                                --   by @fdoctrine@ (which is not fixed)
  , fcanEscape   :: Bool        -- ^ the player can escape the dungeon
  , fneverEmpty  :: Bool        -- ^ the faction declared killed if no actors
  , fhiCondPoly  :: HiCondPoly  -- ^ score polynomial for the player
  , fhasGender   :: Bool        -- ^ whether actors have gender
  , fdoctrine    :: Ability.Doctrine
                                -- ^ non-leaders behave according to this
                                --   doctrine; can be changed during the game
  , fleaderMode  :: Maybe AutoLeader
                                -- ^ whether the faction can have a leader
                                --   and what's its switching mode;
  , fhasUI       :: Bool        -- ^ does the faction have a UI client
                                --   (for control or passive observation)
  , funderAI     :: Bool        -- ^ is the faction under AI control
  }
  deriving (Show, Eq, Generic)

instance Binary Player

data AutoLeader = AutoLeader
  { autoDungeon :: Bool
      -- ^ leader switching between levels is automatically done by the server
      --   and client is not permitted to change to leaders from other levels
      --   (the frequency of leader level switching done by the server
      --   is controlled by @RuleKind.rleadLevelClips@);
      --   if the flag is @False@, server still does a subset
      --   of the automatic switching, e.g., when the old leader dies
      --   and no other actor of the faction resides on his level,
      --   but the client (particularly UI) is expected to do changes as well
  , autoLevel   :: Bool
      -- ^ client is discouraged from leader switching (e.g., because
      --   non-leader actors have the same skills as leader);
      --   server is guaranteed to switch leader within a level very rarely,
      --   e.g., when the old leader dies;
      --   if the flag is @False@, server still does a subset
      --   of the automatic switching, but the client is expected to do more,
      --   because it's advantageous for that kind of a faction
  }
  deriving (Show, Eq, Generic)

instance Binary AutoLeader

teamExplorer :: TeamContinuity
teamExplorer = TeamContinuity 1

victoryOutcomes :: [Outcome]
victoryOutcomes = [Escape, Conquer]

deafeatOutcomes :: [Outcome]
deafeatOutcomes = [Defeated, Killed, Restart]

nameOutcomePast :: Outcome -> Text
nameOutcomePast = \case
  Escape   -> "emerged victorious"
  Conquer  -> "vanquished all opposition"
  Defeated -> "got decisively defeated"
  Killed   -> "got eliminated"
  Restart  -> "resigned prematurely"
  Camping  -> "set camp"

nameOutcomeVerb :: Outcome -> Text
nameOutcomeVerb = \case
  Escape   -> "emerge victorious"
  Conquer  -> "vanquish all opposition"
  Defeated -> "be decisively defeated"
  Killed   -> "be eliminated"
  Restart  -> "resign prematurely"
  Camping  -> "set camp"

endMessageOutcome :: Outcome -> Text
endMessageOutcome = \case
  Escape   -> "Can it be done more efficiently, though?"
  Conquer  -> "Can it be done in a better style, though?"
  Defeated -> "Let's hope your new overlords let you live."
  Killed   -> "Let's hope a rescue party arrives in time!"
  Restart  -> "This time for real."
  Camping  -> "See you soon, stronger and braver!"

screensave :: AutoLeader -> ModeKind -> ModeKind
screensave auto mk =
  let f x@(Player{funderAI=True}, _, _) = x
      f (player, teamContinuity, initial) =
          ( player { funderAI = True
                   , fleaderMode = Just auto }
          , teamContinuity
          , initial )
  in mk { mroster = (mroster mk) {rosterList = map f $ rosterList $ mroster mk}
        , mreason = "This is one of the screensaver scenarios, not available from the main menu, with all factions controlled by AI. Feel free to take over or relinquish control at any moment, but to register a legitimate high score, choose a standard scenario instead.\n" <> mreason mk
        }

-- | Catch invalid game mode kind definitions.
validateSingle :: ModeKind -> [Text]
validateSingle ModeKind{..} =
  [ "mname longer than 20" | T.length mname > 20 ]
  ++ let f cave@(ns, l) =
           [ "not enough or too many levels for required cave groups:"
             <+> tshow cave
           | length ns /= length l ]
     in concatMap f mcaves
  ++ validateSingleRoster mcaves mroster

-- | Checks, in particular, that there is at least one faction with fneverEmpty
-- or the game would get stuck as soon as the dungeon is devoid of actors.
validateSingleRoster :: Caves -> Roster -> [Text]
validateSingleRoster caves Roster{..} =
  [ "no player keeps the dungeon alive"
  | all (\(pl, _, _) -> not $ fneverEmpty pl) rosterList ]
  ++ [ "not exactly one UI client"
     | length (filter (\(pl, _, _) -> fhasUI pl) rosterList) /= 1 ]
  ++ let tokens = mapMaybe (\(_, tc, _) -> tc) rosterList
         nubTokens = nub $ sort tokens
     in [ "duplicate team continuity token"
        | length tokens /= length nubTokens ]
  ++ concatMap (\(pl, _, _) -> validateSinglePlayer pl) rosterList
  ++ let checkPl field plName =
           [ plName <+> "is not a player name in" <+> field
           | all (\(pl, _, _) -> fname pl /= plName) rosterList ]
         checkDipl field (pl1, pl2) =
           [ "self-diplomacy in" <+> field | pl1 == pl2 ]
           ++ checkPl field pl1
           ++ checkPl field pl2
     in concatMap (checkDipl "rosterEnemy") rosterEnemy
        ++ concatMap (checkDipl "rosterAlly") rosterAlly
  ++ let keys = concatMap fst caves
         minD = minimum keys
         maxD = maximum keys
         f (_, _, l) = concatMap g l
         g i3@(ln, _, _) =
           [ "initial actor levels not among caves:" <+> tshow i3
           | ln `notElem` keys ]
     in concatMap f rosterList
        ++ [ "player confused by both positive and negative level numbers"
           | signum minD /= signum maxD ]
        ++ [ "player confused by level numer zero"
           | any (== 0) keys ]

validateSinglePlayer :: Player -> [Text]
validateSinglePlayer Player{..} =
  [ "fname empty:" <+> fname | T.null fname ]
  ++ [ "fskillsOther not negative:" <+> fname
     | any ((>= 0) . snd) $ Ability.skillsToList fskillsOther ]

-- | Validate game mode kinds together.
validateAll :: [ModeKind] -> ContentData ModeKind -> [Text]
validateAll _ _ = []  -- so far, always valid

-- * Mandatory item groups

mandatoryGroups :: [GroupName ModeKind]
mandatoryGroups =
       [CAMPAIGN_SCENARIO, INSERT_COIN]

pattern CAMPAIGN_SCENARIO, INSERT_COIN :: GroupName ModeKind

pattern CAMPAIGN_SCENARIO = GroupName "campaign scenario"
pattern INSERT_COIN = GroupName "insert coin"

-- * Optional item groups

pattern NO_CONFIRMS :: GroupName ModeKind

pattern NO_CONFIRMS = GroupName "no confirms"

makeData :: [ModeKind] -> [GroupName ModeKind] -> [GroupName ModeKind]
         -> ContentData ModeKind
makeData content groupNamesSingleton groupNames =
  makeContentData "ModeKind" mname mfreq validateSingle validateAll content
                  groupNamesSingleton
                  (mandatoryGroups ++ groupNames)
