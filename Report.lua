-- Report.lua — the in-game BUG REPORT blob.
--
-- This SHIPS (it is not dev-only): the whole point is that a public user hits a problem, clicks one button,
-- and pastes a block of text that tells us enough to reproduce it. Every bug this session — the chum that
-- said it cast and didn't, the slot that was OFF and still fired, the catalog buff that could never match —
-- cost hours of back-and-forth to extract facts that this blob would have handed over in one paste.
--
-- ⚠️ PRIVACY IS THE HARD CONSTRAINT. NOTHING here may identify the player. Explicitly EXCLUDED, and no
-- future field may reintroduce them: character name, realm, guild, account/BattleTag, GUIDs, friends,
-- group members, coordinates, any chat text, any target's name. We ship CONFIGURATION and STATE, never
-- identity. Class and level are included because they change behaviour (spell availability, boat spells)
-- and are not identifying on their own. When in doubt, leave it out — a missing field costs one round
-- trip, a leaked one costs trust.
--
-- Shape is deliberately plain text, not JSON: it has to survive being pasted into Discord, a forum, or an
-- email without anyone installing anything.
local _, ns = ...
SBF = SBF or {}

local function ver(addon)
  local g = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ok, v = pcall(g, addon, "Version")
  return (ok and v) or "?"
end

-- every GEC addon that's loaded, with its version — "which builds were in play" is the first question we
-- ask on any report, and a mismatched pair (SBF new, a shared lib old) is a real failure mode.
local GEC_ADDONS = { "SBF", "Haul", "Megaphone", "Gadgets", "GEC-Console", "GECStore-session" }
local LIBS = { "GECBind-1.0", "GECLoot-1.0", "GECTheme-1.0", "GECStore-1.0", "GECData-1.0",
               "GECReader-1.0", "GECMap-1.0", "GECStoreView-1.0" }

local function loadedAddons(out)
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  local parts = {}
  for _, a in ipairs(GEC_ADDONS) do
    local ok, l = pcall(isLoaded, a)
    if ok and l then parts[#parts + 1] = ("%s %s"):format(a, ver(a)) end
  end
  out[#out + 1] = "addons : " .. (#parts > 0 and table.concat(parts, ", ") or "none")
  local lv = {}
  for _, l in ipairs(LIBS) do
    local lib, minor
    if LibStub then lib, minor = LibStub(l, true) end   -- `x and f()` would collapse the second return value
    if lib then lv[#lv + 1] = ("%s.%s"):format((l:gsub("%-1%.0$", "")), tostring(minor or "?")) end
  end
  if #lv > 0 then out[#out + 1] = "libs   : " .. table.concat(lv, ", ") end
end

-- The slot table is the single most useful thing in the report: nearly every bug this session came down to
-- "what was actually configured in this slot". Items are reported by ID (stable, language-neutral,
-- greppable against the catalog).
--
-- CRUCIALLY, listed does NOT mean it will fire. An item can be in a slot's run-it-out list and still never
-- go out — you're out of stock, it's on cooldown, it's a spell this character doesn't know, or Blizzard
-- stripped its use effect. Reading a flat list of IDs and guessing which one was live is exactly the
-- ambiguity that made the chum hunt slow ("would this one have fired or not?"). So every item gets its own
-- line with its real state, and the one that would actually go out is marked. State comes from the ENGINE's
-- own predicates (ns.entryReady / ns.itemUsable / ns.itemCooldown), so the report can't drift from the
-- behaviour it describes.
--
-- Read-only by construction: slotDue() is deliberately NOT called here even though it would be informative,
-- because it MUTATES (it can zero _owe and clear a stale def.buff). A diagnostic must never change the state
-- it is reporting on.
local function itemState(id)
  local n = tonumber(id)
  local sid = ns.spellEntry and ns.spellEntry(id)
  if sid then
    return (ns.spellUsable and ns.spellUsable(sid)) and "ready" or "SPELL NOT KNOWN"
  end
  if not n then return "?" end
  if ns.itemUsable and not ns.itemUsable(n) then return "NO USE EFFECT (can never fire)" end
  local count = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(n)) or 0
  local isToy = (type(PlayerHasToy) == "function") and PlayerHasToy(n) or false
  if count <= 0 and not isToy then return "OUT OF STOCK" end
  local cd = (ns.itemCooldown and ns.itemCooldown(n)) or 0
  if cd > 0 then return ("on cooldown %.0fs"):format(cd) end
  return isToy and count <= 0 and "ready (toy)" or ("ready  x%d"):format(count)
end

local function slotLines(out)
  -- Walk the DESCRIPTOR list, not ActiveSlots: combat/heal live per-CHARACTER (SBF.CharSlots), so iterating
  -- the profile's working slots silently omitted them from every report — a combat-macro bug was invisible in
  -- the very diagnostic meant to show it. SBF.SlotDef(k) routes each id to its real store (profile vs char).
  local keys = {}
  for _, s in ipairs(ns.SLOTS or {}) do keys[#keys + 1] = s.id end
  if #keys == 0 then for k in pairs((SBF.ActiveSlots and SBF.ActiveSlots()) or {}) do keys[#keys + 1] = k end end
  table.sort(keys)
  out[#out + 1] = "-- slots.  '>' = would fire next.  OFF slots never fire regardless of what is listed. --"
  for _, k in ipairs(keys) do
    local d = (SBF.SlotDef and SBF.SlotDef(k)) or nil
    local sd = ns.SlotDef and ns.SlotDef(k)
    local has = d and (d.item or d.toy or d.spell or (d.macro and d.macro ~= "")) and true or false
    if d and (has or #(d.items or {}) > 0 or d.skip) then
      out[#out + 1] = ("  %-12s %-3s mode=%-7s repeat=%-3s refresh=%-4s owe=%-3s buff=%s(%s)"):format(
        k, d.skip and "OFF" or "ON",
        tostring((ns.SlotMode and sd and ns.SlotMode(sd, d)) or d.mode or "-"),
        tostring(d["repeat"] or "-"), tostring(d.refresh or "-"), tostring(d._owe or 0),
        tostring(d.buff or "-"), tostring(d.buffSpell or "-"))
      -- which entry would actually go out. fireAll slots answer it exactly (nextDueItem is read-only);
      -- every other slot fires whatever is currently LOADED on the button, so mark that instead and say so.
      local firing
      if not d.skip then
        if sd and sd.fireAll and ns.nextDueItem then
          local ok, id = pcall(ns.nextDueItem, sd, d)
          firing = ok and id or nil
        else
          firing = ns.curItemId and ns.curItemId(d) or nil
        end
      end
      for _, x in ipairs(d.items or {}) do
        local n = tonumber(x)
        -- Only mark it if it can ACTUALLY go out. Marking the merely-loaded entry put ">" against an
        -- OUT OF STOCK item on a real report — the legend says "would fire next", so pointing at something
        -- that provably cannot fire is worse than not marking anything.
        local ready = (ns.entryReady and ns.entryReady(x)) or false
        local mark = (firing and n and firing == n and ready) and ">" or " "
        out[#out + 1] = ("    %s %-14s %s"):format(mark, tostring(x), itemState(x))
      end
      if #(d.items or {}) == 0 and has then
        out[#out + 1] = ("      %s  (no item list - fires the action directly)"):format(
          tostring(d.item or d.toy or (d.spell and ("spell:" .. d.spell)) or "<macro>"))
      end
      if d.skip then out[#out + 1] = "      (slot is OFF - nothing above will fire)" end
    end
  end
end

-- Settings that change BEHAVIOUR. Sound file paths, window positions and cosmetic prefs are left out on
-- purpose: they can carry a local filesystem path (which is identifying) and they never explain a bug.
local BEHAVIOUR_KEYS = {
  "fastLoot", "sitBeforeCast", "autoSwap", "requireTwoButtons", "applyGrace", "applyMaxTries",
  "applyBackoff", "castBackoff", "consumeSeconds", "poleSlot", "fallingBoats", "refreshSkillOnCast",
  "showUnownedItems", "showUnownedToys", "showWarbandItems", "showHiddenItems", "journalWarmTimeout",
  -- the loot/jump override switches. These decide whether the loot key can bind at all, and a user who
  -- flipped one from a console button has no memory of doing it — so the report has to state them.
  "jumpKeyState", "jumpKeyupHold", "jumpHeldMaxDefer", "pollInterval", "ascentBreaker", "bounceJump",
  "bounceBreakWithBuff", "surfaceClimbJump",
}
-- Settings whose DEFAULT is on (stored as nil until explicitly turned off, read with `~= false`). A nil
-- here means "on", so silently omitting them would misreport the config — the reader can't tell an absent
-- key from an off one.
local DEFAULT_ON = { showUnownedItems = true, showUnownedToys = true, showWarbandItems = true }

-- tostring() on a table prints an ADDRESS, which is noise in a report and differs every session
-- (`fallingBoats=table: 0x9db116570` in the first real report). Render something a human can read.
local function fmtValue(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k2, v2 in pairs(v) do
    if type(v2) ~= "table" then keys[#keys + 1] = ("%s=%s"):format(tostring(k2), tostring(v2)) end
  end
  table.sort(keys)
  return #keys > 0 and ("{" .. table.concat(keys, ",") .. "}") or "{...}"
end

local function settingLines(out)
  local parts = {}
  for _, k in ipairs(BEHAVIOUR_KEYS) do
    local v = SBFDB and SBFDB[k]
    if v ~= nil then parts[#parts + 1] = ("%s=%s"):format(k, fmtValue(v))
    elseif DEFAULT_ON[k] then parts[#parts + 1] = ("%s=true(default)"):format(k) end
  end
  out[#out + 1] = "settings: " .. table.concat(parts, " ")
  -- Call out anything deviating from shipped defaults. A wall of key=value hides the two that matter; the
  -- first real report had EVERY jump switch flipped and it took reading the source to notice.
  local SHIPPED = { jumpKeyState = true, ascentBreaker = true, bounceJump = true, bounceBreakWithBuff = false,
                    surfaceClimbJump = false, jumpKeyupHold = 0.25, pollInterval = 0.15, jumpHeldMaxDefer = 3,
                    fastLoot = false, sitBeforeCast = true, requireTwoButtons = false }
  local off = {}
  for k, v in pairs(SHIPPED) do
    local cur = SBFDB and SBFDB[k]
    if cur ~= nil and cur ~= v then off[#off + 1] = ("%s=%s (default %s)"):format(k, tostring(cur), tostring(v)) end
  end
  table.sort(off)
  if #off > 0 then out[#out + 1] = "CHANGED : " .. table.concat(off, "  ") end
  local dbg = {}
  for _, k in ipairs({ "debug", "buffDebug", "lootDebug", "decisionTrace" }) do
    if SBFDB and SBFDB[k] then dbg[#dbg + 1] = k end
  end
  if #dbg > 0 then out[#out + 1] = "debugOn : " .. table.concat(dbg, ", ") end
end

-- The anomaly channel IS the bug history: every "this should never happen" this session, with counts.
-- Far more valuable than anything the reporter can describe in prose.
local function anomalyLines(out)
  local counts, log
  if SBF.AnomalyReport then counts, log = SBF.AnomalyReport()   -- dev read-back (stripped from public)
  else counts, log = SBF._anomalyCount, SBF._anomalyLog end     -- public: the recorder itself always ships
  counts, log = counts or {}, log or {}
  local tags = {}
  for t, n in pairs(counts) do tags[#tags + 1] = ("%s x%d"):format(t, n) end
  table.sort(tags)
  out[#out + 1] = "-- anomalies --"
  out[#out + 1] = #tags > 0 and ("  totals: " .. table.concat(tags, ", ")) or "  none this session"
  local from = math.max(1, #log - 14)          -- last 15 lines: enough for context, short enough to paste
  for i = from, #log do
    local e = log[i]
    if e then out[#out + 1] = ("  [%s] %s"):format(tostring(e.tag), tostring(e.msg)) end
  end
end

-- Items whose shipped catalog identity we've observed to be WRONG on this client. This is the payload that
-- makes a user report actionable without any back-and-forth: it names the item and both identities.
local function catalogLines(out)
  local db = (SBF.OutputDB and SBF.OutputDB("items")) or {}
  -- "274588 Toxic Tlhapi [learned-only]" instead of a bare number: the first real field report arrived as
  -- five naked ids that had to be looked up by hand, and the reader also couldn't tell WHICH lane the
  -- archived value came from. [catalog] = we ship knowledge for this item (check OUR value first);
  -- [learned-only] = no shipped knowledge, the learner itself got polluted. Item name is best-effort
  -- (C_Item needs the item cached; the id is always there).
  local function itemLabel(id)
    local n = tonumber(id)
    local nm = n and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(n)
    local cm = n and ns.Catalog and ns.Catalog.meta and ns.Catalog.meta[n]
    local lane = (cm and cm.knowledge) and "[catalog]" or "[learned-only]"
    return (nm and (tostring(id) .. " " .. nm) or tostring(id)) .. " " .. lane
  end
  local rows = {}
  for id, r in pairs(db) do
    if r.devOverride then
      rows[#rows + 1] = ("  %s: live=\"%s\"(%s)  catalog=\"%s\"(%s)  [dev override active]"):format(
        itemLabel(id), tostring(r.devOverride.buff), tostring(r.devOverride.buffSpell),
        tostring(r.devOverride.wasBuff or "?"), tostring(r.devOverride.wasSpell or "?"))
    elseif r.relearn then
      rows[#rows + 1] = ("  %s: catalog=\"%s\"(%s) never applied - re-learn armed"):format(
        itemLabel(id), tostring(r.relearn.buff), tostring(r.relearn.buffSpell or "?"))
    elseif r.rejected and #r.rejected > 0 then
      local last = r.rejected[#r.rejected]
      rows[#rows + 1] = ("  %s: rejected buff \"%s\"(%s) x%d"):format(
        itemLabel(id), tostring(last.buff or "?"), tostring(last.buffSpell or "?"), #r.rejected)
    end
  end
  table.sort(rows)
  if #rows > 0 then
    out[#out + 1] = "-- catalog disagreements (rejected = the learned-lane value archived when the watched buff missed 3 casts) --"
    for _, r in ipairs(rows) do out[#out + 1] = r end
  end

  -- Items the catalog ships KNOWLEDGE for but lists in no slot — the exporter's SLOTS list and the JSON's
  -- own slot array can drift, and an item assigned to a slot we don't emit lands in meta and in no picker.
  -- It still seeds a buff identity if the user places it by hand, so a stale one wedges exactly like a
  -- listed item while being invisible to the slot-walking audit. Report the count, and NAME the ones this
  -- player is actually using, since that is the case that explains a bug.
  local cat = ns.Catalog
  if cat and cat.meta then
    local listed = {}
    for _, ids in pairs(cat.slots or {}) do
      for _, id in ipairs(ids or {}) do listed[id] = true end
    end
    -- RETIRED items are in no picker ON PURPOSE (Blizzard stripped their use effect), so counting them as a
    -- gap inflates the number and buries the real ones. Only knowledge-bearing, non-retired items count.
    local orphan, total = {}, 0
    for id, m in pairs(cat.meta) do
      -- `retired` is the catalog's own "deliberately removed" marker. ItemUsable cannot stand in for it: it
      -- returns TRUE for anything the player is not carrying, so retired items you don't own counted as gaps
      -- and every report inflated the number with removals we made on purpose.
      -- `unlisted` is the same idea for a whole slot: tagged for a deliberately never-emitted slot (Buffs is
      -- user-driven, no shipped suggestions — decided 2026-09-02), knowledge ships so a hand-dropped item
      -- seeds right. Counting those five made the "orphan" number non-zero on 100% of installs, which buried
      -- the real drift this audit exists to catch.
      if not listed[id] and m and m.knowledge and not m.retired and not m.unlisted then total = total + 1; orphan[id] = true end
    end
    if total > 0 then
      local inUse = {}
      for _, d in pairs((SBF.ActiveSlots and SBF.ActiveSlots()) or {}) do
        for _, x in ipairs(d.items or {}) do
          local n = tonumber(x)
          if n and orphan[n] then inUse[#inUse + 1] = tostring(n) end
        end
      end
      table.sort(inUse)
      out[#out + 1] = ("catalog : %d item(s) ship knowledge but are in no picker list%s"):format(
        total, #inUse > 0 and ("; IN USE HERE: " .. table.concat(inUse, ", ")) or "")
    end
  end
end

-- ---- LOCALE / spell identity ---------------------------------------------------------------------------
-- Two shipped bugs — a hardcoded "/cast Fishing" and a hardcoded spell id 131474 — were completely invisible
-- on an English client and broke EVERY German one: the default cast silently did nothing, and logging/stats
-- never recorded a thing. Both took a round trip to diagnose because the report said nothing about locale.
-- It does now, and the console probe that found them is useless here: GEC-Console is a dev addon a reporter
-- does not have. So the evidence has to ship inside the report itself.
--
-- One line on an English client (where this class of bug cannot bite), the full picture on any other —
-- the spellbook dump is what proves which ids this character's Fishing actually uses, and it is exactly the
-- thing we had to ask the last reporter for by hand.
local function localeLines(out)
  local locale = (GetLocale and GetLocale()) or "?"
  local resolved = (SBF.FishingSpellName and SBF.FishingSpellName()) or "?"
  local unknown = (SBF.UnknownFishingIds and SBF.UnknownFishingIds()) or {}
  out[#out + 1] = ("fishing : cast resolves to \"%s\"  (locale %s)%s"):format(
    tostring(resolved), tostring(locale),
    #unknown > 0 and ("  |UNSHIPPED CAST ID: " .. table.concat(unknown, ", ") .. "|") or "")
  -- Dump the detail when it can actually tell us something:
  --   * any non-English client — this whole defect class is invisible on enUS;
  --   * a cast id we did not ship with, on ANY locale (the reporter suspected 131476 may be pole- or
  --     account-history dependent, in which case it can appear on English too and nothing else would show it);
  --   * a dev build, so this block can be eyeballed on an English client instead of being unverifiable.
  if locale == "enUS" and #unknown == 0 and not (SBF.IsDev and SBF.IsDev()) then return end

  local cname = UnitChannelInfo and UnitChannelInfo("player") or nil
  local cid = cname and select(8, UnitChannelInfo("player")) or nil
  out[#out + 1] = ("          channeling now: name=%s id=%s  recognised=%s"):format(
    tostring(cname or "-"), tostring(cid or "-"),
    tostring(SBF.IsFishingCast and SBF.IsFishingCast(cname, cid) or false))
  if not (GetProfessions and GetProfessionInfo and C_SpellBook and C_SpellBook.GetSpellBookItemInfo) then return end
  local okP, prof = pcall(function() return select(4, GetProfessions()) end)
  local fi = okP and prof or nil
  if not fi then out[#out + 1] = "          no Fishing profession on this character"; return end
  local okI, n, off = pcall(function()
    local _, _, _, _, num, offset = GetProfessionInfo(fi); return num, offset
  end)
  if not (okI and n and off) then return end
  out[#out + 1] = ("          fishing spellbook (%d entries):"):format(n)
  for i = 1, n do
    local info = C_SpellBook.GetSpellBookItemInfo(off + i, Enum.SpellBookSpellBank.Player)
    if info then
      out[#out + 1] = ("            slot+%d  id=%s  name=%s"):format(
        i, tostring(info.spellID or info.actionID), tostring(info.name))
    end
  end
end

-- The whole report as one pasteable string. `note` is the reporter's own description, included verbatim.
function SBF.BugReport(note)
  local out = {}
  out[#out + 1] = "=== SBF bug report ==="
  out[#out + 1] = ("when   : %s (client uptime %.1fh)"):format(date("%Y-%m-%d %H:%M"), (GetTime() or 0) / 3600)
  -- RETAIL OR CLASSIC, stated rather than inferred. The interface number implies it to someone who knows
  -- the ranges, but a bug report should not need decoding: SBF does not support the Classic flavors, so
  -- "which game is this" changes the answer entirely and was previously a guess from `interface 120100`.
  -- Names are read from the client's own WOW_PROJECT_* globals rather than hardcoded numbers, so a flavor
  -- Blizzard adds later reports its id instead of silently reading as the wrong game.
  local FLAVORS = {
    [_G.WOW_PROJECT_MAINLINE or -1]                 = "Retail",
    [_G.WOW_PROJECT_CLASSIC or -2]                  = "Classic Era",
    [_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC or -3]  = "Burning Crusade Classic",
    [_G.WOW_PROJECT_WRATH_CLASSIC or -4]            = "Wrath Classic",
    [_G.WOW_PROJECT_CATACLYSM_CLASSIC or -5]        = "Cataclysm Classic",
    [_G.WOW_PROJECT_MISTS_CLASSIC or -6]            = "Mists Classic",
  }
  local proj = _G.WOW_PROJECT_ID
  local flavor = (proj and FLAVORS[proj]) or (proj and ("unknown flavor id " .. tostring(proj))) or "unknown"
  local notMainline = proj and _G.WOW_PROJECT_MAINLINE and proj ~= _G.WOW_PROJECT_MAINLINE
  local gameVer, build, _, iface = GetBuildInfo()   -- gameVer: `ver` is the addon version upvalue above
  out[#out + 1] = ("wow    : %s %s (build %s)  interface %s  locale %s%s"):format(
    flavor, tostring(gameVer), tostring(build), tostring(iface),
    tostring(GetLocale and GetLocale() or "?"),
    notMainline and "   <<< NOT RETAIL - fishing works here, but looting does not: the interact range is too short to reach the bobber" or "")
  -- class + level only: they gate spells (boat spells, heals) and are not identifying. NO name/realm/guild.
  localeLines(out)
  local class = select(2, UnitClass("player"))
  out[#out + 1] = ("player : %s lvl %s  (no name/realm/guild collected)"):format(
    tostring(class), tostring(UnitLevel and UnitLevel("player") or "?"))
  loadedAddons(out)
  out[#out + 1] = ("profile: scope=%s dirty=%s  catalog=%s"):format(
    (SBF.IsIndividual and SBF.IsIndividual()) and "individual" or "warband",
    tostring(SBF.IsDirty and SBF.IsDirty() or false),
    tostring((ns.Catalog and ns.Catalog.generated) or "?"))
  out[#out + 1] = ("state  : %s  next=%s"):format(
    tostring(SBF.GetState and SBF.GetState() or "?"), tostring(SBF.GetNext and SBF.GetNext() or "?"))
  -- The dynamic override IS the loot key. When someone reports "the loot key does nothing", this line and
  -- the keys below it are the whole diagnosis: what the controller thinks it bound, why, and what the game
  -- actually has on those keys. A cached-vs-real mismatch here is the bug.
  do
    local jc = SBF.JumpController
    local function keyMap(id)
      local out2 = {}
      for _, k in ipairs((SBF.BindsFor and SBF.BindsFor(id)) or {}) do
        local ok, act = pcall(GetBindingAction, k, true)   -- checkOverride: the loot key is override-only
        out2[#out2 + 1] = ("%s->%s"):format(k, (ok and act ~= "" and act) or "|NONE|")
      end
      return #out2 > 0 and table.concat(out2, " ") or "(no key bound)"
    end
    out[#out + 1] = ("override: want=%s reason=%s ownerSet=%s"):format(
      tostring((jc and jc.Current()) or "none"), tostring(SBF._ovrReason or "-"),
      tostring(jc and jc.Applied()))
    -- Show the NATIVE interact keys next to SBF's own store. A player can bind Interact With Target in the
    -- game's own Key Bindings and never touch SBF's, which renders "(no key bound)" beside a working loot
    -- key — the exact ambiguity that sent this project hunting a dead loot key that was not dead.
    local nativeKeys = (SBF.NativeKeys and SBF.NativeKeys("INTERACTTARGET")) or {}
    out[#out + 1] = ("keys    : fishing[%s]"):format(keyMap("fishing"))
    out[#out + 1] = ("          interact/loot: SBF[%s]  native[%s]"):format(
      keyMap("interact"), #nativeKeys > 0 and table.concat(nativeKeys, " ") or "none")
    -- the CLIENT option behind the interact key (softTargetInteract; 3 = always). Two-button looting is
    -- dead below 3 with no error and a perfectly healthy binding, so a report must show it. Two-button
    -- mode implies the option (EnsureInteractKeyCVar asserts it), so anything but 3 here on a two-button
    -- report means the assert itself is failing - also worth knowing.
    local sti = (C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("softTargetInteract")) or "?"
    out[#out + 1] = ("          softTargetInteract=%s (3=always; two-button looting needs 3)"):format(tostring(sti))
    -- the loot key is NOT a native binding - it exists only as an override SBF applies (see the trace in
    -- auto-memory). "no key bound" or "->|NONE|" on the interact line IS the dead-loot-key report.
    -- GECBind is a FILE-LOCAL in every consumer, never a global — reading it here was always nil, so this
    -- printed 0 forever and fired the "looting cannot work" alarm on healthy installs. SBF.NativeKeys
    -- (Core.lua) closes over the real local and is the shipping accessor.
    if SBFDB.requireTwoButtons and #nativeKeys == 0
       and #((SBF.BindsFor and SBF.BindsFor("interact")) or {}) == 0 then
      out[#out + 1] = "          <<< TWO-BUTTON MODE WITH NO LOOT KEY - looting cannot work"
    end
  end
  settingLines(out)
  out[#out + 1] = ""
  slotLines(out)
  out[#out + 1] = ""
  anomalyLines(out)
  catalogLines(out)
  if note and note ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "-- what happened (reporter) --"
    out[#out + 1] = "  " .. tostring(note)
  end
  out[#out + 1] = "=== end report ==="
  return table.concat(out, "\n")
end

-- ALWAYS opens its own copy window, for everyone. It must never depend on the dev console: a public user
-- doesn't have GEC-Console installed, and the report is worth exactly nothing if they can't select and copy
-- it. Self-contained, closes on Escape, pre-selects the text so it's Ctrl+C and done.
function SBF.ShowBugReport(note)
  local text = SBF.BugReport(note)
  local f = SBF._reportFrame
  if not f then
    f = CreateFrame("Frame", "SBFBugReport", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(700, 500); f:SetPoint("CENTER")
    f:SetMovable(true); f:SetResizable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    if f.SetResizeBounds then f:SetResizeBounds(420, 280) end

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -6)
    f.title:SetText("SBF bug report")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 14, -28)
    hint:SetText("Already selected - press Ctrl+C to copy, then paste it into your report. No character name, realm or guild is included.")
    hint:SetWidth(660); hint:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", "SBFBugReportScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -58); sf:SetPoint("BOTTOMRIGHT", -32, 40)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    -- read-only in practice: any edit just restores the report, so a stray keypress can't corrupt what
    -- gets pasted back to us. Guarded via OnTextChanged (user-gated), NOT OnChar: Backspace/Delete never
    -- fire OnChar, so with the whole blob pre-selected the most natural key there is silently WIPED it.
    eb:SetScript("OnTextChanged", function(self, user)
      if user and self:GetText() ~= (f._text or "") then self:SetText(f._text or ""); self:HighlightText() end
    end)
    sf:SetScrollChild(eb); f.eb, f.sf = eb, sf

    local sel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sel:SetSize(110, 22); sel:SetPoint("BOTTOMLEFT", 14, 12); sel:SetText("Select all")
    sel:SetScript("OnClick", function() eb:SetFocus(); eb:HighlightText() end)

    local rebuild = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rebuild:SetSize(110, 22); rebuild:SetPoint("LEFT", sel, "RIGHT", 8, 0); rebuild:SetText("Refresh")
    rebuild:SetScript("OnClick", function() SBF.ShowBugReport(f._note) end)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); f._fit() end)

    f._fit = function() eb:SetWidth(math.max(200, sf:GetWidth() - 8)) end
    f:SetScript("OnSizeChanged", function() f._fit() end)

    tinsert(UISpecialFrames, "SBFBugReport")     -- Escape closes it
    SBF._reportFrame = f
  end
  f._text, f._note = text, note
  f:Show()
  f._fit()
  f.eb:SetText(text)
  f.eb:SetCursorPosition(0)
  f.eb:SetFocus(); f.eb:HighlightText()
  return text
end
