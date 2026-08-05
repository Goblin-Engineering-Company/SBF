-- Gather.lua — PURE, headless-testable helpers for building a fishing CATCH's item list from a loot window.
-- Loaded by the addon (Core.lua reads ns.Gather) AND by offline tests (loadfile). Makes NO WoW API calls:
-- the caller reads the loot slots into a plain list and passes them in, so the item build is unit-testable.
-- NOTE: the "gathered" container/GameObject classifier that used to live here (Classify / GuidKind) was
-- removed 2026-07-30 along with the gathered-loot feature — SBF now logs ONLY fishing casts.
local ADDON, ns = ...

local M = {}

-- Build a CAUGHT item list from a fishing loot window's slots. PURE. `slots` is an array of
-- { link, count, q, sources }; returns { { id, name, link, count, q }, … } (one per item slot) or
-- nil when the window has no item slots. This is the ATOMIC source for a fishing catch's items — the whole
-- catch (fish + bait + bonus) is in the window at once, so reading the slots can't lose an item to the
-- per-chat-line race the old "You receive loot:" accumulator suffered.
function M.CatchItems(slots)
  local list = {}
  for _, s in ipairs(slots or {}) do
    if s.link then
      list[#list + 1] = {
        id    = tonumber(s.link:match("Hitem:(%d+)")),          -- nil for a currency link (name still shows)
        name  = s.link:match("|h%[(.-)%]|h") or s.link:match("%[(.-)%]"),
        link  = s.link,
        count = s.count or 1,
        q     = s.q,
      }
    end
  end
  return (#list > 0) and list or nil
end

-- Choose the caught item list: the atomic slot scan WINS; the chat accumulator is the fallback (used only
-- when the scan is empty/unavailable). PURE. Never returns an empty list — nil when both are empty, so the
-- caller can fall through to its singular last-item safety net (a catch must never log nil).
function M.PickCaughtList(scan, chat)
  if scan and #scan > 0 then return scan end
  if chat and #chat > 0 then return chat end
  return nil
end

if ns then ns.Gather = M end
return M
