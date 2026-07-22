-- Slots.lua — the SLOT DESCRIPTOR table + ONE unified engine that drives every slot.
--
-- The old Core had ~10 scattered `if slotKey == "x"` branches (in effectLeft, WatchedBuff,
-- buildPressMacro, PreClick) plus side tables (CONSUMABLE_ORDER, CHANNELED, DESC_VERB,
-- SLOT_FALLBACK). Each slot's behaviour was written PER SLOT instead of declared once. This
-- module makes the differences DECLARED DATA on a descriptor and reads that descriptor from
-- one engine, so adding/changing a slot is a data edit, not a new code branch.
--
-- Two categories (see the design doc §2):
--   * ROTATION slots (food/drink/bobber/oversized/lure/poleenchant/chum1/chum2/boat) hold an
--     item/toy list, fire in a MODE (cycle/deplete/random), TRACK an effect (aura or enchant),
--     and LEARN their buff. Items/toys only — NO macros.
--   * ACTION slots (fishing/interact/heal/combat) are a single action or a macro (macros allowed
--     ONLY here). No list, no rotation, no buff tracking. heal/combat fire conditionally.
-- `boat` is a rotation slot whose ONLY specialness (when + how it fires) lives behind role="boat".
local _, ns = ...
SBF = SBF or {}

-- Class-agnostic default for a fresh character's combat slot: acquire a live enemy, then let WoW's
-- built-in one-button rotation do the casting. Users override with their own macro (trinkets, CDs, etc.).
-- No #showtooltip — this is a slot ACTION that SBF embeds into the press macro, not a standalone macro.
local DEFAULT_COMBAT_TAIL = "/cast Single-Button Assistant"
local DEFAULT_COMBAT_MACRO = "/targetenemy [noharm][dead]\n" .. DEFAULT_COMBAT_TAIL
ns.DEFAULT_COMBAT_MACRO = DEFAULT_COMBAT_MACRO

-- Per-character combat & healing slots (class abilities differ per character, so these can never be
-- account-wide). Keyed by Name-Realm under SBFDB.charSlots, parallel to SBFDB.charGear. `combat` seeds
-- the default the first time; `heal` starts empty (there is no universal heal).
function SBF.CharSlots()
  local k = SBF.CharKey()
  SBFDB.charSlots = SBFDB.charSlots or {}
  local cs = SBFDB.charSlots[k]
  if not cs then
    cs = { combat = { id = "combat", macro = DEFAULT_COMBAT_MACRO }, heal = { id = "heal" } }
    SBFDB.charSlots[k] = cs
  end
  -- combat ALWAYS holds an action: the protected default, or the user's replacement. "Off" is the skip flag,
  -- never an empty macro. So if combat ended up with no action at all (cleared, or only ever partially seeded
  -- — the old `or` only filled a MISSING slot, not an empty one), refill the default and keep any skip flag.
  local cb = cs.combat
  if not cb or not (cb.toy or cb.item or cb.spell or (cb.macro and cb.macro ~= "")) then
    cs.combat = { id = "combat", macro = DEFAULT_COMBAT_MACRO, skip = cb and cb.skip or nil }
  end
  cs.heal = cs.heal or { id = "heal" }   -- heal has no universal default; it just starts empty
  return cs
end

-- The single point of truth for "give me slot <id>'s config". combat/heal come from this CHARACTER
-- (SBF.CharSlots); every other slot comes from the active profile/working copy (SBF.ActiveSlots).
-- All engine reads + the combat/heal editing UI go through this so per-character routing is in ONE
-- place. (Distinct from ns.SlotDef, which returns the static slot DESCRIPTOR, not the config table.)
function SBF.SlotDef(id)
  if id == "combat" or id == "heal" then
    return SBF.CharSlots()[id]
  end
  return (SBF.ActiveSlots() or {})[id]
end

-- One-time ACCOUNT-WIDE cleanup for the move to per-character combat/heal. A combat/heal macro that
-- used to live in the SHARED (account-wide) profile can't be attributed to one character, so we do NOT
-- auto-adopt it (the first attempt copied the shared profile into EVERY character, which defeated the
-- whole point). Instead: wipe the per-character store so every character re-seeds its own default, and
-- strip the now-unused combat/heal out of all profiles. Combat/heal are per-character from here on
-- (SBF.CharSlots / SBF.SlotDef). Each user re-sets their per-character combat macro once. Idempotent
-- via the account-wide version flag SBFDB.charSlotsMig.
function SBF.MigrateCharSlots()
  if (SBFDB.charSlotsMig or 0) >= 2 then return end
  SBFDB.charSlots = {}                              -- drop any cross-character contamination; re-seeds per char
  -- INTENTIONALLY account-wide (reads SBFDB.profiles directly, NOT SBF.Store()): this one-time cleanup strips
  -- the now-unused combat/heal out of the ACCOUNT-WIDE (Warband) profiles. Per-character (Individual) stores
  -- are always created BLANK (no combat/heal in their slots), so there is nothing to strip there.
  if SBFDB.profiles then
    for _, p in pairs(SBFDB.profiles) do
      if p.slots then p.slots.combat = nil; p.slots.heal = nil end
    end
  end
  SBFDB.charSlotsMig = 2
end

-- ===== the descriptor =====
-- Static, declared data. Rotation fields: effect ("aura"/"enchant"), priority (rotation order),
-- allowsRandom, allowsRepeat (chum burst), defaultMode ("cycle"/"deplete"), postFire
-- ("channel"/"climb"/nil), role (nil or "boat"), overlay (stacks on another slot), verb (announce
-- word). `learns` is IMPLIED: aura slots learn their buff, enchant slots don't.
-- Action fields: role ("fishing"/"interact"/"heal"/"combat") + existing per-slot config.
-- acceptsMacro is IMPLIED: true for action slots, false for rotation slots.
local SLOTS = {
  -- `priority` = rotation/firing order (which due slot casts first). `display` = order in the
  -- options list (decoupled on purpose, so the UI reads food/drink-first while firing stays bobbers-first).
  -- oversized FIRST (priority 1): it's a keep-up overlay that stacks ON TOP of a regular bobber, so it must be
  -- (re)applied BEFORE the base bobber casts, not after (the base bobber's own cast would otherwise land first
  -- and the overlay only follows on the next press). display order is unchanged (bobber still shows first).
  { id = "oversized",   label = "Oversized Bobber",  effect = "aura",    priority = 1, display = 4, overlay = true, allowsRandom = true, verb = "applying", defaultMode = "cycle" },
  { id = "bobber",      label = "Bobber",            effect = "aura",    priority = 2, display = 3, allowsRandom = true, verb = "applying", defaultMode = "cycle" },
  { id = "lure",        label = "Lure (buff)",       effect = "aura",    priority = 3, display = 5, verb = "applying", defaultMode = "cycle" },
  { id = "poleenchant", label = "Pole Enchant",      effect = "enchant", priority = 4, display = 6, verb = "applying" },   -- enchant: no learn, no random
  { id = "food",        label = "Food",              effect = "aura",    priority = 5, display = 1, postFire = "channel", verb = "eating" },
  { id = "drink",       label = "Drink",             effect = "aura",    priority = 6, display = 2, postFire = "channel", verb = "drinking" },
  -- Chum is the LOWEST rotation priority (fires LAST, right before fishing): its buff is short (~30s), so if it
  -- went out before the slow lure/food/drink/buff setup, that setup time would waste it. Priority 8/9 > Buffs (7).
  { id = "chum1",       label = "Chum (skill)",      effect = "aura",    priority = 8, display = 7, allowsRandom = true, allowsRepeat = true, verb = "throwing", defaultMode = "deplete" },
  { id = "chum2",       label = "Chum (perception)", effect = "aura",    priority = 9, display = 8, allowsRandom = true, allowsRepeat = true, verb = "throwing", defaultMode = "deplete" },
  -- boat: a rotation slot (rotates dinghies, learns its buff) whose due/fire is special (role="boat").
  -- refresh defaults higher than the 5s consumable default so the recast finishes before you'd drop.
  { id = "boat",        label = "Boat",              effect = "aura",    role = "boat", display = 9, postFire = "climb", allowsRandom = true, allowsSpell = true, verb = "activating", defaultMode = "cycle", refreshDefault = 30 },
  -- the additive "keep ALL of these up" slot: holds N arbitrary buff items and fires whichever one's
  -- own buff is gone/low, one item per press, until all are up. `fireAll = true` is the flag the engine
  -- branches on (slotDue/pickItem -> nextDueItem). priority 9 (after chum2=8; boat is role-gated so no
  -- collision). No mode (fireAll IS the behaviour) — the options mode cell is hidden for it.
  { id = "buffs",       label = "Buffs",             effect = "aura",    fireAll = true, allowsSpell = true, priority = 7, display = 10, verb = "applying" },   -- before chum (chum fires last)
  -- action slots (display bumped to 11..14 so they stay LAST after the new Buffs row at 10)
  { id = "fishing",     label = "Cast Fishing",      role = "fishing",  display = 11 },   -- empty = built-in "/cast Fishing"
  { id = "interact",    label = "Interact / Loot",   role = "interact", display = 12, gameBinding = "INTERACTTARGET" },
  { id = "combat",      label = "Combat (attack)",   role = "combat",   display = 13 },    -- fires via [combat] mid-fight
  { id = "heal",        label = "Heal",              role = "heal",     display = 14 },    -- out of combat, until full
}
ns.SLOTS = SLOTS

local SLOT_DEF = {}                         -- id -> descriptor (for fast field lookup)
local SLOT_LABEL = {}                       -- id -> label (out-of-stock messages)
for _, s in ipairs(SLOTS) do SLOT_DEF[s.id], SLOT_LABEL[s.id] = s, s.label end
ns.SLOT_DEF, ns.SLOT_LABEL = SLOT_DEF, SLOT_LABEL

-- derived rotation order: rotation slots (role == nil) sorted by priority. Replaces the
-- hand-kept CONSUMABLE_ORDER list — computed once from the descriptors above.
local ROTATION_ORDER = {}
for _, s in ipairs(SLOTS) do
  if s.role == nil then ROTATION_ORDER[#ROTATION_ORDER + 1] = s.id end
end
table.sort(ROTATION_ORDER, function(a, b) return (SLOT_DEF[a].priority or 99) < (SLOT_DEF[b].priority or 99) end)
ns.ROTATION_ORDER = ROTATION_ORDER

-- generic consume auras that appear the instant you eat/drink — auto-learn must NOT grab these
-- (the real buff is "Well Fed"/"Relaxed", which lands a moment later). Generic, not per-slot.
local LEARN_SKIP = { ["Drink"] = true, ["Food"] = true, ["Eating"] = true, ["Refreshment"] = true }

-- ===== shared low-level helpers =====

-- The display name of an item/toy/spell def. For items we read it out of the stored link
-- (works before GetItemInfo caches it). Casting by name matters: items like the Tuskarr Dinghy
-- LEARN a toy on use, so item:<id> re-learns the bag item while the NAME summons the learned toy.
local function defName(def)
  if def.item then
    return (type(def.item) == "string" and def.item:match("%[(.-)%]")) or GetItemInfo(def.item)
  end
  if def.toy then return C_ToyBox and C_ToyBox.GetToyInfo and (select(2, C_ToyBox.GetToyInfo(def.toy))) end
  if def.spell then return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(def.spell)) or def.spell end
end
ns.defName = defName

-- a stable id for whatever is in a slot, so we can tell when the item was swapped and the
-- learned buff has gone stale.
local function itemKey(def)
  if def.macro and def.macro ~= "" then return "macro:" .. def.macro end
  if def.item and def.item ~= "" then return "item:" .. tostring(GetItemInfoInstant(def.item) or def.item) end
  if def.toy then return "toy:" .. tostring(def.toy) end
  if def.spell then return "spell:" .. tostring(def.spell) end
  return "none"
end
ns.itemKey = itemKey

-- the bare item/toy ID of whatever is loaded in a slot — the key for the per-item buff cache.
local function curItemId(def)
  if def.toy then return def.toy end
  if def.item and def.item ~= "" then
    return GetItemInfoInstant(def.item) or (type(def.item) == "number" and def.item) or nil
  end
  return nil
end
ns.curItemId = curItemId

-- Cast time (SECONDS) of whatever a slot fires, resolved from the game API: 0 = instant, nil = unknown.
-- Items/toys resolve through their on-use spell (GetItemSpell), spells read directly; a macro can /cast
-- anything so it's unknowable (nil). Used to size the boat re-cast window to the ACTUAL cast — the raft is
-- a ~1.5s cast, Levitate/Zen-Flight-type buffs are instant — instead of a flat timer, and persisted per
-- item into the knowledge DB (castTime) so it's exportable.
local function actionCastTime(def)
  if not def then return nil end
  local spellId
  if def.spell and def.spell ~= "" then
    spellId = def.spell
  elseif (def.item and def.item ~= "") or def.toy then
    local iid = curItemId(def) or def.item
    if iid and GetItemSpell then spellId = select(2, GetItemSpell(iid)) end
  end
  if not spellId then return nil end
  local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellId)
  local ms = info and info.castTime
  if ms == nil then return nil end
  return ms / 1000
end
SBF.ActionCastTime = actionCastTime
ns.actionCastTime = actionCastTime

-- A def.items ENTRY is a numeric item/toy ID, or a "spell:<id>" string (Boat/Buffs only). spellEntry(e)
-- returns the numeric spell id when e is a spell entry, else nil. spellName(id) is its display/buff name.
local function spellEntry(e)
  if type(e) == "string" then
    local id = e:match("^spell:(%d+)$")
    return id and tonumber(id) or nil
  end
end
ns.spellEntry = spellEntry
local function spellName(id)
  return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or tostring(id)
end
ns.spellName = spellName

-- Curated dinghy-like boats: each is a TOY that applies a SAME-NAMED buff letting you fish on water.
-- We HARDCODE the buff per boat (instead of learning it) so the two boats can't cross-contaminate each
-- other's learned buff, and so each boat is an always-available Boat-flyout suggestion that can't be lost.
-- Ordered list (for the flyout) + a id->buff lookup. IDs/buffs verified (wowhead).
local KNOWN_BOATS = {
  { id = 85500,  buff = "Anglers Fishing Raft" },   -- NO apostrophe (the actual buff/item name; we'd invented one)
  { id = 166461, buff = "Gnarlwood Waveboard" },
  { id = 198428, buff = "Tuskarr Dinghy" },
  { id = 235801, buff = "Personal Fishing Barge" },
}
ns.KNOWN_BOATS = KNOWN_BOATS
local KNOWN_BOAT_BUFF = {}
for _, b in ipairs(KNOWN_BOATS) do KNOWN_BOAT_BUFF[b.id] = b.buff end
local function knownBoatBuff(id) return KNOWN_BOAT_BUFF[tonumber(id) or id] end
ns.knownBoatBuff = knownBoatBuff

-- when an item is loaded into a slot, pre-fill its buff: a curated boat uses its HARDCODED buff (never the
-- learned cache, which scrambles two boats); else the per-item cache (lookup-first; an unknown item clears
-- it so learnBuff catches the name after the next cast).
local function seedItemBuff(def)
  local iid = curItemId(def)
  local kb = iid and knownBoatBuff(iid)
  -- keep def.buffSpell in lock-step with def.buff so the spellID-preferring "is the buff up" check can
  -- never read a spellId that belongs to a previously-loaded item.
  if kb then def.buff, def.buffFor, def.buffSpell = kb, itemKey(def), nil; return end   -- curated boat: name only
  local rec = iid and SBF.ItemKnow(iid)
  local known = rec and rec.buff
  if known and known ~= "" then def.buff, def.buffFor, def.buffSpell = known, itemKey(def), rec.buffSpell
  else def.buff, def.buffFor, def.buffSpell = nil, nil, nil end
end
ns.seedItemBuff = seedItemBuff

local function hasAction(d)
  return d and (d.item or d.toy or d.spell or (d.macro and d.macro ~= ""))
end
ns.hasAction = hasAction

-- which buff name to watch for a slot: an explicit/learned slot.buff, else a toy's own name
-- (toy buffs usually match the toy).
local function slotBuffName(def)
  if def.buff and def.buff ~= "" then return def.buff end
  if def.toy then return defName(def) end
  return nil
end
ns.slotBuffName = slotBuffName

-- the resolved mode for a slot: saved def.mode, falling back to the descriptor's defaultMode
-- (so bobbers default cycle, chum deplete). A saved "random" on a slot that no longer allows
-- it falls back too — guards a descriptor change from breaking saved data (no back-compat needed).
local function slotMode(slotDef, def)
  local m = def.mode or slotDef.defaultMode or "cycle"
  if m == "random" and not slotDef.allowsRandom then m = slotDef.defaultMode or "cycle" end
  return m
end
ns.SlotMode = slotMode

-- ===== effect time (the `effect` dispatch) =====

-- seconds left on the fishing TOOL's temporary enchant (slot 28, e.g. Writhing Wiggleworm). The
-- tool sits in a profession-equipment slot GetWeaponEnchantInfo can't read, so we parse the
-- "(N min)" off its tooltip. nil if no enchant / unreadable.
local function poleEnchantSecondsLeft()
  if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return nil end
  local data = C_TooltipInfo.GetInventoryItem("player", SBFDB.poleSlot or 28)
  if not (data and data.lines) then return nil end
  for _, ln in ipairs(data.lines) do
    local t = ln.leftText
    if t then
      local n = t:match("%((%d+)%s*[Hh]")        ; if n then return tonumber(n) * 3600 end
      n = t:match("%((%d+)%s*[Mm]")               ; if n then return tonumber(n) * 60 end
      n = t:match("%((%d+)%s*[Ss]")               ; if n then return tonumber(n) end
    end
  end
  return nil
end
SBF.PoleEnchantLeft = poleEnchantSecondsLeft   -- public, for the options "active" readout

-- main-hand weapon temporary enchant seconds (a lure on a normal weapon slot).
local function weaponEnchantSecondsLeft()
  if not GetWeaponEnchantInfo then return nil end
  local has, expMs = GetWeaponEnchantInfo()
  if not has then return nil end
  return (expMs or 0) / 1000
end

-- "seconds left on a slot's effect" — dispatched on slotDef.effect (nil = not active; math.huge =
-- active, no timer):
--   "enchant" -> the slot-28 fishing-tool temp enchant, falling back to a weapon enchant.
--   "aura"    -> a player aura matched by name, read through the ONE buff source (Buffs.lua). Same
--                code for every aura slot — the lure behaves EXACTLY like the bobber (which works).
local function effectLeft(slotDef, def)
  if not (slotDef and def) then return nil end
  if slotDef.effect == "enchant" then
    return poleEnchantSecondsLeft() or weaponEnchantSecondsLeft()
  end
  -- aura path — every other slot, lures included (lures ARE buffs; the slot-28 thing is the separate
  -- Pole Enchant). The watched name must be the BUFF's name, not the item's name.
  local name = slotBuffName(def)
  if not name then return nil end
  -- collect: mirror an explicit/learned slot buff into the per-item DB under the numeric item id
  -- (the key def.items / the diag use), so a buff known only at the slot level — typed, /sbf setbuff,
  -- or learned under a different key — still shows up and is shareable. Idempotent (writes once).
  if def.buff and def.buff ~= "" then
    local iid = curItemId(def)
    if iid and not (SBF.ItemKnow(iid) and SBF.ItemKnow(iid).buff) then
      SBF.ObserveItem(iid, { buff = def.buff })
    end
  end
  -- prefer the spellID identity when we've learned it (robust to a renamed / combat-secret buff name);
  -- fall back to the name lookup for typed buffs and older learned entries that carry no spellId.
  local b = (def.buffSpell and SBF.GetBuffBySpell and SBF.GetBuffBySpell(def.buffSpell)) or SBF.GetBuff(name)
  return b and b.secondsLeft or nil
end
ns.effectLeft = effectLeft

-- public id-keyed wrappers (the options "active / time left" readout + slash commands use these).
function SBF.SlotBuffLeft(slotKey)
  local def = SBF.ActiveSlots()[slotKey]
  return def and effectLeft(SLOT_DEF[slotKey], def) or nil
end

-- the buff name the engine watches for a slot id (for the options field to display): boat always
-- uses the raft name; otherwise the typed/learned name, else the toy fallback.
function SBF.WatchedBuff(slotKey)
  local def = SBF.ActiveSlots()[slotKey]
  if not def then return nil end
  return slotBuffName(def)   -- boat included: it's just a buff, tracked like every rotation slot
end

-- clear a slot's learned buff so it re-learns on the next application (config "relearn"). ALSO
-- drops the account-wide per-item cache — else seedItemBuff re-seeds the OLD (wrong) name the
-- instant the slot reloads, and it can never re-learn.
function SBF.ClearLearnedBuff(slotKey)
  local def = SBF.ActiveSlots()[slotKey]
  if not def then return end
  -- clear EVERY item in the slot (not just the loaded one) — a rotation slot like boat holds several,
  -- and a cross-contaminated one must be re-learnable.
  for _, id in ipairs(def.items or {}) do
    local rec = SBF.ItemKnow(id); if rec then rec.buff, rec.buffSpell = nil, nil end
  end
  local iid = curItemId(def)
  local rec = iid and SBF.ItemKnow(iid)
  if rec then rec.buff, rec.buffSpell = nil, nil end
  def.buff, def.buffFor, def.buffSpell = nil, nil, nil
end

-- ===== item availability =====

-- is the slot's item actually in your bags? Out of lures/chum/food -> stop trying. Only checks
-- real items; toys/spells/macros are assumed available (a macro could /use any of several things).
local function consumableHasItem(def)
  if def.toy then return true end
  if def.item and def.item ~= "" then
    local id = GetItemInfoInstant(def.item) or def.item
    -- a toy-teaching item (e.g. Bat Visage Bobber) is consumed once learned, so it's not in bags —
    -- but you still own the toy, so it's available
    if PlayerHasToy and type(id) == "number" and PlayerHasToy(id) then return true end
    return ((C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id)) or 0) > 0
  end
  return true
end
ns.consumableHasItem = consumableHasItem

local function itemOwned(id)
  id = tonumber(id) or id
  if type(id) ~= "number" then return false end   -- descriptor strings ("spell:<id>") aren't item/toy IDs
  return (GetItemCount(id) or 0) > 0 or (type(PlayerHasToy) == "function" and PlayerHasToy(id)) or false
end

-- seconds of cooldown left on an item/toy (0 = ready). Toys share the item-cooldown API. The GCD
-- (~1.5s) is ignored so a global cooldown never makes an item look unavailable.
local function itemCooldown(id)
  local get = (C_Item and C_Item.GetItemCooldown) or GetItemCooldown
  if not get then return 0 end
  local ok, start, dur = pcall(get, id)
  if not ok or not start or (dur or 0) <= 2 or (start or 0) <= 0 then return 0 end
  local left = start + dur - GetTime()
  return (left > 0) and left or 0
end
ns.itemCooldown = itemCooldown

-- ready to APPLY right now: owned AND off cooldown. The picker prefers these so it never loads an item
-- that can't fire (e.g. a bobber on its ~10-min item cooldown while its 60-min buff is what matters).
local function itemReady(id)
  return itemOwned(id) and itemCooldown(id) <= 0
end

-- a spell is fireable only if THIS character actually knows it (learned or via talents). This is an
-- accessibility gate, NOT a cooldown/resource check — it mirrors itemReady treating an owned item as ready
-- regardless of the GCD. Without it, a spell entry the character doesn't know (e.g. a priest spell in the
-- Buffs slot while on a mage) is fired every cycle: the cast fails ("you don't know that spell"), its buff
-- never applies, so the slot stays due and re-fires forever, blocking the rotation.
local function spellUsable(sid)
  return (IsPlayerSpell and IsPlayerSpell(sid))
      or (IsSpellKnown and IsSpellKnown(sid))
      or false
end
ns.spellUsable = spellUsable

-- ready-to-fire for a def.items ENTRY: a spell must be known on this character (else skip — never fire an
-- unknown spell); everything else defers to itemReady (owned + off cooldown).
local function entryReady(e)
  local sid = spellEntry(e)
  if sid then return spellUsable(sid) end
  return itemReady(e)
end
ns.entryReady = entryReady

-- the buff name to watch for an ENTRY (its OWN buff, independent of what's loaded): a spell's own name,
-- else the item's learned buff, else a toy's own name.
local function entryBuffName(def, e)
  local sid = spellEntry(e)
  if sid then return spellName(sid) end
  local kb = knownBoatBuff(e)
  if kb then return kb end                                -- curated boat: hardcoded buff (no cross-contamination)
  local rec = SBF.ItemKnow(e)
  return (rec and rec.buff) or (def.toy == e and defName(def)) or nil
end
ns.entryBuffName = entryBuffName

-- a consumable is "due" (effect gone) but its item is missing. Returns false so the caller SKIPS the slot
-- (falls through to fishing) instead of blocking on a dead item.
-- NOTE: the old "you're out of <item> — restock" chat warning was REMOVED 2026-07-17 — it fired
-- misleadingly often (e.g. login-time renders before item counts cache made everything look out of stock)
-- and isn't wanted. Re-add behind a debug/opt-in low-stock notice only if users ask. `acting` (real-press
-- vs passive render) is kept in the signature for callers but no longer gates a message.
local function consumableUsable(k, def, acting)   -- luacheck: ignore acting
  return consumableHasItem(def) and true or false
end

-- ===== firing modes (the pickItem resolver) =====
-- One resolver replaces the old pickRandomItem + pickOrderedItem. Reads slotMode():
--   cycle   — advance def._idx to the next list item each fire, wrapping (A->B->C->A). Variety.
--   deplete — use the FIRST owned item until it's gone, then advance ("run it out"). Burn in order.
--   random  — a random owned item excluding the previous (def._lastPick). Gated by allowsRandom.
-- Re-arms the secure button's def.item/toy/etc. + re-seeds the per-item buff when the choice
-- actually changes. No-op for a single-item (or empty) list.
local function ownedPool(def)   -- READY items only (owned + off cooldown), so the picker never lands on a CD'd one
  local pool = {}
  for _, id in ipairs(def.items or {}) do if entryReady(id) then pool[#pool + 1] = id end end
  return pool
end

-- does the slot have at least one item READY to fire right now? Used to SKIP a due slot whose items are
-- all on cooldown / unowned, so it falls through to fishing instead of blocking the cast on a dead item.
local function slotReady(def)
  if def.items and #def.items > 0 then
    for _, id in ipairs(def.items) do if entryReady(id) then return true end end
    return false
  end
  if (def.macro and def.macro ~= "") or def.spell then return true end   -- can't gauge a macro/spell — assume ready
  local iid = curItemId(def)
  if iid then return itemReady(iid) end
  return true
end
ns.slotReady = slotReady

-- load a chosen item id into the def (only when it actually changes, so we don't thrash the button
-- or the learned buff). Returns true if it changed. Handles spell entries ("spell:<id>" strings).
local function armItem(def, id)
  local sid = spellEntry(id)
  if sid then
    if def.spell == sid then return false end
    def.item, def.toy, def.macro = nil, nil, nil
    def.spell = sid
    -- track the spell's own aura by name; the aura's spellId can differ from the cast id, so clear buffSpell
    -- (name lookup is correct here; a real spellId is re-learned on the next cast if the aura differs).
    def.buff, def.buffFor, def.buffSpell = spellName(sid), itemKey(def), nil
    return true
  end
  if not id or id == curItemId(def) then return false end
  def.item, def.toy, def.spell, def.macro = id, nil, nil, nil
  seedItemBuff(def)   -- use the cached per-item buff, else clear so learnBuff re-catches it
  return true
end

-- forward declarations: pickItem (a fireAll slot) calls nextDueItem, which lives in the due-check
-- section below alongside its slotRefresh dependency. Declared here so the reference resolves to these
-- upvalues, not a nil global; the `function nextDueItem(...)` definitions below fill them in.
local slotRefresh, nextDueItem

local function pickItem(slotDef, def)
  if not def.items or #def.items < 1 then return end
  -- Falling-cast boat (Zen Flight): while airborne inside the arm window, FORCE-arm the boat that was DUE when
  -- we jumped (SBF._zenPickId, set by zenBoatDue) — not a fresh rotation pick — so the mid-fall cast is exactly it.
  if slotDef and slotDef.role == "boat" and IsFalling and IsFalling()
      and SBF._zenArm and GetTime() < SBF._zenArm and SBF._zenPickId then
    -- Keep Zen the armed pick — do NOT advance the cycle here. A missed cast leaves you falling back in, and the
    -- pick must stay Zen so it jumps you again until Zen is ACTIVE (it's permanent, so the cycle ends on it).
    armItem(def, "spell:" .. SBF._zenPickId); return
  end
  -- fireAll: no mode/rotation — arm the next item whose buff is down (the SAME one slotDue saw via
  -- nextDueItem), so buildPressMacro fires exactly it. One item per press; nil = nothing left to apply.
  if slotDef.fireAll then
    local id = nextDueItem(slotDef, def)
    if id then armItem(def, id) end
    return
  end
  local mode = slotMode(slotDef, def)
  if mode == "random" then
    local pool = ownedPool(def)
    if #pool == 0 then return end
    if #pool == 1 then armItem(def, pool[1]); def._lastPick = pool[1]; return end
    -- >=2 owned: pick a DIFFERENT item than the one currently loaded, so it ALWAYS changes
    -- (excluding the current pick, not just _lastPick, guarantees variety every cast).
    local cur = curItemId(def)
    local choices = {}
    for _, id in ipairs(pool) do if id ~= cur then choices[#choices + 1] = id end end
    if #choices == 0 then choices = pool end
    local id = choices[math.random(#choices)]
    armItem(def, id); def._lastPick = id
    if SBFDB.debug then
      print(string.format("|cff45c4a0SBF|r random %s: pool=%d -> |cffffd100%s|r",
        slotDef.id, #pool, tostring(id)))
    end
  elseif mode == "deplete" then
    -- first READY item in the drag order; advance when an earlier one is gone OR on cooldown. Toys
    -- never deplete, so deplete = the first owned-and-ready one. entryReady (not itemReady) so a
    -- "spell:<id>" entry routes through spellUsable instead of PlayerHasToy (which errors on a string).
    for _, id in ipairs(def.items) do
      if entryReady(id) then armItem(def, id); return end
    end
  else   -- cycle: advance the index each fire, wrapping. Skips items you don't own OR that are on cooldown.
    local n = #def.items
    local start = (def._idx or 0)
    for step = 1, n do
      local idx = (start + step - 1) % n + 1
      local id = def.items[idx]
      if entryReady(id) then   -- entryReady routes "spell:<id>" via spellUsable (itemReady would hit PlayerHasToy)
        def._idx = idx
        armItem(def, id)
        return
      end
    end
    -- none owned: leave whatever's loaded (consumableUsable warns about the restock)
  end
end
ns.pickItem = pickItem

-- ===== due check (slotDue) =====
-- The shared "time to (re)apply?": ride a stale (item-swapped) buff until it expires, honour the
-- apply-grace, then compare effectLeft against the refresh threshold. The burst-debt override
-- (chum) force-makes a slot due while it still OWES casts, bypassing the grace so it re-fires on
-- the next press. boat's reapply path also uses this (role handler decides whether to call it).
function slotRefresh(slotDef, def)   -- fills the forward-declared upvalue above
  -- per-slot override, else the descriptor's own default (boat is higher), else the global default
  return def.refresh or slotDef.refreshDefault or SBFDB.buffRefresh or 5
end
ns.slotRefresh = slotRefresh

-- ===== fire-all engine (fireAll slots, e.g. "Buffs") =====
-- A fireAll slot juggles N items and keeps EVERY one's buff up — not "pick one, rotate". The novelty
-- is PER-ITEM tracking: each item is due on its OWN buff, gets its OWN apply-grace, and learns its OWN
-- buffDuration. ONE helper drives both due (slotDue) and pick (pickItem) so they can NEVER disagree —
-- the slot must never re-fire an item whose buff is already up. `time()` (unix) for grace/buffDuration
-- (matches lastFired/firedAt); GetBuff's secondsLeft is live (GetTime-based) and used as-is.
--
-- Returns the FIRST item id in the slot that NEEDS applying right now, or nil if all are up.
-- "Needs applying" = ready (owned + off cooldown) AND past its own apply-grace AND its buff is gone/low
-- (live aura < refresh, or — when the aura can't be read — expired per the learned buffDuration).
function nextDueItem(slotDef, def)   -- fills the forward-declared upvalue above
  local refresh = slotRefresh(slotDef, def)
  local grace = SBFDB.applyGrace or 12
  for _, id in ipairs(def.items or {}) do
    if entryReady(id) then                                   -- skip unowned / on-cooldown items entirely
      local fired = def.firedAt and def.firedAt[id]
      if not (fired and (time() - fired) < grace) then
        local rec = SBF.ItemKnow(id)
        local name = entryBuffName(def, id)                  -- spell's own name, or item/toy buff
        local b = name and SBF.GetBuff(name)
        local left = b and b.secondsLeft
        if left then                                        -- live aura readable
          if left < refresh then return id end              -- down/low -> apply
        else                                                -- aura unreadable -> learned-duration fallback
          local bd = rec and rec.buffDuration
          if not (bd and fired and (bd - (time() - fired)) >= refresh) then
            return id                                       -- unknown or expired -> apply (and learn)
          end
        end
      end
    end
  end
  return nil
end
ns.nextDueItem = nextDueItem

local function slotDue(slotDef, def)
  local k = slotDef.id
  -- fireAll: due while ANY item still needs applying (one item per press; stays due across presses
  -- until every item's buff is up). Same helper pickItem uses, so they can't disagree.
  if slotDef.fireAll then return nextDueItem(slotDef, def) ~= nil end
  -- burst debt (chum): while it still owes casts, force it due (bypass the grace) so consecutive
  -- presses keep throwing until the debt is paid. One cast per press (secure button), so repeat=N
  -- means N due-returns over N presses.
  if (def._owe or 0) > 0 then return true end
  local refresh = slotRefresh(slotDef, def)
  -- item swapped since the buff was auto-learned: ride the OLD buff until it expires (no point
  -- re-applying while up), then forget it so the NEW item fires + re-learns. (Typed buffs have no
  -- buffFor, so they're left alone — intentional.)
  if def.buff and def.buff ~= "" and def.buffFor and def.buffFor ~= itemKey(def) then
    local b = SBF.GetBuff(def.buff)
    local left = b and b.secondsLeft
    if left and left >= refresh then return false end   -- old buff still up
    def.buff, def.buffFor, def.buffSpell = nil, nil, nil -- expired -> re-learn the new item (name + spellId)
  end
  -- grace: just fired -> let the buff land before re-evaluating. Re-firing now would restart a
  -- food/drink channel and the ~10s buff would never apply. Also throttles the unknown-buff retry.
  local last = (SBFDB.lastFired and SBFDB.lastFired[k]) or 0
  if time() - last < (SBFDB.applyGrace or 12) then return false end
  -- LIVE aura/enchant is the PRIMARY source of truth. "Fire and forget" must NOT mean "assume it's up
  -- because we fired it" — we always re-check that the buff actually EXISTS. effectLeft present -> not
  -- due, and this clears any misfire streak / back-off (the buff landed, so the slot is healthy).
  local left = effectLeft(slotDef, def)
  if left then def._applyTries = 0; def._backoffUntil = nil; return left < refresh end
  -- effectLeft is nil. If this slot's effect is CHECKABLE — an enchant (tooltip-readable) or an aura whose
  -- buff name we KNOW — then nil means the buff is genuinely GONE, so re-apply NOW. We deliberately do NOT
  -- fall back to the learned buffDuration here: a stale/too-long learned duration (e.g. 3600s) was silently
  -- suppressing a gone buff for its whole fake lifetime. The only guard is the misfire back-off below.
  local checkable = (slotDef.effect == "enchant") or (slotBuffName(def) ~= nil)
  if checkable then
    if def._backoffUntil and time() < def._backoffUntil then return false end   -- napping (postFire set it)
    return true
  end
  -- NOT checkable (buff not learned yet, or genuinely unreadable): we can't see the aura, so fall back to
  -- the learned buffDuration to avoid hammering while it's presumably still up (the brief learning window).
  local iid = curItemId(def)
  local rec = iid and SBF.ItemKnow(iid)
  local bd = rec and rec.buffDuration
  local lastFire = SBFDB.lastFired and SBFDB.lastFired[k]
  if bd and lastFire and (bd - (time() - lastFire)) >= refresh then return false end
  return true   -- nothing known: apply it (and learn buff + duration)
end
ns.slotDue = slotDue

-- ===== boat (role = "boat") =====
-- Boat shares the engine (item list, modes, learning, slotDue reapply) and adds only its firing
-- specifics. Helpers read through SBF.GetBuff now.

-- seconds left on the BEST water-walk buff among ALL of the boat slot's configured items (raft, Levitate,
-- Tuskarr Dinghy, …), or nil if none is up. A boat is satisfied by ANY of its buffs — so having raft up
-- must suppress casting Levitate (the cycle picker only tracks ONE item, which double-cast raft+levitate).
-- Resolves each entry's buff: spell entry -> the aura by spell NAME (aura id can differ from cast id);
-- curated toy -> its hardcoded buff; else the learned per-item buff (+ spellID identity) from the DB.
local function anyBoatBuffLeft(def)
  local best
  for _, e in ipairs(def.items or {}) do
    local name, spell
    local sid = spellEntry(e)
    if sid then name = spellName(sid)
    elseif knownBoatBuff(e) then name = knownBoatBuff(e)
    else local rec = SBF.ItemKnow(e); name, spell = rec and rec.buff, rec and rec.buffSpell end
    local b = (spell and SBF.GetBuffBySpell and SBF.GetBuffBySpell(spell))
           or (name and name ~= "" and SBF.GetBuff and SBF.GetBuff(name))
    if b and b.secondsLeft and (not best or b.secondsLeft > best) then best = b.secondsLeft end
  end
  return best
end
ns.anyBoatBuffLeft = anyBoatBuffLeft

-- does ANY of the boat slot's water-walk buffs currently exist? The buff lands the instant you cast —
-- BEFORE you've surfaced onto the raft — so the buff alone doesn't mean you're standing on it yet.
local function BoatBuffUp()
  local boat = SBF.ActiveSlots().boat
  if not boat then return false end
  -- satisfied by the current pick's buff (effectLeft) OR any other configured boat's buff (anyBoatBuffLeft).
  return (effectLeft(SLOT_DEF.boat, boat) ~= nil) or (anyBoatBuffLeft(boat) ~= nil)
end
ns.BoatBuffUp = BoatBuffUp

-- truly ON the raft = buff up AND surfaced (no longer swimming).
function SBF.IsOnBoat()
  return BoatBuffUp() and not IsSwimming()
end

-- Climbing onto the raft: whenever you HAVE the raft buff but are still IN THE WATER (swimming, not on it),
-- the fishing key becomes JUMP so a press (or a few) hops you up — at the surface AND underwater. This is the
-- "have a raft, floating at the surface, jump on" case; gating it on a 6s cast-window / breath (the old code)
-- wrongly went NO-OP the moment you floated at the surface past that window.
-- Guards: not in combat (can't rebind the override mid-fight) and not mid-jump (IsFalling spaces the hops so
-- we don't double-jump in the air). ANTI-BOUNCE: track when the climb episode started (_surfaceSince); if it
-- runs longer than surfaceMaxSeconds without landing, we can't reach the raft (drifted off) — stop jumping so
-- we don't bounce in place, and boatDueKind RECASTS the raft under us to reposition. The episode resets the
-- instant we're on the raft (not swimming) or the buff drops.
function SBF.Surfacing()
  if not BoatBuffUp() or not IsSwimming() then SBF._surfaceSince = nil; return false end
  if UnitAffectingCombat and UnitAffectingCombat("player") then return false end   -- can't unbind override mid-fight
  -- POST-JUMP SETTLE: each hop makes you 'falling'; stamp when. After landing, hold off re-jumping for
  -- boatJumpDelay so a fast key-mash can't jump-jump-jump in place — that never lets you settle onto the
  -- surface (stuck in falling/swimming, can't fish). The pause gives the state a beat to resolve to on-boat.
  if IsFalling and IsFalling() then SBF._boatJumpAt = GetTime(); return false end
  if SBF._boatJumpAt and (GetTime() - SBF._boatJumpAt) < (SBFDB.boatJumpDelay or 0.5) then return false end
  -- UNDERWATER (breath timer running = actually submerged; IsSubmerged lies at the surface): keep ascending
  -- — a JUMP press swims you UP toward the surface — and RESET the episode clock so surfaceMaxSeconds can't
  -- time us out mid-ascent. Without this, being submerged with a boat buff timed out after 5s -> boatDueKind
  -- fell through to RECAST, the phase-1 gate blocked that cast (can't cast while swimming), and the action
  -- key wedged into a permanent wait/no-op until you jumped by hand. The action key must stay useful (=JUMP)
  -- the whole time you're in the water, so surfaceMaxSeconds only governs the at-the-surface hop-onto-raft.
  if SBF.BreathLeft and SBF.BreathLeft() then SBF._surfaceSince = GetTime(); return true end
  -- AT THE SURFACE (not submerged): the hop-onto-raft JUMP. Off by config -> don't hop here (a jump at the
  -- surface with a water-walk buff feeds the bounce instead of ending it); underwater-ascent above still runs.
  if SBFDB.surfaceClimbJump == false then SBF._surfaceSince = nil; return false end
  SBF._surfaceSince = SBF._surfaceSince or GetTime()
  if (GetTime() - SBF._surfaceSince) > (SBFDB.surfaceMaxSeconds or 5) then return false end   -- can't reach it -> back off (recast)
  return true
end

-- boat's due: (a) swimming with no boat buff -> cast the dinghy (+ climb), or (b) on the boat with
-- the buff running low -> recast to refresh (no climb). Re-fire is suppressed while a cast is in
-- flight (the _boatCastAt window) so a mid-cast mash can't cancel it. Returns "cast" | "refresh" | nil.
local function boatDueKind(slotDef, def)
  if def.skip or not hasAction(def) then return nil end
  if UnitAffectingCombat and UnitAffectingCombat("player") then return nil end   -- never re-cast/climb in combat
  -- suppress re-cast only while THIS action's cast is still landing. The window is the action's REAL cast
  -- time (captured at fire into SBF._boatCastLen: raft ~1.5s, Levitate 0) + a small buffer so an instant
  -- cast can't double-fire before its buff registers. Falls back to climbSeconds when the cast time is
  -- unknown (macro). Climb-onto-it is separate (Surfacing / surfaceMaxSeconds) and runs for EVERY boat.
  local since = SBF._boatCastAt and (GetTime() - SBF._boatCastAt) or nil
  local castLen = (SBF._boatCastLen or SBFDB.climbSeconds or 6) + (SBFDB.boatCastBuffer or 0.5)
  local castInFlight = since ~= nil and since < castLen
  -- KEY: gate on ANY configured water-walk buff, not just the cycle's current pick — else with raft up the
  -- picker advances to Levitate, sees ITS buff missing, and casts a 2nd boat on top (the double-cast bug).
  local left = anyBoatBuffLeft(def)
  if not left then
    -- no water-walk buff detected yet. If we JUST cast (within castLen + boatBuffWait), the buff is very
    -- likely still REGISTERING — WAIT rather than cycle to a 2nd boat (raft->Levitate). Only after the max
    -- wait with still no buff (cast genuinely failed) do we allow a re-cast, so recovery still works.
    if since and since < (castLen + (SBFDB.boatBuffWait or 1.5)) then return nil end
    if IsSwimming() and not castInFlight then return "cast" end   -- in the water, no boat -> cast + climb
    return nil
  end
  -- have a boat buff but STILL in the water: SBF.Surfacing() jumps us on. If that climb episode has TIMED
  -- OUT (drifted off, can't reach it), RECAST to re-summon under us instead of bouncing.
  if IsSwimming() then
    local stuck = SBF._surfaceSince and (GetTime() - SBF._surfaceSince) > (SBFDB.surfaceMaxSeconds or 5)
    if stuck and not castInFlight then return "cast" end
    return nil
  end
  -- on the raft: refresh only when the CURRENTLY-UP boat buff is running low — NOT when the cycle's OTHER
  -- boat happens to be "due" (that was the raft+Levitate double-cast). refreshDefault=30s.
  local thresh = def.refresh or slotDef.refreshDefault or 30
  if not castInFlight and left < thresh then return "refresh" end
  return nil
end
ns.boatDueKind = boatDueKind

-- What pickItem WOULD arm next, WITHOUT mutating — so we can decide "is the due boat a falling-boat?" before
-- the press. Mirrors pickItem's cycle/deplete selection; random is non-deterministic so it returns the first
-- owned (good enough — a random pool with a falling-boat still wants the jump path when it comes up).
local function peekBoatPick(slotDef, def)
  if not def.items or #def.items < 1 then return nil end
  local mode = slotMode(slotDef, def)
  if mode == "deplete" or mode == "random" then
    for _, id in ipairs(def.items) do if entryReady(id) then return id end end
    return nil
  end
  local n = #def.items                       -- cycle: first ready at/after the current index (no advance)
  local start = (def._idx or 0)
  for step = 1, n do
    local id = def.items[(start + step - 1) % n + 1]
    if entryReady(id) then return id end
  end
  return nil
end
ns.peekBoatPick = peekBoatPick

-- Is a FALLING-boat (Zen Flight) the boat currently DUE to cast? True ONLY when: over deep water (swimming),
-- no boat buff up yet, AND the rotation's next pick is a falling-boat. This is the tight gate that fixes the
-- regressions — it does NOT fire on land (not swimming), does NOT preempt the cycle (only when the pick IS the
-- falling-boat, so a due dinghy stays a normal surface-cast), and does NOT retrigger once a boat buff is up.
-- Returns the falling-boat spell id, or nil.
local function zenBoatDue(def)
  if not def or def.skip or not hasAction(def) then return nil end
  -- Only when a boat is GENUINELY due to cast. boatDueKind already encodes "swimming + no boat buff + not
  -- mid-cast + past the buff-registration wait" — reusing it stops Zen double-casting on top of a dinghy that
  -- was JUST cast but whose buff hasn't registered yet (the "state boat, next boat" double-cast).
  if boatDueKind(SLOT_DEF.boat, def) ~= "cast" then return nil end
  local pick = peekBoatPick(SLOT_DEF.boat, def)
  local psid = pick and spellEntry(pick)
  if psid and SBFDB.fallingBoats and SBFDB.fallingBoats[psid] then return psid end
  return nil
end
ns.zenBoatDue = zenBoatDue

-- ===== ComputeNext: role-dispatched pipeline =====
-- Replaces the inline `if slotKey ==` chain. Order (design §4):
--   combat -> heal -> boat(role) -> swimming-idle -> channeling -> interact -> rotation loop -> fishing.
-- Returns def, label, slotKey, timed(bool). `timed` marks a rotation cast (stamps lastFired + learns).

-- combat: report the attack as next (the macro's [combat] block actually fires it) even though we
-- can't reconfigure buttons mid-fight.
local function roleCombat(s)
  local combatDef = SBF.SlotDef("combat")
  if InCombatLockdown() and hasAction(combatDef) then return combatDef, "Attack", "combat", false end
end

-- post-combat / post-damage heal to full. Health is a SECRET value in 12.0 (can't be compared), so
-- we guard the read and lean on "heal until health stops rising" (UNIT_HEALTH change events).
local function roleHeal(s)
  local healDef = SBF.SlotDef("heal")
  if not (hasAction(healDef) and not healDef.skip and SBF._healing) then return end
  -- accessibility gate (same rule as every other slot): if the heal is a bare SPELL this character doesn't
  -- know, don't fire it — clear the heal state so it can't get stuck retrying a cast that always fails. A
  -- macro heal can't be checked (a macro can /cast anything), so it's left to the user, like the combat macro.
  if healDef.spell and not spellUsable(healDef.spell) then SBF._healing = false; return end
  local hp, mx = UnitHealth("player"), UnitHealthMax("player")
  local secret = issecretvalue and (issecretvalue(hp) or issecretvalue(mx))
  local stable = SBF._lastHealthChange and (GetTime() - SBF._lastHealthChange) > (SBFDB.healStable or 3)
  if (not secret) and mx and mx > 0 and hp >= mx then
    SBF._healing = false                               -- health readable + full
  elseif stable then
    SBF._healing = false                               -- health stopped rising = full
  elseif (not SBF._healUntil) or GetTime() > SBF._healUntil then
    SBF._healing = false                               -- hard-stop backstop (window)
  end
  if SBF._healing then return healDef, "Heal", "heal", false end
end

-- boat: cast the dinghy from the water, surface onto it, OR recast to refresh while standing on it.
local function roleBoat(s)
  local def = s.boat
  if not def then return end
  -- Falling-boat is now ACTIVE (Zen up): advance the cycle PAST it so the next boat-need rotates on to the other
  -- boat. Done on ACTIVE (not on the cast attempt) so a missed cast keeps Zen the armed pick, but once it lands
  -- the cycle isn't stuck on Zen forever. (Idempotent: sets _idx to the falling-boat's slot each tick it's up.)
  local activeSid = SBF.FallingBoatActive and SBF.FallingBoatActive(def)
  if activeSid and def.items then
    for i, e in ipairs(def.items) do
      if spellEntry(e) == activeSid then def._idx = i; break end
    end
  end
  -- Falling-cast boat (Zen Flight): boatDueKind below only casts while SWIMMING, but Zen Flight must be cast
  -- while FALLING. Bridge them with a tight, scoped gate (zenBoatDue = falling-boat is the DUE pick over water):
  --   swimming + due  -> ARM a short window, idle here (the JUMP override lifts you). NOT on land, NOT preempting
  --                      the cycle (only when the pick IS the falling-boat), NOT once a boat buff is up.
  --   armed + airborne + its buff not yet up -> CAST it (pickItem force-arms the armed pick).
  -- Once it's active (hovering) the arm/cast stop, so it can't recast you into the atmosphere.
  local zenDue = zenBoatDue(def)
  if zenDue then
    SBF._zenArm = GetTime() + (SBFDB.zenArmWindow or 5)
    SBF._zenPickId = zenDue
    return nil, "Wait", "idle", false                 -- over water, falling-boat due: idle; JUMP override lifts you
  end
  if SBF._zenArm and GetTime() < SBF._zenArm and IsFalling and IsFalling()
      and not (SBF.FallingBoatActive and SBF.FallingBoatActive(def)) then
    return def, "Boat", "boat", true                  -- airborne within the arm window: cast the falling-boat
  end
  local kind = boatDueKind(SLOT_DEF.boat, def)
  if SBF.Surfacing() then
    return nil, "Surface", "surface", false           -- dinghy's up: jump on (handled by the JUMP override)
  end
  if kind == "cast" or kind == "refresh" then
    return def, "Boat", "boat", true                  -- cast/recast the dinghy (timed: learns its buff)
  end
end

function SBF.ComputeNext(acting)
  local s = SBF.ActiveSlots()
  local def, label, key, timed
  def, label, key, timed = roleCombat(s); if def or label then return def, label, key, timed end
  def, label, key, timed = roleHeal(s);   if def or label then return def, label, key, timed end
  def, label, key, timed = roleBoat(s);   if def or label then return def, label, key, timed end
  -- in the water but not mounting (in combat, healing, no boat, or skipped): can't fish from the water. AND you
  -- can NEVER fish while FALLING/airborne — so idle rather than futilely returning Fishing. (The falling case is
  -- what produced "state falling, next fishing" when a Zen arm window expired mid-bounce: roleBoat went nil and
  -- this fell through to Fishing. Falling -> idle keeps that from ever happening.)
  if IsSwimming() or (IsFalling and IsFalling()) then return nil, "Wait", "idle", false end
  -- line is out (channeling Fishing) -> loot the bobber
  if UnitChannelInfo and UnitChannelInfo("player") then return s.interact, "Interact", "interact", false end
  -- ready to cast: the first DUE rotation slot (effect gone/expiring), in derived priority order, else fish
  for _, k in ipairs(ROTATION_ORDER) do
    local d = s[k]
    if d and hasAction(d) and not d.skip and slotDue(SLOT_DEF[k], d) then
      if slotReady(d) then return d, k:gsub("^%l", string.upper), k, true end   -- has an owned + off-cooldown item
      consumableUsable(k, d, acting)   -- nothing ready (out of item / all on cooldown): warn (real press only) + fall through to fish
    end
  end
  return s.fishing, "Fishing", "fishing", false
end

-- short label of the next action — used by Haul's {sbf.next} token
function SBF.GetNext()
  -- When the JUMP override is live, THAT is what the key does — the ComputeNext macro (often "Wait" for the
  -- zen/surfacing idle) is what a press WOULD do if the override weren't there. Report the truth: Jump.
  if SBF._dynOverride == "JUMP" then return "Jump" end
  local _, label = SBF.ComputeNext()
  return label
end


-- ===== macro building =====

-- A fishing-action def -> a macro line, so we can prepend /sit. Items/toys/spells all go out as
-- "/cast <name>" — it summons learned toys (incl. ones whose teaching item was consumed) where
-- "/use" would look for a now-missing bag item and silently do nothing.
local function actionLine(def)
  if not def then return "" end
  if def.macro and def.macro ~= "" then return def.macro end
  local name = defName(def)
  return name and ("/cast " .. name) or ""
end
ns.actionLine = actionLine

-- Guard a fallback block so NONE of it fires in combat: insert [nocombat] into each /use|/cast|
-- /castsequence line that doesn't already carry a condition. Lets the out-of-combat action sit
-- first in the macro without stealing the press mid-fight (one protected action per keypress).
local function guardNoCombat(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local cmd = line:match("^%s*(/%a+)")
    local lc = cmd and cmd:lower()
    if lc == "/use" or lc == "/cast" or lc == "/castsequence" then
      local rest = line:gsub("^%s*" .. cmd .. "%s*", "")
      out[#out + 1] = (rest:sub(1, 1) == "[") and line or (cmd .. " [nocombat] " .. rest)
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end
ns.guardNoCombat = guardNoCombat

-- Guard a combat block so it can ONLY run in combat, regardless of /stopmacro: inject [combat]
-- into every slash command. A command that already carries a condition gets combat folded into
-- each group ([noharm][dead] -> [combat,noharm][combat,dead]). #showtooltip / /stopmacro and
-- non-command lines pass through. Stops a not-[combat]-clean combat macro from firing while fishing.
local function guardCombat(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local cmd = line:match("^%s*(/%a+)")
    local lc = cmd and cmd:lower()
    if cmd and lc ~= "/stopmacro" and lc ~= "/stopcasting" then
      local rest = line:gsub("^%s*" .. cmd .. "%s*", "")
      if rest:sub(1, 1) == "[" then
        out[#out + 1] = cmd .. " " .. rest:gsub("%[", "[combat,")
      else
        out[#out + 1] = cmd .. " [combat] " .. rest
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end
ns.guardCombat = guardCombat

-- the combat slot as a macro line guarded by [combat] (fires only in a fight). A dropped macro is
-- used as-is (guard it yourself); item/toy/spell -> /cast [combat].
local function combatLine(c)
  if not (c and (c.item or c.spell or c.toy or (c.macro and c.macro ~= ""))) then return nil end
  local line
  if c.macro and c.macro ~= "" then line = c.macro
  else local name = defName(c); line = name and ("/cast [combat] " .. name) or nil end
  -- The /targetenemy line belongs ONLY to OUR default combat macro (Single-Button Assistant) — it is NEVER
  -- added to a user's CUSTOM macro. Ships OFF by default: auto-target-on-attack keeps combat FOCUSED on the
  -- attacker, whereas /targetenemy can wander onto the wrong target (field-tested 2026-07-21). `/sbf addtarget
  -- on` opts it in for spawned-monster spots that don't auto-target. Matched EXACTLY against our default, so a
  -- custom macro (Cobra Shot, etc.) is left completely alone.
  if line == DEFAULT_COMBAT_MACRO and not (SBFDB and SBFDB.combatTarget) then
    line = DEFAULT_COMBAT_TAIL
  end
  return line
end
ns.combatLine = combatLine

-- A verb + the specific item/spell NAME for a press, so chat says exactly what's happening
-- ("applying Oversized Bobber", "activating Tuskarr Dinghy"), not the slot. Verb + fallback name
-- come from the descriptor (verb field + label), replacing DESC_VERB + SLOT_FALLBACK.
local function describeAction(slotKey)
  if not slotKey or slotKey == "fishing" then return "fishing" end
  local slotDef = SLOT_DEF[slotKey]
  local def = SBF.ActiveSlots()[slotKey]
  local name = (def and defName(def)) or (slotDef and slotDef.label) or slotKey
  return ((slotDef and slotDef.verb) or "using") .. " " .. tostring(name)
end
ns.describeAction = describeAction

-- The exact macro the Cast Fishing button fires on the next press, for the current state. Shared
-- by PreClick and the /sbf next debug so what you see is what runs. Returns macro, label, slotKey, timed.
local function buildPressMacro(acting)
  local def, label, slotKey, timed = SBF.ComputeNext(acting)
  local slotDef = slotKey and SLOT_DEF[slotKey]
  -- rotation slots pick which item to fire (mode resolver). Action slots never have an items list.
  if def and slotDef and slotDef.role == nil and def.items and #def.items > 0 then
    pickItem(slotDef, def)
  elseif def and slotDef and slotDef.role == "boat" and def.items and #def.items > 0 then
    pickItem(slotDef, def)   -- boat rotates dinghies too
  end
  local fallback = actionLine(def)
  -- pole enchant auto-applies (no click prompt): use the lure, then "use" the fishing tool's slot
  -- so the pending coat lands on it automatically.
  if slotDef and slotDef.effect == "enchant" and def and not (def.macro and def.macro ~= "") then
    local nm = defName(def)
    if nm then fallback = "/use " .. nm .. "\n/use " .. (SBFDB.poleSlot or 28) end
  end
  -- the Cast Fishing slot works empty: default to /cast Fishing. A dragged macro/item/spell overrides.
  -- BUT if the Cast Fishing slot is turned OFF (skip), the press does NOT fish at all — the macro reduces to
  -- just the combat block (when a combat action is loaded), turning the action key into a one-button combat key.
  if slotKey == "fishing" then
    if (SBF.SlotDef("fishing") or {}).skip then
      fallback = ""                                   -- fishing off: no cast (combat block, if any, takes over)
    elseif fallback == "" then
      fallback = "/cast Fishing"
    end
  end
  if slotKey == "fishing" and SBFDB.sitBeforeCast and fallback ~= "" then
    fallback = "/sit\n" .. fallback   -- sit FIRST then cast (cast-then-sit cancels the channel)
  end
  -- action FIRST ([nocombat]-guarded), bail if not in combat, then the combat block ([combat]-guarded
  -- per-line). Double-guarded on purpose.
  local combatDef = SBF.SlotDef("combat")
  local cl = (not (combatDef and combatDef.skip)) and combatLine(combatDef) or nil
  local macro = cl
    and (guardNoCombat(fallback) .. "\n/stopmacro [nocombat]\n" .. guardCombat(cl))
    or fallback
  return macro, label, slotKey, timed
end
ns.buildPressMacro = buildPressMacro

-- ===== post-fire bookkeeping (postFire) =====
-- Called from the PreClick after a press fires a rotation slot. Dispatched on slotDef.postFire:
--   "channel" -> idle-lock the button (food/drink eat/drink can't be interrupted by the next press)
--   "climb"   -> boat climb window + re-fire suppression (the JUMP-onto-raft window)
-- Also decrements the chum burst debt, and (re)arms it when a fresh due paid nothing. Buff learning
-- for aura slots is kicked off here too (the actual learnBuff lives in Core, passed in via ns).
-- Tell the user a buff-applying slot keeps firing but the buff never shows (mislearned name, an item on
-- cooldown, or a genuinely undetectable aura), so it isn't a SILENT failure. Fired once when a slot trips
-- the misfire limit and enters its back-off nap.
function ns.NotifyApplyFail(slotDef, def, tries)
  if not (SBFDB and SBFDB.debug) then return end   -- DEBUG-ONLY: fires misleadingly often in normal play
  local nm = defName(def) or (slotDef and slotDef.label) or (slotDef and slotDef.id) or "?"
  print(string.format("|cff45c4a0SBF|r |cffff6060couldn't confirm \"%s\" applied after %d tries|r — backing off %ds (buff undetectable, item on cooldown, or unusable?).",
    tostring(nm), tries or 0, SBFDB.applyBackoff or 30))
end

local function postFire(slotDef, def, timed)
  if not (slotDef and def) then return end
  if slotDef.postFire == "channel" then
    SBF._consumeUntil = GetTime() + (SBFDB.consumeSeconds or 10)   -- idle so the next press can't interrupt the channel
  elseif slotDef.postFire == "climb" then
    SBF._boatCastAt = GetTime()                                    -- start the cast / re-fire-suppression window
    -- size the window to the ACTION's real cast time (raft ~1.5s, Levitate 0) instead of a flat timer, and
    -- persist it per-item so the knowledge DB carries it (exportable). Live API read is authoritative; the
    -- stored value is the fallback. nil (macro) -> boatDueKind falls back to climbSeconds.
    local len = actionCastTime(def)
    local iid = curItemId(def)
    if len == nil and iid and SBF.ItemKnow then local k = SBF.ItemKnow(iid); len = k and k.castTime end
    if len and iid and SBF.ObserveItem then SBF.ObserveItem(iid, { castTime = len }) end
    SBF._boatCastLen = len
    SBF._surfaceSince = nil                                        -- fresh climb episode (a recast repositions the raft under us)
  end
  -- misfire back-off: count buff-applying fires. slotDue resets this to 0 the instant the buff is actually
  -- detected (effectLeft present). If it climbs to the limit, the buff never landed -> NAP (back-off so we
  -- stop hammering), FORGET a learned buff name so the next attempt re-learns it (a wrong name is the usual
  -- cause), and tell the user once. time() (unix) so the nap survives a /reload and expires correctly.
  if timed and (slotDef.effect == "aura" or slotDef.effect == "enchant") then
    def._applyTries = (def._applyTries or 0) + 1
    local maxTries = SBFDB.applyMaxTries or 3
    if def._applyTries >= maxTries then
      def._applyTries = 0
      def._backoffUntil = time() + (SBFDB.applyBackoff or 30)
      if def.buff and def.buffFor then def.buff, def.buffFor, def.buffSpell = nil, nil, nil end   -- forget likely-wrong learned name
      -- also drop the learned buffDuration for this item: the buff never showed, so the duration is
      -- unreliable — and once the name is forgotten the slot goes "not-checkable" and would otherwise
      -- fall straight back onto that stale timer (the exact 3600s wedge we're fixing). Re-learned on a
      -- future successful application. (ItemKnow returns the live record; ObserveItem can't clear a field.)
      local iid = curItemId(def)
      local rec = iid and SBF.ItemKnow(iid)
      if rec then rec.buffDuration = nil end
      if ns.NotifyApplyFail then ns.NotifyApplyFail(slotDef, def, maxTries) end
    end
  end
  -- burst debt (chum): when a slot that owes nothing becomes due, seed the debt; each fire pays one.
  if timed and slotDef.allowsRepeat then
    local count = math.max(1, math.floor(tonumber(def["repeat"]) or 1))
    if (def._owe or 0) <= 0 then def._owe = count end   -- fresh burst
    def._owe = def._owe - 1                              -- this press paid one
    if def._owe < 0 then def._owe = 0 end
  end
end
ns.postFire = postFire

-- the descriptor for a slot id (Core/Options read this at runtime).
function ns.SlotDef(slotKey) return SLOT_DEF[slotKey] end

ns.LEARN_SKIP = LEARN_SKIP   -- generic consume auras to skip when learning (Core's learnBuff reads it)
