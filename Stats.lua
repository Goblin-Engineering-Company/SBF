-- Stats.lua — the permanent fishing-stats ROLLUP + on-the-fly period views behind the Stats tab.
--
-- Why this file exists: the Log (SBFData.streams.events, formerly streams.fishlog) is a CAPPED, CLEARABLE buffer — anything
-- computed straight off it loses history the moment it's trimmed or "Clear log"-ed. The Stats tab needs
-- numbers that NEVER go away, so we keep a separate, incrementally-maintained rollup in the versioned
-- output store (SBF.OutputDB("stats") -> SBFData.db.stats). New events bump it once each; Clear/trim
-- never touch it; only the Stats tab's explicit "Reset all-time stats" wipes it.
--
-- Boundaries: this is the DATA layer only (Core feeds it one line; Options renders it). Everything here
-- is account-wide-merged for v1 — the shape leaves room for a `ch` dimension later without a migration.
-- CoarsePlace + Aggregate are written as PURE functions so they could be unit-tested if a harness lands.
local ADDON, ns = ...
SBF = SBF or {}

local GECStore = LibStub("GECStore-1.0")

-- The single shared mutable namespace. sessionStartT is a RUNTIME timestamp (set by Core at
-- PLAYER_ENTERING_WORLD) marking the "This session" boundary; a /reload resets it (documented in the UI).
local Stats = { sessionStartT = nil }

-- ============================ rollup shape helpers ============================
-- A rollup-shaped table: the persistent all-time figure AND every live period view share this one shape,
-- so the render layer is identical regardless of source. v = schema version (for a future migration).
local function newRollup()
  return {
    v = 1, firstT = nil, lastT = nil, totalDur = 0,
    kinds = {},   -- [kind] = count        (caught/expired/missed/interrupt/castfail/action/buff)
    interrupts = {},  -- [cause] = count   (combat/moving/jump/unknown) — breakdown of the interrupt kind
    items = {},   -- [itemID] = { n, name, link, last }   (global per-fish tally; name/link denormalized once)
    zones = {},   -- [zoneKey] = { cont, zone, kinds, dur, items = { [itemID] = count }, lastT }  (coarse cont/zone buckets; lastT powers the zone "recent" sort)
  }
end

-- Defend the persistent table's shape: it can be {} on first ever touch, or wiped by Reset, so callers
-- that write into it must ensure the sub-tables exist first. Idempotent.
local function ensureShape(roll)
  roll.v        = roll.v or 1
  roll.totalDur = roll.totalDur or 0
  roll.kinds    = roll.kinds or {}
  roll.interrupts = roll.interrupts or {}
  roll.items    = roll.items or {}
  roll.zones    = roll.zones or {}
  roll.chars    = roll.chars or {}   -- per-character layer (only meaningful on the top-level rollup; harmless elsewhere)
  return roll
end

-- Get (creating on first use) a coarse continent/zone bucket inside a rollup.
local function ensureZone(roll, zoneKey, cont, zone)
  local z = roll.zones[zoneKey]
  if not z then
    z = { cont = cont, zone = zone, kinds = {}, dur = 0, items = {} }
    roll.zones[zoneKey] = z
  end
  return z
end

-- Live midnight as a unix timestamp, from the LOCAL clock (date("*t") is local time). Used by the Today
-- period filter — records with t >= this are "today".
local function midnightT()
  local d = date("*t")
  d.hour, d.min, d.sec = 0, 0, 0
  return time(d)
end

-- Shallow filter: the subset of `records` with t >= minT AND (when chSet is given) e.ch in chSet, order
-- preserved (oldest-first). One pass does both the period and per-character cut. chSet nil = all characters
-- (an EMPTY set keeps nothing — the "no characters shown" state). Pure.
local function filterRecords(records, minT, chSet)
  local out = {}
  if records then
    for i = 1, #records do
      local e = records[i]
      if e and e.t and e.t >= minT and (chSet == nil or chSet[e.ch]) then out[#out + 1] = e end
    end
  end
  return out
end

-- ============================ coarse place key ============================
-- Collapse a full place cascade (array of { name, kind } broad->specific) to the v1 grain: continent +
-- first zone only (sub-areas of one zone all merge to a single row). Returns zoneKey, cont, zone.
--   * cont = the first kind=="continent" entry's name.
--   * zone = the first kind=="zone" entry's name, or "" if none ("(unknown zone)" bucket).
--   * no continent at all (rare / missing place): cont = first entry name (or "Unknown"), zone = "".
-- zoneKey uses \1 as the separator (a char no place name contains) so cont/zone can't collide.
function Stats.CoarsePlace(cascade)
  -- KEY by mapID (locale/rename stable), DISPLAY by name. Cascade levels now carry mapID (via
  -- GECReader.Current.location()); a level without one (the area leaf, or an old pre-mapID record) falls
  -- back to its name in the key so buckets still dedup deterministically.
  local cont, zone, contID, zoneID
  if cascade then
    for i = 1, #cascade do
      local entry = cascade[i]
      if entry then
        if entry.kind == "continent" and not cont then cont, contID = entry.name, entry.mapID
        elseif entry.kind == "zone" and not zone then zone, zoneID = entry.name, entry.mapID end
      end
    end
  end
  if not cont then
    -- no continent in the cascade: fall back to the first entry's name/mapID as the bucket; zone forced empty.
    cont = (cascade and cascade[1] and cascade[1].name) or "Unknown"
    contID = cascade and cascade[1] and cascade[1].mapID
    zone, zoneID = "", nil
  end
  cont = cont or "Unknown"
  zone = zone or ""
  local key = tostring(contID or cont) .. "\1" .. tostring(zoneID or zone)
  return key, cont, zone
end

-- ============================ accumulation ============================
-- Tally one caught ITEM into both the global per-fish table and the zone's fish×zone leaf. `fi` is any table
-- with id/name/link/count (a record `e` itself for a single-item catch, or one entry of e.items for a
-- multi-item catch). Counts every item — a cast can land several at once.
local function addCatchItem(roll, z, fi, t)
  if not (fi and fi.id) then return end
  local add = fi.count or 1
  local it = roll.items[fi.id]
  if not it then it = { n = 0 }; roll.items[fi.id] = it end
  it.n = it.n + add
  if fi.name then it.name = fi.name end                  -- denormalize name/link once (cheap By-fish render)
  if fi.link then it.link = fi.link end
  if fi.q ~= nil then it.q = fi.q end                    -- item quality (0=Poor): drives the "Vendor trash" grouping + quality sort
  if t and (not it.last or t > it.last) then it.last = t end   -- powers the "recent" sort
  z.items[fi.id] = (z.items[fi.id] or 0) + add
end

-- Fold ONE log record into a rollup (mutates roll). The SINGLE accumulator used by BOTH the persistent
-- Record path AND the pure Aggregate (period views + backfill), so all-time and period numbers can never
-- be computed differently. Resolves the record's interned place via GECStore.PlaceInfo on the read side.
local function accumulate(roll, e)
  local k = e and e.k
  if not k then return end
  roll.kinds[k] = (roll.kinds[k] or 0) + 1
  if k == "interrupt" then                                  -- break interrupts down by cause (combat vs movement vs …)
    roll.interrupts = roll.interrupts or {}
    local cause = e.cause or "unknown"
    roll.interrupts[cause] = (roll.interrupts[cause] or 0) + 1
  end
  if e.t then
    roll.firstT = roll.firstT or e.t                      -- earliest counted (records arrive oldest-first)
    if not roll.lastT or e.t > roll.lastT then roll.lastT = e.t end   -- max(): robust even for an unordered slice
  end
  if e.dur then roll.totalDur = roll.totalDur + e.dur end   -- line-in-water time
  -- coarse continent/zone bucket (Unknown bucket when the place can't be resolved)
  local zoneKey, cont, zone = Stats.CoarsePlace(GECStore.PlaceInfo(e.p))
  local z = ensureZone(roll, zoneKey, cont, zone)
  z.kinds[k] = (z.kinds[k] or 0) + 1
  if e.dur then z.dur = z.dur + e.dur end
  if e.t then z.lastT = math.max(z.lastT or 0, e.t) end   -- newest activity in this zone (drives the zone "recent" sort)
  -- per-fish + fish×zone cross-tab. kinds.caught above is ONE per cast (so catch-rate stays cast-based);
  -- here we tally EVERY item the cast landed. e.items holds the full loot list on a multi-item catch;
  -- otherwise the single e.id/e.count carries it. A parse-miss catch (no id) still counts as kinds.caught,
  -- it just has nothing to tally under here.
  if k == "caught" then
    if e.items then
      for i = 1, #e.items do addCatchItem(roll, z, e.items[i], e.t) end
    elseif e.id then
      addCatchItem(roll, z, e, e.t)
    end
  end
end

-- ============================ pure aggregator ============================
-- Aggregate an array of log records into a fresh rollup-shaped table. PURE (no side effects, no globals
-- written) — reused by both the one-time backfill and the live period views.
function Stats.Aggregate(records)
  local roll = newRollup()
  if records then
    for i = 1, #records do accumulate(roll, records[i]) end
  end
  return roll
end

-- Merge one rollup INTO another (dst += src; mutates dst). Sums kinds & totalDur, takes min firstT / max
-- lastT, and deep-merges the items table (sum n; keep name/link/q; max last) and the zones cross-tab (sum
-- each zone's kinds, dur, and per-zone item counts). The inverse-free counterpart to accumulate: it folds
-- whole rollups (the per-character slices) rather than single records. Pure (no globals written).
local function mergeRollup(dst, src)
  if not src then return dst end
  for k, n in pairs(src.kinds or {}) do dst.kinds[k] = (dst.kinds[k] or 0) + n end
  for cause, n in pairs(src.interrupts or {}) do dst.interrupts[cause] = (dst.interrupts[cause] or 0) + n end
  dst.totalDur = (dst.totalDur or 0) + (src.totalDur or 0)
  if src.firstT and (not dst.firstT or src.firstT < dst.firstT) then dst.firstT = src.firstT end
  if src.lastT and (not dst.lastT or src.lastT > dst.lastT) then dst.lastT = src.lastT end
  for id, sit in pairs(src.items or {}) do
    local it = dst.items[id]
    if not it then it = { n = 0 }; dst.items[id] = it end
    it.n = it.n + (sit.n or 0)
    if sit.name then it.name = sit.name end
    if sit.link then it.link = sit.link end
    if sit.q ~= nil then it.q = sit.q end
    if sit.last and (not it.last or sit.last > it.last) then it.last = sit.last end
  end
  for zoneKey, sz in pairs(src.zones or {}) do
    local z = dst.zones[zoneKey]
    if not z then z = { cont = sz.cont, zone = sz.zone, kinds = {}, dur = 0, items = {} }; dst.zones[zoneKey] = z end
    for k, n in pairs(sz.kinds or {}) do z.kinds[k] = (z.kinds[k] or 0) + n end
    z.dur = (z.dur or 0) + (sz.dur or 0)
    if sz.lastT and (not z.lastT or sz.lastT > z.lastT) then z.lastT = sz.lastT end   -- newest of the two slices
    for id, n in pairs(sz.items or {}) do z.items[id] = (z.items[id] or 0) + n end
  end
  return dst
end

-- ============================ persistent rollup ============================
-- The all-time rollup lives in the versioned output store, so introducing it needs no .toc change and it
-- exports alongside the journal for the planned companion app.
local function statsDB()
  return ensureShape(SBF.OutputDB("stats"))
end

-- Get (creating on first use) the per-character rollup for GECStore character index `ch`. Lives beside the
-- top-level all-time figure under stats.chars[ch] and shares the SAME rollup shape, so the render layer is
-- identical whether it reads the account-wide total or one character's slice. Shape-guaranteed.
local function ensureChar(ch)
  local s = statsDB()
  local c = s.chars[ch]
  if not c then c = {}; s.chars[ch] = c end
  return ensureShape(c)
end

-- Build a fresh rollup by merging the per-character slices for every ch in `chSet` (a {[ch]=true} set of
-- SHOWN characters). Returns a rollup-shaped table the render layer treats like any other. An empty/nil set
-- yields an empty rollup (the caller passes nil only for "all characters", which never routes here).
function Stats.MergeChars(chSet)
  local roll = newRollup()
  if chSet then
    local chars = statsDB().chars
    for ch in pairs(chSet) do mergeRollup(roll, chars[ch]) end
  end
  return roll
end

-- Increment the persistent rollup by one freshly-logged event. Called from Core.logFishEvent right after
-- store:Append, with the SAME `e` the stream holds (Append stamps e.t/e.gen in place). Exactly once per
-- logFishEvent call, so a /reload mid-session can't double-count.
function Stats.Record(e)
  if not e then return end
  accumulate(statsDB(), e)
  -- ALSO fold it into this event's character slice (an independent layer — never double-counts the
  -- top-level total above, which stays the all-characters all-time figure). e.ch is stamped by Core.
  local ch = e.ch
  if ch then accumulate(ensureChar(ch), e) end
end

-- One-time backfill: on the first load that finds no `backfilled` flag, SEED the all-time rollup from
-- whatever the current log buffer holds (the only history we have) and arm the flag so it never runs
-- twice. From there the rollup grows forward from new events. Idempotent.
function Stats.EnsureBackfill()
  local roll = statsDB()
  if roll.backfilled then return end
  local seed = Stats.Aggregate(SBF.FishLog and SBF.FishLog() or nil)
  -- copy the seed's fields into the persistent table (its sub-tables are fresh, so they become persistent)
  roll.v, roll.firstT, roll.lastT, roll.totalDur = seed.v, seed.firstT, seed.lastT, seed.totalDur
  roll.kinds, roll.items, roll.zones = seed.kinds, seed.items, seed.zones
  roll.backfilled = true
end

-- One-time PER-CHARACTER backfill, on a SEPARATE flag from EnsureBackfill (the two layers seed independently
-- and must never re-seed each other): the first load with no `charsBackfilled` walks the log buffer grouped
-- by record .ch and folds each character's records into stats.chars[ch], then arms the flag so it never
-- re-runs. The top-level all-time rollup is untouched here. Idempotent.
function Stats.EnsureCharBackfill()
  local s = statsDB()
  if s.charsBackfilled then return end
  local recs = SBF.FishLog and SBF.FishLog() or nil
  if recs then
    for i = 1, #recs do
      local e = recs[i]
      local ch = e and e.ch
      if ch then accumulate(ensureChar(ch), e) end
    end
  end
  s.charsBackfilled = true
end

-- One-time INTERRUPT-CAUSE backfill (its own flag). The interrupt sub-tally (combat/moving/jump/unknown) was
-- added after the rollup already held plain interrupt totals, so seed the breakdown from the log buffer once —
-- into BOTH the top-level rollup and each character's slice. Records carry .cause. Any older interrupts already
-- trimmed from the buffer stay uncounted here and surface as the "unknown" remainder at render. Idempotent.
function Stats.EnsureInterruptBackfill()
  local s = statsDB()
  if s.interruptsBackfilled then return end
  local recs = SBF.FishLog and SBF.FishLog() or nil
  if recs then
    for i = 1, #recs do
      local e = recs[i]
      if e and e.k == "interrupt" then
        local cause = e.cause or "unknown"
        s.interrupts[cause] = (s.interrupts[cause] or 0) + 1
        local ch = e.ch
        if ch then local c = ensureChar(ch); c.interrupts[cause] = (c.interrupts[cause] or 0) + 1 end
      end
    end
  end
  s.interruptsBackfilled = true
end

-- One-time PER-ZONE-TIME backfill (its own flag). The per-zone `lastT` (newest activity in a zone, used by the
-- By-zone "recent" sort) was added after the rollup already held zone buckets, so seed it from the log buffer
-- once — folding each record's e.t into its zone's lastT in BOTH the top-level rollup and each character's slice
-- (same CoarsePlace -> ensureZone resolution accumulate uses). The live period views compute lastT for free via
-- accumulate, so this only fixes the persistent rollups. Any records already trimmed from the buffer stay
-- uncounted, so their zones simply sort last under "recent" until re-fished. Idempotent.
function Stats.EnsureZoneTimeBackfill()
  local s = statsDB()
  if s.zoneTimeBackfilled then return end
  local recs = SBF.FishLog and SBF.FishLog() or nil
  if recs then
    for i = 1, #recs do
      local e = recs[i]
      if e and e.t then
        local zoneKey, cont, zone = Stats.CoarsePlace(GECStore.PlaceInfo(e.p))
        local z = ensureZone(s, zoneKey, cont, zone)
        z.lastT = math.max(z.lastT or 0, e.t)
        local ch = e.ch
        if ch then
          local c = ensureChar(ch)
          local cz = ensureZone(c, zoneKey, cont, zone)
          cz.lastT = math.max(cz.lastT or 0, e.t)
        end
      end
    end
  end
  s.zoneTimeBackfilled = true
end

-- Return a rollup-shaped table for the requested period, optionally filtered to a SET of shown characters
-- `chSet` ({[ch]=true}; nil = all characters). "session" / "today" aggregate the live buffer filtered by
-- timestamp AND character set in one pass. "all" reads the permanent figure: the top-level full-history
-- rollup when chSet is nil (all chars), or a merge of the selected per-char slices for a subset. All return
-- the SAME shape, so the render layer is source-agnostic.
function Stats.GetSet(period, chSet)
  -- The reset line: after a Reset, This session / Today must also read empty and refill forward (they're
  -- computed live from the still-intact log, so without this they'd keep showing pre-reset activity). Raise
  -- each period's lower bound to the reset moment. All-time naturally reads empty (its rollup was wiped).
  local resetT = statsDB().resetT or 0
  if period == "session" then
    -- Boundary = the CURRENT open session's start (SBF.SessionStartT), so starting a new session re-baselines
    -- "This session". Falls back to the login/reset baseline (sessionStartT) when there are no markers yet.
    local sessT = (SBF.SessionStartT and SBF.SessionStartT()) or Stats.sessionStartT or 0
    return Stats.Aggregate(filterRecords(SBF.FishLog and SBF.FishLog() or nil, math.max(sessT, resetT), chSet))
  elseif period == "today" then
    return Stats.Aggregate(filterRecords(SBF.FishLog and SBF.FishLog() or nil, math.max(midnightT(), resetT), chSet))
  end
  if chSet == nil then return statsDB() end   -- all characters → the permanent all-characters full-history figure
  return Stats.MergeChars(chSet)              -- a subset → merge the selected per-char slices (history back to the log buffer)
end

-- Back-compat single-character form: thin wrapper over GetSet. ch nil = all characters.
function Stats.Get(period, ch)
  return Stats.GetSet(period, ch and { [ch] = true } or nil)
end

-- Character indices that should populate the Stats-tab filter dropdown: every key in stats.chars UNION the
-- current character (so the active char always shows even with no recorded data yet). De-duped.
function Stats.CharList()
  local s = statsDB()
  local seen, out = {}, {}
  for ch in pairs(s.chars) do
    if not seen[ch] then seen[ch] = true; out[#out + 1] = ch end
  end
  local cur = GECStore.CharIndex and GECStore.CharIndex()
  if cur and not seen[cur] then out[#out + 1] = cur end
  return out
end

-- The ONLY path that clears the all-time rollup (the Stats tab's confirm-gated "Reset all-time stats").
-- A deliberate reset must STICK: we wipe the contents but KEEP `backfilled = true`, so the next load's
-- EnsureBackfill does NOT re-seed the cleared totals straight back from the (still-full) log buffer —
-- which would make the reset look like it "didn't work" after a /reload. The totals then grow forward
-- from NEW casts only. Never touches the log stream — Clear-log and Reset-stats stay fully independent
-- (use "Clear log" on the Log tab too if you want a completely fresh slate).
function Stats.Reset()
  local s = SBF.OutputDB("stats")
  wipe(s)
  s.v = 1
  s.backfilled = true
  s.chars = {}            -- clear the per-character layer too
  s.charsBackfilled = true   -- re-arm its flag so a reset STAYS empty (no re-seed from the still-full log on next load)
  s.interruptsBackfilled = true   -- same: don't re-seed the (now empty) interrupt breakdown from the log on next load
  s.zoneTimeBackfilled = true   -- same: don't re-seed per-zone lastT from the still-full log on next load
  s.resetT = time()       -- the reset moment: This session / Today now count from HERE (raised in GetSet), not the full log
end

SBF.Stats = Stats
ns.Stats = Stats
