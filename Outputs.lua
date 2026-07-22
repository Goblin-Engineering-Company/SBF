-- Outputs.lua — the placeholder home for SBF's saved OUTPUT databases.
--
-- Design reading #1: a single structured, VERSIONED SavedVariable (SBFData) that every saveable
-- OUTPUT stream collects into — the fishing log, the action log, the learned-item catalog, session
-- stats, and whatever we add later. It's created NOW, ahead of need, so new outputs just DROP IN via
-- SBF.OutputDB("<name>") with no .toc edit / client restart each time. The shape is versioned so we
-- can migrate it cleanly, and it maps onto the planned companion data app later.
--
-- Boundaries: this file is OUTPUTS only. Per-character/account CONFIG still lives in SBFDB; this is a
-- separate SavedVariable (SBFData, declared in SBF.toc) so outputs survive a config reset and export
-- cleanly. Nothing collects into it yet — existing outputs (SBFDB.fishlog/.learned) are left where
-- they are; migrating them here is a later, deliberate step.
local _, ns = ...
SBF = SBF or {}

local SCHEMA_VERSION = 1

-- Ensure the top-level store exists. SavedVariables are restored by the client before any consumer
-- runs, so this just fills in a fresh/empty one on first touch. `version` lets us migrate the shape
-- later; every named database lives under `.db`.
local function ensureStore()
  SBFData = SBFData or {}
  SBFData.version = SBFData.version or SCHEMA_VERSION
  SBFData.db = SBFData.db or {}     -- name -> a persistent database table
  return SBFData
end

-- Get (creating on first use) a named output database. This is the "drop a database in as needed"
-- entry point: `local log = SBF.OutputDB("fishlog")` returns a persistent table you write into, and
-- the client saves it on logout. Reuse the same name to get the same table back.
function SBF.OutputDB(name)
  local store = ensureStore()
  store.db[name] = store.db[name] or {}
  return store.db[name]
end
ns.OutputDB = SBF.OutputDB

-- The whole versioned store (for export / the companion app). Everything is under `.db[<name>]`.
function SBF.OutputStore()
  return ensureStore()
end
