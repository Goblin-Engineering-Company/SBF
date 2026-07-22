-- Items.lua — the ONE consolidated per-item knowledge record. Keyed by the bare numeric item id; lives
-- in the shared output store (SBF.OutputDB("items") -> SBFData.db.items) so it's exportable for the
-- future aggregator. Absorbs the old SBFDB.itemBuffs (buff name) + SBFDB.learned (slots/maps/allZones)
-- and adds buffDuration + cooldown. Last-observed-wins: every observation overwrites + stamps `seen`.
--
-- Record shape (see docs/superpowers/specs/2026-06-09-sbf-item-knowledge-db-design.md):
--   { name, buff, buffSpell, buffDuration, cooldown, castTime, slots = {slotType=true}, maps = {[mapID]=name},
--     allZones, source = "learned"|"user-added", seen = <unix> }
-- (buff = the buff's display name; buffSpell = its spellID identity — stable across locale/rename/secret.)
-- castTime = SECONDS to cast/use this item (0 = instant); observed from the game API when the item fires,
-- used to size the boat re-cast window. Additive + optional — a nil castTime just means "not observed yet".
local _, ns = ...
SBF = SBF or {}

-- the backing table (created on first access by the output store). nil-safe before SBFData exists.
local function store()
  return (SBF.OutputDB and SBF.OutputDB("items")) or nil
end

-- READ-ONLY: the record for an item id, or nil if we've never observed it. Used by the firing due-check
-- and all readers, so it never creates empty records for items merely being checked.
function SBF.ItemKnow(id)
  id = tonumber(id) or id
  local db = store()
  return (id and db and db[id]) or nil
end

-- WRITE: create the record if absent, merge `fields`, set source (default "learned"), bump `seen`.
-- The single write path — last-observed-wins lives here. `fields` may include any record field; nested
-- tables (slots/maps) are MERGED key-by-key, scalars OVERWRITE.
function SBF.ObserveItem(id, fields)
  id = tonumber(id) or id
  local db = store()
  if not (id and db and fields) then return end
  local r = db[id]
  if not r then r = { source = "learned" }; db[id] = r end
  -- A SECRET value (WoW 12.0 can return combat aura NAMES as secret) must never be persisted: it doesn't
  -- survive serialization to SavedVariables, so writing it would blank the field on reload (the reported
  -- item-buff "unlearning"). Skip it here at the ONE write path so the last good value is kept instead of
  -- clobbered. buffSpell (a number) is never secret, so the durable identity always survives.
  local function secret(v) return issecretvalue and issecretvalue(v) or false end
  for k, v in pairs(fields) do
    if secret(v) then                       -- drop a secret scalar/table wholesale — never store it
      -- keep the existing r[k]
    elseif type(v) == "table" then
      r[k] = r[k] or {}
      for kk, vv in pairs(v) do
        if not secret(vv) then r[k][kk] = vv end   -- and drop any secret nested value
      end
    else
      r[k] = v
    end
  end
  r.seen = time()
  return r
end

-- One-time migration: fold the legacy SBFDB.itemBuffs + SBFDB.learned into SBFData.db.items, then drop
-- them (Task 8 removes the drop's last readers; this just carries data forward). Guarded by a flag.
function SBF.MigrateItemKnowledge()
  if not (SBFDB and SBFData) then return end
  if SBFData._itemsMigrated then return end
  local db = store(); if not db then return end
  -- buff names
  if SBFDB.itemBuffs then
    for id, buff in pairs(SBFDB.itemBuffs) do
      if buff and buff ~= "" then SBF.ObserveItem(id, { buff = buff }) end
    end
  end
  -- learned location catalog
  if SBFDB.learned then
    for id, e in pairs(SBFDB.learned) do
      SBF.ObserveItem(id, { name = e.name, slots = e.slots, maps = e.maps, allZones = e.allZones })
    end
  end
  SBFData._itemsMigrated = true
  SBFDB.itemBuffs, SBFDB.learned = nil, nil   -- consolidated into SBFData.db.items
end

ns.ItemKnow, ns.ObserveItem = SBF.ItemKnow, SBF.ObserveItem   -- intra-pack aliases (mirrors Buffs' ns.GetBuff)
