-- Indicator.lua — the ZONE-BUFF SCREEN INDICATOR: a soft, click-through glow around the screen edges while
-- a special fishing aura is on the player, so "you are standing somewhere worth fishing" is visible from the
-- corner of your eye (the damage-vignette idea, in green). Seeded with Cursed Land and Waters (1299580), the
-- Coiled Isle season-2 area buff behind the Captain Tokka reputation arc: when the aura lands on you, THIS is
-- where fishing pays out - but nothing on screen said so until now.
--
-- SHIPPING file. Detection is EVENT-driven (UNIT_AURA -> one C_UnitAuras.GetPlayerAuraBySpellID per watched
-- entry), so it costs nothing at idle and deliberately ignores fishing-mode standby: the indicator's whole
-- job is telling you where to START fishing, before any cast press. Matching is by spellID, so it survives
-- locale differences and the 12.x combat name-secrecy.
--
-- Everything configurable (SBFDB.zoneIndicator): enabled, alpha, edge thickness, pulse seconds, and the
-- watched-aura LIST itself - { spellID, label, color={r,g,b} } rows - so the next zone buff like this is a
-- table row, not a rebuild.

local ADDON, ns = ...   -- luacheck: ignore 211 (ADDON unused; ns reserved for future use)

-- ⚠️ SEED CAVEAT: this default is written into SBFDB ONCE and the saved table outlives every code
-- update (the "Captain Taka" typo survived its own fix this way). Changing seeded STRINGS later
-- needs a migration or a reseed; changing tunable DEFAULTS only affects fresh installs.
local function cfg()
  SBFDB = SBFDB or {}
  local c = SBFDB.zoneIndicator
  if not c then
    c = {
      enabled = true,
      alpha = 0.35,        -- peak edge opacity (the pulse breathes below this)
      thickness = 120,     -- px each edge gradient reaches toward the screen center
      pulse = 2.5,         -- seconds for one breathe cycle (0 = steady, no pulse)
      auras = {
        { spellID = 1299580, label = "Cursed Land and Waters",
          note = "Coiled Isle: fish here for Captain Tokka reputation",
          color = { 0.25, 1.0, 0.45 } },
      },
    }
    SBFDB.zoneIndicator = c
  end
  -- FIELD-LEVEL defaults (the seed caveat above, learned the hard way): everything below arrived after the
  -- auras table already existed in saves, so each block must self-seed into an EXISTING config too.
  -- stable row IDs + CONTENT TAGS (field-level): id anchors the announce latch and future migrations;
  -- content = { expansion, season, zone } is what rows are grouped by - grouping is data-driven, so a
  -- new season's row sorts itself into the right place with no UI work.
  local MN_S2 = { expansion = "Midnight", season = 2, zone = "The Coiled Isle" }
  for _, row in ipairs(c.auras or {}) do
    if row.spellID == 1299580 then row.id = row.id or "clw"; row.content = row.content or MN_S2 end
  end
  -- Patiently Rewarded as a watch row (World tab) - glow + announce + sound, matched by BUFF NAME (its identity is
  -- the editable SBFDB.prBuffName). Seeding migrates the old Audio-feedback sound config into the row and silences
  -- the old consumer (SBFDB.prSound=false - SetupPRWatch's sound gates on it). It has its OWN switch
  -- (ownSwitch): the zone glow toggle in Settings never turns it off, just as it never did the old sound.
  do
    local have
    for _, row in ipairs(c.auras) do if row.id == "pr" then have = true break end end
    if not have then
      c.auras[#c.auras + 1] = {
        id = "pr",
        buffName = (SBFDB.prBuffName and SBFDB.prBuffName ~= "" and SBFDB.prBuffName) or "Patiently Rewarded",
        label = "Patiently Rewarded", note = "a chest has spawned - claim your reward",
        color = { 1.0, 0.85, 0.25 },   -- gold
        soundOn = SBFDB.prSound and true or false,
        soundMode = SBFDB.prSoundMode or "file",
        soundId = SBFDB.prSoundId or 8960,
        soundFile = SBFDB.prSoundFile,
        content = { expansion = "Midnight" },   -- ALL of Midnight, no season/zone: PR procs expansion-wide
        ownSwitch = true,
      }
      SBFDB.prSound = false
    end
    for _, row in ipairs(c.auras) do
      if row.id == "pr" then
        -- the first seed (2026.09.08.3) tagged PR season 2; it's expansion-wide
        if row.content and row.content.season then row.content = { expansion = "Midnight" } end
        row.ownSwitch = true
      end
    end
  end
  -- SEEDED-TEXT MIGRATION (the answer to the seed caveat at the top of this function, and to the "Captain
  -- Taka" episode: a fixed default never reaches a config that already exists). Bump TEXT_REV whenever a
  -- seeded label/note changes, and add the corrected strings here keyed by row id; every existing config
  -- gets rewritten once, then rides the new revision.
  -- CAVEAT: this OVERWRITES the label/note on a matching row, so the day these become user-editable in the
  -- UI, each row needs a "user edited this" flag that the migration skips.
  local TEXT_REV = 2
  if (c.textRev or 1) < TEXT_REV then
    local fixes = {}   -- row id -> { label, note }
    fixes.pr = { label = "Patiently Rewarded",  note = "a chest has spawned - claim your reward" }
    for _, list in ipairs({ c.auras, c.vignettes }) do
      for _, row in ipairs(list or {}) do
        local f = row.id and fixes[row.id]
        if f then row.label, row.note = f.label, f.note end
      end
    end
    c.textRev = TEXT_REV
  end
  return c
end

-- false = the aura glow: green edges and an on-screen announcement while a watched fishing buff is on you.
function SBF.ZoneWatchesFull()
  return false
end

-- the full watch config, for the Settings UI (rows are LIVE references: edits + SBF.ZoneIndicatorRefresh
-- take effect immediately and persist - they're the SavedVariables tables themselves).
function SBF.ZoneWatches() return cfg() end

-- play a watch row's configured sound. `force` = the Settings Test/preview click (plays even when the row's
-- sound is off, so picking a sound always lets you hear it).
function SBF.PlayZoneWatchSound(row, force)
  if not row then return end
  if row.soundOn == false and not force then return end
  if row.soundMode == "file" and row.soundFile then
    pcall(PlaySoundFile, row.soundFile, "Master")
  else
    pcall(PlaySound, row.soundId or 8959, "Master")
  end
end

-- (SBF.PreviewZoneWatch lives below, after the frame/paint machinery it uses.)

local frame, edges, pulseGroup

local function build()
  if frame then return end
  frame = CreateFrame("Frame", "SBFZoneIndicator", UIParent)
  frame:SetAllPoints(UIParent)
  frame:SetFrameStrata("BACKGROUND")   -- under every normal UI element; the world still shows through the alpha
  frame:EnableMouse(false)             -- pure decoration: never intercepts a click
  frame:Hide()
  edges = {}
  -- four gradient bars, each fading from the screen edge toward transparent at the center side
  local defs = {
    { edge = "TOP",    o = "VERTICAL",   flip = true  },
    { edge = "BOTTOM", o = "VERTICAL",   flip = false },
    { edge = "LEFT",   o = "HORIZONTAL", flip = false },
    { edge = "RIGHT",  o = "HORIZONTAL", flip = true  },
  }
  for _, d in ipairs(defs) do
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(1, 1, 1, 1)      -- white base; SetGradient supplies the real color + fade
    edges[d.edge] = { tex = t, o = d.o, flip = d.flip }
  end
  -- gentle breathe: fade the whole frame down and back forever (BOUNCE looping)
  pulseGroup = frame:CreateAnimationGroup()
  pulseGroup:SetLooping("BOUNCE")
  local a = pulseGroup:CreateAnimation("Alpha")
  a:SetFromAlpha(1); a:SetToAlpha(0.35)
  pulseGroup._alpha = a
end

local function layout()
  local c = cfg()
  local th = tonumber(c.thickness) or 120
  local e
  e = edges.TOP;    e.tex:ClearAllPoints(); e.tex:SetPoint("TOPLEFT"); e.tex:SetPoint("TOPRIGHT"); e.tex:SetHeight(th)
  e = edges.BOTTOM; e.tex:ClearAllPoints(); e.tex:SetPoint("BOTTOMLEFT"); e.tex:SetPoint("BOTTOMRIGHT"); e.tex:SetHeight(th)
  e = edges.LEFT;   e.tex:ClearAllPoints(); e.tex:SetPoint("TOPLEFT"); e.tex:SetPoint("BOTTOMLEFT"); e.tex:SetWidth(th)
  e = edges.RIGHT;  e.tex:ClearAllPoints(); e.tex:SetPoint("TOPRIGHT"); e.tex:SetPoint("BOTTOMRIGHT"); e.tex:SetWidth(th)
end

local function paint(color)
  frame._color = color
  local c = cfg()
  local r, g, b = (color and color[1]) or 0.25, (color and color[2]) or 1.0, (color and color[3]) or 0.45
  local peak = tonumber(c.alpha) or 0.35
  local solid = CreateColor(r, g, b, peak)
  local clear = CreateColor(r, g, b, 0)
  for _, e in pairs(edges) do
    -- the gradient runs edge->center: LEFT/BOTTOM start solid and fade out; TOP/RIGHT are the flipped pair
    if e.flip then e.tex:SetGradient(e.o, clear, solid) else e.tex:SetGradient(e.o, solid, clear) end
  end
  local secs = tonumber(c.pulse) or 2.5
  pulseGroup:Stop()
  if secs > 0 then
    pulseGroup._alpha:SetDuration(secs / 2)
    pulseGroup:Play()
  else
    frame:SetAlpha(1)
  end
end

-- the World tab's Test click: show the row's GLOW for a few seconds (plus its sound, forced), then hand the
-- screen back to reality via a normal refresh (which repaints the true state or hides). Runs even with the
-- master off - an explicit test click should always show what the row would look like. Overlapping tests
-- just restart the timer; the token ignores a stale timer firing after a newer preview began.
local previewToken = 0
function SBF.PreviewZoneWatch(row)
  if not row then return end
  SBF.PlayZoneWatchSound(row, true)
  build(); layout(); paint(row.color)
  frame:Show()
  previewToken = previewToken + 1
  local mine = previewToken
  local secs = (ns.numOrDefault and ns.numOrDefault(cfg().previewSecs, 3)) or 3
  C_Timer.After(secs, function()
    -- silent restore: clears the preview without announcing, and works mid-combat (a plain refresh is
    -- held during combat, which would strand the preview glow on screen until the fight ended)
    if mine == previewToken and SBF.ZoneIndicatorRefresh then SBF.ZoneIndicatorRefresh(true) end
  end)
end

-- SEEDING (login / reload): the first read after entering the world takes every row's CURRENT state as the
-- baseline without announcing, so a buff that was already up before a /reload (or a relog) is not "new" again.
local seeding = false
local seedHeld = false       -- a login / reload baseline that combat held back; the next real read takes it
local seedUntil = 0          -- GetTime() until which refreshes only baseline (auras keep arriving for a moment after
                             -- entering the world, so one read is not enough)
-- announce helper: raid-warning + chat line in the row's own color, plus the row's sound when it has one set up.
-- This is THE rising edge of a watch, so it also tells anyone listening (SBF.OnZoneWatchUp: Core logs the
-- Patiently Rewarded chest drop from it, once per proc, through the same combat hold as the glow).
local function announce(row, msg)
  if seeding then return end
  if SBF.OnZoneWatchUp then pcall(SBF.OnZoneWatchUp, row) end
  local col = row.color or { 1, 1, 1 }
  local r, g, b = col[1] or 1, col[2] or 1, col[3] or 1
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
    pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"] or { r = r, g = g, b = b })
  end
  print("|cff45c4a0SBF|r " .. ("|cff%02x%02x%02x"):format(
    math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)) .. msg .. "|r")
  if row.soundMode ~= nil then SBF.PlayZoneWatchSound(row) end   -- a row with no sound configured stays silent
end

-- is an aura row's condition live on the player? spellID rows use the direct (secrecy-proof) lookup;
-- buffName rows (their identity is a name) match through the tolerant name scan.
-- pcall-guarded: aura reads near secret values must never error out the indicator.
local function auraRowUp(row)
  if row.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, row.spellID)
    return ok and aura ~= nil
  end
  if row.buffName and row.buffName ~= "" and SBF.GetBuff then
    local ok, d = pcall(SBF.GetBuff, row.buffName)
    return ok and d ~= nil
  end
  return false
end

local latch = {}             -- row key -> true while the row's condition is live (rising-edge control)
local paintedRow = nil       -- the row currently painting the edges (kept through a mid-combat silent refresh)
local function rowKey(row) return row.id or row.label or tostring(row) end

-- COMBAT HOLD. Reported 2026-09-13: every combat enter/exit re-announced and re-flashed the edges. Cause is
-- the 12.x aura-name secrecy (see Buffs.lua ScanBuffs: a secret-named aura is NOT keyed by name), so a watch
-- that is genuinely, continuously UP reads DOWN
-- during combat and UP again on exit, which is indistinguishable from a real rising edge. Same doctrine as
-- learnBuff's combat-boundary guard: NEVER treat "can't read it right now" as "it isn't there". While
-- combat-flagged we hold everything - no re-reads, no latch moves, no announces, and the glow stays exactly
-- as it was. On PLAYER_REGEN_ENABLED the latches are still the pre-combat truth, so a watch that was up
-- before and after produces NO edge (silence, which is the fix), while one that genuinely started during
-- the fight (the blessing landed mid-fight) is still a real edge and announces then.
local function combatHeld()
  local c = cfg()
  if c.combatHold == false then return false end                  -- tunable escape hatch
  return (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
end

-- `silent` = compute and paint but never announce or move latches (works mid-combat).
function SBF.ZoneIndicatorRefresh(silent)
  local c = cfg()
  local enabled = c.enabled
  if combatHeld() and not silent then
    if GetTime() < seedUntil then seedHeld = true end   -- the baseline read was held: do it on the first real read
    return
  end
  seeding = (not silent) and (GetTime() < seedUntil or seedHeld)
  if seeding then seedHeld = false end
  local paintRow = nil
  -- Every row gets its own rising-edge announce, even when another row wins the paint. Falling edges are
  -- deliberately SILENT (leaving an area must not false-positive). Rows paint in seed order.
  for _, row in ipairs(c.auras or {}) do
    local up = ((enabled or row.ownSwitch) and row.enabled ~= false and auraRowUp(row)) or false
    local k = rowKey(row)
    if up and not latch[k] and not silent then
      announce(row, (row.label or "Zone buff") .. (row.note and (" - " .. row.note) or ""))
    end
    if not silent then latch[k] = up or nil end
    if up and not paintRow then paintRow = row end
  end
  -- a silent restore that lands mid-combat must not let an unreadable state blank a glow that is really
  -- still up: keep painting whatever was painted when the hold began.
  seeding = false
  if silent and combatHeld() then paintRow = paintedRow end
  paintedRow = paintRow
  if paintRow then
    -- already showing this exact color: leave it alone (a repaint restarts the pulse, so every aura event
    -- would snap the glow back to full brightness)
    if not (frame and frame:IsShown() and frame._color == paintRow.color) then
      build(); layout(); paint(paintRow.color)
      frame:Show()
    end
  elseif frame then
    pulseGroup:Stop(); frame:Hide()
  end
end


local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_AURA", "player")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")   -- combat ended: re-read once, now that the reads are trustworthy
ev:SetScript("OnEvent", function(_, event, msg, reloading)
  if event == "PLAYER_ENTERING_WORLD" and (msg or reloading) then                         -- login / reload: baseline
    seedUntil = GetTime() + ((ns.numOrDefault and ns.numOrDefault(cfg().seedSecs, 3)) or 3)
  end
  if event == "PLAYER_REGEN_ENABLED" then
    -- next frame: UnitAffectingCombat can still read true on this one, which would hit the combat hold
    -- and skip the very re-read this event exists to trigger.
    C_Timer.After(0, function() SBF.ZoneIndicatorRefresh() end)
    return
  end
  SBF.ZoneIndicatorRefresh()
end)
