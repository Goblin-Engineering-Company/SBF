-- Help.lua — the SINGLE reloadable source of all SBF help content, addressed by STRING KEY.
-- Both the mouseover tooltips and the (future) help window call SBF.GetHelp("key"):
--   * tooltips render `title` + `body` as plain text (GameTooltip = text + |cff|r colour, no HTML)
--   * the help window renders longer markdown `body` text via the MD->SimpleHTML converter
--     (see docs/wow-addons/markdown-in-simplehtml.md for what markdown survives).
-- Pure .lua: edit + /reload updates everything. (Adding this file to SBF.toc needs ONE client
-- restart the first time; after that it is reload-only.)
local _ = ...
SBF = SBF or {}

SBF.Help = {
  -- ===== Settings: Fishing behavior =====
  ["set.sitBeforeCast"] = { title = "Sit before each cast",
    body = "Sits your character before every cast. A few fishing setups want this; most don't need it." },
  ["set.autoDismount"] = { title = "Auto-dismount to fish",
    body = "When you're on a GROUND mount, the loop dismounts so it can fish. It never dismounts while flying or gliding." },
  ["set.castBackoff"] = { title = "Cast-fail back-off",
    body = "After a cast that misses the water (\"too shallow\" / \"requires fishable water\"), the loop waits this many seconds before retrying, so it doesn't hammer a dead spot." },
  ["set.mouseDouble"] = { title = "Double-click window (sec)",
    body = "How fast the two presses must be to count as a double-click for mouse double-click fishing "
      .. "(turned on with \"Use mouse (double-click)\" in Settings \226\134\146 Interface options). Lower = you must double-click "
      .. "faster; higher = more forgiving but slower single clicks may register as doubles. Default 0.40s." },

  ["set.useMouse"] = { title = "Mouse double-click fishing",
    body = "Double-click the chosen mouse button to fish (and, in two-button mode, a button to loot). "
      .. "A lone single click is never affected. Works OUT OF COMBAT ONLY (override bindings can't be armed "
      .. "in combat). Pick the mouse buttons on the Keybinds tab; tune the speed beside this row (or /sbf mouse)." },
  ["set.twoButton"] = { title = "Two-button mode",
    body = "Off: one Action does both \226\128\148 it casts, then the same key/button loots while the line is out.\n"
      .. "On: the Action only casts; a SEPARATE Loot / Interact key (and mouse button) loots. This is the single "
      .. "switch for whether a separate loot button exists, for keyboard and mouse alike." },

  ["set.gamepadEnable"] = { title = "Enable controller (gamepad) support",
    body = "Lets you fish with a game controller. Ticking this turns on WoW's gamepad support so controller "
      .. "buttons act like keys: click any \"Set key\" button in SBF, then press a controller button to bind "
      .. "it (e.g. bind A to your one fishing button). A /reload may be needed the first time for WoW to "
      .. "pick it up. Unticking leaves WoW's gamepad setting alone (in case you use the controller elsewhere). "
      .. "Type /sbf controller for the full setup guide." },

  ["set.fastLoot"] = { title = "Ultra fast loot  (grab everything instantly, no loot window)",
    body = "Replaces the game's built-in auto-loot with a fast, silent looter: it grabs everything off a "
      .. "corpse/node/catch with no loot window popping up, and keeps up even at low framerate (the built-in "
      .. "auto-loot can drop items when your FPS dips). The normal loot window still appears on its own when "
      .. "it needs you \226\128\148 a locked slot, an item above your group's loot-quality threshold, a "
      .. "bind-on-pickup confirm, or full bags \226\128\148 so nothing is ever silently lost." },

  ["set.gatherLoot"] = { title = "Log gathered loot (chests & containers)",
    body = "Logs the loot you get from OPENING a container \226\128\148 a Midnight special chest, a fished-up "
      .. "openable \226\128\148 as a \"GATHERED\" line in the Log, separate from your fishing catches. Only "
      .. "loot opened OUTSIDE a fishing cast counts (your normal catches stay \"CAUGHT\"), and only world "
      .. "objects/containers (not creature loot \226\128\148 that\226\128\153s Haul\226\128\153s job). Off = these "
      .. "openings aren\226\128\153t recorded." },

  -- ===== Settings: Profiles (location auto-swap) =====
  ["set.advancedMode"] = { title = "Profile advanced mode",
    body = "Off = a single simple setup (hides profiles, zone binding, and save/revert; your edits save "
      .. "automatically). On = multiple profiles that auto-swap by location, with per-zone binding and "
      .. "Save/Revert." },
  ["set.autoSwap"] = { title = "Auto-swap profiles by location",
    body = "When you change zones, SBF automatically activates the profile bound to where you are "
      .. "(most specific match wins: sub-zone, then zone, then region; otherwise the default profile). "
      .. "Turn off to only ever switch profiles by hand." },
  ["set.swapFlash"] = { title = "Flash on profile swap",
    body = "When a location auto-swap activates a different profile, briefly flash its name on screen "
      .. "(as a raid-warning) so you know which setup is now active. Has no effect on manual switches." },

  -- ===== Settings: Gear =====
  ["set.idleRestore"] = { title = "Auto-restore gear when idle",
    body = "When you stop fishing for this many seconds (no action-key press), automatically re-equip the "
      .. "gear you had on before the profile gear went on. Your next action press re-equips the profile "
      .. "gear. Off by default; the seconds field sets the idle threshold." },

  -- ===== Settings: Audio (focus) =====
  ["set.focusAudio"] = { title = "Focus fishing",
    body = "While fishing, mute music/ambience and isolate the bobber splash; restores your normal audio "
      .. "when you stop. Use \"Audio settings\226\128\166\" to set the exact levels SBF switches to." },

  -- ===== Settings: Item pickers =====
  ["set.showUnownedToys"] = { title = "Show toys I don't own",
    body = "Show toys you haven't collected yet in the picker strip (greyed out). Turn off to only see what you own." },
  ["set.showUnownedItems"] = { title = "Show items not in my bags",
    body = "Show items you aren't currently carrying in the picker strip (greyed out). Turn off to only see what's in your bags." },
  ["set.showWarbandItems"] = { title = "Show Warband items",
    body = "Show account-wide collectibles you OWN (toys, account boats) as available options in the slot pickers — on by default. Turn this off (and the \"show I don't own\" toggles) to hide everything you haven't explicitly set, so only items you drag into a slot are used. Useful when you want a character to start from scratch." },

  -- ===== Settings: Audio =====
  ["set.castSound"] = { title = "Fishing-start sound",
    body = "Play a sound when a cast goes out. Pick the sound from the dropdown; Test previews it." },
  ["set.castFailSound"] = { title = "Cast-fail sound",
    body = "Play a sound when a cast fails (too shallow / not fishable water)." },
  ["set.noFishSound"] = { title = "No-fish-hooked sound",
    body = "Play a sound on \"No fish are hooked\" — you pulled the line too early or too late and got "
      .. "nothing (a MISSED bite). Different from cast-fail (can't cast there at all) and from a cast that "
      .. "just runs its full length with no bite (expired)." },
  ["set.expiredSound"] = { title = "Expired-cast sound",
    body = "Play a sound when a cast EXPIRES \226\128\148 the line ran its full length and nothing ever bit. "
      .. "This is the normal \"nothing biting here\" outcome, distinct from a cast-fail (couldn't cast there at "
      .. "all) and from \"no fish hooked\" (a real bite you pulled too early or too late)." },
  ["set.prSound"] = { title = "Patiently Rewarded sound",
    body = "Play a sound the moment the named buff appears on you (once per appearance). The buff name "
      .. "is editable in case it's localised or renamed — defaults to \"Patiently Rewarded\"." },

  -- ===== Settings: Visuals =====
  ["set.bgAlpha"] = { title = "Window opacity",
    body = "How see-through this window's background is. 100% = fully solid." },

  -- ===== Settings: Debugging =====
  ["set.debug"] = { title = "Debug log",
    body = "Prints verbose state, the macro built on each button press, and a short note naming each "
      .. "action as it fires, to chat. For troubleshooting." },
  ["set.footing"] = { title = "Footing debug panel",
    body = "Opens the live state panel showing every signal the loop reads (also /sbf footing)." },

}

-- Look up a help entry by key. Returns { title, body } or nil.
function SBF.GetHelp(key) return (key and SBF.Help and SBF.Help[key]) or nil end
