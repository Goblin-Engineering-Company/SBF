-- Profiles.lua — named, location-bound config profiles. A profile owns the full slot config
-- (the tree that used to live at SBFDB.slots), plus an equipment-set name, a fishing pole item,
-- and an array of location bindings. The engine reads the ACTIVE profile's slots through
-- SBF.ActiveSlots() (Core/Slots/Options no longer touch SBFDB.slots directly).
--
-- Editing model: working copy (SBF.working). Activation deep-copies the profile's slots into the
-- working copy; the engine fishes with the working copy; Save commits it back, Revert discards.
local _, ns = ...
SBF = SBF or {}

-- deepcopy: profiles hold only plain tables/strings/numbers/bools (no functions/userdata), so a
-- recursive table clone is sufficient and safe.
local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = deepcopy(val) end
  return out
end
ns.deepcopy = deepcopy

-- ===== profile store =====
-- SBFDB.profiles : id(string) -> { name, slots, equipSet, pole, bindings = { {tier,value}, ... } }
-- SBFDB.activeProfile / SBFDB.defaultProfile : ids
-- SBFDB.profileSeq : incrementing id counter
-- SBFDB.binds : slotId -> keybind string (lifted out of per-slot config)

-- ===== profile-state scope: Warband (account-wide) vs Individual (per-character) =====
-- SBF.Store() returns the root that holds this character's profile state: SBFDB itself in Warband mode
-- (so existing account-wide data is untouched — no migration), or SBFDB.charStore[charKey()] in Individual
-- mode. EVERY access to profiles/activeProfile/defaultProfile/profileSeq/working goes through this, so
-- isolation is decided in ONE place. (Combat/heal are already per-character via SBF.CharSlots, separate.)
-- FUTURE "C": to also isolate keybinds/settings, route SBFDB.binds*/settings reads through SBF.Store() too.
function SBF.IsIndividual()
  return SBFDB.charScope ~= nil and SBFDB.charScope[SBF.CharKey()] == "individual"
end

function SBF.Store()
  if SBF.IsIndividual() then
    local cs = SBFDB.charStore and SBFDB.charStore[SBF.CharKey()]
    if cs then return cs end
  end
  return SBFDB
end

-- Flip this character between Warband and Individual. First switch to Individual creates a BLANK per-character
-- store (a single empty Default profile) — it does NOT copy the account profiles; copy-over is the future
-- export/import feature. Switching back keeps the stored Individual set for later. After either switch, reload
-- the working copy from the now-active store and reconfigure.
function SBF.SetScope(individual)
  SBFDB.charScope = SBFDB.charScope or {}
  local key = SBF.CharKey()
  if individual then
    SBFDB.charStore = SBFDB.charStore or {}
    if not SBFDB.charStore[key] then
      local id = "p1"
      SBFDB.charStore[key] = {
        profiles = { [id] = { name = "Default", slots = {}, equipSet = nil, pole = nil, bindings = {} } },
        activeProfile = id, defaultProfile = id, profileSeq = 1,
      }
    end
    SBFDB.charScope[key] = "individual"
  else
    SBFDB.charScope[key] = nil
  end
  SBF.working = nil                      -- force LoadWorking to rebuild from the new store
  local st = SBF.Store()
  SBF.LoadWorking(st.activeProfile or st.defaultProfile)
  if SBF.RefreshOptions then SBF.RefreshOptions() end
  if SBF.Apply then SBF.Apply() end
end

local function newId()
  local DB = SBF.Store()
  DB.profileSeq = (DB.profileSeq or 0) + 1
  return "p" .. DB.profileSeq
end
ns.newProfileId = newId

-- Migration: run once. If profiles already exist, no-op. Otherwise fold today's SBFDB.slots into a
-- single "Default" profile, lift per-slot bindings into SBFDB.binds, and point active/default at it.
-- INTENTIONALLY Warband-only: this builds the ACCOUNT-WIDE Default at init, so it reads/writes SBFDB
-- directly (NOT SBF.Store()). It must never target a per-character store. (newId() it calls reads the
-- store, but no scope is set at init so that resolves to SBFDB too.)
function SBF.MigrateProfiles()
  if SBFDB.profiles and SBFDB.activeProfile then return end
  SBFDB.profiles = SBFDB.profiles or {}
  SBFDB.binds = SBFDB.binds or {}

  local slots = SBFDB.slots or {}
  for slotId, def in pairs(slots) do
    if type(def) == "table" and def.binding ~= nil then
      SBFDB.binds[slotId] = def.binding
      def.binding = nil
    end
  end

  local id = newId()
  SBFDB.profiles[id] = {
    name     = "Default",
    slots    = slots,
    equipSet = nil,
    pole     = nil,
    bindings = {},
  }
  SBFDB.activeProfile  = id
  SBFDB.defaultProfile = id
  SBFDB.slots = nil
end

-- The slots table the engine should read/write right now: the working copy if one is loaded,
-- else the active profile's stored slots.
function SBF.ActiveSlots()
  if SBF.working and SBF.working.slots then return SBF.working.slots end
  local DB = SBF.Store()
  local p = DB.profiles and DB.activeProfile and DB.profiles[DB.activeProfile]
  return p and p.slots or {}
end

-- ===== slot-default seeding (single implementation) =====
-- Seed every descriptor slot's defaults into a slots table. This is the SAME per-descriptor default
-- seeding the ADDON_LOADED handler used to do inline; lifted here so it can run both on the active
-- profile at startup AND on a working copy when a profile is activated (so a profile activated later
-- never misses a newly-added descriptor slot). Needs ns.SLOTS (the descriptor list, in Slots.lua).
function SBF.SeedSlots(slotsTable)
  if not slotsTable then return end
  for _, s in ipairs(ns.SLOTS or {}) do
    slotsTable[s.id] = slotsTable[s.id] or {}
    local d = slotsTable[s.id]
    if s.defaultMacro and not d._seeded then d.macro = d.macro or s.defaultMacro; d._seeded = true end
    if d.mode == nil then d.mode = s.defaultMode or "cycle" end   -- seed the firing mode
    d.pick, d._lastPick = nil, nil                                -- drop the old random toggle + runtime pick
  end
end

-- ===== working copy (SBF.working) =====
-- SBF.working = { id=<profileId>, name, slots=<deepcopy>, equipSet, pole, dirty=bool }
-- The engine reads SBF.working.slots via SBF.ActiveSlots(). Edits set SBF.working.dirty = true.
-- Save commits the working copy back to the stored profile; Revert reloads from it (discards).
-- LOCATION BINDINGS ARE NOT HERE: they commit instantly to the stored profile (see the bindings
-- section below) — Save/Revert must never touch them, or a fresh binding gets clobbered.
-- PERSISTENCE: the working copy is stored AT SBFDB.working (a SavedVariable), with SBF.working pointing
-- at the same table, so UNSAVED edits (and the dirty flag) survive /reload and logout. On init the ADDON_
-- LOADED handler adopts SBFDB.working when valid instead of rebuilding fresh.

function SBF.LoadWorking(id)
  local DB = SBF.Store()
  id = id or DB.activeProfile
  local p = DB.profiles[id]
  if not p then return end
  local pg = SBF.ProfileGear(id)          -- gear is per-character, not on the (possibly account-wide) profile
  DB.working = {
    id       = id,
    name     = p.name,                 -- tentative name lives in the working copy; commits on Save
    slots    = deepcopy(p.slots),
    equipSet = pg.equipSet,
    pole     = pg.pole,
    dirty    = false,
  }
  SBF.working = DB.working             -- engine reads SBF.working; SavedVariables auto-persists DB.working
  DB.activeProfile = id
  SBF.SeedSlots(SBF.working.slots)   -- ensure every descriptor slot exists in the working copy
end

function SBF.MarkDirty() if SBF.working then SBF.working.dirty = true end end
function SBF.IsDirty() return SBF.working and SBF.working.dirty or false end

function SBF.SaveWorking()
  local DB = SBF.Store()
  local w = SBF.working; if not w then return end
  local p = DB.profiles[w.id]; if not p then return end
  if w.name ~= nil then p.name = w.name end   -- commit the tentative name
  p.slots    = deepcopy(w.slots)
  local pg = SBF.ProfileGear(w.id)             -- gear commits to the per-character store, not the profile
  pg.equipSet = w.equipSet
  pg.pole     = w.pole
  -- p.bindings deliberately untouched: bindings commit instantly and never live in the working copy
  w.dirty = false
end

function SBF.RevertWorking()
  if SBF.working then SBF.LoadWorking(SBF.working.id) end
end

-- Per-character, per-profile gear config { equipSet, pole }. Gear is ALWAYS per-character — WoW equipment
-- sets are character-specific, and a pole one character owns another may not — so it lives in the per-
-- character CharGear table regardless of the profile's Warband/Individual scope. Keyed by a scope tag
-- ("i:"/"a:") + profile id so a character switching scope never collides its account-wide and individual
-- records for the same logical profile id.
-- Lazily seeded from the legacy inline profile fields on first access, GUARDED by ownership: the pole is
-- only carried over if this character possesses it (C_Item.GetItemCount > 0), and the equipment set only
-- if this character has a set by that name (C_EquipmentSet.GetEquipmentSetID returns non-nil). This
-- prevents cross-character gear bleed without requiring a one-time migration pass at login.
function SBF.ProfileGear(id)
  local cg = SBF.CharGear()
  cg.cfg = cg.cfg or {}
  local key = (SBF.IsIndividual() and "i:" or "a:") .. tostring(id)
  local g = cg.cfg[key]
  if not g then
    g = {}
    local DB = SBF.Store()
    local p = DB.profiles and DB.profiles[id]
    if p then
      if p.pole and (C_Item.GetItemCount(p.pole) or 0) > 0 then g.pole = p.pole end
      if p.equipSet and C_EquipmentSet.GetEquipmentSetID(p.equipSet) then g.equipSet = p.equipSet end
    end
    cg.cfg[key] = g
  end
  return g
end

-- recursive value compare for the working-vs-stored diff: handles nil, scalars, and (deep) tables.
local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Resolve an itemID (or a slot item link/string) to a readable name. Prefers the per-item knowledge
-- DB (SBF.ItemKnow(id).name), then the live item APIs, and finally falls back to "item:<id>" so a
-- not-yet-cached item still reads sensibly in the prompt. Accepts numbers, numeric strings, or links.
local function itemName(id)
  if id == nil then return "?" end
  local num = tonumber(id)
  -- a hyperlink/string item (def.item can hold a "[Name]" link): pull the name out of the brackets.
  if not num and type(id) == "string" then
    local n = id:match("%[(.-)%]")
    if n and n ~= "" then return n end
    num = GetItemInfoInstant and GetItemInfoInstant(id) or nil
  end
  local key = num or id
  local rec = SBF.ItemKnow and SBF.ItemKnow(key)
  if rec and rec.name and rec.name ~= "" then return rec.name end
  if C_Item and C_Item.GetItemNameByID then
    local n = C_Item.GetItemNameByID(key); if n and n ~= "" then return n end
  end
  local gi = GetItemInfo and GetItemInfo(key)
  if gi and gi ~= "" then return gi end
  return "item:" .. tostring(num or id)
end
ns.itemName = itemName

-- the set of itemIDs a slot holds, as a lookup {id=true} — for diffing added/removed items.
local function itemSet(def)
  local set = {}
  for _, id in ipairs((def and def.items) or {}) do set[id] = true end
  return set
end

-- the resolved firing mode of a slot def (saved mode, else the descriptor default). Mirrors ns.SlotMode
-- without depending on its load order; we only need it for display so a plain fallback is fine.
local function modeOf(slotDef, def)
  return (def and def.mode) or (slotDef and slotDef.defaultMode) or "cycle"
end

-- Ordered, human-readable list of EXACTLY what differs between the working copy and its STORED profile —
-- used by the dirty-on-leave prompt so it can say what changed in plain English (item names included).
-- Each entry is a finished sentence/clause; runtime-only fields (_idx/_lastPick/_owe/firedAt/_seeded/pick/
-- buffFor/icon) are ignored — only user-meaningful config is reported. Returns {} when nothing changed.
function SBF.WorkingChanges()
  local w = SBF.working; if not w then return {} end
  local DB = SBF.Store()
  local p = DB.profiles and DB.profiles[w.id]; if not p then return {} end
  local out = {}

  -- profile-level fields
  if w.name ~= p.name then out[#out + 1] = ('renamed to "%s"'):format(tostring(w.name or "")) end
  local pg = SBF.ProfileGear(w.id)
  if w.equipSet ~= pg.equipSet then
    out[#out + 1] = (w.equipSet and w.equipSet ~= "") and ("gear set -> " .. tostring(w.equipSet)) or "gear set cleared"
  end
  if w.pole ~= pg.pole then
    out[#out + 1] = (w.pole and w.pole ~= "") and ("fishing pole -> " .. itemName(w.pole)) or "pole cleared"
  end

  -- (no bindings diff: bindings commit instantly to the stored profile and are never a pending edit)

  -- per-slot deltas (iterate descriptors so the order is stable + only real slots are reported)
  for _, s in ipairs(ns.SLOTS or {}) do
    local wd, pd = (w.slots or {})[s.id] or {}, (p.slots or {})[s.id] or {}
    if not deepEqual(wd, pd) then
      local label = s.label or s.id

      -- skip/active toggle (def.skip = true means OFF; nil/false means ON)
      local wSkip, pSkip = wd.skip and true or false, pd.skip and true or false
      if wSkip ~= pSkip then
        out[#out + 1] = label .. (wSkip and ": turned off" or ": turned on")
      end

      -- items: one line per added/removed itemID, resolved to a name
      local wSet, pSet = itemSet(wd), itemSet(pd)
      for _, id in ipairs(wd.items or {}) do
        if not pSet[id] then out[#out + 1] = label .. ": added " .. itemName(id) end
      end
      for _, id in ipairs(pd.items or {}) do
        if not wSet[id] then out[#out + 1] = label .. ": removed " .. itemName(id) end
      end

      -- macro body (action slots: fishing/interact/heal/combat) changed
      local wMacro, pMacro = wd.macro or "", pd.macro or ""
      if wMacro ~= pMacro then
        out[#out + 1] = label .. ((wMacro ~= "") and ": macro edited" or ": macro cleared")
      end

      -- firing mode (cycle/deplete/random)
      local wMode, pMode = modeOf(s, wd), modeOf(s, pd)
      if wMode ~= pMode then out[#out + 1] = label .. ": mode -> " .. tostring(wMode) end

      -- learned/typed buff watch-name
      local wBuff, pBuff = wd.buff or "", pd.buff or ""
      if wBuff ~= pBuff then
        out[#out + 1] = label .. ((wBuff ~= "") and (': buff -> "' .. wBuff .. '"') or ": buff cleared")
      end

      -- per-slot refresh (recast-at) override
      if wd.refresh ~= pd.refresh then
        out[#out + 1] = (wd.refresh ~= nil) and (label .. ": recast at " .. tostring(wd.refresh) .. "s")
          or (label .. ": recast reset")
      end

      -- chum burst / repeat count
      local wRep, pRep = wd["repeat"], pd["repeat"]
      if wRep ~= pRep then
        out[#out + 1] = (wRep ~= nil) and (label .. ": throw ×" .. tostring(wRep))
          or (label .. ": throw count reset")
      end
    end
  end

  return out
end

-- The STORED profile's bound locations as one readable line: "Quel'Thalas, Voidstorm" or "(not bound)".
-- Reads the stored profile (bindings live there), defaulting to the working copy's profile id.
function SBF.ProfileBoundLocations(id)
  local DB = SBF.Store()
  id = id or (SBF.working and SBF.working.id) or DB.activeProfile
  local p = id and DB.profiles and DB.profiles[id]
  if not p then return "(not bound)" end
  local names = {}
  for _, b in ipairs(p.bindings or {}) do if b.value and b.value ~= "" then names[#names + 1] = b.value end end
  return (#names > 0) and table.concat(names, ", ") or "(not bound)"
end

-- The detailed change list rendered for a (non-scrolling) StaticPopup: GOLD, one delta per line, capped
-- at `maxLines` (default 8) with a "…and N more" tail when longer. Returns "settings" if nothing parsed
-- (shouldn't happen on a dirty profile, but keeps the prompt non-empty). Use /sbf changes for the full list.
function SBF.WorkingChangesText(maxLines)
  maxLines = maxLines or 8
  local ch = SBF.WorkingChanges()
  if #ch == 0 then return "settings" end
  local shown, lines = math.min(#ch, maxLines), {}
  for i = 1, shown do lines[i] = "  • " .. ch[i] end
  if #ch > shown then lines[#lines + 1] = ("  …and %d more"):format(#ch - shown) end
  return table.concat(lines, "\n")
end

-- ===== profile CRUD =====
-- Create a new profile by duplicating `fromId` (default: the default profile). Returns the new id.
function SBF.AddProfile(name, fromId)
  local DB = SBF.Store()
  fromId = fromId or DB.defaultProfile
  local src = DB.profiles[fromId]
  local id = newId()
  DB.profiles[id] = {
    name     = name or "New profile",
    slots    = deepcopy(src and src.slots or {}),
    bindings = {},                 -- a fresh profile starts with NO location bindings
  }
  -- gear is per-character: copy THIS character's gear for the source profile into the new profile's gear
  local sg, ng = SBF.ProfileGear(fromId), SBF.ProfileGear(id)
  ng.equipSet, ng.pole = sg.equipSet, sg.pole
  return id
end

function SBF.RenameProfile(id, name)
  local DB = SBF.Store()
  local p = DB.profiles[id]; if p then p.name = name end
end

-- Reassign which profile is the location-fallback "default". Any profile may become default.
function SBF.SetDefaultProfile(id)
  local DB = SBF.Store()
  if DB.profiles[id] then DB.defaultProfile = id end
end

-- Remove a profile. The default may not be removed. If the active profile is removed, fall back to
-- the default and load its working copy.
function SBF.RemoveProfile(id)
  local DB = SBF.Store()
  if id == DB.defaultProfile then return false, "Can't remove the default profile." end
  if not DB.profiles[id] then return false, "No such profile." end
  DB.profiles[id] = nil
  if DB.activeProfile == id then SBF.LoadWorking(DB.defaultProfile) end
  return true
end

-- Switch the active profile (manual selection). Saves nothing — caller handles any dirty prompt.
function SBF.ActivateProfile(id)
  local DB = SBF.Store()
  if not DB.profiles[id] then return end
  SBF.LoadWorking(id)
  if SBF.AutoPopulatePole then SBF.AutoPopulatePole() end   -- a profile with no pole assigned picks up the equipped one
end

-- ===== location bindings + resolution =====
-- A binding is a NAMED location: { value = <name>, kind = "continent"|"zone"|"area" } stored on the
-- STORED profile (SBFDB.profiles[id].bindings). Bindings COMMIT INSTANTLY — they are deliberately NOT
-- part of the working-copy/Save/Revert cycle, because the auto-swap engine (ResolveProfile, re-run on
-- every cast press + zone change) reads the stored bindings: a save-gated binding wouldn't hold the
-- profile you just bound, and the next cast would swap you back to Default, wasting casts. So bindings
-- are "wiring", applied the moment you click Bind/x; slots/gear/name stay save-gated. SaveWorking/
-- LoadWorking/WorkingChanges do NOT touch bindings (an earlier SaveWorking snapshot-commit silently
-- clobbered fresh bindings — the "binding didn't save" bug). MATCHING is by `value` (name) only; `kind`
-- is for display. ResolveProfile uses the variable-depth SBF.LocationCascade(): of every profile whose
-- binding name appears in the current cascade, the DEEPEST (most-specific) match wins, falling back to
-- the default profile.

-- One-time/idempotent normalizer: convert legacy { tier, value } bindings to { value, kind }. Safe to run
-- every load (it only touches bindings that still carry a `tier` field). MigrateProfiles early-returns
-- once profiles exist, so this lives separately and runs unconditionally at load.
function SBF.NormalizeBindings()
  local DB = SBF.Store()
  for _, p in pairs(DB.profiles or {}) do
    for _, b in ipairs(p.bindings or {}) do
      if b.tier ~= nil then
        b.kind = b.kind or b.tier   -- old tier names (region/zone/sub) become the display kind
        b.tier = nil
      end
    end
  end
end

-- Find which profile (if any) already owns a binding with this location NAME. Returns owner id or nil.
function SBF.BindingOwner(value)
  local DB = SBF.Store()
  for id, p in pairs(DB.profiles or {}) do
    for _, b in ipairs(p.bindings or {}) do
      if b.value == value then return id end
    end
  end
end

-- Bind `id` to a location: display `value`/`kind` + the stable `mapID` (the actual match key at resolve
-- time; the area leaf has no mapID and falls back to name-matching). Rejects empty / another owner; no-dup
-- if already ours. Returns ok, errmsg. Commits INSTANTLY to the stored profile (see the section note:
-- bindings are not save-gated, so auto-swap holds the profile from the moment you bind).
function SBF.AddBinding(id, value, kind, mapID)
  if not value or value == "" then return false, "No location to bind." end
  local DB = SBF.Store()
  local owner = SBF.BindingOwner(value)
  if owner and owner ~= id then
    return false, ("%q is already bound to %q."):format(value, DB.profiles[owner].name or owner)
  end
  local p = DB.profiles[id]; if not p then return false, "No such profile." end
  p.bindings = p.bindings or {}
  if owner == id then return true end   -- already ours; no dup
  p.bindings[#p.bindings + 1] = { value = value, kind = kind, mapID = mapID }
  return true
end

function SBF.RemoveBinding(id, value)
  local DB = SBF.Store()
  local p = DB.profiles[id]; if not p then return end
  for i = #(p.bindings or {}), 1, -1 do
    if p.bindings[i].value == value then table.remove(p.bindings, i) end
  end
end

-- Resolve the best-match profile id for the current location. Builds the variable-depth cascade, maps
-- each level name -> depth (deeper index = more specific), and for every profile binding whose name is in
-- the cascade tracks the GREATEST depth seen. The profile owning the deepest match wins; ties resolve to
-- whichever profile is visited last (bindings are unique per name, so a true tie can't span profiles).
-- Falls back to the default profile when nothing matches.
function SBF.ResolveProfile()
  local DB = SBF.Store()
  -- Match by mapID (stable across locale/rename); keep a by-NAME index too so area-leaf bindings (no mapID)
  -- and any legacy name-only bindings still resolve. Deeper index = more specific.
  local depth, depthByName = {}, {}
  for i, e in ipairs(SBF.LocationCascade()) do
    if e.mapID then depth[e.mapID] = i end
    if e.name then depthByName[e.name] = i end
  end
  local best, bestDepth
  for id, p in pairs(DB.profiles or {}) do
    for _, b in ipairs(p.bindings or {}) do
      local d = (b.mapID and depth[b.mapID]) or (b.value and depthByName[b.value])
      if d and (not bestDepth or d > bestDepth) then best, bestDepth = id, d end
    end
  end
  return best or DB.defaultProfile
end

-- ===== zone-driven auto-swap =====
-- Debounced zone handler. Acts only when the serialized location cascade differs from last acted-on.
-- The _lastCascadeKey debounce is also what makes a MANUAL profile pick stick: it holds until your
-- location actually changes (no separate manual-hold flag is needed).
function SBF.OnZoneMaybeChanged()
  local DB = SBF.Store()
  local casc = SBF.LocationCascade()
  local key = ""
  for _, e in ipairs(casc) do key = key .. "/" .. e.name end
  local last = SBF._lastCascadeKey          -- RUNTIME-only (not SBFDB): nil every login/reload, so the
  if last and last == key then return end   -- first eval after a reload always runs fresh (refreshes the
  local firstRun = (last == nil)            -- bind UI + re-resolves) instead of debouncing on a stale key.
  SBF._lastCascadeKey = key

  -- The location actually changed: refresh the open options UI so the "Bind here" buttons reflect
  -- where you now are (they used to freeze on a stale cascade until a profile swap happened). No-op
  -- when the window is closed. Runs regardless of autoSwap / whether a swap follows.
  if SBF.RefreshOptions then SBF.RefreshOptions() end

  if not SBFDB.autoSwap then return end

  local target = SBF.ResolveProfile()
  if target == (SBF.working and SBF.working.id) then return end   -- already on it

  if SBF.IsDirty() then
    -- A swap to a DIFFERENT profile while you have unsaved edits would discard them — always nag first
    -- (Save/Discard/Open). This only reaches here when target ~= current working id (checked above), so
    -- moving within one profile's area resolves to the same profile -> no swap -> no prompt (no over-nag).
    local name = (SBF.working and DB.profiles[SBF.working.id] and DB.profiles[SBF.working.id].name) or "?"
    -- arg2 carries the whole detail block: bound-locations line + the GOLD detailed change list (capped,
    -- with a "…and N more" tail). The popup text template wraps it with the surrounding prose.
    local list = ("bound to: %s\n\n|cffffd100%s|r"):format(
      SBF.ProfileBoundLocations(SBF.working.id), SBF.WorkingChangesText(8))
    SBF._pendingSwap = target
    -- Context-aware: editing the DEFAULT (catch-all fallback) profile gets a clearer prompt offering
    -- Save-to-Default / New-profile-from-edits / Discard; any other profile keeps the generic prompt.
    local isDefault = (SBF.working and SBF.working.id == DB.defaultProfile)
    StaticPopup_Show(isDefault and "SBF_PROFILE_DIRTY_DEFAULT" or "SBF_PROFILE_DIRTY_ONLEAVE", name, list)
    return
  end
  SBF.DoSwap(target, firstRun)
end

-- Apply a resolved swap: load the working copy + arm the gear (Phase 5 consumes the flag) + feedback.
-- `silent` suppresses the raid-warning flash (used for the initial login resolution) but still loads.
function SBF.DoSwap(target, silent)
  SBF.LoadWorking(target)
  SBF.gearArmed = true                      -- consumed by the first action press in Phase 5
  if SBF.RefreshOptions then SBF.RefreshOptions() end
  if not silent then SBF.AnnounceProfile(target) end
end

-- "Save for here": create a NEW profile from the current dirty working copy, bound to the MOST SPECIFIC
-- (deepest) level of the current location cascade, then revert the edited profile to its saved state.
-- Returns the new id. NO LONGER WIRED to the dirty-on-leave prompt (its button3 is now "Open"); kept
-- available for any future caller. Keeps ns.deepcopy use here in Profiles.lua.
function SBF.SaveWorkingAsNewBound()
  local DB = SBF.Store()
  local w = SBF.working; if not w then return end
  local casc = SBF.LocationCascade()
  local leaf = casc[#casc]               -- deepest/most-specific cascade entry (nil only in odd no-data spots)
  local curId = w.id
  local baseName = (curId and DB.profiles[curId] and DB.profiles[curId].name) or "Profile"
  local id = SBF.AddProfile(baseName .. (leaf and (" @ " .. leaf.name) or ""))
  DB.profiles[id].slots    = deepcopy(w.slots)
  local ng = SBF.ProfileGear(id)
  ng.equipSet, ng.pole = w.equipSet, w.pole
  if leaf then SBF.AddBinding(id, leaf.name, leaf.kind, leaf.mapID) end   -- no leaf (shouldn't happen): create unbound, keep edits
  SBF.RevertWorking()                       -- restore the profile we were editing to its saved state
  return id
end

-- Create a new profile from the CURRENT dirty working copy (slots/equipSet/pole, no bindings), then revert
-- the profile we were editing back to its saved state (the edits moved into the new profile). Returns new id.
-- Mirrors SaveWorkingAsNewBound but takes an explicit name and does NOT bind to a location — used by the
-- dirty-on-leave prompt when the edited profile is the Default (fork the edits into a fresh named profile).
function SBF.SaveWorkingAsNew(name)
  local DB = SBF.Store()
  local w = SBF.working; if not w then return end
  local id = SBF.AddProfile(name and name ~= "" and name or "New profile", w.id)  -- AddProfile deep-copies from a source
  -- AddProfile copies from the STORED source profile, but we want the WORKING (dirty) edits — so overwrite:
  DB.profiles[id].slots    = deepcopy(w.slots)
  local ng = SBF.ProfileGear(id)
  ng.equipSet, ng.pole = w.equipSet, w.pole
  SBF.RevertWorking()   -- restore the edited (Default) profile to its saved/clean state
  return id
end

-- Name of the ACTIVE profile (the one the engine is fishing with). Reads the working copy first so it
-- reflects an in-progress rename before Save, falling back to the stored profile, then "Default". Public
-- so Haul's {sbf.profile} token (and any other consumer) can show which loadout is live.
function SBF.GetProfile()
  if SBF.working and SBF.working.name then return SBF.working.name end
  local DB = SBF.Store()
  local id = (SBF.working and SBF.working.id) or DB.activeProfile
  local p = id and DB.profiles and DB.profiles[id]
  return (p and p.name) or "Default"
end

-- ordered list for the dropdown: default first, then the rest by name.
function SBF.ProfileList()
  local DB = SBF.Store()
  local out = {}
  for id, p in pairs(DB.profiles or {}) do out[#out + 1] = { id = id, name = p.name } end
  table.sort(out, function(a, b)
    if a.id == DB.defaultProfile then return true end
    if b.id == DB.defaultProfile then return false end
    return (a.name or "") < (b.name or "")
  end)
  return out
end
