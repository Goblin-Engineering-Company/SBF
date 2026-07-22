-- Gear.lua — equipment-set + fishing-pole swapping for profiles, plus the gear snapshot/restore used by
-- the "Restore normal gear" action and the idle timer. Equipping is only legal out of combat; callers
-- guard with InCombatLockdown() and defer via PLAYER_REGEN_ENABLED.
local _, ns = ...
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

-- The fishing pole currently equipped, or nil. Reads the dedicated fishing-tool slot first (SBFDB.poleSlot;
-- slot 28 in current content, where the pole is profession equipment). Falls back to scanning all 19 worn
-- slots for a Fishing Pole weapon (weapon classID 2 / subClassID 20) for older content where the pole sits
-- in the main-hand slot.
function SBF.EquippedPole()
  local id = GetInventoryItemID("player", SBFDB.poleSlot or 28)
  if id then return id end
  for s = 1, 19 do
    local iid = GetInventoryItemID("player", s)
    if iid then
      local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(iid)
      if classID == 2 and subClassID == 20 then return iid end   -- Weapon / Fishing Pole
    end
  end
  return nil
end

-- If the ACTIVE profile has no pole assigned in this character's per-profile gear config, and a fishing
-- pole is currently equipped, pull that pole in as the default. Fills ONLY when empty — never overwrites an
-- assigned pole. Writes straight to the saved config (this is a default, NOT a user edit, so it must not
-- mark the profile dirty) and syncs the working copy so the pole box and the change-diff agree. Also
-- refreshes the options window if it's open.
function SBF.AutoPopulatePole()
  if SBFDB.autoAddPole == false then return end
  local id = SBF.Store().activeProfile
  if not id then return end
  local pg = SBF.ProfileGear(id)
  if pg.pole then return end                  -- already assigned: leave it alone
  local equipped = SBF.EquippedPole()
  if not equipped then return end
  pg.pole = equipped
  if SBF.working and SBF.working.id == id then
    SBF.working.pole = equipped               -- keep the live working copy in sync
  end
  if SBF.RefreshOptions then SBF.RefreshOptions() end
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

local function useEquipmentSet(name)
  if not (name and C_EquipmentSet) then return end
  local id = C_EquipmentSet.GetEquipmentSetID(name)
  if id then C_EquipmentSet.UseEquipmentSet(id) end
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
  local snap = SBF.CharGear().snapshot; if not snap then return end
  if InCombatLockdown() then SBF._gearPending = "restore"; return end
  for slot, link in pairs(snap) do if link then EquipItemByName(link, slot) end end
  SBF.CharGear().on = false
end

-- Is the named equipment set CURRENTLY equipped? (C_EquipmentSet exposes a live isEquipped flag, so we can
-- detect when the player changed gear out from under us — manually or otherwise.) True when there's nothing
-- to enforce (no set, or the set no longer exists), so a missing set never forces a re-equip.
local function setEquipped(name)
  if not (name and C_EquipmentSet) then return true end
  local id = C_EquipmentSet.GetEquipmentSetID(name)
  if not id then return true end
  local _, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(id)
  return isEquipped and true or false
end

-- Is the profile's pole currently in the profession tool slot? poleSlot (28) is the slot SBF READS the pole
-- from (the enchant check); we only read here, never pass it as an equip destination. Returns true (nothing
-- to enforce) when this CHARACTER doesn't even own the pole — mirrors setEquipped's missing-set handling, so
-- an account-wide profile naming a pole an alt doesn't have never forces a re-equip (which would loop the
-- gear gate forever: every press tries to equip a pole the char can't, never satisfies, never fishes).
local function poleEquipped(poleID)
  if not poleID then return true end
  if GetInventoryItemID("player", SBFDB.poleSlot or 28) == poleID then return true end   -- already wearing it
  local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(poleID))
            or (GetItemCount and GetItemCount(poleID)) or 0
  return have == 0   -- don't own it -> nothing to equip -> treat as satisfied (don't loop on an alt)
end

-- Make sure the active profile's gear package + pole are actually ON. Called on EVERY action press, so it
-- must be cheap and idempotent: it checks the real equipped state and equips ONLY what's missing. This is
-- what guarantees "hit the action key and you're back in your fishing gear, no matter what changed it".
local function applyProfileGear()
  if SBF._emEditing then return end   -- editing the set in the Equipment Manager: don't fight the user's edits
  if InCombatLockdown() then SBF._gearPending = "apply"; return end
  local w = SBF.working; if not w then return end
  if not (w.equipSet or w.pole) then return end          -- profile manages no gear (e.g. Default) -> leave alone
  local setOK, poleOK = setEquipped(w.equipSet), poleEquipped(w.pole)
  if setOK and poleOK then SBF.CharGear().on = true; return end   -- already wearing it: nothing to do
  -- Snapshot the current gear for Restore ONLY when transitioning from the normal state (CharGear().on
  -- false). If the user changed gear while we thought the profile was on, we re-equip but keep the
  -- original pre-fishing snapshot (Restore = "back to what I had before I started fishing here").
  if not SBF.CharGear().on then snapshotGear() end
  -- Pole: equip WITHOUT a destination slot. Passing slot 28 is rejected as "Invalid inventory dstSlot" —
  -- that param is only for items that fit multiple slots; a pole has one valid slot, so the no-slot form
  -- lets the game place it in the profession tool slot.
  if not setOK and w.equipSet then useEquipmentSet(w.equipSet) end
  if not poleOK and w.pole then EquipItemByName(w.pole) end
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
function SBF.GearNeedsEquip()
  if SBF._emEditing then return false end   -- suspended while editing the set in the Equipment Manager
  local w = SBF.working; if not w then return false end
  if not (w.equipSet or w.pole) then return false end
  return not (setEquipped(w.equipSet) and poleEquipped(w.pole))
end

function SBF.EquipProfileGear() applyProfileGear() end       -- "Equip current profile gear"
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
  if SBF.EquipProfileGear then SBF.EquipProfileGear() end
end

-- combat-end drain: re-run whatever was deferred
local gearFrame = CreateFrame("Frame")
gearFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
gearFrame:SetScript("OnEvent", function()
  local pend = SBF._gearPending; SBF._gearPending = nil
  if pend == "apply" then applyProfileGear() elseif pend == "restore" then restoreGear() end
end)
