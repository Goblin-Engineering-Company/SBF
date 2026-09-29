-- Reach.lua — what SBF does when the fishing bobber lands beyond the interact key's reach.
--
-- The interact key only reels a bobber the client will soft-target, and on WoW: Forever that stops short of the
-- farthest casts no matter what (probed 2026-09-23: SoftTargetInteractRange accepted 60, arc 0-2 made no difference,
-- camera tilt made no difference, a MOUSE click still reels them). Gear.lua raises the range while fishing; this
-- file handles the bobbers that are still out of reach, per SBFDB.reachMode:
--   "recast"    = the next press drops the line and recasts (the cast is logged as its own "unreachable" kind,
--                 outside the cast percentages; see Stats). Default on WoW: Forever / Classic.
--   "mouseover" = the interact keys (and the fishing key in one-button mode) become Blizzard's Interact with
--                 Mouseover: point at the bobber and press.
--   "off"       = leave the keys alone. Default on retail.
-- An optional sound (SBFDB.reachSound) plays once per out-of-reach cast.
-- (no addon-namespace use: everything here hangs off the SBF global)
SBF = SBF or {}

-- Bobber reach is a WoW: Forever / Classic feature: that's where the interact key can't reach every cast. Its
-- Settings section shows only on those clients, and every mode defaults to off on retail.
function SBF.ShowReachSettings() return SBF.CLASSIC_GEAR == true end

-- The modes this build knows (an unknown saved value falls back to the default), which of them turn the interact
-- keys into Interact with Mouseover, and the on-screen alert each one shows. Tables, so a mode can be added from
-- another file without touching this one.
SBF.REACH_MODES = SBF.REACH_MODES or {}
SBF.REACH_MODES.recast, SBF.REACH_MODES.mouseover, SBF.REACH_MODES.off = true, true, true
SBF.REACH_MOUSEOVER = SBF.REACH_MOUSEOVER or {}
SBF.REACH_MOUSEOVER.mouseover = true
SBF.REACH_ALERT = SBF.REACH_ALERT or {}
SBF.REACH_ALERT.recast = "Bobber out of reach - press to recast"
SBF.REACH_ALERT.mouseover = "Bobber out of reach - point at it and press"

function SBF.ReachMode()
  local m = SBFDB.reachMode
  if m == nil or not SBF.REACH_MODES[m] then m = SBF.CLASSIC_GEAR and "recast" or "off" end
  return m
end

function SBF.PlayReachSound()
  if SBFDB.reachSoundMode == "file" and SBFDB.reachSoundFile and SBFDB.reachSoundFile ~= "" then
    return PlaySoundFile(SBFDB.reachSoundFile, "Master")
  end
  return PlaySound(SBFDB.reachSoundId or 8959, "Master")
end

-- ---- detection ----
-- Once the bobber has landed (reachGrace seconds into the channel), is the interact key unable to target it? LIVE
-- state, debounced: the key must have had nothing soft-targeted CONTINUOUSLY for reachNilGrace seconds. Two false
-- alarms shaped this. v1 latched a mid-flight glimpse as "reachable" for the whole cast (so it never fired); the
-- next version fired on EVERY reel, because the bobber despawns a beat before the Fishing channel ends and that
-- beat read as "nothing targetable". That beat is a frame or two; a genuinely unreachable bobber stays unreachable.
-- Timing (tunable): reachGrace 1.0s for the bobber to land, then reachNilGrace 0.3s of nothing targetable, so a far
-- cast is flagged about 1.3s after the cast (was ~2s).
function SBF.BobberOutOfReach()
  if SBF.ReachMode() == "off" or not (SBF.IsFishingChannel and SBF.IsFishingChannel()) then
    SBF._reachNilSince = nil
    return false
  end
  local _, _, _, startMs = UnitChannelInfo("player")
  if not startMs or (issecretvalue and issecretvalue(startMs)) then return false end
  local now = GetTime()
  if (now - startMs / 1000) < (SBFDB.reachGrace or 1.0) then SBF._reachNilSince = nil return false end   -- in flight
  local g = UnitGUID and UnitGUID("softinteract")
  if g and ((issecretvalue and issecretvalue(g)) or g:find("^GameObject")) then   -- unreadable = never block the key
    SBF._reachNilSince = nil
    if SBFDB.reachTrace and SBF._reachSeenFor ~= startMs and SBF.Emit then        -- timing, once per cast
      SBF._reachSeenFor = startMs
      SBF.Emit(("|cff45c4a0SBF reach|r targetable at +%.1fs (range %s)"):format(now - startMs / 1000,
        tostring(C_CVar.GetCVar("SoftTargetInteractRange"))))
    end
    if not (issecretvalue and issecretvalue(g)) then           -- learn the bobber's localized name for the search
      local n = UnitName("softinteract")
      if n and not (issecretvalue and issecretvalue(n)) then SBF._bobberName = n end
    end
    return false
  end
  if SBF._reachNilCast ~= startMs then SBF._reachNilCast, SBF._reachNilSince = startMs, now end
  SBF._reachNilSince = SBF._reachNilSince or now
  if (now - SBF._reachNilSince) < (SBFDB.reachNilGrace or 0.3) then return false end
  if SBF._reachWarnedFor ~= startMs then                         -- once per cast
    SBF._reachWarnedFor = startMs
    SBF._chanOOR = true                                          -- this cast went out of reach (the Stats metric)
    if SBFDB.reachTrace and SBF.Emit then
      SBF.Emit(("|cff45c4a0SBF reach|r OUT OF REACH at +%.1fs (range %s)"):format(now - startMs / 1000,
        tostring(C_CVar.GetCVar("SoftTargetInteractRange"))))
    end
    local mode = SBF.ReachMode()
    if mode == "recast" then SBF._chanUnreachable = true end     -- ended by the recast: its own log kind
    if SBFDB.reachSound then SBF.PlayReachSound() end
    if SBFDB.reachAlert ~= false and UIErrorsFrame then
      local msg = SBF.REACH_ALERT[mode]
      if msg then UIErrorsFrame:AddMessage(msg, 1, 0.82, 0) end
    end
    if not SBF._reachTipShown and SBFDB.reachTip ~= false then     -- once per session: the camera caveat
      SBF._reachTipShown = true
      print("|cff45c4a0SBF|r The interact key can only grab a bobber your camera can see. Zoomed all the way in, or looking down at your feet, a far cast lands off screen and reads as out of reach. Zoom out a little and look out over the water.")
    end
    if SBF.OnOutOfReach then SBF.OnOutOfReach(mode) end         -- optional hook for other code
  end
  return true
end

-- The INTERACT keys follow the bobber's reach too. In a two-button setup the fishing key never becomes the reel key
-- (it stays CLICK SBFBtn_fishing all channel), so the player reels with a separate key bound to Blizzard's Interact
-- with Target, or SBF's interact slot. Confirmed live 2026-09-23: the fishing-key switch alone never reached that
-- player. So while the bobber is out of reach (in a mouseover mode), THOSE keys become Interact with Mouseover
-- and go back the moment it isn't. Own override owner, so it never touches the fishing key's JumpController; the
-- fishing keys themselves are skipped. Out of combat only (override bindings are protected). Called from Core's
-- UpdateFishKey poll.
function SBF.UpdateReachInteractKeys()
  if InCombatLockdown() then return end
  if not SBF._reachOwner then SBF._reachOwner = CreateFrame("Frame") end
  local mode = SBF.ReachMode()
  local oor = SBF.BobberOutOfReach()       -- polled here in EVERY mode: recast needs the message, sound and log flags too
  local want = (SBF.REACH_MOUSEOVER[mode] and oor) or false
  if want == SBF._reachOverride then return end
  SBF._reachOverride = want
  ClearOverrideBindings(SBF._reachOwner)
  if not want then return end
  local skip = {}
  for _, k in ipairs(SBF.BindsFor("fishing") or {}) do skip[k] = true end
  local GECBind = LibStub and LibStub:GetLibrary("GECBind-1.0", true)
  for _, list in ipairs({ (GECBind and GECBind.Keys("INTERACTTARGET")) or {}, SBF.BindsFor("interact") or {} }) do
    for _, k in ipairs(list) do
      if k ~= "" and not skip[k] then skip[k] = true; SetOverrideBinding(SBF._reachOwner, true, k, "INTERACTMOUSEOVER") end
    end
  end
end
