-- Gather.lua — the PURE, headless-testable classifier behind "gathered" (container / GameObject) loot.
-- Loaded by the addon (Core.lua reads ns.Gather) AND by the offline tests (loadfile), mirroring Haul's
-- Replay.lua pattern. It makes NO WoW API calls: the caller reads the loot slots into a plain list and
-- passes them in, so the double-count-safe DECISION is unit-testable offline.
--
-- WHY this decision is load-bearing (see Core.lua for the full field-data story): open-water fishing ALSO
-- reports a GameObject loot source — the bobber fish lands in the SAME GameObject-source bucket as a
-- fished-up container. So "GameObject source -> gathered" ALONE would double-log every fished fish (already
-- logged as `caught`). The structural guard: a GATHERED window is one that opens with NO active/recent
-- Fishing channel. GameObject-only additionally keeps creature combat loot out (that's Haul's job).
local ADDON, ns = ...

local M = {}

-- The "kind" prefix of a WoW GUID: "Creature", "GameObject", "Vehicle", "Item", "Player", "Pet", …
function M.GuidKind(guid)
  return (type(guid) == "string" and guid:match("^(%a+)")) or nil
end

-- Classify one loot window into its gathered containers. PURE — no side effects, no globals, no WoW API.
--   slots = array of { link = <item/currency link or any non-nil truthy>, sources = { { guid=, qty= }, … } }
--           (a money slot has no link and is simply omitted by the caller — coins are never "gathered")
--   opts  = { fishing = <bool> }  -- true while a fishing channel is active / just-stopped: its loot is the
--           caught path's, so the whole window is skipped (returns nil) — this is the double-count guard.
-- Returns: array of { guid = <GameObject GUID>, items = { { link=, count= }, … } } in first-seen order,
--          one entry per distinct GameObject source; or nil when there is nothing to gather.
function M.Classify(slots, opts)
  if opts and opts.fishing then return nil end          -- fishing catch owns this window; never gather it
  local bySource, order
  for _, slot in ipairs(slots or {}) do
    if slot.link then                                   -- no link = money / empty: not a gathered item
      for _, src in ipairs(slot.sources or {}) do
        if src.guid and M.GuidKind(src.guid) == "GameObject" then   -- GameObject only (skip Creature/Item/…)
          bySource = bySource or {}
          if not bySource[src.guid] then
            bySource[src.guid] = {}
            order = order or {}; order[#order + 1] = src.guid       -- stable first-seen order
          end
          local list = bySource[src.guid]
          list[#list + 1] = { link = slot.link, count = src.qty or 1 }
        end
      end
    end
  end
  if not order then return nil end
  local out = {}
  for _, guid in ipairs(order) do out[#out + 1] = { guid = guid, items = bySource[guid] } end
  return out
end

-- Build a CAUGHT item list from a fishing loot window's slots. PURE. `slots` is the same shape Classify
-- takes ({ link, count, q, sources }); returns { { id, name, link, count, q }, … } (one per item slot) or
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
