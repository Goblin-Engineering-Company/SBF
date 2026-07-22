-- Buffs.lua — SBF's aura-reading + watching facade over GECReader.Current.buffs(). The actual HELPFUL
-- aura scan and the 12.0 secret-value guards now live in GECReader (the one getter layer); this file
-- adapts that single snapshot to SBF's callers (byName/ordered/bySpell + the edge-triggered watchers).
--
-- Why a dedicated module: the slot engine (Slots.lua), the boat helpers, the footing panel, the
-- buff-learning poller, and /sbf buffs all need "is this buff up / how long left". They read through
-- ScanBuffs/GetBuff/GetBuffBySpell here, so there's one snapshot shape and everyone agrees.
--
-- 12.0 SECRET VALUES: in combat, an aura's .name (and .expirationTime) can be a "secret" value — comparing
-- it, or using it as a table key, taints/errors. GECReader handles that at the source: a secret-named aura
-- is flagged (not dropped) and keyed by spellId (readable) but never byName; ScanBuffs then filters the
-- secret ones out of the display `ordered` list so no caller ever concats a secret name.
local _, ns = ...
SBF = SBF or {}

-- Lazy GECReader handle (silent = nil-safe if the lib isn't loaded). GECReader.Current.buffs() owns the
-- HELPFUL aura scan + the 12.0 secret-value guards now; SBF no longer hand-rolls a C_UnitAuras walk here.
local function reader()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECReader-1.0", true)) or nil
end

-- One fresh snapshot of every player HELPFUL aura via GECReader. Returns byName, ordered, bySpell:
--   byName  -> { name -> details }    (a secret-named aura is NOT keyed here — its name is unreadable)
--   ordered -> array for /sbf buffs    (secret-named auras filtered OUT: the display concats each .name)
--   bySpell -> { spellId -> details }  (INCLUDES a secret-named aura whose spellId is still readable — the
--              point of spellID identity: a learned buff stays trackable even when its name goes secret)
-- Each detail: { name, spellId, icon, duration, expirationTime, count, secondsLeft, secret }.
function SBF.ScanBuffs()
  local R = reader()
  local b = R and R.Current and R.Current.buffs and R.Current.buffs()
  if not b then return {}, {}, {} end
  local ordered = {}
  for _, d in ipairs(b.ordered) do
    if not d.secret then ordered[#ordered + 1] = d end   -- drop secret-named auras from the display list
  end
  return b.byName, ordered, b.bySpell
end

-- Normalize a buff/item name for tolerant matching: strip apostrophes (straight ' and curly ’/‘), dashes
-- (hyphen + en/em), collapse whitespace, lowercase. This is a BACKSTOP only (exact match is tried first):
-- a hand-entered or hardcoded name can drift from the real one by punctuation/case, so rather than trust
-- our stored string we fall back to a fuzzy compare. NOT a substitute for storing the correct name — it's
-- belt-and-suspenders. (The Anglers Fishing Raft bug was our OWN invented apostrophe; the data is now fixed.)
local function normBuffName(s)
  s = s:gsub("\226\128\152", ""):gsub("\226\128\153", "")   -- curly ‘ (U+2018) and ’ (U+2019)
  s = s:gsub("\226\128\147", ""):gsub("\226\128\148", "")   -- en – (U+2013) and em — (U+2014) dash
  s = s:gsub("['`%-]", "")                                   -- straight ' backtick and hyphen
  return (s:gsub("%s+", " ")):lower()
end
ns.normBuffName = normBuffName

-- Details for ONE buff by name, or nil if it's not up. secondsLeft = math.huge when the aura has no timer
-- (a permanent buff). THE aura source for the slot engine's "aura" effect path.
function SBF.GetBuff(name)
  if not (name and name ~= "") then return nil end
  local byName = SBF.ScanBuffs()
  local hit = byName[name]
  if hit then return hit end
  -- exact miss: try an apostrophe/case-tolerant match (item-vs-buff punctuation drift, see normBuffName)
  local target = normBuffName(name)
  for k, v in pairs(byName) do
    if normBuffName(k) == target then return v end
  end
  return nil
end

-- Details for ONE buff by spellID (identity), or nil if not up. Preferred over GetBuff(name) for LEARNED
-- buffs: a spellID survives a locale change / rename AND a 12.0 secret name (bySpell still carries it).
function SBF.GetBuffBySpell(spellId)
  if not spellId then return nil end
  local _, _, bySpell = SBF.ScanBuffs()
  return bySpell and bySpell[spellId] or nil
end

-- ---- buff watcher --------------------------------------------------------------------
-- Edge-triggered watchers: register a name with onAppear / onExpire callbacks, get back a
-- handle. A single low-frequency tick re-scans and fires onAppear on the RISING edge (buff
-- went from absent->present) and onExpire on the FALLING edge, passing the full details
-- object. Debounced by construction — one callback per transition, never per tick.
local watchers = {}                  -- handle -> { name, onAppear, onExpire, _up }
local watchFrame, watchAccum = nil, 0
local WATCH_TICK = 0.3               -- seconds between scans (low-freq: a buff appearing is not time-critical)

local function watchTick()
  if not next(watchers) then return end
  local byName = SBF.ScanBuffs()     -- one scan shared across every watcher this tick
  for _, w in pairs(watchers) do
    local d = byName[w.name]
    local up = d ~= nil
    if up and not w._up then
      w._up = true
      if w.onAppear then w.onAppear(d) end     -- rising edge
    elseif (not up) and w._up then
      w._up = false
      if w.onExpire then w.onExpire(w._last) end  -- falling edge (last-seen details)
    end
    w._last = d or w._last
  end
end

-- WatchBuff{ name=…, onAppear=fn(details), onExpire=fn(details) } -> handle.
-- The handle is opaque; pass it to SBF.UnwatchBuff to stop. Cheap to register many.
function SBF.WatchBuff(spec)
  local w = { name = spec.name, onAppear = spec.onAppear, onExpire = spec.onExpire, _up = false }
  watchers[w] = w
  if not watchFrame then
    watchFrame = CreateFrame("Frame")
    watchFrame:SetScript("OnUpdate", function(_, e)
      watchAccum = watchAccum + e
      if watchAccum >= WATCH_TICK then watchAccum = 0; watchTick() end
    end)
  end
  return w
end

-- Stop a watcher (and let its rising edge re-fire if re-registered later).
function SBF.UnwatchBuff(handle)
  if handle then watchers[handle] = nil end
end

-- Retune the watched name on an existing handle (the Patiently-Rewarded picker edits the
-- name live). Resets the edge so the next tick re-evaluates from scratch.
function SBF.SetWatchName(handle, name)
  if not handle then return end
  handle.name = name; handle._up = false; handle._last = nil
end

ns.GetBuff = SBF.GetBuff                     -- intra-pack alias (Slots.lua reads this at runtime)
ns.GetBuffBySpell = SBF.GetBuffBySpell       -- spellID-keyed sibling (Slots.lua's learned-buff-up check)
