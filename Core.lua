-- SBF — fishing helper. Each "slot" (food/drink/lure/boat/cast/interact + custom
-- buttons) is backed by a hidden SecureActionButton pre-loaded with an item or
-- macro, and bound to a key combo via an override binding. An addon can't press
-- keys itself — you press the combo (one key), and the secure button fires the
-- item/macro. That's why combos (CTRL/ALT/SHIFT) matter.
local ADDON, ns = ...
SBF = SBF or {}

-- BUILD STAMP — the SINGLE source of truth is the `## Version` in SBF.toc (the canonical delivery key the
-- website/Uplink compare). Read it via metadata instead of hand-keeping a second constant that WILL drift
-- (it did: the toc bumped while this string didn't, so the in-game "build" stamp disagreed with the toc /
-- website). Now the header + login message ALWAYS match the toc. NOTE: GetAddOnMetadata reflects the toc as
-- parsed at CLIENT LAUNCH, so a `## Version` bump only shows after a FULL restart, not a bare /reload.
SBF.BUILD = (((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)("SBF", "Version")) or "?"

-- Release CHANNEL of THIS installed copy, read from the `## X-GEC-Channel` .toc field the publish scripts
-- stamp in ("dev" | "prerelease" | "public"). nil when running from unpublished SOURCE (a plain rsync/dev
-- copy carries no marker) — that's a local dev build. (X-prefixed .toc fields are readable via metadata.)
function SBF.Channel()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ch = get and get("SBF", "X-GEC-Channel")
  return (ch and ch ~= "") and ch or nil
end
-- A colored "[channel]" badge for the version / build readouts — shown for every channel EXCEPT public (the
-- default needs no badge). Unpublished source shows [local]. "" when nothing to show. Prerelease=amber, else teal.
function SBF.ChannelBadge()
  local ch = SBF.Channel() or "local"
  if ch == "public" then return "" end
  local col = (ch == "prerelease") and "ffcf40" or "45c4a0"
  return "  |cff" .. col .. "[" .. ch .. "]|r"
end

-- ===== Fishing cast: native binding (menu/source-of-truth) + override-click (the actual trigger) =====
-- The fishing key is a real WoW binding, "CLICK SBFBtn_fishing:LeftButton", declared in Bindings.xml so it
-- appears in WoW's Key Bindings menu (under the SBF header) and ConsolePort's picker, and is the SINGLE
-- SOURCE OF TRUTH (SBF.BindsFor reads it via GetBindingKey). The globals below are its menu label + header.
--   * Setting BINDING_NAME_* / BINDING_HEADER_SBF taints Blizzard's keybinding UI the same BENIGN way every
--     keybind addon does (incl. our own Haul: BINDING_NAME_HAUL_*). It does NOT block the cast — we chased
--     that ghost for hours; the real cast failures were an override-install gap (fixed via UPDATE_BINDINGS)
--     plus a restricted test account, never this taint.
--   * The CAST itself fires via an OVERRIDE-click that SBF.Apply installs over the key — the "blessed"
--     hardware path that carries the protected cast for our INSECURE smart button. The bare native binding
--     alone runs the PreClick but silently drops the cast, so the override is what actually fishes.
_G["BINDING_HEADER_SBF"] = "SBF — Single-Button Fishing"
_G["BINDING_NAME_CLICK SBFBtn_fishing:LeftButton"] = "Action / Cast"

-- Lazy GECReader handle (the one live-getter layer — the ONLY code that touches Blizzard APIs). Looked up
-- at call time (never cached at load) with silent=true so a load-order slip / missing lib yields nil instead
-- of erroring. Mirrors how GECStore fetches the Reader.
local function reader()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECReader-1.0", true)) or nil
end

-- Lazy GECStore handle (the per-character state cache / professions data). Same call-time, silent=true pattern
-- as reader() so a load-order slip yields nil. (A module-level `local GECStore` also exists lower down for the
-- fishlog store; this getter serves code declared ABOVE that line — e.g. SBF.FishingSkill.)
local function gecStore()
  return (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)) or nil
end

-- Stable per-character key for ALL per-character SBF storage (charGear, charSlots, charScope, charStore,
-- skillCache, welcomeHide). The GUID is the true identity — it survives a rename, and a delete+recreate of
-- a same-name character never collides. Name-Realm is a pre-login fallback only (a GUID can be absent before
-- PLAYER_LOGIN). Read through GECReader.Current.identity() so SBF never touches Blizzard APIs directly here.
function SBF.CharKey()
  local R = reader()
  local id = R and R.Current and R.Current.identity and R.Current.identity()
  return (id and id.guid)
    or (id and id.name and (id.name .. "-" .. (id.realm or "?")))
    or "?"
end

-- ===== Dev mode =====
SBF.DEV = false
function SBF.IsDev()
  if SBFDB and SBFDB.dev ~= nil then return SBFDB.dev end   -- runtime override (/sbf dev) wins
  return SBF.DEV                                            -- otherwise the build default
end

-- The slot descriptor table (SLOTS) + the unified slot engine now live in Slots.lua; Core
-- reads them through the shared `ns` table. These locals alias what Core uses a lot, so the
-- rest of this file reads the same as before without re-qualifying ns.* everywhere.
local SLOTS = ns.SLOTS   -- the descriptor list (load-time read; ipairs'd in ADDON_LOADED)

local DB_DEFAULTS = {
  -- (no `slots` default: the per-slot config tree now lives inside the active profile, reached via
  -- SBF.ActiveSlots(); the profile migration + descriptor seeding build it. See Profiles.lua.)
  advancedMode = true,  -- show the full profile/binding UI on the Buttons page. false = SIMPLE (Default-only:
                        -- profiles, zone binding, and Save/Revert hidden; edits auto-commit). Default true
                        -- preserves current behavior; onboarding can flip it for new users.
  autoSwap = true,      -- auto-swap the active profile by location (zone-driven; see Profiles.OnZoneMaybeChanged)
                        -- (runtime field SBFDB._lastTiers is set in code, not defaulted here)
  swapFlash = true,     -- flash the swapped-in profile's name as a raid-warning on an auto-swap
  autoDismount = false, -- on a GROUND mount, fire /dismount so you can fish (never while flying)
  requireTwoButtons = false, -- two-button mode: the action key only casts; loot via the loot key
  gamepadEnable = false, -- "Enable controller support": ticking sets the GamePadEnable CVar to "1" so
                         -- controller buttons generate PAD* binding tokens SBF can bind. Unticking leaves
                         -- the CVar alone (the user may use the gamepad elsewhere). May need a /reload.
  sitBeforeCast = true, -- prepend /sit to each fishing cast (stationary = safer)
  healSeconds = 12,     -- backstop: never heal longer than this after leaving combat
  healStable = 3,       -- stop healing once health hasn't risen for this long (= full).
                        -- must be a bit longer than your heal's cast time + GCD.
  lastFired = {},       -- slotKey -> unix time it was last injected (interval tracking)
  fastLoot = false,     -- fast, silent, framerate-independent auto-loot via GECLoot-1.0 (replaces the client's
                        -- built-in auto-loot; the real loot window still surfaces for locked/high-quality/BoP/bags-full)
  gatherLoot = true,    -- log GameObject/container loot opened OUTSIDE a fishing channel (chests, fished-up
                        -- containers) as a "gathered" fishlog entry — the loot the caught path misses
  gatherFishGuardSec = 3, -- after a fishing channel stops, ignore GameObject loot for this long (it's the
                        -- fished catch's own loot — the caught path owns it; this prevents double-logging)
  debug = false,        -- print state/next-action/macro + each action fired to chat on every key press
  buffDebug = false,    -- DEV: dedicated buff/enchant DETECTION channel — every learn/reject/known hit prints, alone
  lootDebug = false,    -- DEV: dump the fish-vs-chest classification signals on every loot window (fishing-tail state + per-slot t)
  decisionTrace = false,-- DEV: dump the full per-press decision matrix (pre-gates + slot due/ready) to chat
  buffRefresh = 5,      -- recast a consumable when its buff has < this many sec left
  applyMaxTries = 3,    -- a buff-applying slot fires this many times with no detectable buff -> back off + notify
  applyBackoff = 30,    -- how long (sec) a slot naps after tripping applyMaxTries before it retries
  applyGrace = 12,      -- after firing a consumable, wait this long before re-checking
                        -- (food/drink buffs take ~10s to land; don't restart them)
  consumeSeconds = 10,  -- after firing food/drink, the button is idle this long so a
                        -- press can't interrupt the eat/drink before the buff applies
  climbSeconds = 6,     -- after casting the dinghy, jump to climb on for this long
  surfaceMaxSeconds = 5,-- keep JUMPing onto the raft up to this long; if still not on it, recast to reposition
                        -- (then stop, so falling off later doesn't bounce forever)
  bounceJump = true,    -- when airborne/falling (e.g. the post-dinghy "bounce" WoW bug), the fishing key
                        -- becomes JUMP to break the bounce loop — like the surfacing climb. Set false to disable.
  boatCastBuffer = 0.5, -- padding (s) added to a boat action's real cast time before re-casting is allowed,
                        -- so an INSTANT boat (Levitate) can't double-cast before its buff registers.
  boatBuffWait = 1.5,   -- after a boat cast, keep waiting up to this long for its buff to REGISTER before
                        -- allowing another boat cast — covers the gap between cast-complete and buff-applied.
  boatJumpDelay = 0.5,  -- after a climb-onto-boat JUMP, hold off the next jump this long so a fast key-mash
                        -- can't jump in place forever (never settling onto the surface to fish).
  jumpActiveWindow = 5, -- the addon only takes over your key with a JUMP override while you've fished (an action
                        -- press or the fishing channel) within this many seconds — so swimming past never jumps.
  ascentBreaker = true, -- Zen ascent breaker (band-aid): when Zen is flying you UP, the key becomes JUMP so a
                        -- press breaks the climb. Turn OFF to reproduce the raw stuck-jump bug for a real fix.
  bounceBreakWithBuff = false, -- let the bounce-breaker fire even with a boat/water-walk buff up (the SURFACE
                        -- bounce). Off historically because the OLD stuck-jump fed it; with IsKeyDown the jump is
                        -- clean, so a fishing-key press should now BREAK that bounce. Toggle on to test it.
  surfaceClimbJump = false, -- Surfacing(): JUMP to hop onto the raft while at the SURFACE with a boat buff. Default
                        -- OFF — at the surface a jump just feeds the water-walk bounce; we only jump to ascend when
                        -- SUBMERGED. Turn ON only if a PHYSICAL raft (dinghy) needs the at-surface hop to climb on.
  zenArmWindow = 2,     -- falling-boat (Zen Flight): after jumping out of the water with one DUE, how long the
                        -- cast-while-falling stays armed. Short on purpose: covers the jump arc, then the key
                        -- re-arms to JUMP so you bounce + retry quickly rather than drifting armed for seconds.
  -- ---- jump/override diagnostics (isolate the bounce mechanics; see /sbf jumpdiag) ----
  jumpLock = false,     -- DIAGNOSTIC: when true, the fishing key is ALWAYS the JUMP override (out of combat) —
                        -- nothing else. Lets you test whether a single press = a single jump, and whether a
                        -- second press recovers from a bounce. Toggle with /sbf jumplock.
  pollInterval = 0.15,  -- how often (s) the override poll re-evaluates the key. Exposed so timing can be tuned:
                        -- lower = snappier state->override (catches the falling window sooner) but more CPU.
  jumpKeyState = true,  -- JumpController: use IsKeyDown (real physical key read) to defer binding changes while
                        -- the key is HELD — the definitive fix for the stuck-jump. Off = fall back to the timer below.
  jumpKeyupHold = 0.25, -- JumpController FALLBACK (used only when IsKeyDown can't read the key — mouse/controller,
                        -- or jumpKeyState off): min time a JUMP is held before it can be replaced so its key-UP lands.
  winPos = nil,         -- saved options-window position { point, x, y }
  poleSlot = 28,        -- inventory slot of the fishing tool (for pole-enchant checks + pole equip)
  autoAddPole = true,   -- on first setup (empty pole config), pull in the currently-equipped fishing pole
  -- gear snapshot + "in fishing gear" flag are PER-CHARACTER now: SBFDB.charGear[name-realm].{snapshot,on}
  -- (see Gear.lua SBF.CharGear). The old account-wide gearSnapshot/profileGearOn are migrated then dropped.
  idleRestoreEnabled = true,  -- ON by default: after this long with no action press, auto-restore your normal gear
  idleRestoreSeconds = 30,    -- idle threshold (s) for the auto-restore above (also restores focus audio)
  focusAudio = {        -- reconfigure WoW's own sound while fishing (isolate the bobber splash), parallel to gear
    enabled = false,
    -- the "focus" preset: isolate the splash (full SFX/master, mute music/ambience, low dialog). The 5
    -- volumes are the only controls; apply forces Sound_EnableMusic/EnableAmbience on so volume rules.
    master = 1.0, sfx = 1.0, music = 0.0, ambience = 0.0, dialog = 0.3,
  },
  castSound = false,    -- play a sound when the fishing channel starts
  castSoundMode = "kit",-- "kit" = built-in SoundKit id, "file" = bundled sound file
  castSoundId = 5274,   -- SoundKit id for "kit" mode (5274 = AUCTION_WINDOW_OPEN chime)
  castFailSoundMode = "kit",
  castFailSoundId = 8959,-- 8959 = RAID_WARNING (cast-fail alert sound)
  castSoundFile = "Interface\\AddOns\\SBF\\sounds\\cast.ogg",  -- path for "file" mode
  logActions = true,    -- Log-tab VIEW filter: show action lines (food/drink/chum/lure/…) in the list. Actions
                        -- are ALWAYS logged; this only shows/hides them. true = shown.
  fishlogMax = 150,     -- DISPLAY cap: how many recent log lines the Log tab RENDERS (raw log is never trimmed);
                        -- kept modest so the columnar list stays smooth — editable ("show") on the Log tab
  logSearchMode = "highlight",  -- Log-tab search mode: "highlight" (tint + next/prev jump) | "filter" (show only matches)
  statsRefresh = "live",-- Stats-tab auto-refresh: "live" (redraw on each logged event) | 1/2/5 (timer secs) | "off" (manual)
  noFishSound = false,  -- play a sound when a cast ends with no fish hooked (optional warning)
  noFishSoundMode = "kit",
  noFishSoundId = 8959, -- SoundKit id (kit mode); 8959 = RAID_WARNING
  noFishSoundFile = "",
  -- "Expired" cast alert: the cast ran its FULL channel with no bite (not a cast-fail, not a missed bite).
  -- Classified in the channel-stop grace (Core), so this sound fires there, not on an immediate event.
  expiredSound = false, -- play a sound when a cast expires (ran full length, nothing hooked)
  expiredSoundMode = "kit",
  expiredSoundId = 8959,-- SoundKit id (kit mode); 8959 = RAID_WARNING
  expiredSoundFile = "",
  -- "Patiently Rewarded" buff alert: the FIRST consumer of the Buffs.lua watcher. Plays the chosen
  -- sound once when the named buff appears (rising edge). The name is configurable (the buff may be
  -- localised/renamed) — anything later (other buff alerts) reuses the same WatchBuff API.
  prSound = false,
  prSoundMode = "file",   -- default the Patiently Rewarded alert to the bundled "Yay" sound (below)
  prSoundId = 8960,       -- SoundKit fallback (kit mode); 8960 = READY_CHECK ding — a clear, positive ping
  prSoundFile = "Interface\\AddOns\\SBF\\sounds\\YAY.mp3",   -- bundled "Yay" (needs a full game restart to load)
  prBuffName = "Patiently Rewarded",
  bgAlpha = 0.94,       -- window background opacity (Options slider)
  minimap = { pos = 220 },  -- minimap button angle (degrees around the ring)
  -- Mouse double-click fishing: fire SBF's secure fishing button (and optionally loot/interact) from a
  -- DOUBLE-CLICK of a chosen mouse button, WITHOUT stealing normal single clicks. See SBF.MouseInit /
  -- the GLOBAL_MOUSE_DOWN handler below: a double-click momentarily arms a secure override binding so the
  -- 2nd click fires the button, then clears it (single clicks pass through untouched). doubleSec = the
  -- max gap (s) between the two presses that still counts as a double-click.
  -- fishButton/lootButton default UNSET (nil): a "BUTTON2" default re-applied right-click on every load via
  -- ApplyDefaults, so clearing it never stuck (and a fresh char showed "right button" for no reason). The user
  -- picks the button; mouse mode only enables once it's set.
  mouse = { enabled = false, fishButton = nil, lootButton = nil, doubleSec = 0.4, debug = false },
  -- boat spells that must be cast while FALLING, not submerged (Zen Flight): press jumps you out of the water,
  -- then the next press casts once you're falling. [spellId]=true; add any other flight-type "boat" here.
  fallingBoats = { [125883] = true },   -- Zen Flight
}
SBF.DB_DEFAULTS = DB_DEFAULTS   -- exposed as the canonical settings-key list

-- The rotation order (CONSUMABLE_ORDER), the generic-aura learn skip-list (LEARN_SKIP), the
-- channel/postFire data (was CHANNELED), and the firing/due/effect engine all live in Slots.lua
-- now. Core reads them through `ns` (ns.ROTATION_ORDER, ns.LEARN_SKIP, ns.SlotDef, ns.slotDue, …).
local LEARN_SKIP = ns.LEARN_SKIP

local function ApplyDefaults(dst, def)
  for k, v in pairs(def) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      ApplyDefaults(dst[k], v)
    elseif dst[k] == nil then dst[k] = v end
  end
end

------------------------------------------------------------------- iterate ----
-- call fn(key, def) for every slot + custom button (key = unique button suffix)
function SBF.EachDef(fn)
  local slots = SBF.ActiveSlots()
  for _, s in ipairs(SLOTS) do
    slots[s.id] = slots[s.id] or {}
    fn(s.id, slots[s.id], s)
  end
end

------------------------------------------------------------- secure buttons ---
local buttons = {}         -- key -> SecureActionButton
SBF._buttons = buttons     -- expose the registry (read-only ref) so Dev.lua can dump live macrotext
local bindOwner = CreateFrame("Frame")   -- owns the override bindings
local GECBind = LibStub:GetLibrary("GECBind-1.0")   -- shared keybind lib (owns the secure click-edge handling)
local GECLoot = LibStub:GetLibrary("GECLoot-1.0", true)   -- shared fast-loot lib (optional: nil-safe if not embedded)

-- Push SBF's fast-loot preference into the shared looter: enable/disable SBF as a requester and mirror SBF's
-- debug-log state into the lib's chat dump. Idempotent — safe to call on load and on every toggle change.
function SBF.ApplyFastLoot()
  if not GECLoot then return end
  if SBFDB and SBFDB.fastLoot then GECLoot:Enable("SBF") else GECLoot:Disable("SBF") end
  -- Observe (independent of fast-loot) so GECLoot tracks the action context (Fishing/gather casts) and its
  -- ClassifyLootSlot returns a real src for the fishlog even when fast-loot is off. Idempotent.
  if GECLoot.Observe then GECLoot:Observe("SBF") end
  GECLoot:SetDebug("SBF", SBFDB and SBFDB.debug or false)
end

-- Phase-5 gear pseudo-actions: two bindable, NON-secure actions (gear equip/restore are protected only via
-- their own combat guards, not secure casts) keyed in SBFDB.binds like slots. Plain Buttons whose OnClick
-- runs the function; SBF.Apply wires their override bindings off SBFDB.binds["equipGear"/"restoreGear"].
local GEAR_ACTIONS = {
  equipGear   = function() SBF.EquipProfileGear() end,
  restoreGear = function() SBF.RestoreNormalGear() end,
}
local gearActionBtns = {}
for id, fn in pairs(GEAR_ACTIONS) do
  local b = CreateFrame("Button", "SBFGear_" .. id, UIParent)
  b:RegisterForClicks("AnyUp")
  b:SetScript("OnClick", fn)
  b:Hide()
  gearActionBtns[id] = b
end

-- A secure button fires its protected action on key-DOWN or key-UP per the ActionButtonUseKeyDown CVar; a
-- fixed "AnyUp" silently DROPS the cast on key-down clients (the long "won't cast on the new account" bug).
-- GECBind.RegisterSecureClicks owns this now — it registers the matching edge AND keeps the button re-synced
-- on CVAR_UPDATE for the life of the session. NEVER hardcode RegisterForClicks on a secure cast button. (See
-- CLAUDE.md "Secure buttons" + auto-memory.)
local function EnsureButton(key)
  if buttons[key] then return buttons[key] end
  local b = CreateFrame("Button", "SBFBtn_" .. key, UIParent, "SecureActionButtonTemplate")
  GECBind.RegisterSecureClicks(b)
  b:Hide()
  buttons[key] = b
  return b
end

-- shared low-level helpers now live in Slots.lua (defName/itemKey/curItemId/seedItemBuff/
-- hasAction/slotBuffName/…). Core aliases the few it uses directly so the code below reads
-- the same; cross-file calls resolve at runtime via `ns`.
local defName, hasAction = ns.defName, ns.hasAction
local itemKey, curItemId = ns.itemKey, ns.curItemId

-- load a slot's item/macro onto its secure button (macro wins if both set). Items
-- and toys go through a "/use <name>" macro for the learn-vs-summon reason above.
local function Configure(b, def)
  GECBind.RegisterSecureClicks(b)   -- keep the click edge matched to ActionButtonUseKeyDown on every (re)apply
  b:SetAttribute("type", nil)
  b:SetAttribute("item", nil); b:SetAttribute("macrotext", nil)
  b:SetAttribute("spell", nil); b:SetAttribute("toy", nil)
  if def.macro and def.macro ~= "" then
    b:SetAttribute("type", "macro"); b:SetAttribute("macrotext", def.macro)
  else
    -- everything else fires via "/cast <name>": it resolves items, toys AND spells,
    -- and crucially still works for items that teach a toy then get consumed (e.g.
    -- the Bat Visage Bobber) where "/use <name>" finds no bag item and does nothing.
    local name = defName(def)
    if name then
      b:SetAttribute("type", "macro"); b:SetAttribute("macrotext", "/cast " .. name)
    elseif def.item and def.item ~= "" then
      b:SetAttribute("type", "item"); b:SetAttribute("item", "item:" .. (GetItemInfoInstant(def.item) or def.item))
    elseif def.toy then
      b:SetAttribute("type", "item"); b:SetAttribute("item", "item:" .. def.toy)
    end
  end
end

-- ---- buff-based consumable timing -------------------------------------------
-- A rotation slot is "due" when its tracked effect (aura or enchant) is gone or within its
-- refresh threshold — the engine's slotDue (Slots.lua) decides that for every slot. The aura
-- reads route through Buffs.lua (SBF.GetBuff / SBF.ScanBuffs), the ONE secret-guarded source.

-- Learn which buff a consumable applied: poll for the FIRST new (or refreshed), non-generic,
-- un-taken buff after the cast. "First to appear" (not "biggest") is what keeps two consumables
-- fired back-to-back (the skill & perception chums) from grabbing each other's buff, since each
-- one's buff shows up when IT fires. Diffs two ScanBuffs snapshots (secret-named auras already
-- dropped there), keyed name -> expirationTime, so a refresh (a bumped expiry on an existing
-- buff) is caught too, not just a brand-new name.
local function expiryMap()
  local m = {}
  for name, d in pairs((SBF.ScanBuffs())) do m[name] = d.expirationTime or 0 end
  return m
end
-- ============================ buff/enchant DETECTION debug channel (compartmentalized) ============================
-- A dedicated trace for how SBF learns / rejects / already-knows each item's buff or enchant. Gated on its OWN
-- flag SBFDB.buffDebug so it can run ALONE (no other debug noise), and it also rides SBFDB.debug so a general
-- debug session still sees it. Every learn, mount-reject, and already-known hit prints — the source tag marks
-- whether a KNOWN value was learned live or hard-coded (a future shipped seed reads source="seed"). Toggle it
-- with /sbf buffdebug (or the GEC-Console button). Kept in one place so it's easy to keep an eye on.
local function bdbg(fmt, ...)
  if not (SBFDB and (SBFDB.buffDebug or SBFDB.debug)) then return end
  print("|cff88ccffSBF buff|r " .. string.format(fmt, ...))
end
SBF._buffDbg = bdbg   -- exposed so the enchant-capture block elsewhere logs on the SAME channel

-- Reject a MOUNT aura from learning: you can't fish mounted, so a mount aura in the learn window is the
-- "mounted right after casting" pollution. Authoritative + PER-AURA — C_MountJournal.GetMountFromSpell maps the
-- aura's spellId to a mount. (A blanket IsMounted() skip would wrongly drop a legit fishing buff that's up
-- alongside the mount, so we reject the SPECIFIC aura and keep scanning for the real one.)
local function auraIsMount(spellId)
  if not (spellId and C_MountJournal and C_MountJournal.GetMountFromSpell) then return false end
  return C_MountJournal.GetMountFromSpell(spellId) and true or false
end

-- The ONE learning entry point. Every aura-slot fire routes through here unconditionally (from the single
-- arm point); THIS function owns the whole "is there anything to learn, and for which item?" decision — the
-- caller carries no per-slot guard, so nothing has to be rewired per slot. A fireAll slot (Buffs) tracks each
-- item's buff SEPARATELY, so learning is PER-ITEM: gate on the pinned item's own learned record, not the
-- slot-level cdef.buff (which one item would set, blocking the rest).
local function learnBuff(slotKey, cdef, deadline)
  if not cdef then return end
  -- PIN the item we're learning FOR at CALL time. The aura that lands is from THIS item's cast; a
  -- rotating slot (e.g. boat with two boats) may re-arm cdef to a different item before the async poll
  -- fires, so reading the id inside the poll would mis-attribute the buff to the wrong boat.
  local atIid, atKey = curItemId(cdef), itemKey(cdef)
  local sdFA = ns.SlotDef and ns.SlotDef(slotKey); local fireAll = sdFA and sdFA.fireAll
  -- SPELL-PICK persist: a spell armed in a slot (boat/buffs) has no item id, so today it never reaches
  -- db.items and never flows to the server (only the slot-level cdef.buff). Record its identity under a
  -- "spell:N" key so it exports like an item; DB2 fills authoritative duration/effect. Runs for fireAll AND
  -- rotation slots. buffSpell may be nil until the aura is learned — the spell id + name are the identity.
  if cdef.spell and SBF.ObserveItem then
    -- prefer a READABLE learned name; if cdef.buff went secret in combat, fall back to the spell's own name
    -- (a secret would be dropped by ObserveItem anyway, but the `or` must not short-circuit ON the secret).
    local learnedName = cdef.buff
    if learnedName and issecretvalue and issecretvalue(learnedName) then learnedName = nil end
    SBF.ObserveItem("spell:" .. cdef.spell, { kind = (sdFA and sdFA.effect) or "aura",
      name = ns.spellName and ns.spellName(cdef.spell) or nil,
      buff = learnedName or (ns.spellName and ns.spellName(cdef.spell)) or nil,
      buffSpell = cdef.buffSpell, slots = { [slotKey] = true } })
    bdbg("|cff80ff80SPELL|r %s -> |cffffd100%s|r (spell %s)", slotKey,
      tostring(ns.spellName and ns.spellName(cdef.spell) or cdef.spell), tostring(cdef.spell))
  end
  -- a fireAll pick with no numeric id is a SPELL entry ("spell:N"): it names its own buff (entryBuffName ->
  -- spellName) and there's no per-item ItemKnow to write, so there is nothing more to LEARN — skip cleanly.
  -- (Non-fireAll spell slots still learn into the slot-level cdef.buff below, which IS how they're tracked.)
  if fireAll and not atIid then return end
  local function alreadyLearned()
    -- Gate on the DURABLE identity (buffSpell), not just the display NAME: the buff name can go secret in
    -- combat (and is no longer persisted when it does — see Items.lua ObserveItem), so a record with a valid
    -- buffSpell but a transiently-blank buff must still read as LEARNED, or the item churns through the learn
    -- loop every fire. A non-empty name alone also counts (pre-buffSpell records / spell-less learns).
    if fireAll then local r = atIid and SBF.ItemKnow(atIid)
      return r and ((r.buffSpell and r.buffSpell ~= 0) or (r.buff and r.buff ~= "")) and true or false end
    return ((cdef.buffSpell and cdef.buffSpell ~= 0) or (cdef.buff and cdef.buff ~= "")) and true or false
  end
  if alreadyLearned() then
    if SBFDB and (SBFDB.buffDebug or SBFDB.debug) then   -- report WHAT is already known + its source (learned vs hard-coded)
      local rec = atIid and SBF.ItemKnow(atIid)
      local src = (rec and rec.source) or "?"
      local tag = (src == "seed" or src == "builtin") and "  |cff80ff80(hard-coded)|r" or ("  |cff808080(" .. src .. ")|r")
      bdbg("known %s item=%s buff=|cffffd100%s|r%s", slotKey, tostring(atIid),
        tostring((rec and rec.buff) or cdef.buff or "?"), tag)
    end
    return   -- nothing new for this pick — cheap early-out (no ScanBuffs snapshot)
  end
  local before = expiryMap()
  local function poll()
    if not cdef or alreadyLearned() then return end
    local taken = {}   -- buffs other slots already own
    for sk, sd in pairs(SBF.ActiveSlots()) do
      if sk ~= slotKey and sd.buff and sd.buff ~= "" then taken[sd.buff] = true end
    end
    for name, exp in pairs(expiryMap()) do
      if not LEARN_SKIP[name] and not taken[name]
        and (before[name] == nil or (exp or 0) > (before[name] or 0) + 1) then
        local d = SBF.GetBuff and SBF.GetBuff(name)   -- the just-landed aura's details (duration + spellId)
        local spellId = d and d.spellId
        if auraIsMount(spellId) then
          -- a mount aura (mounted mid-learn) — reject it and keep scanning for the real fishing buff
          bdbg("reject |cffff6060%s|r (spell %s) for %s: |cffff6060mount aura|r", name, tostring(spellId), slotKey)
        else
          if not fireAll then            -- fireAll uses PER-ITEM buffs (entryBuffName), never a slot-level one
            cdef.buff = name             -- display name (localised; can go secret in combat)
            cdef.buffSpell = spellId     -- IDENTITY: survives rename + secret-name; the preferred match key
            cdef.buffFor = atKey         -- the item (pinned at call time) this buff was learned for
          end
          -- snapshot the spell into the shared registry so log/{spell} rendering can show the buff uniformly.
          if spellId and GECStore and GECStore.Note then GECStore.Note("spell", spellId) end
          local iid = atIid              -- cache per-item (account-wide) so we never re-learn it
          if iid then
            -- also capture the aura's FULL length (buffDuration) + its spellId so the due-check has a fallback
            -- timer AND a stable identity when the live aura name can't be read.
            SBF.ObserveItem(iid, { kind = "aura", buff = name, buffSpell = spellId,
              buffDuration = (d and d.duration and d.duration > 0) and d.duration or nil })
          end
          bdbg("|cff80ff80LEARNED|r %s -> |cffffd100%s|r (spell %s, dur %s) item=%s", slotKey, name,
            tostring(spellId), tostring((d and d.duration) or "?"), tostring(atIid))
          return
        end
      end
    end
    if GetTime() < deadline then C_Timer.After(0.5, poll) end
  end
  C_Timer.After(0.5, poll)
end

-- ComputeNext / GetNext, the rotation due/effect engine, the boat due/surface helpers
-- (BoatBuffUp / IsOnBoat / Surfacing), WatchedBuff / SlotBuffLeft / ClearLearnedBuff, the
-- item-availability checks, the firing-mode resolver, and the macro builders ALL live in
-- Slots.lua now. Core just calls them via SBF.* / ns.*. The boat helpers Core's footing/
-- state code uses are aliased here.
local BoatBuffUp = ns.BoatBuffUp

-- current state (live): Combat > Fishing > Boat > Surfacing > Swimming > Falling > Ground.
-- Combat wins even though we can't act on it (it's still the real state). "Fishing" =
-- the line is out (a channel); that's when the key flips to loot. (No "Underwater" —
-- IsSubmerged() reads true even while treading at the surface, so it's meaningless.)
-- Falling (airborne — jumped, fell off, or stuck in the post-dinghy bounce) MUST be reported:
-- it was previously falling through to "Ground", so {sbf.state} lied ("Ground") while the
-- footing panel correctly read airborne. Mirrors ns.ReadState()'s footing (swimming beats falling).
function SBF.GetState()
  if InCombatLockdown() then return "Combat" end
  if UnitChannelInfo and UnitChannelInfo("player") then return "Fishing" end
  if SBF.IsOnBoat() then return "Boat" end
  if SBF.Surfacing() then return "Surfacing" end   -- dinghy up, still in the water
  if IsSwimming() then return "Swimming" end
  if IsFalling and IsFalling() then return "Falling" end   -- airborne: jumped / fell / post-boat bounce
  return "Ground"
end

-- ZONE-LOCAL fishing skill. There's no API for "this zone's fishing line", so (like FishingTracker) we map
-- the current zone's CONTINENT to its expansion fishing skill-line ID, then read that line directly with
-- C_TradeSkillUI.GetProfessionInfoBySkillLineID (works window-closed). Skill-line IDs verified in-game via
-- /sbf fishlines. Both tables are EDITABLE here — add a continent (e.g. Midnight's) or fix an overlap with
-- no rebuild. The continent UI-map IDs are stable Blizzard map ids; resolve by walking C_Map parents.
SBF.FISHING_LINE = {                 -- expansion -> skillLineID (for reference / future use)
  classic = 2592, outland = 2591, northrend = 2590, cataclysm = 2589, pandaria = 2588,
  draenor = 2587, legion = 2586, bfa = 2585, shadowlands = 2754, dragonflight = 2826,
  warwithin = 2876, midnight = 2911, base = 356,
}
SBF.FISHING_LINE_BY_CONTINENT = {    -- continent UI-map id -> fishing skillLineID
  [13]  = 2592, [12]  = 2592,        -- Eastern Kingdoms / Kalimdor -> Classic
  [101] = 2591,                      -- Outland
  [113] = 2590,                      -- Northrend
  [424] = 2588,                      -- Pandaria
  [572] = 2587,                      -- Draenor
  [619] = 2586,                      -- Broken Isles (Legion)
  [875] = 2585, [876] = 2585,        -- Zandalar / Kul Tiras (BfA)
  [1550] = 2754,                     -- Shadowlands
  [1978] = 2826,                     -- Dragon Isles (Dragonflight)
  [2274] = 2876,                     -- Khaz Algar (War Within)
  [2537] = 2911,                     -- Quel'Thalas (Midnight) — its own continent, nested under EK(13), so it
                                     -- wins on the parent-walk before the EK->Classic rule is reached
}

-- the fishing skill line for the player's current zone, or nil. Reads the RAW map ancestry from GECReader
-- (best->root) and returns the first level whose mapID is a known continent — same "first ancestor in the
-- table wins" walk as before (so Quel'Thalas still beats its EK parent), just sourced from the getter layer.
local function zoneFishingLine()
  local R = reader()
  local chain = R and R.Current and R.Current.mapChain and R.Current.mapChain()
  if not chain then return nil end
  for _, lv in ipairs(chain) do
    local line = lv.mapID and SBF.FISHING_LINE_BY_CONTINENT[lv.mapID]
    if line then return line end
  end
end

-- Returns level, maxLevel, modifier for the CURRENT ZONE's fishing line, or nil when absent (never a wrong
-- live 0). The BASE level/max is read from the GECStore per-character professions cache — the library owns
-- caching, warming, and updates (GECStore.ProfessionsWarmed() reports live-vs-cached; the header colors on it),
-- and .lines[lineID] is nil when the char has no skill in that line. The MODIFIER (green +gear/lure boost) is
-- SBF-owned and gear-derived — the library doesn't carry it — so SBF reads it live and only when the data is
-- warm (0 otherwise; the full gear-derived boost catalog is future work, [[sbf-effective-fishing-skill]]).
function SBF.FishingSkill()
  local line = zoneFishingLine() or SBF.FISHING_LINE.midnight   -- unmapped continent -> current-expansion line
  local S = gecStore()
  if not (line and S and S.CharInfo and S.CharIndex) then return nil end
  local ch = S.CharInfo(S.CharIndex())
  local prof = ch and ch.state and ch.state.professions
  local base = prof and prof.lines and prof.lines[line]
  if not base then return nil end                              -- nil = no cached/live skill for this line
  local mod = 0
  if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
    local p = C_TradeSkillUI.GetProfessionInfoBySkillLineID(line)
    if p and (p.maxSkillLevel or 0) > 0 then mod = p.skillModifier or 0 end   -- gear-derived, live-only (SBF owns it)
  end
  return base.level or 0, base.max, mod
end

-- "300/300 (+116)" with the bonus in green — the shared string for Haul's {sbf.fishing} token AND the SBF
-- window header readout. "" when you have no Fishing skill (so a Haul watcher of just {sbf.fishing} hides).
function SBF.GetFishing()
  local level, maxLevel, mod = SBF.FishingSkill()
  if not level then return "" end
  local s = level .. "/" .. (maxLevel or level)
  if mod and mod > 0 then s = s .. " |cff33ff33(+" .. mod .. ")|r" end
  return s
end

-- ===== Skill Book =====
-- Ordered expansion list for the Skill Book tab (release order). {catalogKey, displayName}; catalogKey indexes
-- SBF.FISHING_LINE. The generic "base" line (356) is intentionally omitted — it's the legacy pre-split fishing
-- skill, not an expansion, and reports odd values.
SBF.SKILLBOOK_ORDER = {
  { "classic",      "Classic" },        { "outland",     "Outland" },
  { "northrend",    "Northrend" },      { "cataclysm",   "Cataclysm" },
  { "pandaria",     "Pandaria" },       { "draenor",     "Draenor" },
  { "legion",       "Legion" },         { "bfa",         "Battle for Azeroth" },
  { "shadowlands",  "Shadowlands" },    { "dragonflight","Dragonflight" },
  { "warwithin",    "The War Within" }, { "midnight",    "Midnight" },
}

-- Per-expansion fishing skill for a GECStore character index (nil = current character). Reads the professions
-- cache (.lines[lineID], populated + owned by GECStore). Returns an ordered list of rows:
--   { label, line, level, max, has, current }   -- has=false when the char has no skill in that line;
-- current=true for the expansion of the zone you're standing in. nil when the store is unavailable.
function SBF.SkillBookFor(charIdx)
  local S = gecStore(); if not (S and S.CharInfo and S.CharIndex) then return nil end
  local idx = charIdx or S.CharIndex()
  local ch = idx and S.CharInfo(idx)
  local lines = ch and ch.state and ch.state.professions and ch.state.professions.lines
  local curLine = zoneFishingLine()
  local out = {}
  for _, e in ipairs(SBF.SKILLBOOK_ORDER) do
    local line = SBF.FISHING_LINE[e[1]]
    local l = line and lines and lines[line]
    out[#out + 1] = {
      label = e[2], line = line,
      level = l and l.level, max = l and l.max, has = l ~= nil,
      current = (line ~= nil and line == curLine),
    }
  end
  return out
end

-- Characters to offer in the Skill Book selector: ordered { idx, name } (GECStore char index + display name),
-- the CURRENT character pinned first, then every other registry character that has professions data cached.
function SBF.SkillBookChars()
  local S = gecStore(); if not (S and S.CharInfo and S.EnsureDB) then return nil end
  local cur = S.CharIndex and S.CharIndex()
  local db = S.EnsureDB()
  local items = db and db.registry and db.registry.char and db.registry.char.items or {}
  local out, seen = {}, {}
  local function add(idx)
    if not idx or seen[idx] then return end
    local info = S.CharInfo(idx); if not info then return end
    seen[idx] = true
    out[#out + 1] = { idx = idx, name = info.name or ("char " .. tostring(idx)) }
  end
  add(cur)                                   -- current character first (even with no data yet)
  local rest = {}
  for i = 1, #items do
    local it = items[i]
    if it and not seen[i] and it.state and it.state.professions then rest[#rest + 1] = i end
  end
  table.sort(rest, function(a, b) return (items[a].name or "") < (items[b].name or "") end)
  for _, i in ipairs(rest) do add(i) end
  return out
end

-- pull the perception value out of a structured tooltip (C_TooltipInfo) — a leftText may hold several
-- \n-joined sub-lines, so we take the number from the sub-line that actually says "perception".
local function scanPerception(data)
  if not (data and data.lines) then return nil, 0 end
  local txt, val = nil, 0
  for _, line in ipairs(data.lines) do
    local t = line.leftText
    -- 12.0 "secret value" taint: some aura tooltip text is a secret string that can't be string-operated
    -- (errors on index/concat, esp. in combat). Skip those lines — we can't read them anyway.
    if t and not (issecretvalue and issecretvalue(t)) then
      for sub in (t .. "\n"):gmatch("(.-)\n") do
        if sub:lower():find("perception") then
          local digits = ((sub:match("([%d,]+)") or ""):gsub(",", ""))   -- (gsub returns str,count)
          local n = tonumber(digits)
          txt = (txt and (txt .. " | ") or "") .. sub
          if n then val = val + n end
        end
      end
    end
  end
  return txt, val
end
ns.scanPerception = scanPerception

-- Total fishing perception from normal gear (slots 1-19, incl. enchants) + the Fishing Tool (slot 28) +
-- active buffs (lure/chum/food/the Grand Line buff). SKIPS profession slots 20-27 (other professions carry
-- their own perception). Returns total (number) + a contributors list { {src, name, text, val} } for /sbf perc.
function SBF.Perception()
  local total, contrib = 0, {}
  for slot = 1, 28 do
    if slot < 20 or slot == 28 then
      local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
      local data = link and C_TooltipInfo and C_TooltipInfo.GetInventoryItem and C_TooltipInfo.GetInventoryItem("player", slot)
      local txt, val = scanPerception(data)
      if txt then total = total + val; contrib[#contrib + 1] = { src = "gear", name = (GetItemInfo(link)), text = txt, val = val } end
    end
  end
  local i = 1
  while i <= 60 do
    local data = C_TooltipInfo and C_TooltipInfo.GetUnitBuff and C_TooltipInfo.GetUnitBuff("player", i)
    if not (data and data.lines and data.lines[1]) then break end
    local txt, val = scanPerception(data)
    if txt then total = total + val; contrib[#contrib + 1] = { src = "buff", name = data.lines[1].leftText, text = txt, val = val } end
    i = i + 1
  end
  return total, contrib
end

-- just the perception number (for the header readout + Haul's {sbf.perception} token).
function SBF.GetPerception() return (SBF.Perception()) or 0 end

-- Is the player CURRENTLY channeling the FISHING spell specifically (not a combat/other channel)? Uses the
-- same precise test as the cast tracker (spell id 131474 / name "Fishing"), so the idle observer treats only
-- real fishing as "still active" — a combat channel must never keep gear/audio applied forever.
function SBF.IsFishingChannel()
  if not UnitChannelInfo then return false end
  local cname, _, _, _, _, _, _, cid = UnitChannelInfo("player")
  if not cname then return false end
  return cid == 131474 or cname == "Fishing"
end

-- seconds of air left if the BREATH mirror timer is running, else nil. This is the
-- RELIABLE "actually underwater" test (IsSubmerged reads true at the surface too).
local function breathSecondsLeft()
  if not GetMirrorTimerInfo then return nil end
  for i = 1, 3 do
    local timer, value = GetMirrorTimerInfo(i)
    if timer == "BREATH" then return (value or 0) / 1000 end
  end
  return nil
end
SBF.BreathLeft = breathSecondsLeft

-- Macro-line builders (actionLine / guardNoCombat / guardCombat / combatLine), the firing-mode resolver,
-- describeAction, and buildPressMacro all live in Slots.lua; Core aliases the few PreClick calls here.
-- ⚠️ SHIPPING CODE — MUST stay OUTSIDE the @strip block below. These are called by BARE NAME from PreClick;
-- a strip once swallowed this block (it was parked between two dev dumps) and every fishing press crashed
-- with "attempt to call a nil value" in the PUBLIC build (dev + luacheck can't see it). Keep it out here.
local combatLine = ns.combatLine
local guardCombat, describeAction = ns.guardCombat, ns.describeAction
local buildPressMacro = ns.buildPressMacro
-- (actionLine is aliased inside the dev @strip block below — it's used only by the diagnostic dumps.)

-- Chat a one-line note of what an action-key press fired (Debug-log only; no-op presses stay quiet).
local function announce(txt)
  if SBFDB and SBFDB.debug then print("|cff45c4a0SBF|r |cffffd100" .. tostring(txt) .. "|r") end
end


-- An addon can't jump or interact-with-target on its own, but it CAN rebind the
-- fishing key to those built-in actions. The key dynamically becomes: JUMP while
-- surfacing onto the dinghy, INTERACT while the line is out (loot the bobber),
-- else the smart button. You just keep pressing one key. Polled
-- (no event for submerged/channeling), throttled, skipped in combat.

-- Does the boat slot need FALLING-cast (Zen Flight)? The armed pick (boat.spell) is only set DURING a boat
-- press (buildPressMacro), so it's unreliable at decision time — instead detect from the CONFIGURED items:
-- true if the armed pick OR any configured boat item is a falling-boat. Safe on a mixed slot because every
-- boat spell casts fine mid-fall (the water-walk ones just apply as you land), so jump-then-cast never breaks
-- a normal boat. Without this the detection reads false, and the bounce-breaker keeps the key on JUMP → bounce.
local function boatIsFalling(boat)
  if not (boat and SBFDB and SBFDB.fallingBoats) then return false end
  if boat.spell and SBFDB.fallingBoats[boat.spell] then return true end
  if boat.items then
    for _, e in ipairs(boat.items) do
      local sid = ns.spellEntry and ns.spellEntry(e)
      if sid and SBFDB.fallingBoats[sid] then return true end
    end
  end
  return false
end
SBF.BoatIsFalling = boatIsFalling   -- exposed for the /sbf boat debug readout

-- The UNIQUE "cast the falling-boat now" signal (the combination that breaks the bounce-vs-cast collision):
-- a configured falling-boat (Zen Flight) whose OWN buff is DOWN. Checked per-spell, NOT via BoatBuffUp() —
-- which any configured water-walk boat (Levitate/Path of Frost up) trips, wrongly blocking Zen Flight. Returns
-- the spell id that needs casting, or nil. When this is set + FALLING, we cast (not bounce); when nil + falling,
-- the bounce-breaker runs as normal. That's the whole disambiguation.
local function fallingBoatNeeded(boat)
  if not (boat and hasAction(boat) and not boat.skip and SBFDB and SBFDB.fallingBoats) then return nil end
  for _, e in ipairs(boat.items or {}) do
    local sid = ns.spellEntry and ns.spellEntry(e)
    if sid and SBFDB.fallingBoats[sid] then
      local nm = ns.spellName and ns.spellName(sid)
      local up = nm and SBF.GetBuff and SBF.GetBuff(nm)
      if not (up and up.secondsLeft and up.secondsLeft > 0) then return sid end   -- its own buff down -> cast it
    end
  end
  return nil
end
SBF.FallingBoatNeeded = fallingBoatNeeded

-- The inverse: a configured falling-boat whose buff is currently UP = Zen Flight ACTIVE. Zen Flight is a
-- FLYING state (IsFlying/IsFalling can read true) yet you CAN fish from the hover, and its buff can be
-- permanent (GetBuff -> secondsLeft = math.huge), so presence is what matters. Used to (a) let canCast be YES
-- while flying and (b) stop the bounce-breaker from hijacking the key once you're hovering. Returns spell id or nil.
local function fallingBoatActive(boat)
  if not (boat and SBFDB and SBFDB.fallingBoats) then return nil end
  for _, e in ipairs(boat.items or {}) do
    local sid = ns.spellEntry and ns.spellEntry(e)
    if sid and SBFDB.fallingBoats[sid] then
      local nm = ns.spellName and ns.spellName(sid)
      if nm and SBF.GetBuff and SBF.GetBuff(nm) then return sid end
      -- Robust fallback: Zen Flight IS a flying state and is NOT a mount. If you're flying and not mounted with a
      -- falling-boat configured, treat it as ACTIVE even when the buff read misses (name/ID drift or the post-cast
      -- registration lag) — that gap is what let the bounce-breaker re-arm JUMP and fly you into space.
      if IsFlying and IsFlying() and not (IsMounted and IsMounted()) then return sid end
    end
  end
  return nil
end
SBF.FallingBoatActive = fallingBoatActive

-- SELF-CONTAINED band-aid: should the fishing key become JUMP to DISRUPT a Zen Flight ASCENT? A cast landing at
-- the top of the jump arc can leave you climbing; a JUMP press then delivers a clean key-down+up that breaks the
-- stuck climb. True ONLY when Zen is ACTIVE (flying) AND you're actually MOVING (ascending) — so hovering to fish
-- (flying, not moving) stays untouched and the press still casts/fishes. One responsibility, no side effects.
local function zenAscentBreaker(boat)
  if SBFDB.ascentBreaker == false then return false end               -- band-aid toggled off (test the raw bug)
  if not (boat and hasAction(boat)) then return false end
  if not (SBF.FallingBoatActive and SBF.FallingBoatActive(boat)) then return false end
  if not (IsFlying and IsFlying()) then return false end
  return (GetUnitSpeed and GetUnitSpeed("player") or 0) > 0            -- moving = ascending; a press breaks it
end
SBF.ZenAscentBreaker = zenAscentBreaker

-- ==== JumpController: the SOLE owner of the fishing key's dynamic override binding ====
-- EVERY dynamic override for the fishing key — JUMP (surfacing / bounce-breaker / Zen jump-out), the loot
-- INTERACT, or none — flows through here, and nothing else calls SetOverrideBinding/ClearOverrideBindings on
-- this key. Its defining rule (the reason it exists): when a JUMP binding is released, the physical key-UP must
-- have already landed on JUMP. Clearing a JUMP binding mid-press drops the key-up and WoW treats jump as HELD —
-- that is the continuous "flying into space". So a JUMP is held for a minimum settle time before it can be
-- replaced or cleared. Pure state machine over (desired action, keys): DesiredOverride decides intent only; the
-- controller owns ALL the wiring, so jump behaves exactly one way everywhere it is used.
local JumpController = {}
do
  local owner = CreateFrame("Frame")
  local applied = nil        -- the binding currently on the key ("JUMP" | an interact binding | nil)
  local appliedKeys = ""     -- the key-set 'applied' was bound to (re-applied when the key-set changes)
  local jumpSince = 0        -- GetTime() when the current JUMP was applied (0 when 'applied' isn't JUMP)

  local function minHold() return SBFDB.jumpKeyupHold or 0.25 end   -- settle time so a JUMP's key-up lands first

  -- Is any fishing key PHYSICALLY held right now? Reads the RAW key state (IsKeyDown excludeBindingState=true) so
  -- our own override-to-JUMP doesn't mask it. This is the real read that replaces the key-up TIMER: we simply
  -- never touch the binding while a key is down. Strips a modifier prefix (SHIFT-F -> F); pcall-guarded because a
  -- mouse/controller "key" may not be an IsKeyDown name (those fall back to the timer path in Apply).
  local function anyKeyHeld(keys)
    if not (IsKeyDown and SBFDB.jumpKeyState ~= false) then return nil end   -- nil = "couldn't read" -> use timer
    local read = false
    for _, k in ipairs(keys or {}) do
      local base = (type(k) == "string" and k:match("[^-]+$")) or k
      local ok, down = pcall(IsKeyDown, base, true)
      if ok then read = true; if down then return true end end
    end
    return read and false or nil   -- false = read & up; nil = never read a valid key -> timer fallback
  end

  local function bind(action, sig, keys)
    ClearOverrideBindings(owner)
    if action then for _, key in ipairs(keys) do SetOverrideBinding(owner, true, key, action) end end
    jumpSince = (action == "JUMP") and GetTime() or 0
    applied, appliedKeys = action, sig
    SBF._dynOverride = action                                        -- for /sbf next + diagnostics
  end

  -- Request the desired binding for 'keys'. Returns true iff the applied binding actually CHANGED.
  function JumpController.Apply(action, keys)
    local sig = table.concat(keys or {}, "|")
    if action == applied and sig == appliedKeys then return false end      -- already there: no churn
    -- THE FIX: never change the binding while the fishing key is PHYSICALLY HELD (real read via IsKeyDown, not a
    -- timer guess). Clearing a JUMP mid-hold drops the key-up -> WoW keeps jump held -> fly-up; binding JUMP onto
    -- an already-held key makes it a held-jump -> ascend. Deferring every change until the key is UP prevents
    -- both. The poll re-checks within pollInterval, so the change lands the instant you release.
    local held = anyKeyHeld(keys)
    if held == true then return false end
    -- Fallback ONLY when IsKeyDown couldn't read the key (mouse/controller, or SBFDB.jumpKeyState=false): the old
    -- key-up settle TIMER, so those inputs still get some protection.
    if held == nil and applied == "JUMP" and action ~= "JUMP" and (GetTime() - jumpSince) < minHold() then
      return false
    end
    bind(action, sig, keys)
    return true
  end

  function JumpController.Clear() if applied ~= nil or appliedKeys ~= "" then bind(nil, "", {}) end end
  function JumpController.Current() return applied end                     -- the live binding (or nil)
  function JumpController.Applied() return appliedKeys ~= "" end           -- is an owner override in place?
  -- The physical jump just landed (swimming->falling) while JUMP is bound: restart the key-up hold from HERE so
  -- it protects THIS press's release, not the stale bind time. Without this the hold expired during a long swim
  -- and a slow/held press dropped its key-up -> stuck jump -> the intermittent fly-up.
  function JumpController.NoteJumpEdge() if applied == "JUMP" then jumpSince = GetTime() end end
end
SBF.JumpController = JumpController

local function DesiredOverride()
  local s = SBF.ActiveSlots()
  -- never bind JUMP while combat-flagged (we couldn't unbind it again until combat
  -- ends, leaving the key stuck jumping)
  local combat = UnitAffectingCombat and UnitAffectingCombat("player")
  -- DIAGNOSTIC jump-lock: force the key to JUMP and nothing else, to isolate the override/bounce mechanics
  -- from the whole decision tree. Still respects the combat guard (can't rebind mid-fight). See /sbf jumpdiag.
  if SBFDB.jumpLock and not combat then return "JUMP", "jumpLock" end
  -- GATE: the fishing-loop JUMP overrides (surfacing, Zen jump-out, bounce-breaker) only engage while you're
  -- ACTIVELY fishing — a recent action press or fishing-channel activity. Just swimming past with a boat/Zen in
  -- the slot must NOT let the addon hijack your key to JUMP (the "swam by, pressed nothing, jumps forever" bug).
  local active = math.max(SBF.lastActionAt or 0, SBF.lastFishingAt or 0)
  local fishing = active > 0 and (GetTime() - active) < (SBFDB.jumpActiveWindow or 5)
  if fishing and hasAction(s.boat) and SBF.Surfacing() and not combat then
    return "JUMP", "surface"
  end
  -- Falling-cast boats (Zen Flight): the collision with the bounce-breaker below (both want the key on "falling")
  -- is broken by the UNIQUE combination fallingBoatNeeded() — a falling-boat whose OWN buff is down. ONLY in that
  -- combination do we diverge: SWIMMING -> JUMP (drop into the fall), FALLING -> return nil so the press CASTS
  -- (beats the bounce-breaker). Every other falling state (no falling-boat needed) falls straight through to the
  -- bounce-breaker, so a normal bounce still gets its JUMP. This is the state-combo disambiguation.
  do
    local zenDue = fishing and ns.zenBoatDue and ns.zenBoatDue(s.boat)
    if zenDue and not combat then
      SBF._zenArm = GetTime() + (SBFDB.zenArmWindow or 2)     -- over water, falling-boat due: arm + jump out
      SBF._zenPickId = zenDue
      -- Over water with Zen due: a STABLE JUMP — NO debounce. The JumpController binds it once and re-applying
      -- the same JUMP is a no-op, so a steady "swimming" state yields a steady JUMP that can't re-fire (jumpLock
      -- proved a stable jump never bounces). The old debounce flipped JUMP<->nil on a TIMER while the state never
      -- changed, and that self-inflicted oscillation was the "override over and over" loop + the climb. The cast
      -- happens on the real swimming->falling change (arm block below); hold=true covers that one handoff's key-up.
      if IsSwimming and IsSwimming() then return "JUMP", "zenJump" end
    end
    -- Keep the cast window OPEN for the whole bounce: while FALLING with a falling-boat still needed (configured,
    -- no boat buff, not yet hovering), refresh the arm every frame so it can't expire mid-bounce (zenBoatDue only
    -- fires on SWIMMING frames, so a fall-dominant bounce would otherwise time the arm out after zenArmWindow and
    -- drop you to the bounce-breaker / the falling->fishing fall-through). _zenPickId stays set from the jump.
    if fishing and IsFalling and IsFalling() and boatIsFalling(s.boat)
        and not (ns.BoatBuffUp and ns.BoatBuffUp()) and not fallingBoatActive(s.boat) then
      SBF._zenArm = GetTime() + (SBFDB.zenArmWindow or 2)
    end
    -- inside the arm window + airborne + not yet hovering: return nil so the press CASTS (beats the bounce-breaker)
    if SBF._zenArm and GetTime() < SBF._zenArm and IsFalling and IsFalling() and not combat
        and not fallingBoatActive(s.boat) then
      return nil, "armCast"
    end
  end
  -- Zen Flight ASCENT BREAKER (self-contained; see zenAscentBreaker): if Zen is flying you UPWARD (active +
  -- moving), make the key JUMP so a press breaks the climb with a clean key-up. Hovering-to-fish (not moving)
  -- falls right past this to the normal cast/fish path.
  if fishing and zenAscentBreaker(s.boat) and not combat then
    return "JUMP", "ascent"
  end
  -- Bounce-bug breaker: dismissing the dinghy (or an awkward landing) can trap you airborne in a
  -- water "bounce" loop — you bob up/down endlessly. WoW breaks it the instant you JUMP. So while
  -- we're falling/airborne the fishing key becomes JUMP, exactly like the surfacing climb. Mid-air
  -- JUMP is a no-op in WoW, so this can't double-jump — it only fires on the split-second of surface
  -- contact that ends each bounce, then the override clears once you're grounded/swimming again.
  -- ...with three exclusions, so JUMP only fires in the case it was built for (the dismissed-raft airborne trap:
  -- NO boat buff, falling, over/near water):
  --   * FLYING/GLIDING (Zen hover, dragonriding) — reads as falling but a JUMP just flies you up.
  --   * a BOAT BUFF is up — then a "falling" flicker is the water-walk SURFACE BOUNCE, and JUMP FEEDS it
  --     (your reload-into-a-loop). #2 handles a real submerged ascent; the bounce-breaker must stay out of it.
  if fishing and SBFDB.bounceJump ~= false and IsFalling and IsFalling() and not combat
      and not (IsFlying and IsFlying()) and not (IsGliding and IsGliding())
      and (SBFDB.bounceBreakWithBuff or not (ns.BoatBuffUp and ns.BoatBuffUp()))   -- with-buff test: the surface bounce
      and not fallingBoatActive(s.boat) then
    return "JUMP", "bounce"
  end
  if UnitChannelInfo and UnitChannelInfo("player") and not hasAction(s.interact)
    and not SBFDB.requireTwoButtons then                  -- two-button mode: action key doesn't loot
    return ((s.interact and s.interact.gameBinding) or "INTERACTTARGET"), "interact"
  end
  return nil, "idle"
end
local prevFalling = false   -- for the swimming->falling RISING edge (the physical jump landing)
local function UpdateFishKey()
  if InCombatLockdown() then return end
  local keys = SBF.BindsFor("fishing")   -- Key1/Key2/Controller — override ALL of them while the line is out
  if #keys == 0 then JumpController.Clear(); prevFalling = false; return end
  -- JUMPING IS ACTIVITY. A jump press fires the binding, NOT the secure button, so it never runs PreClick and
  -- never refreshes lastActionAt — so a long HOLD (or a jump sequence longer than jumpActiveWindow) would let the
  -- activity gate expire and clear the JUMP override out from under your still-held key -> stuck key-down. While
  -- the override is ALREADY JUMP, keep the window alive. The FIRST activation still needs a real press, so
  -- swimming past with nothing pressed stays quiet (the override is never JUMP there, so this never fires).
  if JumpController.Current() == "JUMP" then SBF.lastActionAt = GetTime() end
  -- Physical jump just landed (swimming->falling) while JUMP is bound: restart the key-up hold from HERE, so it
  -- protects THIS press's release (the bind-time hold went stale over a long swim -> slow presses lost the key-up).
  local falling = (IsFalling and IsFalling()) or false
  if falling and not prevFalling then JumpController.NoteJumpEdge() end
  prevFalling = falling
  local action, reason = DesiredOverride()
  -- (The "wait"/disabled suppression is handled in PreClick with a combat-safe macro, not a no-op override —
  -- an override would also block the combat attack off this key.) The controller owns capture/hold/release.
  local changed = JumpController.Apply(action, keys)
  SBF._ovrReason = reason   -- which DesiredOverride branch decided the current override (for the trace)
  if changed and SBFDB.debug then
    local bt = SBF.ActiveSlots().boat
    print(string.format("|cff45c4a0SBF|r key override -> |cffffd100%s|r  (state=%s swim=%s fall=%s fly=%s zenDue=%s active=%s armed=%s)",
      JumpController.Current() or "none (fires the button)", tostring(SBF.GetState()),
      tostring(IsSwimming and IsSwimming()), tostring(IsFalling and IsFalling()),
      tostring(IsFlying and IsFlying()), tostring(ns.zenBoatDue and ns.zenBoatDue(bt)),
      tostring(fallingBoatActive(bt)), tostring((SBF._zenArm and GetTime() < SBF._zenArm) or false)))
  end
  if SBF._tracing and SBF.Trace then                       -- per-poll trace to the GEC-Console Feed tab
    SBF.Trace((changed and "*" or " ") .. tostring(reason or "-"))   -- * = the override changed this tick
  end
end


-- Set a button's macrotext AND (dev) echo the FINAL wrapped macro to the GEC-Console Feed — so pressing the
-- fishing key prints a live transcript of exactly what got overlaid THIS press (combat guardCombat wrap and
-- all), which a static GetAttribute dump can't show. Toggle with /sbf macrotrace. The echo is @strip'd out of
-- public and gated on SBF._macroTrace; btn:SetAttribute is the shipping behaviour.
local function applyMacro(btn, text, tag)
  btn:SetAttribute("macrotext", text)
end


local pollFrame, pollAccum = CreateFrame("Frame"), 0
pollFrame:SetScript("OnUpdate", function(_, elapsed)
  pollAccum = pollAccum + elapsed
  if pollAccum >= (SBFDB.pollInterval or 0.15) then
    pollAccum = 0
    UpdateFishKey()
    -- Stamp fishing-activity while the line is out (the bobber sits 10-20s with NO keypress). The idle
    -- auto-restore measures inactivity from max(lastActionAt, lastFishingAt), so it can't conclude "idle"
    -- mid-channel and yank gear/audio while you're still fishing. Only the real Fishing channel counts.
    if SBF.IsFishingChannel() then SBF.lastFishingAt = GetTime() end
  end
end)

-- Phase-5 idle auto-restore: ~1s throttle. When enabled, after idleRestoreSeconds with no action press while
-- wearing the profile gear package, restore your normal gear (the next press re-equips it — see PreClick).
local idleFrame, idleAccum = CreateFrame("Frame"), 0
idleFrame:SetScript("OnUpdate", function(_, elapsed)
  idleAccum = idleAccum + elapsed
  if idleAccum < 1 then return end
  idleAccum = 0
  if SBF._emEditing then return end   -- editing the set in the Equipment Manager: don't yank gear out mid-edit
  if not (SBFDB and SBFDB.idleRestoreEnabled) then return end
  -- "Idle" = no ACTION press AND no FISHING activity for the full window. Measuring from max(lastActionAt,
  -- lastFishingAt) means the bobber sitting out (no keypress) still counts as active, and the full
  -- idleRestoreSeconds only starts counting AFTER fishing genuinely stops — not from the last keypress.
  local lastActive = math.max(SBF.lastActionAt or 0, SBF.lastFishingAt or 0)
  if lastActive == 0 or (GetTime() - lastActive) <= (SBFDB.idleRestoreSeconds or 30) then return end
  if SBF.IsFishingChannel and SBF.IsFishingChannel() then return end   -- still channeling Fishing RIGHT NOW: not idle
  -- genuinely idle long enough: return everything fishing reconfigured (gear + focus audio) to normal, via the
  -- single packaged revert (each side-effect self-guards / no-ops when not applied).
  if SBF.RevertToNormal then SBF.RevertToNormal() end
end)

-- Phase-1 cast-failure back-off: a cast that misses fishable water fires a red UI error and NO
-- channel starts. Back off briefly so the loop/brain doesn't hammer a dead spot (ns.FishingAction
-- returns "wait" while backed off). NOTE: the numeric error TYPE (57) is SHARED with other
-- "can't do that" messages (e.g. "Can't do that while moving"), so we match the SPECIFIC WORDING
-- of the cast-failure, not the type. Add other real cast-fail phrasings to CAST_FAIL_TEXT.
local CAST_FAIL_TEXT = { "fishable water", "too shallow" }   -- lowercase substrings of genuine cast-failure messages
-- Line-of-sight: casting at a water spot behind an obstacle fires "Target not in line of sight" (locale-correct
-- via the global). It's a genuine cast-fail — back off + log it, not the loop hammering a blocked spot.
local LOS_MSG = SPELL_FAILED_LINE_OF_SIGHT and tostring(SPELL_FAILED_LINE_OF_SIGHT):lower() or nil
if LOS_MSG and LOS_MSG ~= "" then CAST_FAIL_TEXT[#CAST_FAIL_TEXT + 1] = LOS_MSG end
local function isCastFailMsg(msg)
  msg = tostring(msg or ""):lower()
  for _, t in ipairs(CAST_FAIL_TEXT) do if msg:find(t, 1, true) then return true end end
  return false
end
-- WHY a cast failed, tagged onto every castfail event (log display + the server record). Values:
--   los = target not in line of sight · nowater = not aimed at fishable water · shallow = water too shallow ·
--   nil = matched a cast-fail but the specific reason isn't classified (rare / new wording).
local function castFailCause(msg)
  msg = tostring(msg or ""):lower()
  if LOS_MSG and LOS_MSG ~= "" and msg:find(LOS_MSG, 1, true) then return "los" end
  if msg:find("fishable water", 1, true) then return "nowater" end
  if msg:find("too shallow", 1, true) then return "shallow" end
  return nil
end
-- Bags-full during looting: WoW MAILS un-looted items when the loot window closes with items still in it
-- (the "Postmaster" overflow). Auto-loot surfaces the window when bags fill (GECLoot), but a recast would
-- then CLOSE it and mail the loot — so SBF PAUSES casting while bags are full and loot is still in the window
-- (see ns.FishingAction). Locale-correct via the globals.
local BAGS_FULL_ERR = {}
if ERR_INV_FULL then BAGS_FULL_ERR[ERR_INV_FULL] = true end
if ERR_BAG_FULL then BAGS_FULL_ERR[ERR_BAG_FULL] = true end
-- region (continent) / zone / sub-zone, captured per fishing-log entry.
function SBF.ZoneTiers()
  local sub = (GetSubZoneText and GetSubZoneText()) or ""
  local zone = GetZoneText() or ""
  if sub == zone then sub = "" end
  local region, mapID, guard = "", C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"), 0
  while mapID and guard < 12 do
    guard = guard + 1
    local info = C_Map.GetMapInfo(mapID); if not info then break end
    if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent then region = info.name or ""; break end
    mapID = info.parentMapID; if not mapID or mapID == 0 then break end
  end
  return region, zone, sub
end

-- VARIABLE-DEPTH location cascade, ordered BROAD -> SPECIFIC, for profile location bindings + the fishlog
-- place. Now delegates to GECReader.Current.location() — the ONE location cascade shared across GEC addons,
-- which owns the C_Map walk / continent detection / subzone leaf. Each entry: { mapID, name, mapType,
-- kind = "continent"|"zone"|"area" } (the area leaf has no mapID — it's GetSubZoneText). Returns {} when the
-- Reader is absent (never errors). SBF no longer walks C_Map itself here.
function SBF.LocationCascade()
  local R = reader()
  local loc = R and R.Current and R.Current.location and R.Current.location()
  return loc or {}
end

-- The fishing journal now lives in the shared GECStore stream (SBFData.streams.fishlog): every record
-- carries the character index (ch), interned place (p), 2-decimal coords, and standard field names.
-- Oldest-first; readers reverse-iterate for newest-first display (Task 4/5). SBF.RefreshLog live-updates the Log tab.
local GECStore = LibStub("GECStore-1.0")
local fishStoreHandle
local function fishStore()
  fishStoreHandle = fishStoreHandle or GECStore.RegisterStore({ sv = "SBFData", schemaVersion = 2, src = "SBF",
    build = function() return SBF and SBF.BUILD end })
  return fishStoreHandle
end
-- The live fishing-event stream (oldest-first; readers reverse-iterate for newest-first display). Increment 2
-- (2026-07-18) moved it from streams.fishlog onto the CANONICAL streams.events, so Resolve/reconstruct/Combine +
-- the server ingest apply — the fishing cast-outcome kinds are events like Haul's loot (§10.7). Same accessor.
function SBF.FishLog() return fishStore():Stream("events") end

-- The CANONICAL session controller (GECStore.Session bound to SBF's store): owns the login→logout
-- lifecycle — mints the sid, lays start/stop markers, freezes the §3.3 record, and RepairOrphans /
-- RepairIfDangling protect the data. Same engine Haul uses. Lazy (the Session module attaches after
-- GECStore-1.0 loads). Increment 2 moves fishlog into streams.events so Resolve/reconstruct/Combine apply.
local fishSession
local function fishSessionCtrl()
  if not fishSession then
    local S = GECStore.Session
    if S and S.For then fishSession = S.For(fishStore()) end
  end
  return fishSession
end
SBF.Session = fishSessionCtrl

-- Manual "New session" (the GEC-Console button, /run SBF.NewSession()). SBF owns NONE of the lifecycle
-- logic — it just asks the controller to cycle: the library closes the open session (stop marker + frozen
-- record) and begins a fresh one (new sid + start marker) in one atomic call, so the stop always precedes
-- the start. Prices are {} (SBF doesn't value catches until increment 3). Refreshes the Log/Stats so the new
-- start marker shows immediately. Returns the new sid.
function SBF.NewSession()
  local S = fishSessionCtrl()
  if not (S and S.NewSession) then return end
  local sid = S:NewSession({}, "user")
  if SBF.RefreshLog then SBF.RefreshLog() end
  if SBF.RefreshStats then SBF.RefreshStats() end
  print("|cff45c4a0SBF|r new fishing session (|cffffffff" .. tostring(sid) .. "|r)")
  return sid
end

-- The CURRENT open session's start time = the newest "start" marker's timestamp. This is the boundary the
-- Stats "This session" view counts from, so starting a new session (SBF.NewSession lays a fresh start marker)
-- RE-BASELINES "This session" instead of it counting from login. Returns nil when no markers exist yet (Stats
-- then falls back to the login/reset baseline). Cheap reverse scan; markers are few.
function SBF.SessionStartT()
  local d = rawget(_G, "SBFData")
  local mk = d and d.streams and d.streams.markers
  if not mk then return nil end
  for i = #mk, 1, -1 do
    local m = mk[i]
    if m and m.k == "start" then return m.t end
  end
  return nil
end

-- Embed a registry copy into SBFData on logout/reload so the exported file resolves ch/p standalone.
local gecLogoutFrame = CreateFrame("Frame")
gecLogoutFrame:RegisterEvent("PLAYER_LOGOUT")
gecLogoutFrame:SetScript("OnEvent", function() fishStore():Snapshot() end)

local function logFishEvent(kind, extra, dur)
  local store = fishStore()
  local e = { k = kind, ch = GECStore.CharIndex(), p = GECStore.PlaceIndex(SBF.LocationCascade()) }
  do local S = fishSessionCtrl(); if S then e.sid = S:Sid() end end   -- attribute the event to the open session
  if dur then e.dur = math.floor(dur * 10 + 0.5) / 10 end   -- channel length (s), for the journal + footing stats
  -- coords + heading from the getter layer (x/y are 0-100 2-decimal, heading whole degrees). Casts happen
  -- out of combat, so the position is never a secret value here.
  local R = reader()
  local pos = R and R.Current and R.Current.position and R.Current.position()
  if pos then
    if pos.x then e.x = pos.x end
    if pos.y then e.y = pos.y end
    if pos.heading then e.h = pos.heading end
  end
  -- uiMapID the x/y are relative to (the SAME GetBestMapForUnit the position getter reads). Stored so a record
  -- is self-contained for later MAP PINS: (m, x/100, y/100) → an exact world position, no place-cascade lookup
  -- needed. Casts are stationary, so this matches the coords captured a beat earlier. See [[node-map-data]].
  if C_Map and C_Map.GetBestMapForUnit then
    local mid = C_Map.GetBestMapForUnit("player")
    if mid then e.m = mid end
  end
  if extra then for k, v in pairs(extra) do e[k] = v end end
  store:Append("events", e)                        -- stamps t + gen; appends oldest-first (CANONICAL stream, §10.7)
  if SBF.Stats then SBF.Stats.Record(e) end        -- bump the permanent all-time rollup (same e the stream holds)
  -- The raw log is NEVER trimmed — it stores always (non-destructive history). SBFDB.fishlogMax is now only a
  -- DISPLAY cap (how many recent lines the Log tab renders), applied in the viewer, not here.
  if SBF.RefreshLog then SBF.RefreshLog() end
  -- "Live" Stats-tab refresh: redraw on each logged event so the tab updates in real time as you fish.
  -- RefreshStats early-returns when the page isn't shown, so this is cheap when the tab/window is closed.
  -- The timer / "off" modes opt out here (a C_Timer ticker or manual clicks drive them instead).
  if SBF.RefreshStats and (SBFDB.statsRefresh or "live") == "live" then SBF.RefreshStats() end
end
SBF.LogFishEvent = logFishEvent

-- Increment 2 wipe (fishlog → streams.events): the fishing journal moved onto the canonical events stream so
-- Resolve/reconstruct/Combine + server ingest apply. Pre-release, the schema-1 fishlog + any increment-1 session
-- scaffolding are CLEARED (accepted — no in-place migration) so schema 2 starts pristine. One-time,
-- gated on the old stream / an under-2 version still being present; idempotent thereafter. The permanent all-time
-- rollup lives in SBFData.db.stats (NOT under streams), so it survives untouched. Must run BEFORE the first
-- fishStore()/session init, since RegisterStore overwrites SBFData.version to 2.
local function migrateFishlogWipe()
  local d = rawget(_G, "SBFData")
  if not d then return end   -- fresh install: RegisterStore creates version 2 clean
  local hasOldStream = d.streams and d.streams.fishlog ~= nil
  if (d.version or 1) >= 2 and not hasOldStream then return end   -- already migrated
  d.streams = d.streams or {}
  d.streams.fishlog = nil   -- the dead stream name
  d.streams.events  = nil   -- clean slate (drops any increment-1 test events)
  d.streams.markers = nil
  d.sessions        = nil
  d._open           = nil   -- controller's open-session pointer
  d._sidelined      = nil
  d.liveSession     = nil
  d.sidelined       = nil
  d.version         = 2
end
SBF.MigrateFishlogWipe = migrateFishlogWipe

-- Fishing skill-ups in the Log: ride GECStore's OnSkillIncrease feed (it scrapes CHAT_MSG_SKILL and fires a
-- self-identifying payload — lineID/skillName/newLevel/delta; same feed Haul's Skills tracker uses). We keep
-- ONLY fishing lines (filtered by SBF.FISHING_LINE, so it's locale-proof — no name matching) and drop them
-- into the same fishlog stream, so a "▲226" level-up lands in the Log right next to the casts that earned it
-- (with the auto-stamped time / character / place / coords every fishlog entry carries). Always-on, like the
-- casts themselves; a skill-up is at least +1, so a nil delta (cold line) defaults to 1.
local FISHING_LINE_SET = {}
for _, id in pairs(SBF.FISHING_LINE) do FISHING_LINE_SET[id] = true end
local function onFishingSkillUp(p)
  if not (p and p.lineID and FISHING_LINE_SET[p.lineID]) then return end
  logFishEvent("skill", { id = p.lineID, name = p.skillName, lvl = p.newLevel, amount = p.delta or 1 })
end
if GECStore.OnSkillIncrease then GECStore.OnSkillIncrease(onFishingSkillUp) end

-- SINGLE source of truth for what a fishing cast became — the log AND the footing panel both go
-- through this, so they can never disagree. "expired" is POSITIVE: the channel ran (near) its full
-- expected length with no bite. A channel that stopped SHORT with no catch/no-fish is an INTERRUPT,
-- not expired (cut off by jump/move/combat — even when the cause wasn't captured). The live loop
-- only needs the binary "line out?"; this 4-way verdict is purely for logging.
-- Order: caught -> missed (the 413) -> expired (full duration) -> interrupt (cut short).
local function classifyCast(c)
  if c.caught then return "caught" end
  if c.missed then return "missed" end
  if c.exp and c.dur then return (c.dur >= c.exp - 1) and "expired" or "interrupt" end
  return (c.cause or c.combat) and "interrupt" or "expired"   -- expected length unknown (rare): fall back to signals
end
SBF._ClassifyCast = classifyCast

-- ===== Gathered / container loot capture (structurally double-count-safe) =====
-- WHY the guard is essential: open-water fishing ALSO reports a GameObject loot source. Field data proved
-- this — the bobber fish (e.g. "Lost Sole", 1800×) lands in the SAME GameObject-source / "Unknown node"
-- bucket as a fished-up container ("Strange Goop") in Haul's gather log. So a naive "GameObject source →
-- gathered" scan would DOUBLE-LOG every fished fish (already logged as `caught` by the channel path).
--
-- The structural discriminator: a GATHERED window is one that opens with NO active/recent Fishing channel.
-- A fished catch's loot lands DURING / right after the channel (SBF._fishChanActive / SBF._fishLootUntil);
-- a container you right-click (a Midnight chest, a fished-up openable) opens with NO channel — and that is
-- exactly the loot the caught path MISSES today: its "You receive loot:" lines accumulate but never get a
-- CHANNEL_STOP to flush them, so they only ever reached the learned-item catalog, never the fishlog.
-- Predicate = GameObject-sourced (excludes creature combat loot — Haul's job) AND not fishing-attributable.
-- The pure decision (fishing guard + GameObject filter + per-source grouping) lives in ns.Gather (Gather.lua)
-- so it's headless-testable; Core supplies the WoW-API reads + the per-GUID dedup + the fishlog row build.
local gSeen, gSeenOrder = {}, {}   -- per-source-GUID dedup (LOOT_READY re-fires; a node GUID is unique per spawn)
local function gMark(guid)
  if not guid or gSeen[guid] then return false end
  gSeen[guid] = true; gSeenOrder[#gSeenOrder + 1] = guid
  if #gSeenOrder > 800 then local o = table.remove(gSeenOrder, 1); gSeen[o] = nil end
  return true
end
local function scanGathered()
  if not (GetLootSourceInfo and GetNumLootItems and ns.Gather) then return end
  -- LOOT-CLASSIFICATION diagnostic (SBFDB.lootDebug): dump every signal that decides fish-vs-chest at the
  -- moment a window opens, so a controlled test (stop fishing, wait, open a chest) shows EXACTLY why it
  -- classified as it did — GECLoot's fishing-tail state + the per-slot classified `t`. Toggle: /sbf lootdebug.
  if SBFDB and SBFDB.lootDebug then
    local now, gl = GetTime(), GECLoot
    print(string.format("|cffff9040SBF loot|r window @ fishActive=%s consumed=%s tail-Δ=%s lastCast=%s(%s) gather=%s | fishChan=%s catchPend=%s lootFishing=%s fishSeen=%s",
      tostring(gl and gl._fishActive), tostring(gl and gl._fishConsumed),
      (gl and gl._fishUntil) and string.format("%.1fs", now - gl._fishUntil) or "—",
      tostring(gl and gl._lastCast and gl._lastCast.spell or "—"),
      (gl and gl._lastCast) and string.format("%.1fs", now - gl._lastCast.t) or "—",
      tostring(gl and gl._gather and gl._gather.node or "—"),
      tostring(SBF._fishChanActive), tostring(SBF._catchPending), tostring(SBF._lootFishing), tostring(SBF._fishLootSeen)))
    for slot = 1, (GetNumLootItems() or 0) do
      local link = GetLootSlotLink and GetLootSlotLink(slot)
      local guid = GetLootSourceInfo and GetLootSourceInfo(slot)
      local src = gl and gl.ClassifyLootSlot and gl.ClassifyLootSlot(slot)
      print(string.format("   slot %d: %s  guid=%s  -> |cffffd100t=%s|r objID=%s",
        slot, tostring((link and link:match("%[(.-)%]")) or link or "money/?"),
        tostring(guid), tostring(src and src.t or "nil"), tostring(src and src.objID or "—")))
    end
  end
  -- read the loot window into the plain shape ns.Gather uses (no decision logic here). count/q come from
  -- GetLootSlotInfo (authoritative per-slot stack + quality); sources from GetLootSourceInfo (GameObject id).
  local n = GetNumLootItems() or 0
  local slots = {}
  local srcByGuid = {}   -- GameObject/Creature GUID -> GECLoot-classified src {t, objID/npcID, node, ...}
  for slot = 1, n do
    local link = GetLootSlotLink and GetLootSlotLink(slot)   -- nil for a money slot: coins are not "gathered"
    if link then
      local quantity, quality
      if GetLootSlotInfo then local _, _, q3, _, q5 = GetLootSlotInfo(slot); quantity, quality = q3, q5 end
      local raw, sources = { GetLootSourceInfo(slot) }, {}   -- (guid, qty) pairs — one slot can have >1 source
      for i = 1, #raw, 2 do sources[#sources + 1] = { guid = raw[i], qty = raw[i + 1] or 1 } end
      -- SHARED src classification (unified-schema Phase 3): GECLoot reads the same slot + the action context
      -- and returns {t, guid, npcID, objID, node} — fish / herb / mining / gather / chest / kill / …. Stamped
      -- onto the fishlog entry so a caught/gathered record knows its source (matches Haul's src).
      local src = GECLoot and GECLoot.ClassifyLootSlot and GECLoot.ClassifyLootSlot(slot)
      if src and sources[1] and sources[1].guid then srcByGuid[sources[1].guid] = srcByGuid[sources[1].guid] or src end
      slots[#slots + 1] = { link = link, count = quantity or 1, q = quality, sources = sources, src = src }
    end
  end
  -- Window ownership is decided ONCE, the first LOOT_READY of a window, and stays sticky until LOOT_CLOSED.
  -- If the window opened during / just-after a Fishing channel it's the caught path's — never gather ANY of
  -- it, even if LOOT_READY re-fires later (slow manual looting) after the post-stop time guard has elapsed.
  if SBF._lootFishing == nil then
    local now = GetTime()
    -- SOURCE-AWARE ownership: a window whose primary source classifies as NON-fishing (chest / container /
    -- gather / kill) is never the catch — force it onto the gathered path so it logs as gathered with its own
    -- source, even if it opened inside the post-catch guard tail. Only a fishing source (or an unclassified
    -- window during the tail) stays with the caught path. This stops a chest opened right after reeling in
    -- from being logged as a caught fish. (GECLoot MINOR 9 now tags such a chest t="chest", not "fish".)
    local wsrc = slots[1] and slots[1].src
    local wt = wsrc and wsrc.t
    if wt and wt ~= "fish" then
      SBF._lootFishing = false
    else
      SBF._lootFishing = (SBF._fishChanActive or (SBF._fishLootUntil and now <= SBF._fishLootUntil)) or false
    end
    -- ATOMIC caught-item capture: snapshot the WHOLE catch (fish + bait + bonus) from the loot window NOW,
    -- before GECLoot drains it — this is the reliable source for the caught entry's item list, replacing the
    -- fragile per-line chat accumulator that lost items when a recast reset it mid-grace. Gated tighter than
    -- _lootFishing (which spans the wide _fishLootUntil tail so containers opened seconds later aren't
    -- gathered): capture ONLY while the channel is live or a catch grace is still pending, so a container
    -- opened in that tail is never mistaken for a catch. The STOP+0.8 grace consumes SBF._caughtSlots; a new
    -- catch's first LOOT_READY overwrites it. NOT reset at CHANNEL_START (that would re-open the recast race).
    if SBF._lootFishing then SBF._fishLootSeen = true end   -- a REAL fishing loot window opened this cast (source-confirmed)
    if SBF._lootFishing and (SBF._fishChanActive or SBF._catchPending) then
      SBF._caughtSlots = ns.Gather.CatchItems(slots)      -- ONLY a fishing window feeds the catch (a chest can't overwrite it)
      SBF._caughtSrc = slots[1] and slots[1].src or nil   -- window source (fishing → {t="fish",...}); stamped on the caught entry
    end
  end
  if SBF._lootFishing then return end                     -- fishing loot -> caught path ONLY (never gathered)
  if not (SBFDB and SBFDB.gatherLoot) then return end     -- gathered logging is opt-out; the catch capture above is always on
  local containers = ns.Gather.Classify(slots, { fishing = false })
  if not containers then return end
  -- one gathered entry per container (source GUID): primary item fields + full items list, so it renders and
  -- searches exactly like a catch (multi-item chest → one row per item in the Log).
  for _, c in ipairs(containers) do
    -- herbalism/mining nodes ALSO loot from a GameObject, so Gather.Classify sweeps them in — but they're
    -- OTHER gathering professions, not fishing. This is a fishing journal (Haul tracks general gathering),
    -- so never log herb/ore here. Only fished-up containers / chests belong. (src.t from GECLoot.)
    local csrc = srcByGuid[c.guid]
    local skipProf = csrc and (csrc.t == "herb" or csrc.t == "mining")
    if (not skipProf) and gMark(c.guid) then
      local list = {}
      for _, it in ipairs(c.items) do
        list[#list + 1] = {
          id    = tonumber(it.link:match("Hitem:(%d+)")),   -- nil for a currency link (name still shows)
          name  = it.link:match("|h%[(.-)%]|h") or it.link:match("%[(.-)%]"),
          link  = it.link,
          count = it.count or 1,
          q     = select(3, GetItemInfo(it.link)),          -- item quality (nil for currency): powers sort/coloring
        }
      end
      if #list > 0 then
        local first = list[1]
        local extra = { id = first.id, name = first.name, link = first.link, count = first.count, q = first.q,
                        src = srcByGuid[c.guid] }   -- the node/container source (herb/mining/gather/chest)
        if #list > 1 then extra.items = list end            -- multi-item container: carry the FULL loot list
        logFishEvent("gathered", extra)
      end
    end
  end
end
SBF._ScanGathered = scanGathered

-- Localized "You receive loot:" prefixes (LOOT_ITEM_SELF / _MULTIPLE) — the ONLY self-loot chat lines that
-- count as a fishing catch. "You receive item:" (pushed) and "You create:" (created) also fire CHAT_MSG_LOOT,
-- but WITHOUT a loot window — they're inventory/UI events (clicking a collectible toy in the Collections tab,
-- combining items), and must NOT be logged as a catch. This is the "Burnished Helm clicked in the UI got
-- logged as a caught fish" fix. Real fishing loot arrives as "You receive loot:" (+ a LOOT_OPENED window).
local FISH_LOOT_PREFIXES = {}
do
  local function addP(fmt)
    local p = fmt and fmt:match("^(.-)%%s")
    if p and p ~= "" then FISH_LOOT_PREFIXES[#FISH_LOOT_PREFIXES + 1] = p end
  end
  addP(LOOT_ITEM_SELF); addP(LOOT_ITEM_SELF_MULTIPLE)   -- luacheck: globals LOOT_ITEM_SELF LOOT_ITEM_SELF_MULTIPLE
  if #FISH_LOOT_PREFIXES == 0 then FISH_LOOT_PREFIXES[1] = "You receive loot" end
end
local function isFishLootLine(msg)
  for _, p in ipairs(FISH_LOOT_PREFIXES) do if msg:find(p, 1, true) then return true end end
  return false
end

-- Always-on cast tracker: cast-fail + "no fish" audio AND the fishing log (every outcome).
local castFailFrame = CreateFrame("Frame")
castFailFrame:RegisterEvent("UI_ERROR_MESSAGE")
castFailFrame:RegisterEvent("UI_INFO_MESSAGE")               -- "No fish are hooked" = info type 413
castFailFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
castFailFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
castFailFrame:RegisterEvent("LOOT_OPENED")
castFailFrame:RegisterEvent("LOOT_READY")   -- gathered scan: fires BEFORE fast-loot (GECLoot) empties the slots
castFailFrame:RegisterEvent("LOOT_CLOSED")  -- resets the per-window fishing-ownership flag for the gathered scan
castFailFrame:RegisterEvent("CHAT_MSG_LOOT")
castFailFrame:RegisterEvent("PLAYER_STARTED_MOVING")   -- mark a MOVEMENT interrupt even if motion ended before the stop
castFailFrame:RegisterEvent("PLAYER_REGEN_DISABLED")   -- entered COMBAT during the channel = a combat interrupt
castFailFrame:SetScript("OnEvent", function(_, ev, a, b)
  if ev == "UI_ERROR_MESSAGE" then
    if BAGS_FULL_ERR[b] then SBF._lootBlocked = true end   -- bags full while looting -> pause casts (a recast would close the window + mail the loot)
    if isCastFailMsg(b) then               -- b = the message text; match wording, not the shared type
      SBF._castBackoffUntil = GetTime() + (SBFDB.castBackoff or 1.5)
      if SBFDB.castFailSound then SBF.PlayCastFailSound() end
      logFishEvent("castfail", { cause = castFailCause(b) })   -- tag WHY (los / nowater / shallow) — log display + server record
    end
  elseif ev == "UI_INFO_MESSAGE" then
    if a == 413 then                       -- "No fish are hooked": retrieved too early/late (MISSED)
      SBF._logMissedT = GetTime()
      if SBFDB.noFishSound then SBF.PlayNoFishSound() end
    end
  elseif ev == "UNIT_SPELLCAST_CHANNEL_START" and a == "player" then
    SBF._castBackoffUntil = nil            -- a real cast started -> clear the back-off
    -- only track the FISHING channel — a combat channel must not reach the log / cause checks below
    local cname, _, _, st, en, _, _, cid = UnitChannelInfo("player")
    if cid == 131474 or cname == "Fishing" then
      SBF._logCast = GetTime()
      SBF._fishChanActive = true              -- gathered-scan guard: this loot window belongs to the caught path
      SBF._logCastExp = (st and en and en > st) and ((en - st) / 1000) or nil   -- expected full window (s)
      SBF._logCaughtItems = {}            -- fresh per-cast loot accumulator (so a multi-item catch keeps ALL items)
      SBF._fishLootSeen = false           -- per-cast: set true only when a source-confirmed FISHING window opens
      SBF._chanMoved, SBF._chanCombat = false, false   -- per-cast interrupt-cause flags, set by the movement/combat events below
      -- persist the in-flight cast so a /reload mid-channel doesn't lose the reference: GetTime() is
      -- continuous across /reload, so the stored start stays valid; re-linked at login (PEW below).
      SBFDB._inflight = { start = SBF._logCast, exp = SBF._logCastExp, t = time() }
    else
      SBF._logCast, SBF._logCastExp = nil, nil
    end
  elseif ev == "LOOT_OPENED" then
    SBF._logCaughtT = GetTime()            -- a loot window opened during/after the cast = a real catch signal
  elseif ev == "LOOT_READY" then
    scanGathered()                         -- capture GameObject/container loot opened outside a fishing channel
  elseif ev == "LOOT_CLOSED" then
    SBF._lootFishing = nil                 -- next loot window re-decides ownership (fishing catch vs container)
    SBF._lootBlocked = nil                 -- window dealt with (looted or closed) -> resume casting
  elseif ev == "CHAT_MSG_LOOT" then
    -- ONLY a "You receive loot:" line counts as a catch. Pushed ("You receive item:") / created ("You create:")
    -- lines are UI/inventory events (clicking a collectible, combining items) with no loot window — ignoring
    -- them stops non-fished items (e.g. a toy clicked in Collections) from being logged as a caught fish.
    if a and isFishLootLine(a) then
      SBF._logCaughtT = GetTime()          -- timestamp the loot; attributed to a cast by its start time
      local item = {
        id = tonumber(a:match("Hitem:(%d+)")),
        name = a:match("|h%[(.-)%]|h") or a:match("%[(.-)%]"),
        link = a:match("|c%x+|Hitem:.-|h.-|h|r") or a:match("|Hitem:.-|h.-|h"),   -- full item link (quality-colored, hoverable)
        count = tonumber(a:match("x(%d+)")) or 1,
      }
      item.q = select(3, GetItemInfo(item.link or item.id or 0))   -- item quality (0=Poor/gray … 4=Epic); cached right after loot, for the Stats "Vendor trash" grouping + quality sort
      SBF._logCaughtItem = item            -- last item (single-item fallback / back-compat)
      -- accumulate EVERY loot line for this cast: fishing can yield several items at once (the fish plus
      -- bonus loot, or multiple fish), each arriving as its own CHAT_MSG_LOOT. Keeping only the last would
      -- undercount. Reset at each fishing CHANNEL_START; read at the STOP grace below.
      SBF._logCaughtItems = SBF._logCaughtItems or {}
      SBF._logCaughtItems[#SBF._logCaughtItems + 1] = item
    end
  elseif ev == "PLAYER_STARTED_MOVING" then
    if SBF._logCast then SBF._chanMoved = true end     -- moved during a fishing channel -> movement interrupt
  elseif ev == "PLAYER_REGEN_DISABLED" then
    if SBF._logCast then SBF._chanCombat = true end    -- pulled into combat during a fishing channel -> combat interrupt
  elseif ev == "UNIT_SPELLCAST_CHANNEL_STOP" and a == "player" then
    if SBF._logCast then
      local castStart, castExp = SBF._logCast, SBF._logCastExp
      local dur = GetTime() - castStart                         -- how long the channel actually ran
      SBF._logCast, SBF._logCastExp = nil, nil
      -- gathered-scan guard: the catch's loot lands right after the stop — keep gathering suppressed for a
      -- short window so this cast's own loot is never re-logged as "gathered" (the caught path owns it).
      SBF._fishChanActive = false
      SBF._fishLootUntil = GetTime() + (SBFDB.gatherFishGuardSec or 3)
      SBF._catchPending = true                                  -- a catch is awaiting resolution: the loot window
                                                                -- that opens now (LOOT_READY) is THIS cast's catch, so
                                                                -- its slots may be captured into SBF._caughtSlots
      SBFDB._inflight = nil                                      -- cast resolved -> clear the persisted in-flight
      -- capture an interrupt CAUSE now (it's transient — gone by the grace timer). Precedence: combat (got
      -- attacked) > jump > movement. We fold in the per-cast flags set DURING the channel (_chanCombat /
      -- _chanMoved) so a brief move that ended before the stop, or combat we're no longer "in" by the stop,
      -- is still attributed instead of falling through to "unknown".
      local cause
      if (UnitAffectingCombat and UnitAffectingCombat("player")) or SBF._chanCombat then cause = "combat"
      elseif IsFalling and IsFalling() then cause = "jump"
      elseif SBF._chanMoved then cause = "moving"
      else
        local sp = GetUnitSpeed and GetUnitSpeed("player")   -- can be a SECRET value in combat -> never compare it
        if sp and not (issecretvalue and issecretvalue(sp)) and sp > 0.1 then cause = "moving" end
      end
      C_Timer.After(0.8, function()        -- grace: a catch's loot / the 413 can land just after the stop
        local combat = (UnitAffectingCombat and UnitAffectingCombat("player")) or false
        -- caught requires BOTH a catch-timed loot signal AND a source-confirmed fishing window this cast, so a
        -- chest/container opened during the grace (which also trips _logCaughtT) can never register as a catch.
        local caught = ((SBF._logCaughtT and SBF._logCaughtT >= castStart - 0.3) and SBF._fishLootSeen) or false
        local missed = (SBF._logMissedT and SBF._logMissedT >= castStart - 0.3) or false
        local kind = classifyCast({ caught = caught, missed = missed, dur = dur, exp = castExp,
          cause = cause, combat = combat })
        SBF._catchPending = false                    -- this cast's catch is now resolved
        local extra
        if kind == "caught" then
          -- PREFER the atomic slot scan (SBF._caughtSlots, captured whole at LOOT_READY); fall back to the
          -- chat accumulator, then the singular last-item — a catch must never log nil or drop the fish.
          local list = (ns.Gather and ns.Gather.PickCaughtList and ns.Gather.PickCaughtList(SBF._caughtSlots, SBF._logCaughtItems))
                       or (SBF._caughtSlots and #SBF._caughtSlots > 0 and SBF._caughtSlots)
                       or SBF._logCaughtItems
          if list and #list > 0 then
            local first = list[1]
            extra = { id = first.id, name = first.name, link = first.link, count = first.count, q = first.q,
                      src = SBF._caughtSrc }            -- the fishing source (fish / bobber), from GECLoot's classifier
            if #list > 1 then extra.items = list end   -- multi-item catch: carry the FULL loot list ({id,name,link,count} each)
          else
            extra = SBF._logCaughtItem                 -- safety fallback (shouldn't happen on a caught, but never log nil)
          end
          SBF._caughtSlots, SBF._caughtSrc = nil, nil  -- consume: this catch's atomic stash is used up
        elseif kind == "interrupt" then extra = { cause = cause or (combat and "combat") or "unknown" } end
        logFishEvent(kind, extra, dur)
        if kind == "expired" and SBFDB.expiredSound then SBF.PlayExpiredSound() end   -- expired = ran full, no bite
        -- expose the ONE classified result so the footing panel (and any future reader) mirrors the log
        SBF._lastCast = { kind = kind, dur = dur, exp = castExp, cause = extra and extra.cause, t = GetTime() }
      end)
    end
  end
end)

-- ===== Native binding bridge (the fishing cast + interact loot are NATIVE Key Bindings) =====
-- Cast Fishing lives in WoW's own Key Bindings as the command below (declared in Bindings.xml). The native
-- binding is the SINGLE SOURCE OF TRUTH: SBF's own UI, WoW's Key Bindings menu, and ConsolePort all read /
-- write the SAME binding, so they can never disagree. (Interact/Loot likewise uses the native INTERACTTARGET.)
-- The dev-only per-slot/gear keybinds still ride SBF's internal override store (SBFDB.binds*) — those aren't
-- exposed to the native menu on purpose.
-- All native-binding mechanics (key inspection, conflict prompt, the capture widget) live in the shared
-- GECBind-1.0 lib so SBF, Haul, and any future addon behave identically. Core uses it for the fishing
-- key-set + the migration; Options/Welcome use its capture widget. (GECBind is declared once up in the secure
-- buttons section so the button helpers can use it too.)
SBF.FISHING_CMD = "CLICK SBFBtn_fishing:LeftButton"
-- thin back-compat shims (older call sites read these): delegate to the lib.
function SBF.NativeKeys(command) return GECBind.Keys(command) end
function SBF.NativeKeyOfKind(command, kind) return GECBind.KeyOfKind(command, kind) end

-- Multi-binding: an action can be triggered by Key 1 (SBFDB.binds), an optional Key 2 (SBFDB.binds2),
-- AND a controller button (SBFDB.bindsCtrl) all at once. Returns the non-empty combos for an action id,
-- in that order. (The per-slot popups + master key still read/write binds[id] — back-compat preserved.)
-- FISHING is the exception: its keys live in the NATIVE binding (SBF.FISHING_CMD), so we read them from
-- there — that's what the dynamic loot override rebinds while the line is out.
function SBF.BindsFor(id)
  if id == "fishing" then return GECBind.Keys(SBF.FISHING_CMD) end
  local out = {}
  local b1 = SBFDB.binds and SBFDB.binds[id]
  local b2 = SBFDB.binds2 and SBFDB.binds2[id]
  local bc = SBFDB.bindsCtrl and SBFDB.bindsCtrl[id]
  if b1 and b1 ~= "" then out[#out + 1] = b1 end
  if b2 and b2 ~= "" then out[#out + 1] = b2 end
  if bc and bc ~= "" then out[#out + 1] = bc end
  return out
end

-- Release a key `combo` from every SBF-OWNED binding so it can be reassigned without colliding: clears it from
-- all three internal slot stores (binds/binds2/bindsCtrl, any slot), and — if it's the native fishing key —
-- clears that native slot too (keyboard AND controller). Used by the per-slot keybind editor's conflict prompt
-- so accepting "reassign here" actually frees the key from wherever it was. Leaves NON-SBF game bindings alone
-- (an SBF override merely shadows those while active, so there's nothing to steal).
function SBF.FreeCombo(combo)
  if not combo or combo == "" then return end
  for _, store in ipairs({ "binds", "binds2", "bindsCtrl" }) do
    local t = SBFDB[store]
    if t then for id, v in pairs(t) do if v == combo then t[id] = nil end end end
  end
  for _, kind in ipairs({ "key", "pad" }) do
    if GECBind.KeyOfKind(SBF.FISHING_CMD, kind) == combo then GECBind.Clear(SBF.FISHING_CMD, kind) end
  end
end

-- One-time-per-load migration: lift any OLD internal fishing keybinds (SBFDB.binds/binds2/bindsCtrl.fishing)
-- and the old internal interact CONTROLLER bind into the native bindings, so existing users keep their keys
-- after the move to native-as-source-of-truth. GECBind.Migrate only seeds a command with no native key yet
-- (idempotent); we then clear the internal copies so SBF.Apply never re-creates an override for them.
function SBF.MigrateBindsToNative()
  if InCombatLockdown() then return end
  -- fishing -> native cast command (first non-empty internal store wins; Migrate only seeds if native empty)
  local fk
  for _, store in ipairs({ "binds", "binds2", "bindsCtrl" }) do
    local v = SBFDB[store] and SBFDB[store].fishing
    if v and v ~= "" and not fk then fk = v end
  end
  if fk then GECBind.Migrate({ [SBF.FISHING_CMD] = fk }) end
  -- interact CONTROLLER -> the pad slot of native INTERACTTARGET (coexists with a keyboard interact key, so
  -- seed the pad slot specifically rather than only-when-the-whole-command-is-empty).
  local ic = SBFDB.bindsCtrl and SBFDB.bindsCtrl.interact
  if ic and ic ~= "" and not GECBind.KeyOfKind("INTERACTTARGET", "pad") then
    GECBind.Set(ic, "INTERACTTARGET", "pad")
  end
  -- drop the now-migrated internal copies (fishing on every store; interact's controller)
  for _, store in ipairs({ "binds", "binds2", "bindsCtrl" }) do
    if SBFDB[store] then SBFDB[store].fishing = nil end
  end
  if SBFDB.bindsCtrl then SBFDB.bindsCtrl.interact = nil end
end

-- (re)load every button + (re)apply its key combo. Deferred if in combat.
function SBF.Apply()
  if InCombatLockdown() then SBF._pending = true; return end
  SBF._pending = nil
  ClearOverrideBindings(bindOwner)
  SBF.EachDef(function(key, def, src)
    local binds = SBF.BindsFor(key)
    local actionable = (def.macro and def.macro ~= "") or (def.item and def.item ~= "")
      or def.spell or def.toy
    local gameAction = def.gameBinding or (src and src.gameBinding)
    if not actionable and gameAction then
      -- pure game binding (e.g. interact -> Interact With Target). We don't own a secure button for it,
      -- so there's nothing to pre-create; only wire it when a key/button is actually captured in SBF.
      for _, binding in ipairs(binds) do SetOverrideBinding(bindOwner, false, binding, gameAction) end
    else
      -- our own secure button. ALWAYS ensure + configure it, even with NO captured key, so external
      -- "CLICK SBFBtn_<slot>:LeftButton" bindings resolve — a controller button assigned in ConsolePort,
      -- or a key set in WoW's own Key Bindings (both via Bindings.xml). (This is also what attaches the
      -- fishing "brain" PreClick below — buttons.fishing must exist for the loop to drive a click-target.)
      local b = EnsureButton(key)
      Configure(b, def)
      -- Trigger EVERY secure slot (incl. fishing) via an OVERRIDE-CLICK binding. Override-clicks are the
      -- "blessed" addon path that carries the protected-cast privilege through to our INSECURE smart button
      -- (the PreClick brain). A plain native "CLICK SBFBtn_fishing" binding does NOT — the press runs the
      -- PreClick but the secure cast is silently dropped (confirmed on a clean, addon-free client). So for
      -- fishing the native binding stays only as the SOURCE OF TRUTH / menu+ConsolePort display, and we read
      -- its keys here (SBF.BindsFor("fishing") -> GetBindingKey) to override-bind the REAL trigger.
      for _, binding in ipairs(binds) do SetOverrideBindingClick(bindOwner, false, binding, b:GetName()) end
    end
  end)

  -- gear pseudo-actions (not in ns.SLOTS, so not covered by EachDef): bind their combos to the plain
  -- click-buttons created above. Same bind keys (Key1/Key2/Controller), same override owner (cleared above).
  for id, btn in pairs(gearActionBtns) do
    for _, binding in ipairs(SBF.BindsFor(id)) do
      SetOverrideBindingClick(bindOwner, false, binding, btn:GetName())
    end
  end

  -- mouse double-click fishing: install the WorldFrame detection hook + clear any stale momentary binding to
  -- match the current enabled state. Its bindings live on mouseBindOwner (NOT bindOwner above), so the
  -- ClearOverrideBindings at the top of Apply never touches them.
  if SBF.MouseApply then SBF.MouseApply() end

  -- the Cast Fishing button checks swimming on each press: if you're swimming and
  -- a Boat is set, this press casts the boat (so you stand on the raft); otherwise
  -- it does the fishing action. IsSwimming() is false once you're on the raft, so
  -- the very next press fishes — self-correcting.
  local fb = buttons.fishing
  if fb then
    fb:SetScript("PreClick", function(self)
      if InCombatLockdown() then return end
      -- Phase-5 gear: stamp the last action-press time (the idle timer reads it). The actual gear equip is
      -- handled as its OWN press below (just before the fish macro), so a gear swap and the fishing channel
      -- never collide on the same press.
      SBF.lastActionAt = GetTime()
      SBF.gearArmed = nil   -- legacy arm flag no longer gates anything; the gear gate below does

      -- Self-correct the active profile: if auto-swap is on and a different profile resolves for where we
      -- are (e.g. the login resolution ran before the map loaded and stuck on Default), switch now so the
      -- right gear/config is used. Skip while dirty (don't discard unsaved edits on a press; the zone
      -- prompt owns that path). Runs BEFORE the gear gate so the gate then equips the correct profile's gear.
      if SBFDB.autoSwap and not SBF.IsDirty() and SBF.ResolveProfile then
        local target = SBF.ResolveProfile()
        if target and SBF.working and target ~= SBF.working.id then SBF.DoSwap(target) end
      end

      -- Focus fishing audio: starting to fish reconfigures WoW's sound (isolate the bobber splash, mute
      -- music/ambience). Parallel to gear — applied on a press, restored on idle/stop/login. No-op unless
      -- enabled + not already applied. CVars aren't protected, so this is safe and needs no [combat] dance.
      if SBF.ApplyFocusAudio then SBF.ApplyFocusAudio() end

      -- Gear gate — HIGHEST PRIORITY, the very first thing a press does. If the active profile's gear/pole
      -- isn't currently on, THIS press changes gear and does NOT fish (you can't swap gear and start the
      -- fishing channel on the same press — "you can't do that right now"). The press equips; the next press
      -- moves on (dismount/fish/etc). One step per press, gear first. Out of combat only (guaranteed by the
      -- early return up top), so the equip is unrestricted and can't taint the cast. No-op when gear's
      -- already correct, so normal fishing is untouched.
      if SBF.GearNeedsEquip and SBF.GearNeedsEquip() then
        SBF.EquipProfileGear()
        announce("equipping gear")
        local combatDef = SBF.SlotDef("combat")
        local cl = (not (combatDef and combatDef.skip)) and combatLine(combatDef) or nil
        self:SetAttribute("type", "macro")
        self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
        applyMacro(self, cl and ("/stopmacro [nocombat]\n" .. guardCombat(cl)) or "", "combat-hold")
        return
      end

      -- Phase-1 gate: not castable (flying/moving/mounted/swimming/...) -> no-op press.
      -- Belt-and-suspenders for the ~0.15s override-poll lag (the dynamic override suppresses
      -- the key the rest of the time). Loot-while-channeling is handled by the INTERACT override.
      local fa = ns.FishingAction and ns.FishingAction()
      if fa == "dismount" then          -- ground mount + auto-dismount on: dismount; next press fishes
        announce("dismounting")
        self:SetAttribute("type", "macro")
        self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
        applyMacro(self, "/dismount", "dismount")
        return
      elseif fa == "wait" then          -- disabled (flying/moving/loot-mode/...) -> no-op OUT of
        -- combat, but KEEP the [combat] attack so combat still fires off the action key.
        local combatDef = SBF.SlotDef("combat")
        local cl = (not (combatDef and combatDef.skip)) and combatLine(combatDef) or nil
        self:SetAttribute("type", "macro")
        self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
        applyMacro(self, cl and ("/stopmacro [nocombat]\n" .. guardCombat(cl)) or "", "combat-hold")
        return
      elseif fa == "lootone" then       -- fast-loot off + loot window open: press loots ONE slot, no cast
        -- Inert cast (keep the [combat] attack so a mob mid-loot still gets hit), and flag PostClick to
        -- LootSlot one item. LootSlot is unprotected, so it runs safely in the post-secure-click hook.
        local combatDef = SBF.SlotDef("combat")
        local cl = (not (combatDef and combatDef.skip)) and combatLine(combatDef) or nil
        self:SetAttribute("type", "macro")
        self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
        applyMacro(self, cl and ("/stopmacro [nocombat]\n" .. guardCombat(cl)) or "", "combat-hold")
        self._sbfLootOne = true         -- PostClick loots one slot (see the PostClick hook)
        announce("looting")
        return
      end
      -- consume lock: after firing food/drink, the button does no consumable/fishing
      -- action for a few seconds so a press can't interrupt the eat/drink. BUT keep the
      -- combat block — a mob hitting you mid-eat must still get attacked (we can't
      -- rebuild the button once combat starts). Out of combat the /stopmacro [nocombat]
      -- makes it a harmless no-op that won't interrupt eating.
      if SBF._consumeUntil and GetTime() < SBF._consumeUntil then
        local combatDef = SBF.SlotDef("combat")
        local cl = (not (combatDef and combatDef.skip)) and combatLine(combatDef) or nil
        self:SetAttribute("type", "macro")
        self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
        applyMacro(self, cl and ("/stopmacro [nocombat]\n" .. guardCombat(cl)) or "", "combat-hold")
        if SBFDB.debug then
          print(string.format("|cff45c4a0SBF|r consume-lock %.0fs left (combat-only)",
            SBF._consumeUntil - GetTime()))
        end
        return
      end
      local macro, label, slotKey, timed = buildPressMacro(true)   -- real press: may emit the restock warning
      announce(describeAction(slotKey))
      self:SetAttribute("type", "macro")
      self:SetAttribute("item", nil); self:SetAttribute("spell", nil); self:SetAttribute("toy", nil)
      applyMacro(self, macro, label or "action")
      if timed and slotKey then
        SBFDB.lastFired = SBFDB.lastFired or {}
        SBFDB.lastFired[slotKey] = time()   -- mark this rotation slot as just used
      end
      -- fireAll per-item stamp: a fireAll slot (Buffs) keeps N buffs up, so it needs PER-ITEM grace +
      -- buffDuration anchoring, not the slot-wide lastFired. Stamp the item that just fired (the one
      -- pickItem armed) so nextDueItem won't re-count it as due before its buff lands / per its duration.
      do
        local sd = slotKey and ns.SlotDef(slotKey)
        if timed and sd and sd.fireAll then
          local cd = SBF.ActiveSlots()[slotKey]
          local fid = cd and ns.curItemId(cd)
          if fid then cd.firedAt = cd.firedAt or {}; cd.firedAt[fid] = time() end
        end
      end
      -- post-fire bookkeeping, dispatched on the descriptor (replaces the slotKey== branches):
      --   postFire="channel" -> idle-lock (food/drink); "climb" -> boat climb window + re-fire
      --   suppress; plus the chum burst-debt decrement. (See Slots.postFire.)
      local slotDef = slotKey and ns.SlotDef(slotKey)
      local cdef = slotKey and SBF.ActiveSlots()[slotKey]
      if slotDef and cdef then ns.postFire(slotDef, cdef, timed) end
      -- B2 action log: record ONLY the SBF action that just fired (food/drink/chum/lure/bobber/boat),
      -- here at fire-time. `timed` is exactly the rotation/boat fires — so manual casts (herbalism,
      -- Opening, mining, …) can never leak in (the old blanket UNIT_SPELLCAST_SUCCEEDED handler did).
      -- ALWAYS logged now — SBFDB.logActions is a VIEW filter on the Log tab (show/hide), not a capture gate.
      if timed and slotKey and cdef then
        logFishEvent("action", { spell = ns.defName(cdef) or (slotDef and slotDef.label) or slotKey, slotKey = slotKey })
      end
      -- observe the item's COOLDOWN into the knowledge record: the item goes on cooldown the instant it
      -- fires, but the API reads 0 this same frame — read it next frame (C_Timer.After + pcall, guarded
      -- like itemCooldown). The >2 filter drops the global ~1.5s GCD so it isn't mistaken for the item CD.
      if timed and slotKey and cdef then
        local iid = ns.curItemId and ns.curItemId(cdef)
        if iid then
          C_Timer.After(0.5, function()
            local get = (C_Item and C_Item.GetItemCooldown) or GetItemCooldown
            if not get then return end
            local ok, start, dur = pcall(get, iid)
            if ok and start and (dur or 0) > 2 and start > 0 then SBF.ObserveItem(iid, { cooldown = dur }) end
          end)
        end
      end
      -- buff learning, also descriptor-driven: aura slots learn (`effect == "aura"`), enchant slots
      -- don't (no aura). The boat is an aura slot too, so its real buff (which may differ from the
      -- raft item name) gets captured into the account-wide DB the same way. Food/drink buffs land
      -- slowly (~10s), so watch up to the grace window; fast slots use a short window so back-to-back
      -- casts (the two chums) don't grab each other's buff.
      -- Learning is UNIVERSAL: route every aura-slot fire through learnBuff, which owns the whole
      -- "anything to learn, for which item?" decision (per-item for fireAll, slot-level otherwise). One
      -- place, no per-slot guards here — enchant slots (no aura) are the only ones excluded.
      if slotDef and cdef and timed and slotDef.effect == "aura" then
        local window = (slotDef.postFire == "channel") and (SBFDB.applyGrace or 12) or 4
        learnBuff(slotKey, cdef, GetTime() + window)
      end
      -- ENCHANT slots (Nat's / pole-enchant lures) carry NO aura to learn, but they DO have data worth
      -- recording — for curation + the server: mark the item's kind = "enchant" (so an empty `buff` reads as
      -- "correct, it's an enchant" not "missing"), and capture the enchant's DURATION, sampled right after it
      -- lands (PoleEnchantLeft handles the slot-28 pole case). No buff/spell (not an aura); cooldown stays as
      -- observed above (enchants have none). The just-applied remaining ~= full length, so it's a good default.
      if slotDef and cdef and timed and slotDef.effect == "enchant" then
        local iid = ns.curItemId and ns.curItemId(cdef)
        if iid then
          SBF.ObserveItem(iid, { kind = "enchant" })   -- type is known immediately, even if the timer read fails
          if SBF._buffDbg then SBF._buffDbg("|cff80ff80ENCHANT|r %s item=%s applied — reading duration", slotKey, tostring(iid)) end
          C_Timer.After(0.5, function()
            local left = SBF.PoleEnchantLeft and SBF.PoleEnchantLeft()
            if left and left > 0 then
              SBF.ObserveItem(iid, { buffDuration = math.ceil(left) })
              if SBF._buffDbg then SBF._buffDbg("enchant %s item=%s dur=|cffffd100%ss|r", slotKey, tostring(iid), tostring(math.ceil(left))) end
            elseif SBF._buffDbg then
              SBF._buffDbg("enchant %s item=%s: |cffff6060no enchant timer readable|r", slotKey, tostring(iid))
            end
          end)
        end
      end
      if SBFDB.debug then   -- one PreClick per press now (up-stroke), so print every time
        local inCombat = UnitAffectingCombat and UnitAffectingCombat("player")
        print(string.format("|cff45c4a0SBF|r press -> state=|cffffd100%s|r next=|cffffd100%s|r (%s)  "
          .. (inCombat and "|cffff3333COMBAT=true|r" or "|cff33ff33combat=false|r"),
          tostring(SBF.GetState()), tostring(label), tostring(slotKey)))
        print("|cff7f7f7f  macro:|r " .. macro:gsub("\n", " |cff7f7f7f¬|r "))
      end
    end)
    -- DIAGNOSTIC (debug only): PostClick fires ONLY if the secure click actually completed. So:
    --   "press ->" (PreClick) but NO "PostClick fired"  => the secure click isn't completing; the cast never runs.
    --   BOTH lines but still no cast                     => the secure click ran and the CLIENT rejected /cast.
    -- Hooked once (additive HookScript — the mouse-loot path also PostClick-hooks this button).
    if not fb._dbgPostHooked then
      fb._dbgPostHooked = true
      fb:HookScript("PostClick", function(self)
        if self._sbfLootOne then          -- fast-loot-off paced loot: take one slot per press
          self._sbfLootOne = nil
          SBF.LootOneSlot()
        end
        if SBFDB.debug then print("|cff45c4a0SBF|r |cff33ff33PostClick fired|r — secure click completed") end
      end)
    end
  end
end

-- Build the WoW binding string for a key with the currently-held modifiers.
-- WoW's canonical order is ALT-CTRL-SHIFT-<KEY>.
function SBF.ComboString(keyName)
  local m = ""
  if IsAltKeyDown() then m = m .. "ALT-" end
  if IsControlKeyDown() then m = m .. "CTRL-" end
  if IsShiftKeyDown() then m = m .. "SHIFT-" end
  return m .. keyName
end

-- ===========================================================================
-- Mouse double-click fishing (GoFish / ZenFishing approach) — fire SBF's SECURE
-- fishing button by DOUBLE-clicking a chosen mouse button.
--
-- The hard constraint: addon code can't press the protected fishing cast — it
-- must come from a HARDWARE click landing on a secure button. The mechanism,
-- arm-on-the-2nd-click exactly as GoFish/ZenFishing do it:
--   * GLOBAL_MOUSE_DOWN is OBSERVE-ONLY (does NOT consume the click). On a
--     CONFIRMED double-click (MIN < gap < doubleSec) we arm the override binding
--     RIGHT THEN, in the same input pass, so the click resolves to the secure
--     button. A 1st/slow click does NOT arm — it passes straight through.
--   * THE KEY PIECE we were missing: right-click (and left-drag) puts the game
--     into MOUSELOOK (camera), which CONSUMES the click so the override binding
--     never fires. So before arming we do `if IsMouselooking() then
--     MouselookStop() end` — exactly what GoFish/ZenFishing do. THIS is why
--     right-click "did nothing" for us.
--   * The binding is cleared in the secure button's POSTCLICK (after the cast
--     actually fires) — the real ZenFishing/GoFish teardown — plus a short
--     seq-guarded fallback timer in case the click never reached the button, so
--     a stale binding can never linger.
--   * A SEPARATE owner frame (mouseBindOwner) keeps these bindings off bindOwner
--     (the key bindings), so the two never clash; out of combat only; also
--     cleared on PLAYER_REGEN_ENABLED and in MouseApply/disable.
-- ===========================================================================
local mouseBindOwner = CreateFrame("Frame")   -- owns ONLY the double-click bindings (never bindOwner's keys)
local mouseArmedToken = nil     -- which token currently has an armed binding (nil = nothing armed)
local mouseArmedIsGame = false  -- the armed binding is a raw game binding (loot/INTERACTTARGET) — no PostClick
local mouseClearSeq = 0         -- monotonic: bumped on every arm/clear; only the matching fallback timer fires
local MOUSE_MIN = 0.02          -- ignore a 2nd press faster than this (a bounce, not a deliberate double)
local MOUSE_FALLBACK = 0.1      -- if the click never reached the secure button (no PostClick), clear after this
SBF._mouseGaps = SBF._mouseGaps or {}   -- last few REAL double-click gaps (for /sbf mouse tuning)

local function mdbg(...) if SBFDB and SBFDB.mouse and SBFDB.mouse.debug then print("|cff66ccffSBF mouse|r", ...) end end

-- map a GLOBAL_MOUSE_DOWN button name to the WoW binding token form (BUTTON1..BUTTON5)
local MOUSE_TOKEN = {
  LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
  Button4 = "BUTTON4", Button5 = "BUTTON5",
}
local function mouseToken(name)
  return MOUSE_TOKEN[name] or (type(name) == "string" and name:match("^BUTTON%d$")) or nil
end

-- Clear any armed double-click binding. Guarded — we must NEVER leave a stale override binding (it would
-- make every press of that mouse button fire the action). Bumps the seq so any pending fallback timer no-ops.
local function mouseClear()
  mouseClearSeq = mouseClearSeq + 1
  mouseArmedToken = nil
  mouseArmedIsGame = false
  pcall(ClearOverrideBindings, mouseBindOwner)
end
SBF.MouseClear = mouseClear

-- Arm the binding for `token` to fire `target` (a secure button name) or, for a game binding like
-- INTERACTTARGET, the binding command itself — called on the CONFIRMED 2nd click of a double, in the same
-- input pass, so this click resolves to the secure button. Stops mouselook FIRST (else the camera eats the
-- click). Schedules a seq-guarded FALLBACK clear in case the click never reaches the button's PostClick.
-- `isGameBinding` doubles as the "loot via raw INTERACTTARGET" marker (no secure button to PostClick-hook),
-- so the fallback prints "fired (loot)" for that path — otherwise it would be misleadingly silent.
local function mouseArm(token, target, isGameBinding)
  if InCombatLockdown() then return end   -- never fiddle override bindings in combat
  -- if a DIFFERENT token was armed, clear it first so two configured buttons can't both stay armed
  if mouseArmedToken and mouseArmedToken ~= token then pcall(ClearOverrideBindings, mouseBindOwner) end
  -- THE FIX: leave mouselook so the click isn't consumed by the camera and actually reaches the binding.
  if IsMouselooking and IsMouselooking() then pcall(MouselookStop) end
  local ok
  if isGameBinding then
    ok = pcall(SetOverrideBinding, mouseBindOwner, true, token, target)
  else
    ok = pcall(SetOverrideBindingClick, mouseBindOwner, true, token, target)
  end
  if not ok then mouseClear(); return end
  mouseArmedToken = token
  mouseArmedIsGame = isGameBinding and true or false   -- the game-binding (loot) path has no PostClick
  mouseClearSeq = mouseClearSeq + 1
  local mySeq = mouseClearSeq
  C_Timer.After(MOUSE_FALLBACK, function()
    if mouseClearSeq == mySeq then
      -- a game-binding (loot) arm has no secure PostClick, so the click fired via this fallback window:
      -- print "fired (loot)" here so debug isn't silent for that path. Secure-button arms print in PostClick.
      if mouseArmedToken and mouseArmedIsGame then mdbg("fired (loot)") end
      mouseClear()
    end
  end)
end

-- Resolve what the loot/interact double-click should fire. Mirrors how the interact slot is wired in
-- SBF.Apply: an interact slot with an actual item/macro is a SECURE CLICK button; otherwise it falls back
-- to the game binding (INTERACTTARGET). Returns (target, isGameBinding) or nil if interact isn't usable.
local function interactTarget()
  local s = SBF.ActiveSlots()
  local def = s.interact
  local actionable = def and ((def.macro and def.macro ~= "") or (def.item and def.item ~= "")
    or def.spell or def.toy)
  if actionable and buttons.interact then
    return buttons.interact:GetName(), false
  end
  -- no secure action loaded: use the game binding (the same INTERACTTARGET the key path uses)
  local gb = (def and def.gameBinding) or "INTERACTTARGET"
  return gb, true
end

-- Clear the mouse override binding once the secure action has FIRED — the real GoFish/ZenFishing teardown.
-- Hooked (once) onto a secure button's PostClick. No-op unless a mouse arm is actually active, so a normal
-- KEY press of the same button doesn't print/clear spuriously.
local mousePostHooked = {}
local function mouseHookPostClick(btn)
  if not btn or mousePostHooked[btn] then return end
  mousePostHooked[btn] = true
  btn:HookScript("PostClick", function()
    if mouseArmedToken then
      mdbg("fired")
      mouseClear()
    end
  end)
end
SBF.MouseHookPostClick = mouseHookPostClick

local mouseLastDown = {}         -- token -> GetTime() of its last press (for double-click timing)
local function mouseEnabled() return SBFDB and SBFDB.mouse and SBFDB.mouse.enabled end

-- The detection handler. Wired to WorldFrame:OnMouseDown (see below) — GoFish's exact approach. WorldFrame's
-- OnMouseDown fires EARLIER in the input pass than GLOBAL_MOUSE_DOWN (which fires after the click is already
-- resolved against the binding table — the residual race that made arm-on-2nd land only ~50%), so arming
-- here reliably affects THIS click. (It also only fires for clicks on the 3D world, exactly where fishing
-- happens; UI clicks don't trigger it, which is desirable.)
local function mouseOnDown(button)
  if not mouseEnabled() then return end          -- disabled: do nothing, single clicks fully untouched
  if InCombatLockdown() then return end          -- never touch override bindings in combat (can't arm bindings)
  local token = mouseToken(button)
  if not token then return end
  local m = SBFDB.mouse
  local twoBtn = SBFDB.requireTwoButtons and true or false
  -- SINGLE-BUTTON mode: only the Action button is live (it casts AND loots via the fishing button's dynamic
  -- INTERACTTARGET override). Ignore the loot token entirely — no separate loot button exists in this mode.
  if token == m.fishButton then
    -- ok, the Action button
  elseif twoBtn and m.lootButton and token == m.lootButton then
    -- ok, the Loot button (two-button mode only)
  else
    return                                       -- not a live configured button for the current mode
  end
  local now = GetTime()
  local prev = mouseLastDown[token]
  local gap = prev and (now - prev) or nil
  local maxWin = m.doubleSec or 0.4
  if gap and gap > MOUSE_MIN and gap < maxWin then
    -- CONFIRMED 2nd click of a double: arm NOW (after MouselookStop) so THIS click fires the secure button;
    -- the binding clears in the button's PostClick. Record the REAL gap, reset so the 3rd click starts fresh.
    local g = SBF._mouseGaps; g[#g + 1] = gap; while #g > 8 do table.remove(g, 1) end
    mdbg(string.format("double-click %dms on %s -> arm", math.floor(gap * 1000 + 0.5), token))
    if token == m.fishButton then
      -- the Action button. CRUCIAL: keyboard single-button LOOTING works via the dynamic override that
      -- rebinds the fishing KEY to INTERACTTARGET while the line is out (DesiredOverride) — it does NOT run
      -- through the fishing button's click. A mouse click of buttons.fishing would therefore only cast, never
      -- loot. So we mirror the key: ask DesiredOverride() what the key would become right now — if it's a game
      -- action (INTERACTTARGET while looting, JUMP while surfacing), arm the mouse button to THAT; otherwise
      -- arm it to click the fishing button (cast). This makes the mouse Action button cast AND loot, exactly
      -- like the keyboard single button.
      local dyn = DesiredOverride()
      if dyn then
        mouseArm(token, dyn, true)        -- game binding (loot/jump) — same as the key's dynamic override
      else
        local fb = buttons.fishing
        if fb then mouseHookPostClick(fb); mouseArm(token, fb:GetName(), false) end
      end
    else   -- the loot button (two-button mode)
      local target, isGame = interactTarget()
      if target then
        if not isGame and buttons.interact then mouseHookPostClick(buttons.interact) end
        mouseArm(token, target, isGame)
      end
    end
    mouseLastDown[token] = nil   -- consume: the 3rd click is a fresh sequence, not a new "double" off this one
  else
    -- 1st click (or too-slow gap): just record the time. Do NOT arm — the click passes through normally.
    mouseLastDown[token] = now
  end
end

-- DETECTION SOURCE: WorldFrame:OnMouseDown (GoFish's approach), hooked ONCE. Falls back to GLOBAL_MOUSE_DOWN
-- on the (unlikely) chance WorldFrame is unavailable. The handler self-gates on mouseEnabled(), so the hook
-- can stay installed; MouseApply just flips the enabled flag + clears state.
local mouseFrame = CreateFrame("Frame")          -- only used for the GLOBAL_MOUSE_DOWN fallback path
local mouseHookInstalled, mouseUsingFallback = false, false
local function mouseInstallDetection()
  if mouseHookInstalled then return end
  if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function(_, button) mouseOnDown(button) end)
    mouseHookInstalled = true
  else
    mouseUsingFallback = true
    mouseFrame:SetScript("OnEvent", function(_, _, button) mouseOnDown(button) end)
    mouseHookInstalled = true
  end
end

-- (Re)apply mouse double-click state: install the WorldFrame detection hook once, and ALWAYS clear any armed
-- binding. Called from SBF.Apply and the enable toggle. The hook self-gates on mouseEnabled(); the fallback
-- event is registered/unregistered to match. The clear is a no-op when nothing is armed.
function SBF.MouseApply()
  mouseClear()
  mouseLastDown = {}
  mouseInstallDetection()
  if mouseUsingFallback then
    if mouseEnabled() then mouseFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
    else mouseFrame:UnregisterEvent("GLOBAL_MOUSE_DOWN") end
  end
end

-- /sbf mouse — diagnostics for tuning the double-click window.
function SBF.DebugMouse()
  local m = (SBFDB and SBFDB.mouse) or {}
  print("|cff45c4a0SBF mouse|r double-click fishing:")
  print(string.format("  enabled=%s  debug=%s  detect=%s  two-button=%s  in-combat=%s  mouselook=%s  armed=|cffffd100%s|r",
    m.enabled and "|cff33ff33ON|r" or "|cff808080OFF|r",
    m.debug and "|cff33ff33ON|r" or "|cff808080OFF|r",
    mouseUsingFallback and "GLOBAL_MOUSE_DOWN(fallback)" or "WorldFrame:OnMouseDown",
    tostring(SBFDB and SBFDB.requireTwoButtons and true or false),
    tostring(InCombatLockdown()), tostring(IsMouselooking and IsMouselooking() or false),
    tostring(mouseArmedToken or "none")))
  print(string.format("  fishButton=|cffffd100%s|r  lootButton=|cffffd100%s|r  doubleSec=|cffffd100%.2f|r  (min %dms, arm-on-2nd + MouselookStop; fallback %dms)",
    tostring(m.fishButton), tostring(m.lootButton), m.doubleSec or 0.4,
    math.floor(MOUSE_MIN * 1000 + 0.5), math.floor(MOUSE_FALLBACK * 1000 + 0.5)))
  local target, isGame = interactTarget()
  print(string.format("  interact -> %s (%s)", tostring(target), isGame and "game binding" or "secure click"))
  local g = SBF._mouseGaps or {}
  if #g == 0 then
    print("  recent double-click gaps: |cff808080(none yet — double-click your action button to test)|r")
  else
    local parts = {}
    for _, v in ipairs(g) do parts[#parts + 1] = string.format("%dms", math.floor(v * 1000 + 0.5)) end
    print("  recent double-click gaps: |cffffd100" .. table.concat(parts, "  ") .. "|r")
  end
end



-- Play the configured cast sound — a built-in SoundKit id ("kit") or a file bundled
-- in the addon's sounds/ folder ("file"). Always on the Master channel so it's heard
-- even with game SFX muted. Returns whether it actually played (for /sbf testsound).
function SBF.PlayCastSound()
  if SBFDB.castSoundMode == "file" and SBFDB.castSoundFile and SBFDB.castSoundFile ~= "" then
    local ok = PlaySoundFile(SBFDB.castSoundFile, "Master")
    if ok == false then
      print("|cff45c4a0SBF|r couldn't play sound file: |cffff5555" .. SBFDB.castSoundFile
        .. "|r (must be .ogg/.mp3 in the addon, needs a full restart after adding)")
    end
    return ok
  end
  return PlaySound(SBFDB.castSoundId or 8960, "Master")
end

-- the cast-fail alert sound (its own picker in Settings). Mirrors PlayCastSound.
function SBF.PlayCastFailSound()
  if SBFDB.castFailSoundMode == "file" and SBFDB.castFailSoundFile and SBFDB.castFailSoundFile ~= "" then
    return PlaySoundFile(SBFDB.castFailSoundFile, "Master")
  end
  return PlaySound(SBFDB.castFailSoundId or (SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED) or 847, "Master")
end

-- the no-fish-hooked warning sound (its own picker in Settings). Mirrors PlayCastSound.
function SBF.PlayNoFishSound()
  if SBFDB.noFishSoundMode == "file" and SBFDB.noFishSoundFile and SBFDB.noFishSoundFile ~= "" then
    return PlaySoundFile(SBFDB.noFishSoundFile, "Master")
  end
  return PlaySound(SBFDB.noFishSoundId or 8959, "Master")
end

-- the cast-expired warning sound (channel ran its full length with no bite). Mirrors PlayCastSound.
function SBF.PlayExpiredSound()
  if SBFDB.expiredSoundMode == "file" and SBFDB.expiredSoundFile and SBFDB.expiredSoundFile ~= "" then
    return PlaySoundFile(SBFDB.expiredSoundFile, "Master")
  end
  return PlaySound(SBFDB.expiredSoundId or 8959, "Master")
end

-- the "Patiently Rewarded" buff-appear sound (its own picker in Settings). Mirrors PlayCastSound.
function SBF.PlayPRSound()
  if SBFDB.prSoundMode == "file" and SBFDB.prSoundFile and SBFDB.prSoundFile ~= "" then
    return PlaySoundFile(SBFDB.prSoundFile, "Master")
  end
  return PlaySound(SBFDB.prSoundId or 888, "Master")
end

-- Register (or retune) the "Patiently Rewarded" watcher: it fires PlayPRSound once on the rising
-- edge of the configured buff (only when the toggle is on). The handle is kept so the options
-- name field can retune it live. Pure consumer of the Buffs.lua WatchBuff API — no special-casing.
function SBF.SetupPRWatch()
  local name = (SBFDB.prBuffName and SBFDB.prBuffName ~= "" and SBFDB.prBuffName) or "Patiently Rewarded"
  if SBF._prWatch then
    SBF.SetWatchName(SBF._prWatch, name)
  else
    SBF._prWatch = SBF.WatchBuff({
      name = name,
      onAppear = function(d)
        if SBFDB.prSound then
          SBF.PlayPRSound()
          logFishEvent("buff", { name = (d and d.name) or "Patiently Rewarded" })   -- also drop it in the log
        end
      end,
    })
  end
end

-- Feedback when an auto-swap loads a new profile: flash the profile's name as a raid warning
-- (gated on SBFDB.swapFlash). The on-screen indicator (Buttons page) is refreshed separately by
-- SBF.RefreshOptions; this is the transient "you swapped" cue. Safe no-op for a missing id.
function SBF.AnnounceProfile(id)
  local DB = SBF.Store()
  local p = id and DB.profiles[id]; if not p then return end
  if SBFDB.swapFlash and RaidNotice_AddMessage then
    -- gold (not the default red), and "::" instead of the U+2192 arrow (which renders as a black box)
    RaidNotice_AddMessage(RaidWarningFrame, "SBF :: " .. (p.name or "?"), { r = 1, g = 0.82, b = 0 })
  end
end

----------------------------------------------------------------- minimap button --
-- Self-contained minimap button (no library). Draggable around the ring; angle saved
-- in SBFDB.minimap.pos. Click toggles the SBF options window.
function SBF.CreateMinimapButton()
  if not Minimap or _G.SBFMinimapButton then return end
  SBFDB.minimap = SBFDB.minimap or { pos = 220 }
  local db = SBFDB.minimap
  local btn = CreateFrame("Button", "SBFMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel(8); btn:SetSize(28, 28)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp"); btn:RegisterForDrag("LeftButton")

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background"); bg:SetSize(18, 18)
  bg:SetPoint("TOPLEFT", 6, -5)
  local fs = btn:CreateFontString(nil, "ARTWORK")
  fs:SetFont(STANDARD_TEXT_FONT, 8, "OUTLINE"); fs:SetTextColor(0.27, 0.77, 0.63)
  fs:SetPoint("CENTER", bg, "CENTER", 0, 0); fs:SetText("SBF")  -- centered on the icon
  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(48, 48)
  border:SetPoint("TOPLEFT")

  local atan2 = math.atan2 or math.atan   -- 5.1 has atan2; newer Lua: atan(y, x)
  local function place()   -- snap to the ring at the saved angle
    local a = math.rad(db.pos or 220)
    local r = (Minimap:GetWidth() / 2) + 6   -- sit just outside the ring, any minimap size
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
  end
  btn:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", function(frame)   -- follow the cursor exactly while dragging
      local scale = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      local mx, my = Minimap:GetCenter()
      cx, cy = cx / scale - mx, cy / scale - my
      frame:ClearAllPoints()
      frame:SetPoint("CENTER", Minimap, "CENTER", cx, cy)
      db.pos = math.deg(atan2(cy, cx))
    end)
  end)
  btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil); self:UnlockHighlight(); place()   -- snap onto the ring
  end)
  btn:SetScript("OnClick", function() if SBF.ToggleOptions then SBF.ToggleOptions() end end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Single-Button Fishing")
    GameTooltip:AddLine("Click to open · drag to move", 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", GameTooltip_Hide)
  place()
end

---------------------------------------------------------------------- events --
-- Arm the post-damage heal: the next press heals (until health stops rising, or the
-- backstop window elapses). Used both after combat AND after out-of-combat damage
-- (damaging water/fatigue/fall) — the latter never fires PLAYER_REGEN_ENABLED.
local function armHeal(reason)
  if not hasAction(SBF.SlotDef("heal")) then return end
  SBF._healing = true
  SBF._healUntil = GetTime() + (SBFDB.healSeconds or 12)
  SBF._lastHealthChange = GetTime()   -- fresh start so it doesn't read "stable" instantly
  if SBFDB.debug then print("|cff45c4a0SBF|r heal armed (" .. (reason or "?") .. ")") end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")   -- crossed into a new zone
f:RegisterEvent("ZONE_CHANGED")            -- crossed a sub-zone boundary
f:RegisterEvent("ZONE_CHANGED_INDOORS")    -- stepped indoors (sub-zone change)
f:RegisterEvent("SKILL_LINES_CHANGED")     -- fishing skill data lands a moment after login -> re-read the readout
f:RegisterEvent("TRADE_SKILL_LIST_UPDATE") -- a fishing line's per-expansion data became available
f:RegisterEvent("UPDATE_BINDINGS")          -- binding set (re)loaded/changed -> re-install the override-click trigger
f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")   -- fishing line goes out
f:RegisterUnitEvent("UNIT_HEALTH", "player")                    -- health CHANGED (can't read it, but can see it move)
f:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "UNIT_HEALTH" then
    SBF._lastHealthChange = GetTime()   -- stamp it so "heal until it stops rising" works
    -- Arm the heal on an out-of-combat health change ONLY when we can READ that we're actually hurt
    -- (hp < max). UNIT_HEALTH fires on health going UP too (regen / food buffs), and when the value is
    -- hidden (a SECRET value in Midnight content) we can't tell a drop from regen — arming there caused
    -- phantom heals while eating/recovering near full (you'd see it cast Heal uninjured). When the value
    -- is hidden we simply don't arm from a health change; post-combat healing still arms via REGEN_ENABLED.
    if not SBF._healing and not InCombatLockdown() and hasAction(SBF.SlotDef("heal")) then
      local hp, mx = UnitHealth("player"), UnitHealthMax("player")
      local readable = hp and mx and mx > 0 and not (issecretvalue and (issecretvalue(hp) or issecretvalue(mx)))
      if readable and hp < mx then armHeal("damage") end
    end
    return
  end
  if event == "UNIT_SPELLCAST_CHANNEL_START" then
    if SBFDB and SBFDB.castSound then SBF.PlayCastSound() end
    return
  end
  if event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
    if SBF.OnZoneMaybeChanged then SBF.OnZoneMaybeChanged() end
    return
  end
  if event == "UPDATE_BINDINGS" then
    -- The fishing cast fires via an OVERRIDE-click that SBF.Apply installs over the fishing key (the bare
    -- native "CLICK SBFBtn_fishing" binding silently DROPS the protected cast). That override is keyed off
    -- GetBindingKey(...), so if the binding set wasn't readable when Apply last ran (e.g. a freshly-built
    -- install at login), the override never got installed and the press fell through to the bare native
    -- binding = no cast. Re-applying whenever the binding set (re)loads or changes self-heals that gap.
    if SBF.Apply then SBF.Apply() end
    return
  end
  if event == "SKILL_LINES_CHANGED" or event == "TRADE_SKILL_LIST_UPDATE" then
    -- the zone's fishing-line data just became readable (or changed) — re-render the skill readout. The SBF
    -- window header re-reads via RefreshOptions; Haul's {sbf.fishing} bar re-reads on its own update tick.
    -- Call FishingSkill() directly too: it caches the live value whenever data is available, so the moment
    -- you fish (gain a point) or open the journal, the per-character cache seeds even with the window closed —
    -- and the NEXT fresh login shows it immediately instead of blank.
    if SBF.FishingSkill then SBF.FishingSkill() end
    if SBF.RefreshOptions then SBF.RefreshOptions() end
    return
  end
  if event == "ADDON_LOADED" and arg1 == ADDON then
    SBFDB = SBFDB or {}
    -- GECStore adoption (clean start): the old loose fishlog is abandoned; its data moves to the
    -- GECStore stream (SBFData.streams.fishlog). Drop the dead key once.
    SBFDB.fishlog = nil
    -- increment 2: wipe the old streams.fishlog (+ increment-1 session scaffolding) so schema 2 starts clean.
    -- MUST run before the first fishStore()/session init below (RegisterStore overwrites SBFData.version to 2).
    migrateFishlogWipe()
    ApplyDefaults(SBFDB, DB_DEFAULTS)
    SBFDB.themePreset = SBFDB.themePreset or "everforest"  -- GECTheme per-addon palette (default = everforest)
    -- one-time profile migration: fold the existing SBFDB.slots tree into a single "Default" profile
    -- and lift per-slot keybinds into SBFDB.binds. Runs BEFORE the seeding loop so the seeding writes
    -- into the active profile's slots (via SBF.ActiveSlots()), not a phantom SBFDB.slots the engine
    -- never reads. On later logins this no-ops (profiles already exist) and the seeding still targets
    -- the live profile, so new descriptor slots get seeded there.
    if SBF.MigrateProfiles then SBF.MigrateProfiles() end
    -- one-time per character: adopt the active profile's combat/heal into this char's charSlots so users
    -- who configured them before the per-character move don't lose their setup (no-op once _migrated).
    if SBF.MigrateCharSlots then SBF.MigrateCharSlots() end
    -- normalize legacy { tier, value } location bindings to the variable-depth { value, kind } shape
    -- (idempotent; runs every load since MigrateProfiles no-ops once profiles exist).
    if SBF.NormalizeBindings then SBF.NormalizeBindings() end
    -- one-time slot migration to the descriptor model (no back-compat — single dev/user build):
    --   * the old def.pick (ordered/random) is gone -> def.mode, defaulting to the slot's
    --     defaultMode (bobbers become cycle, chum deplete) when unset.
    --   * wipe the stale runtime fields (def.pick, def._lastPick) so nothing references them.
    -- The per-descriptor seeding now lives in SBF.SeedSlots (Profiles.lua), so the working copy can
    -- run the SAME seeding when a profile is activated.
    SBF.SeedSlots(SBF.ActiveSlots())
    -- load the working copy: edits go here, the engine fishes with it, Save commits it back to the
    -- stored profile. The working copy PERSISTS at SBF.Store().working (SavedVariable), so unsaved edits + the
    -- dirty flag survive /reload and logout. Adopt the persisted copy when it's still valid (its profile
    -- exists); otherwise rebuild fresh. SeedSlots runs either way so a newly-added descriptor slot is
    -- present in the restored copy too.
    -- Adopt the persisted working copy from THIS character's active store (SBF.Store(): SBFDB in Warband,
    -- the per-char store in Individual) so an Individual character restores ITS working copy, not the account's.
    local pdb = SBF.Store()
    if pdb.working and pdb.working.id and pdb.profiles[pdb.working.id]
      and type(pdb.working.slots) == "table" then
      SBF.working = pdb.working
      pdb.activeProfile = pdb.working.id
      if SBF.SeedSlots then SBF.SeedSlots(SBF.working.slots) end
    elseif SBF.LoadWorking then
      pdb.working = nil                   -- stale/invalid (deleted profile / corrupt save): drop it, rebuild
      SBF.LoadWorking()
    end
    SBFDB.customs, SBFDB.cseq, SBFDB.announce = nil, nil, nil   -- removed features; drop their stale saved data
    -- fold the legacy per-item stores (itemBuffs + learned) into the one SBFData.db.items record. Items.lua
    -- loads first, so the accessors exist here. Reads the old tables then nils them in one pass (Task 8).
    if SBF.MigrateItemKnowledge then SBF.MigrateItemKnowledge() end
    -- recover ORPHANED events (a sid with events but no start marker — lifecycle lost, e.g. a wiped markers
    -- stream) by encapsulating them at their own timestamps, BEFORE the fresh-login session opens below.
    do local S = fishSessionCtrl(); if S and S.RepairOrphans then
      local n = S:RepairOrphans()
      if n and n > 0 then print("|cff45c4a0SBF|r |cffffaa44recovered " .. n .. " orphaned session(s)|r from the log.") end
    end end
  elseif event == "PLAYER_LOGIN" then
    -- Opt into the GECStore professions field (it's tier="optional" / opt-in) so the per-character cache
    -- actually COLLECTS fishing skill — SBF.FishingSkill reads .lines[lineID] from it. Without this the field
    -- is never snapshotted (empty .lines) while ProfessionsWarmed() can still be true, so the header wrongly
    -- shows "No fishing skill here". Persists once set + snapshots immediately; safe to call every login.
    do
      local S = gecStore()
      if S and S.SetFieldEnabled then S.SetFieldEnabled("professions", true) end
    end
    -- Re-resolve the working copy now that the char key is reliable. UnitName("player") is nil at
    -- ADDON_LOADED, so SBF.Store() there resolves to Warband even for an Individual character — re-adopt
    -- from the CORRECT store here (idempotent for Warband: same store, same copy).
    do
      local pdb = SBF.Store()
      if pdb.working and pdb.working.id and pdb.profiles[pdb.working.id] and type(pdb.working.slots) == "table" then
        SBF.working = pdb.working
        pdb.activeProfile = pdb.working.id
        -- Gear is PER-CHARACTER, but the persisted working copy is account-wide (SBFDB.working), so it carries
        -- the equipSet/pole of whichever character last edited it. Re-seed gear from THIS character's ProfileGear
        -- so an alt never SHOWS or SAVES another character's pole/set. (Char key is reliable here at PLAYER_LOGIN;
        -- the LoadWorking branch below already routes gear through ProfileGear, so only the adopt path needs this.)
        if SBF.ProfileGear then
          local pg = SBF.ProfileGear(pdb.working.id)
          SBF.working.equipSet, SBF.working.pole = pg.equipSet, pg.pole
        end
      elseif SBF.LoadWorking then
        SBF.working = nil
        SBF.LoadWorking(pdb.activeProfile or pdb.defaultProfile)
      end
      if SBF.SeedSlots then SBF.SeedSlots(SBF.ActiveSlots()) end
    end
    SBF.MigrateBindsToNative()   -- lift old internal fishing/interact-controller binds into the native bindings
    SBF.Apply()
    if SBF.InitOptions then SBF.InitOptions() end
    if SBF.CreateMinimapButton then SBF.CreateMinimapButton() end
    if SBF.SetupPRWatch then SBF.SetupPRWatch() end     -- arm the Patiently-Rewarded buff alert
    SBF.ApplyFastLoot()                                 -- register/unregister SBF with the shared fast-loot lib + mirror debug
    if SBF.Stats then SBF.Stats.EnsureBackfill(); SBF.Stats.EnsureCharBackfill(); SBF.Stats.EnsureInterruptBackfill(); SBF.Stats.EnsureZoneTimeBackfill() end    -- one-time seed of the all-time + per-character rollups (+ interrupt-cause breakdown + per-zone lastT) from the log buffer
    if SBFDB and SBFDB.showFooting and SBF.SetFooting then SBF.SetFooting(true) end  -- restore debug panel
    -- one-time gear migration (done HERE, not ADDON_LOADED, so UnitName/realm are reliable for the char key):
    -- fold the OLD account-wide gear snapshot/flag into THIS character's per-char store, then drop the old
    -- keys. Only the current char inherits them (they were that char's gear anyway).
    if (SBFDB.gearSnapshot or SBFDB.profileGearOn) and SBF.CharGear then
      local cg = SBF.CharGear()
      if cg.snapshot == nil and SBFDB.gearSnapshot then cg.snapshot = SBFDB.gearSnapshot end
      if cg.on == nil and SBFDB.profileGearOn ~= nil then cg.on = SBFDB.profileGearOn end
      SBFDB.gearSnapshot, SBFDB.profileGearOn = nil, nil
    end
    -- (Fishing-state handling on load moved to PLAYER_ENTERING_WORLD, which gets isInitialLogin / isReloadingUi
    -- args: a /reload must CARRY OVER the fishing state, a fresh login must REVERT it. PLAYER_LOGIN can't tell
    -- the two apart, so it no longer touches gear/audio here.)
    print("|cff45c4a0SBF|r loaded |cff808080(build " .. tostring(SBF.BUILD) .. ")|r — /sbf to configure.")
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Mark the "This session" boundary for the Stats tab. arg1 = isInitialLogin: stamp a FRESH start ONLY
    -- on a true login, and PERSIST it (SBFDB) so a /reload — which fires PEW with arg2 = isReloadingUi and
    -- wipes Lua state — KEEPS the same session boundary instead of resetting it. A later zone-load PEW (neither
    -- flag) just re-reads the stored value. So "this session" = since you actually logged in, surviving reloads.
    if SBF.Stats then
      if arg1 then SBFDB.sessionStartT = time() end      -- real login -> new session
      SBFDB.sessionStartT = SBFDB.sessionStartT or time()  -- first-ever run / no initial-login flag: seed once
      SBF.Stats.sessionStartT = SBFDB.sessionStartT
    end
    -- CANONICAL GECStore session (the one that syncs to the server): a fresh login (arg1) closes the prior
    -- open run at its LAST ACTIVITY (reason "logout" — not "now", so an overnight logout doesn't inflate the
    -- duration) then begins a new one; a /reload (arg2, not arg1) RESUMES — the controller's _open persists
    -- on SBFData so the run continues under the same sid with no new start. Sids are STRINGS (never coerced).
    do
      local S = fishSessionCtrl()
      if S then
        if arg1 then
          S:RepairIfDangling({}, "logout")   -- fresh login: close the prior run at last activity (no-op if...
          S:Begin("user")                    -- ...already stopped), then begin a new one
        elseif not S:IsOpen() then
          S:Begin("user")                    -- reload/zone-in with NO open run (first-ever or post-wipe): open one
        end
        -- else (a /reload with an open run already persisted on SBFData._open): RESUME — do nothing, same sid
      end
    end
    -- Auto-populate the active profile's pole from the equipped one on a real login or a /reload (not on
    -- later zone-load PEWs). Delayed so inventory and item-info data are readable — both are unreliable for
    -- the first moment after login/reload.
    if (arg1 or arg2) and C_Timer and C_Timer.After then
      C_Timer.After(2, function() if SBF.AutoPopulatePole then SBF.AutoPopulatePole() end end)
    end
    -- arg1 = isInitialLogin, arg2 = isReloadingUi. Reopen across a /reload if the
    -- window was up; a fresh login leaves it closed (until /sbf).
    if arg2 and SBFDB and SBFDB.shown then
      if SBF.ShowOptions then SBF.ShowOptions() end
    elseif arg1 and SBFDB then
      SBFDB.shown = false
    end
    -- Load-time fishing-state handling (ONLY on the initial entering — arg1/arg2 — not later zone changes).
    -- The fishing state (CharGear().on / .audioOn) is SavedVariable-backed and the gear/audio actually persist
    -- across a /reload on their own; the addon is the only thing that would undo them. So:
    --   * /reload (isReloadingUi): CARRY OVER — re-assert the state (re-equip/re-apply only what's off) so you
    --     come back fishing with no extra keypress. Stamp lastFishingAt so the idle clock has a baseline (else
    --     max(lastActionAt, lastFishingAt)==0 and the idle observer's `lastActive == 0` guard would never
    --     auto-revert if you then walked away without casting).
    --   * fresh login (isInitialLogin): REVERT — don't come back (hours later) stuck in fishing gear with no
    --     weapon / music muted. (RevertToNormal self-guards + defers gear for combat.)
    if (arg1 or arg2) and SBF.CharGear and (SBF.CharGear().on or SBF.CharGear().audioOn) then
      if arg2 then
        if SBF.ActivateFishing then SBF.ActivateFishing() end
        SBF.lastFishingAt = GetTime()   -- start the idle clock so genuine inactivity still reverts later
      elseif arg1 then
        if SBF.RevertToNormal then SBF.RevertToNormal() end
      end
    end
    -- re-link an in-flight fishing cast across a /reload (SBF._logCast was wiped, but the channel keeps
    -- running and GetTime() is continuous across /reload). If we're STILL channeling Fishing, restore the
    -- tracking so the stop classifies correctly instead of being dropped/mislabeled; otherwise drop it
    -- (the outcome is unknowable — we missed the stop/loot during the reload gap).
    if SBFDB and SBFDB._inflight then
      local inf = SBFDB._inflight
      local cname, _, _, _, _, _, _, cid = UnitChannelInfo("player")
      if (cname == "Fishing" or cid == 131474) and inf.t and (time() - inf.t) < 60 then
        SBF._logCast, SBF._logCastExp = inf.start, inf.exp
      else
        SBFDB._inflight = nil
      end
    end
    -- entering the world (login / loading screen / zone-in) is also a location change point
    if SBF.OnZoneMaybeChanged then SBF.OnZoneMaybeChanged() end
    -- deferred login re-resolve: the very first resolution can run before the map is ready (cascade empty),
    -- so the indicator/profile stick on Default. On initial login OR a /reload, retry once after the map
    -- settles. OnZoneMaybeChanged debounces on the cascade key, so it's a cheap no-op if already correct.
    if (arg1 or arg2) and SBF.OnZoneMaybeChanged then
      C_Timer.After(1.5, function() if SBF.OnZoneMaybeChanged then SBF.OnZoneMaybeChanged() end end)
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if SBF._pending then SBF.Apply() end
    if SBF.MouseClear then SBF.MouseClear() end   -- never carry a stale mouse override binding out of combat
    armHeal("combat")   -- left combat: heal to full
  end
end)

-- Catalog (ns.Catalog, set by Data.lua): curated item IDs per slot, from the bundled
-- sbfcatalog data. Returns a slot's candidates annotated with whether YOU own each —
-- toys via the toy box, items via bag count. This is what the config pickers will read.
local CAT_SLOTS = { "food", "drink", "bobber", "lure", "poleenchant",
                    "chum_skill", "chum_perception", "ward", "boat" }

-- C_ToyBox.PlayerHasToy lies (returns false) until the Collections module is loaded
-- into memory — which doesn't happen on a fresh /reload until you open Collections.
-- Force-load it once so toy ownership reads correctly without opening anything.
local _collectionsReady = false
local function ensureCollections()
  if _collectionsReady then return end
  _collectionsReady = true
  -- Load the Collections module so PlayerHasToy / C_ToyBox queries read correctly. DO NOT touch the
  -- toy-box FILTERS (ForceToyRefilter / SetFilters / etc.) from here — those TAINT the Toy Box, which
  -- then blocks the protected "use/learn toy" action when you click a toy item in your bags.
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if load then pcall(load, "Blizzard_Collections") end
end

local function itemOwned(id)
  -- a "spell:N" entry (boat/buffs) isn't an item — "owned" means the spell is KNOWN, not a toy/bag count.
  local sid = ns.spellEntry and ns.spellEntry(id)
  if sid then
    return (IsPlayerSpell and IsPlayerSpell(sid)) or (IsSpellKnown and IsSpellKnown(sid)) or false
  end
  id = tonumber(id) or id
  if type(id) ~= "number" then return false end   -- never hand a non-numeric to the item/toy APIs
  return (GetItemCount(id) or 0) > 0 or (type(PlayerHasToy) == "function" and PlayerHasToy(id)) or false
end

-- "_all" is the fireAll Buffs slot's catalog key: it has no shipped category, so its flyout shows
-- ALL learned items (every item you've ever dropped into ANY slot), not a per-slot subset.
local ALL_LEARNED = "_all"

function ns.OwnedCatalog(catSlot)
  ensureCollections()
  local cat = ns.Catalog
  local allLearned = (catSlot == ALL_LEARNED)
  local out, seen = {}, {}
  if (not allLearned) and cat and cat.slots and cat.slots[catSlot] then
    for _, id in ipairs(cat.slots[catSlot]) do
      local m = (cat.meta and cat.meta[id]) or {}
      out[#out + 1] = { id = id, name = m.name or tostring(id), source = m.source,
                        expansion = m.expansion, owned = itemOwned(id) }
      seen[id] = true
    end
  end
  -- the map ancestry you're in NOW (every mapID best->root), to flag whether a learned item is confirmed
  -- for this zone. Sourced from the getter layer, same set LearnItem records into an item's `maps`.
  local curZones = {}
  local R = reader()
  local chain = (R and R.Current and R.Current.mapChain and R.Current.mapChain()) or {}
  for _, lv in ipairs(chain) do if lv.mapID then curZones[lv.mapID] = true end end
  -- merge items LEARNED in-game (dropped into this slot) that aren't in the shipped catalog. For the
  -- "_all" key (the Buffs slot) EVERY learned item qualifies, ignoring which slot it was dropped into.
  local items = (SBF.OutputDB and SBF.OutputDB("items")) or {}
  for id, e in pairs(items) do
    if (allLearned or (e.slots and e.slots[catSlot])) and not seen[id] then
      local zoneOk = e.allZones or false                  -- "works everywhere" flag, OR used here before
      if not zoneOk then for m in pairs(e.maps or {}) do if curZones[m] then zoneOk = true; break end end end
      out[#out + 1] = { id = id, name = e.name or tostring(id), source = e.source, owned = itemOwned(id),
                        learned = true, zoneOk = zoneOk, allZones = e.allZones, maps = e.maps }
    end
  end
  return out
end

-- learn an item dropped into a slot: record it into the account-wide item-knowledge record (via
-- ObserveItem) with the current map cascade (the zones where it's usable). Grows the catalog from real use.
function ns.LearnItem(id, catSlot)
  id = tonumber(id) or id
  if not id then return end
  -- "_all" is the Buffs slot's catalog SENTINEL, not a real slot type — don't record it as one (it would
  -- pollute the per-slot map). The item + its zone cascade are still recorded so it counts as learned.
  if catSlot == "_all" then catSlot = nil end
  local R = reader()
  local info = R and R.Resolve and R.Resolve.item and R.Resolve.item(id)   -- id -> name via the getter layer
  local fields = { name = (info and info.name) or nil, slots = catSlot and { [catSlot] = true } or nil, maps = {} }
  local chain = (R and R.Current and R.Current.mapChain and R.Current.mapChain()) or {}
  for _, lv in ipairs(chain) do if lv.mapID then fields.maps[lv.mapID] = lv.name end end   -- full zone->root ancestry
  SBF.ObserveItem(id, fields)
end

-- ---- footing / posture debug -------------------------------------------------
-- Read-only diagnostic spike: surfaces the RAW movement signals and the FOOTING we
-- derive from them, live, so the resolver's footing state can be validated against
-- reality before anything is built on it. /sbf footing toggles a small live readout.
-- This fires NOTHING — it only reads and prints.
-- mirror timers (breath/fatigue) are looked up by NUMERIC INDEX; the name is the first
-- return. Iterate the few slots and match the name we want. Returns true if active.
local function mirrorActive(which)
  if not GetMirrorTimerInfo then return false end
  for i = 1, 3 do
    local ok, name = pcall(GetMirrorTimerInfo, i)
    if ok and name == which then return true end
  end
  return false
end

-- ns.ReadState(): the single read-only source of truth for the resolver, the grid, and the
-- debug panel. NO side effects (no RNG, no SetAttribute) — safe to call from the poll AND the
-- panel. (Was the spike's local `rawFooting`.)
function ns.ReadState()
  -- GetUnitSpeed is a SECRET number in combat (Midnight) — comparing it taints/errors,
  -- so guard with issecretvalue and report movement as unknown while in combat.
  local rawSpeed = GetUnitSpeed and GetUnitSpeed("player")
  local speedSecret = (issecretvalue and rawSpeed ~= nil and issecretvalue(rawSpeed)) or false
  local speed = (not speedSecret) and (rawSpeed or 0) or nil
  local control = true                                       -- false = feared/stunned/controlled
  if HasFullControl then control = (HasFullControl() and true) or false end
  local chanName, chanEnd
  if UnitChannelInfo then local n, _, _, _, e = UnitChannelInfo("player"); chanName, chanEnd = n, e end
  local chanLeft = chanEnd and ((chanEnd / 1000) - GetTime()) or nil
  local castName = (UnitCastingInfo and UnitCastingInfo("player")) or nil   -- non-channel cast name
  local gliding = false                                      -- skyriding/dragonriding glide
  if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
    local ok, g = pcall(C_PlayerInfo.GetGlidingInfo); gliding = (ok and g) or false
  end
  local facing = GetPlayerFacing and GetPlayerFacing()       -- heading in radians; nil when map open
  if facing and issecretvalue and issecretvalue(facing) then facing = nil end
  local px, py                                               -- normalized map position (0-1)
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if mapID and C_Map.GetPlayerMapPosition then
    local ok, p = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if ok and p then
      local x, y = p:GetXY()
      if not (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then px, py = x, y end
    end
  end
  local r = {
    mounted    = (IsMounted and IsMounted()) or false,
    swimming   = (IsSwimming and IsSwimming()) or false,
    submerged  = (IsSubmerged and IsSubmerged()) or false,   -- head underwater (may be nil API)
    breath     = mirrorActive("BREATH"),
    flying     = (IsFlying and IsFlying()) or false,
    gliding    = gliding,
    facing     = facing,
    px         = px,
    py         = py,
    falling    = (IsFalling and IsFalling()) or false,
    taxi       = (UnitOnTaxi and UnitOnTaxi("player")) or false,
    vehicle    = (UnitInVehicle and UnitInVehicle("player")) or false,
    speed      = speed,
    speedSecret = speedSecret,
    moving     = (speed ~= nil) and (speed > 0.1) or false,
    boatBuff   = BoatBuffUp(),
    flyable    = (IsFlyableArea and IsFlyableArea()) or false,
    indoors    = (IsIndoors and IsIndoors()) or false,
    outdoors   = (IsOutdoors and IsOutdoors()) or false,
    stealthed  = (IsStealthed and IsStealthed()) or false,
    fatigue    = mirrorActive("EXHAUSTION"),
    channeling = chanName ~= nil,
    chanName   = chanName,
    chanLeft   = chanLeft,
    casting    = castName,
    combat     = (UnitAffectingCombat and UnitAffectingCombat("player")) or false,
    lockdown   = (InCombatLockdown and InCombatLockdown()) or false,
    dead       = (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or false,
    control    = control,
    resting    = (IsResting and IsResting()) or false,
    lootOpen   = (LootFrame and LootFrame.IsShown and LootFrame:IsShown()) or false,
  }
  -- derive footing, most-specific first. (sitting is NOT API-readable in retail — we'd
  -- only know we sat because WE issued /sit; shown as grounded here.)
  local foot
  if r.taxi or r.vehicle then foot = "taxi/vehicle"
  elseif r.gliding then foot = "gliding"
  elseif r.mounted then foot = r.flying and "mounted(flying)" or "mounted"
  elseif r.swimming then foot = r.submerged and "swimming(submerged)" or "swimming"
  elseif r.falling then foot = "airborne"                    -- jumped / fell off: NOT fishable
  elseif r.boatBuff then foot = "on-boat"                    -- have boat & not swim/mount/fly: on the raft (moving or not)
  else foot = "grounded" end                                 -- on land. moving is a SEPARATE flag, not a footing
  r.footing = foot
  -- CAN-CAST: positioned to start a fishing cast — none of the movement/posture blockers
  -- (on-boat is fine; resting/combat/dead/control/channeling are SEPARATE resolver gates).
  -- speedSecret (combat) forces NO since we can't confirm "not moving" — and you can't fish
  -- in combat anyway.
  -- Zen Flight (a falling-boat) is a FLYING/falling state but you CAN fish from the hover — so when it's
  -- ACTIVE, flying/falling must NOT block the cast (moving/mounted/etc still do). Its buff can be permanent.
  local zenActive = fallingBoatActive(SBF.ActiveSlots().boat)
  r.canCast = not (r.mounted or (r.flying and not zenActive) or r.gliding or r.moving or r.swimming
    or r.submerged or r.breath or (r.falling and not zenActive) or r.taxi or r.vehicle or r.speedSecret)
  -- grid-driving signals for the fishing loop, MUTUALLY EXCLUSIVE:
  --   LOOT white = line is out (channeling) -> the ONLY allowed action is loot
  --   CAST white = able to start a fresh cast (can-cast, not already fishing, not combat)
  r.lootReady = r.channeling
  r.castReady = r.canCast and not r.channeling and not r.combat
  -- single-button: the action key is ALSO the attack key, so when a combat action is configured
  -- the loop should keep firing in combat (it attacks) rather than hold. Exposed for the grid.
  local combatDef = SBF.SlotDef("combat")
  r.combatReady = (not (combatDef and combatDef.skip)) and hasAction(combatDef) and true or false
  return r
end

-- Phase-1 resolver gate: pure reads of ns.ReadState() (no secure calls here). What the One
-- Button resolves to right now, by the fishing invariant:
--   "loot" = line is out (channeling) -> the ONLY action
--   "cast" = can-cast and not channeling
--   "wait" = neither (flying/moving/mounted/swimming/combat/...) -> do nothing
-- Loot ONE slot from the open loot window — the paced manual-loot step used when fast-loot (GECLoot) is off.
-- LootSlot is unprotected, so PostClick (after the inert secure click) can call it. Loots the lowest slot that
-- still holds an item/coin; when the last slot clears the window closes on its own. Bags-full is handled
-- upstream (UI_ERROR -> SBF._lootBlocked -> "wait"), so we never fight an un-lootable window here.
function SBF.LootOneSlot()
  if not (GetNumLootItems and LootSlot and GetLootSlotInfo) then return end
  local n = GetNumLootItems() or 0
  for slot = 1, n do
    local tex = GetLootSlotInfo(slot)   -- nil on an already-looted (empty) slot
    if tex then LootSlot(slot); return end
  end
end

function ns.FishingAction()
  local s = ns.ReadState()
  if s.channeling then
    if SBFDB.requireTwoButtons then return "wait", s end   -- two-button mode: action key inert while looting
    return "loot", s
  end
  -- Bags full with loot STILL in the window: don't cast. A recast would close the surfaced loot window and
  -- WoW would mail the un-looted items (Postmaster). Wait until the window is dealt with (LOOT_CLOSED clears it).
  if SBF._lootBlocked and (GetNumLootItems and GetNumLootItems() or 0) > 0 then return "wait", s end
  -- Fast-loot OFF with a loot window still holding items: DON'T cast — a recast closes the window and WoW
  -- mails/loses the un-looted items. Instead loot ONE slot per press (paced manual loot). When it empties the
  -- window closes (LOOT_CLOSED) and casting resumes. Bags-full is caught above (_lootBlocked -> full stop).
  if not SBFDB.fastLoot and (GetNumLootItems and GetNumLootItems() or 0) > 0 then return "lootone", s end
  if SBF._castBackoffUntil and GetTime() < SBF._castBackoffUntil then return "wait", s end  -- dead-spot back-off
  -- auto-dismount: on a GROUND mount only (NEVER flying/gliding/falling — that would drop you),
  -- if enabled, the press fires "/dismount"; the next press then casts. Self-correcting.
  if s.mounted and not (s.flying or s.gliding or s.falling) and SBFDB.autoDismount then
    return "dismount", s
  end
  -- swimming with a boat available: let the press THROUGH (the smart button casts the dinghy /
  -- the JUMP override surfaces you onto it). can-cast is false while swimming, so without this
  -- the gate would suppress the key and the boat would never cast.
  local boat = SBF.ActiveSlots().boat
  -- cast the dinghy only when you DON'T already have its buff. (Old check was
  -- not-IsOnBoat, but IsOnBoat = buff AND not-swimming, so while swimming it was always
  -- false and it re-cast forever even with the buff up.) With the buff, the JUMP
  -- override surfaces you onto it instead of re-casting.
  -- Falling-cast boat (Zen Flight) needed: FISHING IS IMPOSSIBLE here — you have no boat buff over deep water.
  -- This must come BEFORE the canCast/fishing return, because bouncing at the surface flickers falling<->grounded
  -- every frame, and at a grounded frame canCast briefly goes TRUE and would slip into fishing. So while a
  -- falling-boat is needed: airborne -> CAST it (arm THAT spell, not a rotation pick, so it's Zen Flight);
  -- not airborne yet -> WAIT (the JUMP override gets you up). Never "cast"/fish.
  -- Falling-boat (Zen Flight): keep PreClick's fa in sync with roleBoat. Over water + falling-boat due -> "wait"
  -- (inert press; the JUMP override lifts you). Airborne within the arm window (not yet hovering) -> "boat" so the
  -- press flows to buildPressMacro/roleBoat and casts it. On land nothing's due -> falls through to normal fishing.
  if ns.zenBoatDue and ns.zenBoatDue(boat) then return "wait", s end
  if SBF._zenArm and GetTime() < SBF._zenArm and s.falling
      and not (SBF.FallingBoatActive and SBF.FallingBoatActive(boat)) then
    return "boat", s
  end
  if s.swimming and boat and hasAction(boat) and not boat.skip and not BoatBuffUp() then
    return "boat", s
  end
  if s.canCast then return "cast", s end
  return "wait", s
end


-- (SBF's dev console + its capture helper were removed — the standalone GEC-Console addon replaces them.
--  The /sbf slash handler below stays; its diagnostics are now buttons in GEC-Console's Commands.lua.)

-- PUBLIC support switches for the jump/boat loop — /sbf jump [name [on|off|value]]. The core fix (keystate) is
-- on by default; the rest are belt-and-suspenders / edge-case workarounds a user can be told to flip if they hit
-- an issue, WITHOUT needing the dev Debug panel (which is stripped from the public build).
local JUMP_SWITCHES = {
  keystate   = { key = "jumpKeyState",        default = true,  desc = "core fix: read the physical key (IsKeyDown) and never rebind while held" },
  ascent     = { key = "ascentBreaker",       default = true,  desc = "Zen ascent breaker (a press breaks a fly-up)" },
  bounce     = { key = "bounceJump",          default = true,  desc = "bounce-breaker (JUMP while falling)" },
  bouncebuff = { key = "bounceBreakWithBuff", default = false, desc = "let the bounce-breaker fire with a boat/water-walk buff up" },
  surface    = { key = "surfaceClimbJump",    default = false, desc = "jump onto the raft at the surface" },
  hold       = { key = "jumpKeyupHold",       default = 0.25, num = true, desc = "key-up hold fallback, seconds (mouse/controller keys)" },
  poll       = { key = "pollInterval",        default = 0.15, num = true, desc = "override poll interval, seconds" },
}
local JUMP_ORDER = { "keystate", "ascent", "bounce", "bouncebuff", "surface", "hold", "poll" }
function SBF.JumpSwitch(rest)
  local name, val = (rest or ""):match("^(%S*)%s*(.-)%s*$")
  name = (name or ""):lower(); val = (val or ""):lower()
  local function cur(s) local v = SBFDB[s.key]; if v == nil then v = s.default end; return v end
  if name == "" then
    print("|cff45c4a0SBF|r jump switches — |cffffd100/sbf jump <name> [on|off|number]|r:")
    for _, n in ipairs(JUMP_ORDER) do
      local s = JUMP_SWITCHES[n]; local c = cur(s)
      local shown = s.num and (tostring(c) .. "s") or (c ~= false and "|cff33ff33on|r" or "|cff808080off|r")
      print(string.format("  |cffffd100%-10s|r %s  — %s", n, shown, s.desc))
    end
    print("  |cffffd100reset|r — restore all to defaults")
    return
  end
  if name == "reset" then
    for _, s in pairs(JUMP_SWITCHES) do SBFDB[s.key] = s.default end
    print("|cff45c4a0SBF|r jump switches reset to defaults."); return
  end
  local s = JUMP_SWITCHES[name]
  if not s then print("|cff45c4a0SBF|r unknown switch '" .. name .. "' — |cffffd100/sbf jump|r for the list."); return end
  if s.num then
    local n = tonumber(val)
    if n and n >= 0 then SBFDB[s.key] = n end
    print(string.format("|cff45c4a0SBF|r jump.%s = |cffffd100%ss|r", name, tostring(cur(s))))
  else
    local nv
    if val == "on" then nv = true elseif val == "off" then nv = false else nv = cur(s) == false end
    SBFDB[s.key] = nv
    print(string.format("|cff45c4a0SBF|r jump.%s = %s", name, nv and "|cff33ff33ON|r" or "|cff808080OFF|r"))
  end
end

SLASH_SBF1 = "/sbf"
SlashCmdList.SBF = function(msg)
  -- split into command + remainder WITHOUT lowercasing the remainder (buff names
  -- are case-sensitive and have spaces, e.g. /sbf setbuff lure Lucky Loa Lure)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "welcome" then
    if SBF.ShowWelcome then SBF.ShowWelcome() end
  elseif cmd == "jump" then                                   -- PUBLIC: workaround switches for the jump/boat loop
    if SBF.JumpSwitch then SBF.JumpSwitch(rest) end           -- (the full Debug panel is dev-only / stripped)
  elseif cmd == "addtarget" or cmd == "tgt" then              -- PUBLIC: opt-in /targetenemy in OUR default combat macro
    if rest == "on" then SBFDB.combatTarget = true            -- opt-in: add /targetenemy to the default macro
    elseif rest == "off" then SBFDB.combatTarget = nil        -- default: no target line (auto-target)
    else SBFDB.combatTarget = (not SBFDB.combatTarget) or nil end
    if SBF.Apply then SBF.Apply() end                         -- rebuild the button so the change takes effect now
    print("|cff45c4a0SBF default combat target-acquire|r (default macro only, never a custom one): "
      .. (SBFDB.combatTarget
        and "|cff33ff33ON|r — |cffffd100/targetenemy [noharm][dead]|r added to the default combat macro"
        or "|cff808080OFF|r — rely on auto-target when attacked (default; keeps focus on the attacker)"))
  -- (welcome moved to the leading `if` above; controller + mouse removed entirely — not useful)
  else
    if SBF.ToggleOptions then SBF.ToggleOptions() end
  end
end
