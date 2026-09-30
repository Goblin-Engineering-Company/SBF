-- Gear.lua — equipment-set + fishing-pole swapping for profiles, plus the gear snapshot/restore used by
-- the "Restore normal gear" action and the idle timer. Equipping is only legal out of combat; callers
-- guard with InCombatLockdown() and defer via PLAYER_REGEN_ENABLED.
local _, ns = ...
-- Forever (interface 16001) ships the modern API WITHOUT the deprecated item globals; alias them to C_Item
-- file-locally (never write _G, so other addons' own version checks are untouched). Retail: unchanged.
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
local GetItemCount = GetItemCount or (C_Item and C_Item.GetItemCount)
local EquipItemByName = EquipItemByName or (C_Item and C_Item.EquipItemByName)
SBF = SBF or {}

-- ---- per-character gear state ----
-- The gear snapshot + "in fishing gear" flag are PER-CHARACTER (a snapshot's item links only make sense on
-- the char they were taken on — restoring them on another char could equip items it doesn't have). Keyed by
-- name-realm under SBFDB.charGear. CharGear() returns this char's { snapshot=<slot->link>, on=<bool> } table.
local function charKey()
  return SBF.CharKey()
end
function SBF.CharGear()
  local k = charKey()
  SBFDB.charGear = SBFDB.charGear or {}
  SBFDB.charGear[k] = SBFDB.charGear[k] or {}
  return SBFDB.charGear[k]
end

-- Where the fishing pole lives on THIS client. Retail: the fishing profession-TOOL slot (SBFDB.poleSlot, 28).
-- WoW: Forever (interface 16001) and every Classic client have no profession tool slots at all: the pole is a
-- two-handed WEAPON in the main hand (16). Keyed on the interface number, not WOW_PROJECT_ID, because Forever
-- reports the mainline project id. Every pole read/equip/lure line goes through this one function.
local CLASSIC_GEAR = ((GetBuildInfo and (select(4, GetBuildInfo()))) or 120100) < 100000
local INVSLOT_MH = INVSLOT_MAINHAND or 16
SBF.CLASSIC_GEAR = CLASSIC_GEAR
function SBF.PoleSlot()
  if CLASSIC_GEAR then return INVSLOT_MH end
  return SBFDB.poleSlot or 28
end

-- The fishing pole currently equipped, or nil. Reads the dedicated fishing-tool slot first (SBF.PoleSlot();
-- slot 28 in current content, where the pole is profession equipment). Falls back to scanning all 19 worn
-- slots for a Fishing Pole weapon (weapon classID 2 / subClassID 20) for older content where the pole sits
-- in the main-hand slot.
function SBF.EquippedPole()
  local id = GetInventoryItemID("player", SBF.PoleSlot())
  if id and not CLASSIC_GEAR then return id end   -- classic main hand holds ANY weapon: fall through to the type check
  for s = 1, 19 do
    local iid = GetInventoryItemID("player", s)
    if iid then
      local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(iid)
      if classID == 2 and subClassID == 20 then return iid end   -- Weapon / Fishing Pole
    end
  end
  return nil
end

-- Keep the ACTIVE profile's pole in step with the pole you are actually wearing (slot 28, or a fishing pole in
-- a weapon slot). Writes straight to the saved config — this is a DEFAULT, not a user edit, so it must not mark
-- the profile dirty — and syncs the working copy so the pole box and the change-diff agree.
--
-- This used to be fill-only: `if pg.pole then return end`. That looked conservative and was actively harmful,
-- because `pg.pole` stops meaning "the pole you chose" the moment it is set. It is written automatically the
-- first time a profile is touched, and `ProfileGear` ownership-checks it only at CREATION (Profiles.lua:203),
-- never again — so the very first pole a character ever held outranks reality forever. Diagnosed live: slot 28
-- held 6365 while the profile was pinned to 6256, a pole the user did not even recognise. And the profile pole
-- is what SBF EQUIPS when you start fishing, so the stale value was actively swapping a better pole OUT on
-- every cast. Silent, permanent, and invisible in the UI because the box just shows the old id.
--
-- THE RULE: the PROFILE always wins. This only ever fills an EMPTY pole slot — it never replaces a pole the
-- profile already has, even if you're wearing a different one. That matters because profiles are per-location:
-- sitting in Default with your everyday pole on, then switching to a profile that uses a special pole, must not
-- let the worn pole overwrite that profile's pick. An earlier revision preferred the equipped pole and
-- announced the swap; that was wrong for exactly this case and is gone.
--
-- There is NO exception and no clearing of any kind: see the fill-only note at the `if current then return`
-- below. Setting `autoAddPole = false` turns the fill off entirely.
-- RETAIL ONLY (2026-09-30). The retail pole lives in its own tool slot and rarely changes, so an empty box adopting
-- it is exactly what a new player wants. WoW: Forever's pole is a main-hand weapon you may carry several of, so there
-- the box is only ever what the player put in it (or the pole saved in the gear set, AdoptSetPole). And once the
-- player CLEARS the box themselves (poleCleared, set by the right-click clear), it stays empty. Returns the pole.
function SBF.AutoPopulatePole()
  if CLASSIC_GEAR or SBFDB.autoAddPole == false then return nil end
  local id = SBF.Store().activeProfile
  if not id then return end
  local pg = SBF.ProfileGear(id)
  local equipped = SBF.EquippedPole()
  -- Compare against what the user can SEE. The working copy is the live, possibly-unsaved edit that the pole
  -- box renders; the saved config is only what was last written. Right-clicking the box calls setPole(nil),
  -- which clears WORKING and leaves pg.pole intact — so reading pg alone said "already in step with your
  -- equipped pole" while the box sat visibly empty and no pole ever got equipped. Checking the saved copy for
  -- a UI state that lives in the working copy is the whole bug.
  local live = (SBF.working and SBF.working.id == id) and SBF.working or nil
  -- `(live and live.pole) or pg.pole` was WRONG and defeated the whole fix: when the working copy exists with
  -- pole = nil — exactly the state right-click-clear produces — Lua falls straight through to the stale saved
  -- id, so the cleared box read as "already set" and never refilled. If a working copy exists it IS the answer,
  -- nil included. Only fall back to the saved config when there is no working copy at all.
  local current
  if live then current = live.pole else current = pg.pole end

  -- NO DEAD-ID DELETION. An earlier revision cleared a stored pole that GetItemCount couldn't find, which is
  -- an unattended destructive write running 2s after every login — and GetItemCount(id, true) does not see the
  -- WARBAND bank, so a pole parked there reads as "gone" and the profile's pick gets destroyed. A pole you
  -- cannot currently reach is still your choice; the cost of keeping it is a pinned slot you can right-click
  -- to clear, which is strictly better than silently losing it. Fill-only, per "the profile always wins".
  if current then return nil end                -- THE PROFILE WINS: a real pole is set, leave it alone
  if (live and live.poleCleared) or (not live and pg.poleCleared) then return nil end   -- the player emptied it
  if not equipped then return nil end           -- slot empty but nothing worn to adopt: nothing to do

  pg.pole = equipped
  if live then live.pole = equipped end         -- keep the live working copy (and the box) in sync
  if SBF.RefreshOptions then SBF.RefreshOptions() end
  return equipped
end

-- The profile's pole box is empty but its GEAR SET holds a fishing pole: that pole is the player's choice, so adopt it
-- into the box (2026-09-30). Forever/Classic: a Fishing Pole in the set's main hand; retail: whatever the set saved in
-- the fishing tool slot. Only a pole the character owns, and only when the box is EMPTY (the box always wins).
-- Written like the old auto-fill: straight to the saved profile + the working copy, so it doesn't mark the profile
-- dirty. Returns the adopted pole id, or nil. Called on the action press, just before the gear gate.
function SBF.AdoptSetPole()
  local w = SBF.working
  if not (w and w.equipSet and not w.pole and not w.poleCleared and C_EquipmentSet) then return nil end   -- cleared on purpose
  local id = C_EquipmentSet.GetEquipmentSetID(w.equipSet)
  local ids = id and C_EquipmentSet.GetItemIDs and C_EquipmentSet.GetItemIDs(id)
  if not ids then return nil end
  local pole = ids[SBF.PoleSlot()]
  if type(pole) ~= "number" or pole <= 1 then return nil end
  if CLASSIC_GEAR and select(7, GetItemInfoInstant(pole)) ~= 20 then return nil end   -- a sword in the set: not a pole
  local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(pole)) or (GetItemCount and GetItemCount(pole)) or 0
  if have == 0 then return nil end
  local pid = SBF.Store and SBF.Store().activeProfile
  -- the saved profile too, but never under unsaved edits (Save / Revert then decide, as for any other change)
  if pid and pid == w.id and not w.dirty and SBF.ProfileGear then SBF.ProfileGear(pid).pole = pole end
  w.pole = pole
  print(("|cff45c4a0SBF|r Using the fishing pole from gear set |cffffd100%s|r for profile |cffffd100%s|r."):format(
    w.equipSet, w.name or "?"))
  if SBF.RefreshOptions then SBF.RefreshOptions() end
  return pole
end

-- The profile has no pole set: say so ONCE per session per profile (chat), so the player knows to drag the pole
-- they want into the Profile page's pole box. SBF then equips no pole at all (whatever is worn stays on).
local poleNoted = {}
function SBF.NoteMissingPole()
  if not CLASSIC_GEAR then return end            -- retail: the tool slot's pole stays on, nothing to warn about
  local w = SBF.working
  if not w or w.pole then return end
  local key = w.id or "?"
  if poleNoted[key] then return end
  poleNoted[key] = true
  print(("|cff45c4a0SBF|r Profile |cffffd100%s|r has no fishing pole set, so SBF won't equip one. Open |cffffd100/sbf|r, "
    .. "Profile page, and drag the pole you want to fish with into the Fishing pole box."):format(w.name or "?"))
end

-- ---- focus fishing audio (reconfigure WoW's sound while fishing) ----
-- Snapshot → apply the "focus" preset (isolate the bobber splash: full master/SFX, mute music/ambience/
-- dialog) → restore, parallel to the gear lifecycle and stored per-character in CharGear() (.audioSnapshot
-- + .audioOn). CVars aren't protected, so reads/writes are safe out of AND in combat — no defer needed.
-- Each entry: { cvar, key, kind } where kind "vol" = a 0..1 volume, "tog" = a 0/1 enable toggle.
local AUDIO_CVARS = {
  { cvar = "Sound_MasterVolume",   key = "master",        kind = "vol" },
  { cvar = "Sound_SFXVolume",      key = "sfx",           kind = "vol" },
  { cvar = "Sound_MusicVolume",    key = "music",         kind = "vol" },
  { cvar = "Sound_AmbienceVolume", key = "ambience",      kind = "vol" },
  { cvar = "Sound_DialogVolume",   key = "dialog",        kind = "vol" },
  { cvar = "Sound_EnableMusic",    key = "enableMusic",   kind = "tog" },
  { cvar = "Sound_EnableAmbience", key = "enableAmbience",kind = "tog" },
}
ns.AUDIO_CVARS = AUDIO_CVARS

local function setCVarSafe(cvar, value) pcall(SetCVar, cvar, value) end
local function getCVarSafe(cvar) local ok, v = pcall(GetCVar, cvar); return ok and v or nil end

-- write ONE focusAudio field to its CVar in the live "focus" form (vol -> "0".."1" string, tog -> "0"/"1").
-- Used both by ApplyFocusAudio and by the live-edit path (sliders re-apply when focus audio is already on).
function SBF.SetFocusCVar(key, value)
  for _, e in ipairs(AUDIO_CVARS) do
    if e.key == key then
      if e.kind == "vol" then setCVarSafe(e.cvar, tostring(value or 0))
      else setCVarSafe(e.cvar, (value and "1") or "0") end
      return
    end
  end
end

-- Snapshot all 7 CVars (so RestoreAudio puts the player's originals back, enables included) then apply the
-- focus preset: the 5 volumes from focusAudio.*, and FORCE Sound_EnableMusic/EnableAmbience to "1" so the
-- volume sliders are the single control (music/ambience volume 0 = silent; with enable off you'd hear
-- nothing regardless of the slider). This is the shared "apply the preset to live CVars" body, used by
-- ApplyFocusAudio (real, on-fish) AND the settings-popup preview.
local function applyPresetCVars(fa)
  for _, e in ipairs(AUDIO_CVARS) do
    if e.kind == "vol" then setCVarSafe(e.cvar, tostring(fa[e.key] or 0))
    else setCVarSafe(e.cvar, "1") end           -- always enable music + ambience; volume is the control
  end
end
SBF._applyPresetCVars = applyPresetCVars        -- the preview path (Options.lua) reuses this

-- Snapshot the player's current 7 CVars into CharGear().audioSnapshot. Shared by ApplyFocusAudio and the
-- popup preview so both restore from the same captured originals.
local function snapshotAudio()
  local snap = {}
  for _, e in ipairs(AUDIO_CVARS) do snap[e.cvar] = getCVarSafe(e.cvar) end
  SBF.CharGear().audioSnapshot = snap
end
SBF._snapshotAudio = snapshotAudio

-- Restore the player's captured CVars (the originals) — used by RestoreAudio and the popup preview-close.
local function restoreAudioCVars()
  local snap = SBF.CharGear().audioSnapshot
  if snap then for cvar, v in pairs(snap) do if v ~= nil then setCVarSafe(cvar, v) end end end
end
SBF._restoreAudioCVars = restoreAudioCVars

function SBF.ApplyFocusAudio()
  local fa = SBFDB.focusAudio; if not (fa and fa.enabled) then return end
  if SBF._emEditing then return end          -- skip while editing in the Equipment Manager (consistency w/ gear)
  local cg = SBF.CharGear(); if cg.audioOn then return end
  -- If the settings popup is previewing, the snapshot already holds the player's ORIGINALS (taken before
  -- the preview). Don't re-snapshot the preview state — just promote preview into the real applied state.
  if not SBF._audioPreview then snapshotAudio() end
  SBF._audioPreview = nil                     -- a real apply supersedes any preview
  applyPresetCVars(fa)
  cg.audioOn = true
end

function SBF.RestoreAudio()
  local cg = SBF.CharGear(); if not cg.audioOn then return end
  restoreAudioCVars()
  cg.audioOn = false
end

-- ---- bobber reach (the interact key's range while fishing) ----
-- The interact key only soft-targets objects inside SoftTargetInteractRange (about 10yd by default), and a bobber lands
-- 15-20yd out, so on WoW: Forever most far casts couldn't be reeled with the key. Raised while fishing, restored with the
-- rest of "back to normal" (snapshot in SBFDB.reachState, see below). SBFDB.bobberReach = yards
-- to apply; nil = REACH_DEFAULT on classic-layout clients and 0 (leave the player's setting alone) on retail.
-- 60, not 20: measured 2026-09-25 at range 20, half of all casts (25 of 49) were never targetable, while every
-- reachable one was targetable at the first check (+1.0s), so the cutoff was distance, not timing. The client
-- accepts 60 and reached most casts there; Reach.lua handles the rest.
local REACH_DEFAULT = 60
local function reachYards()
  local v = SBFDB.bobberReach
  if v == 20 and not SBFDB._reachDefault60 then v = nil; SBFDB.bobberReach = nil end   -- one-time: the old ticked 20
  SBFDB._reachDefault60 = true
  if v == nil then v = CLASSIC_GEAR and REACH_DEFAULT or 0 end
  return tonumber(v) or 0
end
function SBF.ReachYards() return reachYards() end
-- SoftTargetInteractRange is a CLIENT-WIDE setting that the game saves to its config file, so the applied flag and
-- the player's own value live at ACCOUNT scope ({ on, snap } in SBFDB.reachState), never per character: a per-
-- character flag let an alt see "not applied", snapshot the raised value as the player's own, and put the raised
-- value back on every restore (QC 2026-09-29). The snapshot is never our own value: if the setting already reads
-- what we'd apply and we have no record of the player's, the game default is what goes back.
local function reachState()
  local r = SBFDB.reachState
  if not r then
    r = {}
    SBFDB.reachState = r
    local cg = SBF.CharGear and SBF.CharGear()           -- one-time move from the old per-character fields
    if cg and cg.reachOn then r.on = true; r.snap = cg.reachSnapshot end
  end
  local cg = SBF.CharGear and SBF.CharGear()
  if cg then cg.reachOn, cg.reachSnapshot = nil, nil end
  return r
end
SBF.ReachState = reachState
local function reachDefault()
  local d = C_CVar and C_CVar.GetCVarDefault and C_CVar.GetCVarDefault("SoftTargetInteractRange")
  return d or "10"
end
-- Checks the LIVE setting on every call, never just the saved flag: anything that resets the setting (another
-- addon, the game's own options) would otherwise leave SBF fishing at the short default range.
function SBF.ApplyBobberReach()
  local want = reachYards()
  if want <= 0 then return end
  local r = reachState()
  local cur = getCVarSafe("SoftTargetInteractRange")
  if r.on and tonumber(cur) == want then return end
  if not r.on then
    if tonumber(cur) ~= want then r.snap = cur                               -- the player's own value
    elseif r.snap == nil or tonumber(r.snap) == want then r.snap = reachDefault() end   -- already raised: never keep ours
  end
  setCVarSafe("SoftTargetInteractRange", tostring(want))
  r.on = true
end
-- ---- fishing camera zoom (Forever / Classic) ----
-- The interact key only targets what the CAMERA can see, so a player zoomed all the way in (first person) or
-- looking at their feet reads every far cast as out of reach. While fishing, SBF zooms the camera out to at least
-- SBFDB.reachZoom (camera distance; nil = REACH_ZOOM_DEFAULT on classic-layout clients, 0 = off, retail off), and
-- puts the zoom back when fishing stops. Only ever zooms OUT (never pulls a wider camera in). Zoom is reliable to
-- drive (GetCameraZoom + CameraZoomOut/In return to the exact distance). The snapshot is session-only on purpose:
-- zoom doesn't survive a relog, so a saved snapshot would "restore" a stale distance at the next login.
local REACH_ZOOM_DEFAULT = 8
local function zoomTarget()
  local v = SBFDB.reachZoom
  if v == nil then v = CLASSIC_GEAR and REACH_ZOOM_DEFAULT or 0 end
  return tonumber(v) or 0
end
function SBF.ReachZoom() return zoomTarget() end
-- OPTIONAL "face forward" (SBFDB.reachFaceView, off by default): on every cast press (the flag resets when a cast
-- ends, in Core's channel-stop handler, so moving the camera mid-cast is corrected on the next cast), reset one of WoW's saved
-- camera views (SBFDB.reachViewSlot, default 5) to the game default and switch to it. Saved views are relative to
-- the character, so the camera lands behind you looking straight ahead at a normal distance, whatever angle it had.
-- It overwrites that view slot, which is why it's opt-in. Stopping restores the zoom distance as usual; from first
-- person that returns you to first person facing forward, so the old angle doesn't matter.
function SBF.ApplyFishingZoom()
  if not (GetCameraZoom and CameraZoomOut) then return end
  if SBFDB.reachFaceView and CLASSIC_GEAR and not SBF._faceViewDone and SetView and ResetView then
    if SBF._zoomSnap == nil then SBF._zoomSnap = GetCameraZoom() or 0 end   -- before the view changes the distance
    local slot = tonumber(SBFDB.reachViewSlot) or 5
    ResetView(slot)
    SetView(slot)
    SBF._faceViewDone = true
    return                                                  -- the view glides in; the zoom floor applies next press
  end
  local want = zoomTarget()
  if want <= 0 then return end
  local cur = GetCameraZoom() or 0
  if cur >= want - 0.05 then return end
  if SBF._zoomSnap == nil then SBF._zoomSnap = cur end      -- the player's own distance, taken once per fishing run
  CameraZoomOut(want - cur)
end
function SBF.RestoreFishingZoom()
  SBF._faceViewDone = nil                                   -- next fishing run faces forward again
  local snap = SBF._zoomSnap
  if snap == nil then return end
  SBF._zoomSnap = nil
  if not (GetCameraZoom and CameraZoomIn) then return end
  local d = (GetCameraZoom() or 0) - snap
  if d > 0.05 then CameraZoomIn(d) end                      -- back to the exact distance they had
end

-- `keepFlag` = put the player's value back but remember that SBF applied it (logout: if the client dies before the
-- setting is saved, the next login still knows to restore).
function SBF.RestoreBobberReach(keepFlag)
  local r = reachState(); if not r.on then return end
  setCVarSafe("SoftTargetInteractRange", r.snap or reachDefault())
  if not keepFlag then r.on = false end
end

-- Is anything fishing-related applied right now (gear, focus audio, interact reach, camera zoom)? The ONE predicate
-- the idle observer and the login/reload handling share, so a new applied state is added here only.
function SBF.FishingStateApplied()
  local cg = SBF.CharGear and SBF.CharGear()
  return (cg and (cg.on or cg.audioOn)) or reachState().on or SBF._zoomSnap ~= nil or false
end
-- The client-setting half of it (reach + zoom), which is restored on idle whether or not gear auto-restore is on.
function SBF.ClientStateApplied()
  return reachState().on or SBF._zoomSnap ~= nil or false
end

-- ---- equipment sets (Blizzard Equipment Manager) ----
function SBF.EquipmentSetNames()
  local out = {}
  if C_EquipmentSet then
    for _, setId in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
      local name = C_EquipmentSet.GetEquipmentSetInfo(setId)
      if name then out[#out+1] = name end
    end
  end
  table.sort(out)
  return out
end

-- A set with MISSING items (sold, banked, destroyed: the set's "lost" count) never finishes Blizzard's own swap, so
-- SBF used to retry it on every press and never fish (reported 2026-09-24). Now: equip whatever of the set is in
-- your bags, slot by slot, and once only missing pieces are left, count the set as on and fish. A one-time chat note
-- per set per session names the set and how many pieces are missing.
local missingWarned = {}
local function warnMissing(name, n)
  if missingWarned[name] then return end
  missingWarned[name] = true
  print(("|cff45c4a0SBF|r Gear set |cffffd100%s|r is missing %d item(s) that aren't in your bags. Fishing with the "
    .. "rest. Re-save the set in the Equipment Manager to clear this note."):format(name, n or 0))
end

local function setInfo(name)
  if not (name and C_EquipmentSet) then return nil end
  local id = C_EquipmentSet.GetEquipmentSetID(name)
  if not id then return nil end
  local _, _, _, isEquipped, _, _, numInBags, numLost = C_EquipmentSet.GetEquipmentSetInfo(id)
  return id, isEquipped, numInBags or 0, numLost or 0
end

-- The profile POLE owns its slot(s), never the equipment set. Otherwise a set saved with a different item there and
-- the profile pole take turns: pole on, set puts its item back, pole on... every press is a gear press (the profile
-- flash pops each time) and the loop never fishes (QC 2026-09-29, and the retail report of the same day with a newly
-- awarded pole). Forever/Classic: the pole IS the main hand, so the weapon slots (16, 17) are the pole's whenever the
-- profile names a pole this character owns. Retail: the tool slot (28) is the pole's, but only when the set actually
-- holds a DIFFERENT item there; otherwise retail keeps Blizzard's own whole-set swap, exactly as before.
local WEAPON_SLOTS = { [16] = true, [17] = true }
local function ownsPole()
  local w = SBF.working
  if not (w and w.pole) then return false end
  local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(w.pole))
            or (GetItemCount and GetItemCount(w.pole)) or 0
  return have > 0
end
-- The only pole SBF equips is the profile's own (2026-09-30), so a gear set never puts a pole on: with no profile
-- pole the set's pole slot is skipped too, and whatever pole is worn stays where it is.
local function poleSkipSlots(id)
  local w = SBF.working
  if CLASSIC_GEAR then
    if ownsPole() then return WEAPON_SLOTS end
    -- no profile pole: skip only a POLE the set holds in the main hand (a set's real weapon still equips)
    local ids = (C_EquipmentSet.GetItemIDs and C_EquipmentSet.GetItemIDs(id)) or {}
    local mh = ids[INVSLOT_MH]
    if type(mh) == "number" and mh > 1 and select(7, GetItemInfoInstant(mh)) == 20 then return WEAPON_SLOTS end
    return nil
  end
  local ids = (C_EquipmentSet.GetItemIDs and C_EquipmentSet.GetItemIDs(id)) or {}
  local slot = SBF.PoleSlot()
  local inSet = ids[slot]
  if type(inSet) == "number" and inSet > 1 and not (w and inSet == w.pole) then return { [slot] = true } end
  return nil
end

-- The set's pieces this character should be wearing: slot -> itemID, skipping ignored slots (and the slots the
-- profile pole owns).
local function setPieces(id, skip)
  local out = {}
  local ids = (C_EquipmentSet.GetItemIDs and C_EquipmentSet.GetItemIDs(id)) or {}
  local ignored = (C_EquipmentSet.GetIgnoredSlots and C_EquipmentSet.GetIgnoredSlots(id)) or {}
  for slot, itemID in pairs(ids) do
    if not ignored[slot] and not (skip and skip[slot]) and type(itemID) == "number" and itemID > 1 then
      out[slot] = itemID
    end
  end
  return out
end

local function useEquipmentSet(name)
  local id, _, _, numLost = setInfo(name)
  if not id then return end
  local skip = poleSkipSlots(id)
  if numLost == 0 and not skip then C_EquipmentSet.UseEquipmentSet(id) return end
  if numLost > 0 then warnMissing(name, numLost) end           -- some pieces are gone: equip the rest one by one
  for slot, itemID in pairs(setPieces(id, skip)) do
    if GetInventoryItemID("player", slot) ~= itemID then
      local link = SBF.BagItemLink(itemID)
      if link then EquipItemByName(link, slot) end
    end
  end
end

-- ---- snapshot / restore (gear package only; pole excluded) ----
local EQUIP_SLOTS = {}
for i = 1, 19 do EQUIP_SLOTS[i] = i end          -- standard equipment inventory slots

local function snapshotGear()
  local snap = {}
  for _, slot in ipairs(EQUIP_SLOTS) do snap[slot] = GetInventoryItemLink("player", slot) end
  SBF.CharGear().snapshot = snap
end

local function restoreGear()
  -- "Back to normal" restores audio too (no-op if focus audio isn't applied), so the Restore-gear button and
  -- the equip-mgr-close path bring sound back with gear. Audio CVars are unprotected, so restore them even
  -- when the gear restore has to defer for combat below.
  if SBF.RestoreAudio then SBF.RestoreAudio() end
  local cg = SBF.CharGear()
  local snap = cg.snapshot
  -- Only while SBF has the fishing gear ON, and only ONCE: the snapshot is spent by the restore. A kept snapshot
  -- used to replay on every later "back to normal" (the idle revert for the interact range or camera alone, too),
  -- forcing days-old gear over whatever you had equipped by hand (QC 2026-09-29).
  if snap and cg.on then
    if InCombatLockdown() then SBF._gearPending = "restore"; return end   -- retry after combat (keep on=true)
    for slot, link in pairs(snap) do if link then EquipItemByName(link, slot) end end
    cg.snapshot = nil
  end
  -- Clear the "in fishing gear" flag even when there was NO snapshot to restore. Keeps state honest and,
  -- crucially, lets the idle observer stop: with a stuck on=true it (via ShouldIdleRestore) would otherwise
  -- call restoreGear every tick forever.
  SBF.CharGear().on = false
end

-- Is the named equipment set CURRENTLY equipped? (C_EquipmentSet exposes a live isEquipped flag, so we can
-- detect when the player changed gear out from under us — manually or otherwise.) True when there's nothing
-- to enforce (no set, or the set no longer exists), so a missing set never forces a re-equip.
local function setEquipped(name)
  local id, isEquipped, numInBags, numLost = setInfo(name)
  if not id then return true end                               -- no set / set deleted: nothing to enforce
  local skip = poleSkipSlots(id)
  if skip then                                                 -- judge the set without the pole's slot(s)
    local short = 0
    for slot, itemID in pairs(setPieces(id, skip)) do
      if GetInventoryItemID("player", slot) ~= itemID then
        if SBF.BagItemLink(itemID) then return false end       -- a piece is in the bags: still to equip
        short = short + 1                                      -- not worn, not in the bags: missing
      end
    end
    if short > 0 then warnMissing(name, short) end
    return true
  end
  if isEquipped then return true end
  if numLost > 0 and numInBags == 0 then                       -- everything you still own is on; only missing pieces left
    warnMissing(name, numLost)
    return true
  end
  return false
end

-- Is the profile's pole currently in its slot (SBF.PoleSlot(): 28 on retail, main hand on Forever/Classic)?
-- That's the slot SBF READS the pole
-- from (the enchant check); we only read here, never pass it as an equip destination. Returns true (nothing
-- to enforce) when this CHARACTER doesn't even own the pole — mirrors setEquipped's missing-set handling, so
-- an account-wide profile naming a pole an alt doesn't have never forces a re-equip (which would loop the
-- gear gate forever: every press tries to equip a pole the char can't, never satisfies, never fishes).
local function poleEquipped(poleID)
  if not poleID then return true end
  if GetInventoryItemID("player", SBF.PoleSlot()) == poleID then return true end   -- already wearing it
  local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(poleID))
            or (GetItemCount and GetItemCount(poleID)) or 0
  return have == 0   -- don't own it -> nothing to equip -> treat as satisfied (don't loop on an alt)
end

-- What to hand EquipItemByName for the pole. WoW: Forever silently ignores EquipItemByName(itemID) for the pole (probed
-- 2026-09-23: by id -> nothing, no error; by the bag item's LINK -> equipped first try), and so did the equipment set's
-- own swap. So pass the live hyperlink of the copy in your bags, then the generic item link, and only fall back to the
-- bare id. Links work on retail too.
function SBF.BagItemLink(itemID)
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return nil end
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID and info.hyperlink then return info.hyperlink end
    end
  end
  return nil
end
function SBF.PoleEquipArg(poleID)
  local link = SBF.BagItemLink(poleID) or (C_Item and C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(poleID)))
  return link or poleID
end

-- Make sure the active profile's gear package + pole are actually ON. Called on EVERY action press, so it
-- must be cheap and idempotent: it checks the real equipped state and equips ONLY what's missing. This is
-- what guarantees "hit the action key and you're back in your fishing gear, no matter what changed it".
local function applyProfileGear()
  if SBF._emEditing then return end   -- editing the set in the Equipment Manager: don't fight the user's edits
  if InCombatLockdown() then SBF._gearPending = "apply"; return end
  local w = SBF.working; if not w then return end
  -- (The empty-pole fill does NOT live here. This function is only reached through the GearNeedsEquip gate,
  -- which returns false for a profile with no equipSet and no pole — the exact case the fill exists for — so a
  -- hook here is unreachable when it matters. It runs in the press path ahead of that gate instead.)
  if not (w.equipSet or w.pole) then return end          -- profile manages no gear (e.g. Default) -> leave alone
  local setOK, poleOK = setEquipped(w.equipSet), poleEquipped(w.pole)
  if setOK and poleOK then SBF.CharGear().on = true; return end   -- already wearing it: nothing to do
  -- Snapshot the current gear for Restore ONLY when transitioning from the normal state (CharGear().on
  -- false). This captures whatever you're wearing right before SBF's first gear change this session, which is
  -- your normal loadout when you press from normal gear. If the user changed gear while we thought the profile
  -- was on, we re-equip but keep the original pre-fishing snapshot (Restore = "back to what I had before I
  -- started fishing here"). Note: on retail the pole lives in slot 28 (outside 1-19), so a pole you normally
  -- wear is untouched by snapshot/restore. On Forever/Classic the pole IS the main hand, so the snapshot holds
  -- your real weapons (main + off hand) and Restore puts them back in place of the pole.
  if not SBF.CharGear().on then snapshotGear() end
  -- Pole: equip WITHOUT a destination slot. Passing slot 28 is rejected as "Invalid inventory dstSlot" —
  -- that param is only for items that fit multiple slots; a pole has one valid slot, so the no-slot form
  -- lets the game place it in the profession tool slot.
  if CLASSIC_GEAR and not poleOK and w.pole then
    -- Forever/Classic: the pole goes on ALONE this press. Fired in the same instant as an equipment-set swap, the
    -- swap locks the items it is moving and the pole equip is silently dropped. The set swap in turn skips the pole
    -- on Forever, so the set sat at 9/10 and every press re-tried both, forever. One step per press: pole now, then
    -- the set (if anything else is still missing) on the next press. Retail keeps the combined path below.
    EquipItemByName(SBF.PoleEquipArg(w.pole))
  else
    if not setOK and w.equipSet then useEquipmentSet(w.equipSet) end
    -- Retail equips the pole by its item id, as it always has; the bag-link form is a Forever workaround only.
    if not poleOK and w.pole then EquipItemByName(CLASSIC_GEAR and SBF.PoleEquipArg(w.pole) or w.pole) end
  end
  SBF.CharGear().on = true
  -- Announce the active PROFILE (gold raid-warning flash), gated on the same toggle as the profile-swap
  -- flash. Shows the profile name (what you swapped INTO), not the gear-set name — the profile is the unit
  -- the user thinks in; its gear set is just one of its settings.
  if SBFDB.swapFlash and RaidNotice_AddMessage then
    RaidNotice_AddMessage(RaidWarningFrame, "SBF :: "..(w.name or "fishing"), { r = 1, g = 0.82, b = 0 })
  end
end

-- Does the active profile manage gear that ISN'T currently worn? The PreClick uses this to decide whether
-- a press is a "change gear" press (equip, don't fish) vs a normal fishing press. Cheap (a couple of API
-- reads); false when the profile manages no gear (e.g. Default) or everything's already on.
function SBF.GearNeedsEquipIgnoringEdit()
  local w = SBF.working; if not w then return false end
  if not (w.equipSet or w.pole) then return false end
  return not (setEquipped(w.equipSet) and poleEquipped(w.pole))
end
function SBF.GearNeedsEquip()
  if SBF._emEditing then return false end   -- suspended while editing the set in the Equipment Manager
  return SBF.GearNeedsEquipIgnoringEdit()
end

function SBF.EquipProfileGear() applyProfileGear() end       -- "Equip current profile gear"

-- The Equipment Manager button's edit session: put the whole fishing set on, then suspend auto-equip so SBF doesn't
-- fight the player's edits. On Forever/Classic one gear press equips only the POLE (the set follows on the next),
-- so a single call opened the editor in normal armor plus the pole, one Save away from overwriting the fishing set
-- (QC 2026-09-30). There the rest of the set goes on a moment later, still out of combat, before editing starts.
function SBF.EquipForEdit()
  applyProfileGear()
  SBF._emEditing = true
  if not (CLASSIC_GEAR and C_Timer) then return end
  C_Timer.After(0.6, function()
    if not SBF._emEditing or InCombatLockdown() or not SBF.GearNeedsEquipIgnoringEdit() then return end
    SBF._emEditing = false
    applyProfileGear()
    SBF._emEditing = true
  end)
end
function SBF.RestoreNormalGear() restoreGear() end           -- "Restore normal gear"

-- The SINGLE "return to normal" entry point: packages every "back to normal" side-effect (gear + audio) in
-- one place so callers (idle auto-restore, login restore, the Restore button) don't each have to know the
-- full list, and any future revert side-effect gets added HERE only. Each inner call self-guards and is a
-- no-op when nothing's applied: RestoreAudio early-returns unless CharGear().audioOn; restoreGear early-
-- returns unless a snapshot exists (and defers itself for combat). restoreGear ALSO calls RestoreAudio, so
-- audio is restored even if gear has to defer — calling RestoreAudio explicitly too is harmless (idempotent:
-- the second call sees audioOn already false and no-ops). Safe to call when nothing is applied.
-- NOTE: deliberately NO "still fishing" guard here — the manual Restore button and login restore must ALWAYS
-- revert. The fishing guard lives in the idle observer (Core.lua) only.
function SBF.RevertToNormal()
  if SBF.RestoreNormalGear then SBF.RestoreNormalGear() end   -- gear (also brings audio back via restoreGear)
  if SBF.RestoreAudio then SBF.RestoreAudio() end             -- explicit + idempotent: covers the no-gear-snapshot case
  if SBF.RestoreBobberReach then SBF.RestoreBobberReach() end -- the interact range goes back to the player's own value
  if SBF.RestoreFishingZoom then SBF.RestoreFishingZoom() end -- and the camera zoom
end

-- Should the idle observer revert fishing gear/audio RIGHT NOW? Extracted from the OnUpdate closure in
-- Core.lua as a pure decision so it's unit-testable (tests/idle_restore_test.lua). `now` is GetTime().
-- The load-bearing gate is `cg.on or cg.audioOn`: the observer must act ONLY while something fishing-related
-- is actually applied. Without it the observer re-ran RevertToNormal on EVERY ~1s tick once you'd gone idle,
-- and restoreGear force-equipped the stored snapshot each time — silently stomping any gear you tried to
-- equip by hand while standing still (the "gear keeps swapping back on its own, no keypress" bug). After one
-- successful RevertToNormal clears on/audioOn, every later tick short-circuits here (the combat-deferred case
-- keeps on=true, so it correctly keeps wanting to restore until PLAYER_REGEN_ENABLED drains it).
-- The ONE idle clock, shared by both decisions below: "genuinely idle" = some activity was recorded, the
-- idle window has fully elapsed since the last of it (action press OR fishing-channel activity), and the
-- Fishing channel isn't live right now (a bobber sitting out is active, not idle). idleRestoreSeconds is
-- the single tunable window — gear restore and the fishing-mode drop deliberately share it, so "the gear
-- swap timer" and "the standby timer" are the same timer in the user's mental model.
local function idlePast(now)
  if not SBFDB then return false end
  local lastActive = math.max(SBF.lastActionAt or 0, SBF.lastFishingAt or 0)
  if lastActive == 0 or (now - lastActive) <= (SBFDB.idleRestoreSeconds or 30) then return false end
  if SBF.IsFishingChannel and SBF.IsFishingChannel() then return false end   -- still channeling Fishing: not idle
  return true
end

function SBF.ShouldIdleRestore(now)
  if SBF._emEditing then return false end                          -- editing the set: never yank gear mid-edit
  if not (SBFDB and SBFDB.idleRestoreEnabled) then return false end
  if not SBF.FishingStateApplied() then return false end   -- nothing applied -> nothing to revert
  return idlePast(now)
end

-- With gear auto-restore OFF, the interact range and camera zoom still go back after the idle window: they are
-- client settings, not gear, and "Auto-restore gear when idle" never promised to keep them.
function SBF.ShouldIdleRestoreClient(now)
  if SBF._emEditing then return false end
  if not SBFDB or SBFDB.idleRestoreEnabled then return false end   -- the full revert above covers it
  if not SBF.ClientStateApplied() then return false end
  return idlePast(now)
end

-- Should the idle observer drop FISHING MODE right now? Fishing mode (SBF.fishingModeActive, armed by the
-- first action-key press) is what keeps the background machinery running — the per-frame reel watch, the
-- 0.15s key-override poll, the buff-watch scan. Dropping it puts all of that on standby until the next
-- press. Deliberately INDEPENDENT of the gear gates above: a player with no gear package and idle-restore
-- off must still get the standby (they were the ones paying the always-on CPU cost forever). No _emEditing
-- gate either — dropping the mode touches no gear, so an Equipment Manager edit doesn't need to block it.
function SBF.ShouldDropFishingMode(now)
  if not SBF.fishingModeActive then return false end
  return idlePast(now)
end

-- The SINGLE "enter / re-assert the fishing state" entry point, mirroring RevertToNormal(): applies focus
-- audio + ensures the profile gear package is on. Programmatic re-assert (used by the /reload carry-over;
-- available for future use) — any future APPLY side-effect gets added HERE only. Each inner call is already
-- idempotent / self-guarding: ApplyFocusAudio no-ops when audio isn't enabled or is already applied;
-- applyProfileGear no-ops when the set+pole are already worn (re-equips only what's missing). Safe to call
-- when the state is already fully applied. Deliberately NO "first press / don't fish this press" gate — that
-- one-step-per-press logic stays in the PreClick; this is the plain programmatic apply.
function SBF.ActivateFishing()
  if SBF.ApplyFocusAudio then SBF.ApplyFocusAudio() end
  if SBF.ApplyBobberReach then SBF.ApplyBobberReach() end
  if SBF.ApplyFishingZoom then SBF.ApplyFishingZoom() end
  if SBF.EquipProfileGear then SBF.EquipProfileGear() end
end

-- combat-end drain: re-run whatever was deferred
local gearFrame = CreateFrame("Frame")
gearFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
gearFrame:SetScript("OnEvent", function()
  local pend = SBF._gearPending; SBF._gearPending = nil
  if pend == "apply" then applyProfileGear() elseif pend == "restore" then restoreGear() end
end)
