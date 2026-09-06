-- Indicator.lua — the ZONE-BUFF SCREEN INDICATOR: a soft, click-through glow around the screen edges while
-- a special fishing aura is on the player, so "you are standing somewhere worth fishing" is visible from the
-- corner of your eye (the damage-vignette idea, in green). Seeded with Cursed Land and Waters (1299580), the
-- Coiled Isle season-2 area buff behind the Captain Tokka reputation arc: the surge event blesses the area,
-- the aura lands on you, and THIS is where fishing pays out - but nothing on screen said so until now.
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
  return c
end

local frame, edges, pulseGroup
local activeSpell = nil        -- spellID currently lighting the glow (nil = hidden)

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

-- one pass over the watched list -> the first aura that's live on the player wins. pcall-guarded: aura reads
-- near secret values must never error out the indicator.
local function liveEntry()
  local c = cfg()
  if not c.enabled then return nil end
  for _, row in ipairs(c.auras or {}) do
    if row.spellID and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
      local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, row.spellID)
      if ok and aura then return row end
    end
  end
  return nil
end

function SBF.ZoneIndicatorRefresh()
  local row = liveEntry()
  if row then
    build(); layout(); paint(row.color)
    frame:Show()
    if activeSpell ~= row.spellID then
      activeSpell = row.spellID
      -- first sight this session: say WHAT the glow means, loudly once (raid-warning style) + a chat line
      local msg = (row.label or "Zone buff") .. (row.note and (" - " .. row.note) or "")
      if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"] or { r = 0.3, g = 1, b = 0.5 })
      end
      print("|cff45c4a0SBF|r |cff40ff70" .. msg .. "|r")
    end
  else
    activeSpell = nil
    if frame then pulseGroup:Stop(); frame:Hide() end
  end
end

local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_AURA", "player")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function() SBF.ZoneIndicatorRefresh() end)
