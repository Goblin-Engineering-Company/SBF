-- Venom.lua — the COUNTER some fishing poles carry. The Coiled Huntress (Midnight, item 244790) siphons Venom into
-- itself on every successful catch in The Coiled Isle's waters; Seasage Polo turns it into Coiled Filament (currency
-- 3546). The game stores the count per character and exposes no API for it, but the pole's own tooltip prints it:
-- its Equip line names the pole and carries a "+406 Venom" line. So SBF reads it from the tooltip of whatever pole is
-- in the pole slot: any pole whose Equip text names itself and holds a "+N <word>" line counts, so the next pole
-- like this works with no code change, and the word comes back localized from the client.
--
-- SHIPPING file. Read on demand with a short cache (a tooltip read per render would be wasteful), so it costs
-- nothing while nothing asks.

SBF = SBF or {}

local FILAMENT_CURRENCY = 3546            -- Coiled Filament (what Seasage Polo turns the venom into)
local CACHE_SECS = 1

local cache = { t = -1 }
-- this session's gains { last, gained }: kept per character in SBFDB so a /reload doesn't zero it (the Stats tab's
-- "This session" survives a reload too); a fresh LOGIN starts a new one (PLAYER_ENTERING_WORLD below).
local memBase = nil                       -- used when SavedVariables aren't there (offline test)
local function charKey()
  local n, r = UnitName and UnitName("player"), GetRealmName and GetRealmName()
  return (n or "?") .. "-" .. (r or "?")
end
local function getBase()
  if not SBFDB then return memBase end
  SBFDB.venomSession = SBFDB.venomSession or {}
  return SBFDB.venomSession[charKey()]
end
local function setBase(b)
  if not SBFDB then memBase = b; return end
  SBFDB.venomSession = SBFDB.venomSession or {}
  SBFDB.venomSession[charKey()] = b
end

-- Parse the pole's tooltip: returns count, word (e.g. 406, "Venom") or nil when the worn pole carries no counter.
local function readPole()
  if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem and SBF.PoleSlot) then return nil end
  local ok, d = pcall(C_TooltipInfo.GetInventoryItem, "player", SBF.PoleSlot())
  if not (ok and d and d.lines and d.lines[1]) then return nil end
  local name = d.lines[1].leftText
  if type(name) ~= "string" or name == "" or (issecretvalue and issecretvalue(name)) then return nil end
  for i = 2, #d.lines do
    local t = d.lines[i].leftText
    if type(t) == "string" and not (issecretvalue and issecretvalue(t)) and t:find(name, 1, true) then
      for sub in (t .. "\n"):gmatch("([^\n]*)\n") do
        local num, word = sub:match("^%s*%+([%d%.,%s]+)%s+(%S.-)%s*$")
        if num then
          local n = tonumber((num:gsub("[^%d]", "")))
          if n then return n, word end
        end
      end
    end
  end
  return nil
end

-- The worn pole's counter: count, word. nil when the pole has none. Cached for CACHE_SECS.
function SBF.PoleCounter()
  local now = GetTime()
  if now - cache.t >= CACHE_SECS then
    cache.t = now
    cache.n, cache.word = readPole()
    if cache.n then
      -- this session's gains: only increases count, so a turn-in at Seasage Polo (the count DROPS) never makes
      -- "this session" go negative or lose what was caught before it.
      local base = getBase()
      if base == nil then base = { last = cache.n, gained = 0 }; setBase(base) end
      if cache.n > base.last then base.gained = base.gained + (cache.n - base.last) end
      base.last = cache.n
    end
  end
  return cache.n, cache.word
end

-- Counter gained since this login / reload (survives a turn-in: gains before it are kept).
function SBF.PoleCounterSession()
  SBF.PoleCounter()
  local base = getBase()
  return base and base.gained or nil
end

-- Coiled Filament on hand.
function SBF.CoiledFilament()
  local c = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(FILAMENT_CURRENCY)
  return c and c.quantity or nil
end

-- SAMPLING. The count only changes on a catch, so SBF re-reads it right after each loot window closes, whether or not
-- any window is open to show it: the per-session gain is built from these readings, and a turn-in at Seasage Polo
-- between two readings would otherwise lose whatever was caught since the last one. A few reads over the next
-- seconds cover the server's update landing late; SBF.OnPoleCounterChanged (the header) hears about every change.
local READ_DELAYS = { 0.5, 1.5, 3 }
local function sample()
  local before = cache.n
  cache.t = -1
  local n = SBF.PoleCounter()
  if n ~= before and SBF.OnPoleCounterChanged then pcall(SBF.OnPoleCounterChanged, n) end
end
local ev = CreateFrame and CreateFrame("Frame")   -- (nil only in the offline test harness)
if ev then
  ev:RegisterEvent("LOOT_CLOSED")
  ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  ev:RegisterEvent("PLAYER_ENTERING_WORLD")
  ev:SetScript("OnEvent", function(_, event, isLogin)
    if event == "PLAYER_ENTERING_WORLD" and isLogin then setBase(nil) end   -- a fresh login starts a new session
    if not C_Timer then return end
    if event == "LOOT_CLOSED" then
      for _, d in ipairs(READ_DELAYS) do C_Timer.After(d, sample) end
    elseif event == "PLAYER_ENTERING_WORLD" then
      C_Timer.After(3, sample)                  -- item tooltips aren't reliable for the first moment after login
    else
      C_Timer.After(0.2, sample)
    end
  end)
end
