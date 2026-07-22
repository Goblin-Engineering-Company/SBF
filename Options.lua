-- SBF options — drag an item (or type a macro) into each slot, then set a key
-- combo. Built as an AddOns Settings canvas page.
local ADDON, ns = ...

-- Shared GECTheme handle (per-addon palette via SBFDB.themePreset). Every access through this proxy
-- first re-activates SBF's preset, so reading Theme.colors.X always returns SBF's palette — even from a
-- closure that runs later (mirrors the taint-safe-widgets / closure-capture rule).
local Theme = LibStub("GECTheme-1.0").ForAddon(
  function() return (SBFDB and SBFDB.themePreset) or "everforest" end,
  function(v) SBFDB.themePreset = v end)


-- The action-slot widgets, keybind cells, and config popup were extracted to OptionsWidgets.lua
-- (loads first). Re-bind the ones Build() still calls by their original local names so every call
-- site below is unchanged; catalogStrips/catalogStripRenders are the SAME tables shared with the
-- widgets file. `panel` (the window) is created here in Build() and published as ns.opt.panel.
local panel
local masterKeyBtn   -- luacheck: ignore  (forward-declared, intentionally never assigned; Keybinds "after" callbacks guard with `if masterKeyBtn`)
local accentRGB            = ns.opt.accentRGB
local markDirty            = ns.opt.markDirty
local styleSlot            = ns.opt.styleSlot
local helpTip              = ns.opt.helpTip
local helpLabel            = ns.opt.helpLabel
local MakeRow              = ns.opt.MakeRow
local MakeKeybindButton    = ns.opt.MakeKeybindButton
local MakeNativeBindButton = ns.opt.MakeNativeBindButton
local MakeMouseButton      = ns.opt.MakeMouseButton
local BindText             = ns.opt.BindText
local catalogStrips        = ns.opt.catalogStrips
local catalogStripRenders  = ns.opt.catalogStripRenders
local STRIP_X              = ns.opt.STRIP_X
local ROW_H                = ns.opt.ROW_H
local ICON                 = ns.opt.ICON

-- The tab strip is now the shared lib fixture: Theme.TabStrip(parent, x, y, defs, onSelect) -> setActive(key).
-- (SBF's hand-rolled MakeTabStrip was identical — the lib's Columns/TabStrip were ported up from these very
-- helpers — so the call site below just swaps in Theme.TabStrip; defs + setActive usage are unchanged.)

-- ===== profile-bar StaticPopups =====
-- Confirm removing a profile, and confirm switching away from a profile with unsaved edits. The
-- Build() closure registers its callbacks into these via SBF._profilePopup (set when the bar is built),
-- since StaticPopupDialogs entries are file-scoped but the bar's refresh logic lives inside Build().
SBF._profilePopup = SBF._profilePopup or {}
StaticPopupDialogs["SBF_REMOVE_PROFILE"] = {
  text = "|cff45c4a0SBF|r\n\nRemove the profile \"%s\"? This can't be undone.",
  button1 = "Remove", button2 = CANCEL,
  OnAccept = function() if SBF._profilePopup.onRemove then SBF._profilePopup.onRemove() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["SBF_SWITCH_DIRTY"] = {
  text = "|cff45c4a0SBF|r\n\nYou have unsaved changes. Switch profiles anyway?\n(your unsaved edits will be discarded)",
  button1 = "Switch", button2 = CANCEL,
  OnAccept = function() if SBF._profilePopup.onSwitch then SBF._profilePopup.onSwitch() end end,
  OnCancel = function() if SBF._profilePopup.onSwitchCancel then SBF._profilePopup.onSwitchCancel() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
-- Profile-scope flip confirms (the Individual checkbox on the Profile page). Switching scope swaps the WHOLE
-- visible profile set, so we confirm first. The first switch to Individual starts a BLANK Default profile —
-- it does NOT copy the account profiles (copy-over is the future export/import feature). SBF._scopePopup.apply
-- runs the actual SBF.SetScope + rebuilds the page; declining leaves the checkbox snapped back to the live scope.
StaticPopupDialogs["SBF_SCOPE_TO_INDIVIDUAL"] = {
  text = "|cff45c4a0SBF|r\n\nGive THIS character its own separate set of profiles?\n\nThe first time, it starts with a single empty Default profile (it does NOT copy your account-wide profiles). Switching back later restores the shared set. Combat & heal stay per-character either way.",
  button1 = "Make Individual", button2 = CANCEL,
  OnAccept = function() if SBF._scopePopup and SBF._scopePopup.apply then SBF._scopePopup.apply() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["SBF_SCOPE_TO_WARBAND"] = {
  text = "|cff45c4a0SBF|r\n\nSwitch this character back to the shared (Warband) profiles?\n\nIts individual profile set is kept and returns if you switch back to Individual.",
  button1 = "Use Warband", button2 = CANCEL,
  OnAccept = function() if SBF._scopePopup and SBF._scopePopup.apply then SBF._scopePopup.apply() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
-- Zone auto-swap caught unsaved edits as you LEAVE: offer to Save them, Discard them, or fork them into
-- a NEW profile bound to the zone you're leaving (so "this setup belongs here") — then swap to the
-- location-resolved profile (SBF._pendingSwap). Distinct from SBF_SWITCH_DIRTY (manual dropdown switch).
-- Zone-leave prompt: you changed the active profile's setup, and the new location resolves to a DIFFERENT
-- profile. Names the profile + lists what changed (arg1 = name, arg2 = the change list), then offers to
-- Save these edits / Discard them / Open the window to review (no swap).
StaticPopupDialogs["SBF_PROFILE_DIRTY_ONLEAVE"] = {
  text = "SBF — unsaved changes to profile \"%s\"\n%s\n\nSave them to this profile, discard them, or open SBF to review?",
  button1 = "Save", button2 = "Discard", button3 = "Open",
  OnAccept = function() SBF.SaveWorking(); SBF.DoSwap(SBF._pendingSwap) end,   -- Save (button1)
  OnCancel = function() SBF.DoSwap(SBF._pendingSwap) end,                      -- Discard (button2)
  OnAlt = function()                                                          -- Open (button3): review, no swap
    SBF._pendingSwap = nil                                                    -- they'll decide manually
    if SBF.OpenToTab then SBF.OpenToTab("buttons") end                        -- land on the Buttons page; working copy stays dirty
  end,
  -- Escape must NOT run OnCancel (that's Discard+swap = data loss). noCancelOnEscape closes the dialog
  -- without running OnCancel: the user stays on their current (still-dirty) profile, NOT swapped. The
  -- zone already advanced _lastCascadeKey, so auto-swap won't re-nag until the location changes again.
  timeout = 0, whileDead = true, hideOnEscape = true, noCancelOnEscape = true, preferredIndex = 3,
}
-- Context-aware variant of the above for when the edited profile IS the Default (catch-all fallback). Same
-- shape (3 buttons, no-swap-on-Escape), but the labels/actions are framed for Default: "Save to Default"
-- writes the edits into Default, "New profile" forks them into a fresh named profile (chaining the
-- SBF_NEW_PROFILE name-entry popup), and "Discard" drops them. OnZoneMaybeChanged picks which dialog to
-- show, so neither dialog ever mutates the other — no stale label/handler can leak between the two cases.
StaticPopupDialogs["SBF_PROFILE_DIRTY_DEFAULT"] = {
  text = "SBF — unsaved changes on the Default profile \"%s\"\n%s\n\nSave them to Default (the catch-all profile), start a New profile from them, or Discard before switching?",
  button1 = "Save to Default", button2 = "Discard", button3 = "New profile",
  OnAccept = function() SBF.SaveWorking(); SBF.DoSwap(SBF._pendingSwap) end,   -- Save to Default (button1)
  OnCancel = function() SBF.DoSwap(SBF._pendingSwap) end,                      -- Discard (button2)
  OnAlt = function()                                                          -- New profile (button3)
    -- Fork the current dirty edits into a NEW named profile, then swap. Chain the name-entry popup: on
    -- accept, SaveWorkingAsNew moves the edits off Default (reverting Default clean) into the new profile,
    -- THEN we run the pending swap. If they cancel the name popup, nothing changes and no swap happens.
    SBF._profilePopup.prefill = ""
    SBF._profilePopup.onName = function(text)
      SBF.SaveWorkingAsNew(text)
      SBF.DoSwap(SBF._pendingSwap)
    end
    StaticPopup_Show("SBF_NEW_PROFILE")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, noCancelOnEscape = true, preferredIndex = 3,
}
-- Name-entry prompts for Add / Duplicate. Both carry an edit box; Add starts blank, Duplicate prefills
-- "<name> copy" (set in OnShow from SBF._profilePopup.prefill). OnAccept reads the box and routes to
-- SBF._profilePopup.onName(text); the per-click closure (set when the button is clicked) creates +
-- activates the profile. Enter accepts (EditBoxOnEnterPressed clicks button1).
StaticPopupDialogs["SBF_NEW_PROFILE"] = {
  text = "|cff45c4a0SBF|r\n\nName your new profile:",
  button1 = OKAY, button2 = CANCEL,
  hasEditBox = true,
  OnShow = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if eb then eb:SetText(""); eb:SetFocus() end
  end,
  OnAccept = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if SBF._profilePopup.onName then SBF._profilePopup.onName(eb and eb:GetText() or "") end
  end,
  EditBoxOnEnterPressed = function(self)
    local parent = self:GetParent()
    if SBF._profilePopup.onName then SBF._profilePopup.onName(self:GetText() or "") end
    if parent then parent:Hide() else StaticPopup_Hide("SBF_NEW_PROFILE") end
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
StaticPopupDialogs["SBF_DUP_PROFILE"] = {
  text = "|cff45c4a0SBF|r\n\nName the duplicate profile:",
  button1 = OKAY, button2 = CANCEL,
  hasEditBox = true,
  OnShow = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if eb then eb:SetText(SBF._profilePopup.prefill or ""); eb:HighlightText(); eb:SetFocus() end
  end,
  OnAccept = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if SBF._profilePopup.onName then SBF._profilePopup.onName(eb and eb:GetText() or "") end
  end,
  EditBoxOnEnterPressed = function(self)
    local parent = self:GetParent()
    if SBF._profilePopup.onName then SBF._profilePopup.onName(self:GetText() or "") end
    if parent then parent:Hide() else StaticPopup_Hide("SBF_DUP_PROFILE") end
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
-- Binding the DEFAULT profile is contradictory (default is the everything/fallback profile). Instead of
-- refusing outright, this prompt explains why and offers to spin up a NEW profile (duplicated from default)
-- bound to the clicked location. Mirrors the other name-entry popups (prefilled edit box, Enter accepts).
StaticPopupDialogs["SBF_BIND_DEFAULT"] = {
  text = "|cff45c4a0SBF|r\n\nThe default profile is the fallback and can't be bound to a single location.\nName a new profile to bind to this spot:",
  button1 = OKAY, button2 = CANCEL,
  hasEditBox = true,
  OnShow = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if eb then eb:SetText(SBF._profilePopup.prefill or ""); eb:HighlightText(); eb:SetFocus() end
  end,
  OnAccept = function(self)
    local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
    if SBF._profilePopup.onName then SBF._profilePopup.onName(eb and eb:GetText() or "") end
  end,
  EditBoxOnEnterPressed = function(self)
    local parent = self:GetParent()
    if SBF._profilePopup.onName then SBF._profilePopup.onName(self:GetText() or "") end
    if parent then parent:Hide() else StaticPopup_Hide("SBF_BIND_DEFAULT") end
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Reset all-time stats — the ONLY path that clears the permanent rollup. Confirm-gated (it can't be
-- undone). It never touches the fishing log; SBF._statsResetPopup.onReset (set by the Stats page build)
-- calls Stats.Reset + re-renders. File-scoped entry like the others, callback bridged via the closure.
SBF._statsResetPopup = SBF._statsResetPopup or {}
StaticPopupDialogs["SBF_RESET_STATS"] = {
  text = "|cff45c4a0SBF|r\n\nReset your all-time fishing stats to zero?\n(your fishing log is NOT affected — this only clears the Stats totals)",
  button1 = "Reset", button2 = CANCEL,
  OnAccept = function() if SBF._statsResetPopup.onReset then SBF._statsResetPopup.onReset() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Build()
  -- Standalone movable window via the shared GECTheme fixture (matches Haul / Megaphone): navy panel +
  -- header band + accent title + themed X + drag-move + resize grip + collapse + pos/size/collapsed
  -- persistence. savedKey = SBFDB reuses SBF's EXISTING winPos/winSize/collapsed/bgAlpha keys (the lib's
  -- saved schema uses those exact field names), so user placement carries over with no migration.
  -- minWidth/minHeight = the conservative build floor (refined at runtime by _applyWindowMin's SetResizeBounds
  -- once the two pages are measured). onResize routes the lib's OnSizeChanged to SBF's scroll reflow.
  -- NOT a specialFrame on purpose: CloseSpecialWindows() (fired by opening the Blizzard Settings panel) would
  -- otherwise slam this shut — same reasoning as before. Trade-off: Esc doesn't close it; use the X or /sbf.
  local BUILD_MIN_W = (SBF.IsDev and SBF.IsDev()) and 768 or 624   -- covers the widest banner pre-measure
  local content
  panel, content = Theme.Window({
    name = "SBFOptions",
    title = "SBF  |cff66ccff::|r  |cff808080Single-Button Fishing|r",   -- build # shown only in the dev bottom bar (see Reload UI block)
    width = 564, height = 520, minWidth = BUILD_MIN_W, minHeight = 560,
    resizable = true, collapsible = true, specialFrame = false,
    deferCollapseInCombat = true,   -- this window hosts SECURE buttons (Skill Book journal) -> collapse toggles
                                    -- content visibility, which is combat-protected; defer to combat-end (GECTheme)
    savedKey = SBFDB,
    onResize = function() if panel._onWindowResize then panel._onWindowResize() end end,
  })
  -- Opacity: SBF's slider sets SBFDB.bgAlpha then calls panel.ApplyBg(); route that to the lib's ApplyAlpha
  -- (which re-paints the panel at the new alpha). Keep the ApplyBg name so the slider call site is unchanged.
  function panel.ApplyBg() panel:ApplyAlpha(SBFDB.bgAlpha or 0.94) end
  panel.ApplyBg()
  SBF._optionsPanel = panel   -- exposed so the Welcome panel can keep the two-button UI in sync when both are open
  ns.opt.panel = panel        -- the extracted widgets (markDirty / buildCfgPopup) reach the window through this
  panel:Hide()

  -- Right-aligned readout in the window header band (left of the close X): "Skill: 300/300 (+116)   Perc: 200"
  -- — the skill's +bonus in green (SBF.GetFishing), the perception total in gold (SBF.GetPerception). Location-
  -- aware; refreshes on skill/lure changes, zone changes, aura changes, gear/enchant swaps, and on show. Shows
  -- even while collapsed (the header stays), so you always see your skill + perception.
  local fishFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fishFS:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -34, -10); fishFS:SetJustifyH("RIGHT")
  Theme.Font(fishFS, "text")
  -- Active-profile readout, moved UP into the header (was on the Profile page). Sits just left of the skill/
  -- perc readout so it's visible on every tab and even while collapsed. refreshProfileBar sets its text and
  -- shows it only in advanced mode (where more than the Default profile exists).
  local headerProfileFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  -- Anchor TOP-to-TOP (not center RIGHT->LEFT): an EMPTY fishFS (no skill data yet, e.g. right after
  -- activation before TRADE_SKILL_LIST_UPDATE fires) collapses to zero height, and a center anchor would
  -- ride the profile readout up too high. Pinning both TOP edges keeps it level regardless of fishFS content.
  headerProfileFS:SetPoint("TOPRIGHT", fishFS, "TOPLEFT", -16, 0); headerProfileFS:SetJustifyH("RIGHT")
  Theme.Font(headerProfileFS, "text")
  -- Width the skill/perc readout reserves while it has no text yet, so the profile readout ("Active: X")
  -- anchored to its left edge keeps a stable home instead of flying to the far right until skill loads. Sized
  -- to a typical full readout ("Skill: 300/300 (+116)   Perc: 200"); auto-sizes to the real text once present.
  local FISH_READOUT_RESERVE = 200
  -- Is the professions cache warmed (live) this session? The library owns the detection; SBF just asks.
  local function profsWarm()
    local S = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)
    return S and S.ProfessionsWarmed and S.ProfessionsWarmed()
  end
  local function updateFishingReadout()
    local parts = {}
    local warm = profsWarm()
    local s = SBF.GetFishing and SBF.GetFishing() or ""
    if s ~= "" then
      -- have a skill value: WHITE "Skill:" when live/warm, GRAY when it's cached (from a prior session)
      parts[#parts + 1] = (warm and "Skill: " or "|cff888888Skill:|r ") .. s
    elseif warm then
      parts[#parts + 1] = "|cff888888No fishing skill here|r"   -- data loaded + this line absent = genuinely none
    else
      parts[#parts + 1] = "|cff888888Skill: not loaded|r"       -- cold + uncached: nudge to open a journal
    end
    local perc = SBF.GetPerception and SBF.GetPerception() or 0
    if perc and perc > 0 then parts[#parts + 1] = "Perc: |cffffd100" .. perc .. "|r" end
    local text = table.concat(parts, "   ")
    fishFS:SetText(text)
    fishFS:SetWidth(text == "" and FISH_READOUT_RESERVE or 0)   -- 0 = auto-size to the real readout
  end
  updateFishingReadout()
  local fishEv = CreateFrame("Frame")
  fishEv:RegisterEvent("SKILL_LINES_CHANGED")       -- skill or lure/chum modifier changed
  fishEv:RegisterEvent("TRADE_SKILL_LIST_UPDATE")   -- per-expansion fishing data became readable (opening the
                                                    -- fishing journal fires THIS, not SKILL_LINES_CHANGED — so
                                                    -- without it the header stayed stale until a /reload)
  fishEv:RegisterEvent("ZONE_CHANGED_NEW_AREA")     -- location -> active expansion fishing line
  fishEv:RegisterEvent("UNIT_AURA")                 -- a perception buff (Grand Line / chum / food) applied/dropped
  fishEv:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")  -- gear/enchant perception changed
  fishEv:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" and unit ~= "player" then return end
    if panel:IsShown() then updateFishingReadout() end
  end)
  -- also refresh on the library's skill-up feed (in addition to the raw events above); the cache warms/updates
  -- on the backend and this repaints the readout (e.g. gray->white when the professions data first warms).
  do
    local S = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("GECStore-1.0", true)
    if S and S.OnSkillIncrease then
      S.OnSkillIncrease(function() if panel:IsShown() then updateFishingReadout() end end)
    end
  end
  panel:HookScript("OnShow", updateFishingReadout)
  -- reset window size/position — recover if the resize grip ends up off-screen (Settings page button + /sbf
  -- window). Clears the saved keys, re-expands, recentres, then re-floors from the stored mins.
  local function ResetWindow()
    SBFDB.winSize, SBFDB.winPos, SBFDB.collapsed = nil, nil, false
    if panel.SetCollapsed then panel:SetCollapsed(false) end   -- ensure expanded (shows content, restores grip)
    panel:SetSize(564, 520)
    panel:ClearAllPoints(); panel:SetPoint("CENTER")
    if panel._applyWindowMin then panel._applyWindowMin() end
  end
  panel._resetWindow = ResetWindow
  -- collapse passthrough used by ShowOptions (collapse-on-show). The lib's own SetCollapsed handles the
  -- header-click toggle + height + persistence; this wrapper just exposes it under SBF's existing name.
  panel._setCollapsed = function(v) if panel.SetCollapsed then panel:SetCollapsed(v) end end

  -- ===== tabs =====
  local pages = {}
  local tabSetActive                              -- assigned by MakeTabStrip below
  local function ShowTab(key)
    if key ~= "buttons" then                      -- leaving Buttons: fold every open strip back down
      for _, collapse in ipairs(catalogStrips) do collapse() end
    end
    for k, p in pairs(pages) do p:SetShown(k == key) end
    if tabSetActive then tabSetActive(key) end     -- just recolours; tab keeps its position
    SBFDB.optTab = key
    if key == "log" and SBF.RefreshLog then SBF.RefreshLog() end
    if key == "stats" and SBF.RefreshStats then SBF.RefreshStats() end
    if key == "skillbook" and SBF.RefreshSkillBook then SBF.RefreshSkillBook() end
  end
  panel._showTab = ShowTab
  local tabDefs = {
    { key = "buttons",  label = "Profile" },
    { key = "behavior", label = "Settings" },
    { key = "keys",     label = "Keybinds" },
    { key = "skillbook", label = "Skill Book" },
    { key = "log",      label = "Log" },
    { key = "stats",    label = "Stats" },
    { key = "about",    label = "About" },
  }
  -- Theme.Window's `content` frame already STARTS below its 34px header band, so the tabs/pages anchor from
  -- the content top with NO header allowance (matching Haul's rhythm: tabs at -8, pages at -44). The old
  -- -42 / -76 double-counted the header band (the content used to be SetAllPoints(panel)), which is what
  -- left the big header→tabs gap after the Theme.Window swap.
  tabSetActive = Theme.TabStrip(content, 12, -8, tabDefs, ShowTab)   -- returns setActive(key); ShowTab drives highlighting
  local function makePage()
    local p = CreateFrame("Frame", nil, content)
    p:SetPoint("TOPLEFT", 12, -44); p:SetPoint("BOTTOMRIGHT", -12, 38)   -- -44 = tab y(8) + tab h(~30) + gap(~6)
    p:Hide(); return p
  end
  pages.buttons, pages.behavior, pages.log = makePage(), makePage(), makePage()
  pages.keys = makePage()
  pages.stats = makePage()
  pages.skillbook = makePage()
  pages.about = makePage()

  -- Body-area rule: any page whose content can exceed a short (resizable) window is wrapped in a
  -- scroll child with a modern arrow-less MinimalScrollBar that AUTO-HIDES when the content fits.
  -- Returns the scroll child to parent content to. (Buttons opts out — it has its own slot-list scroll.)
  local function attachPageScroll(page, childW, childH)
    local sf = CreateFrame("ScrollFrame", nil, page)
    sf:SetPoint("TOPLEFT", 0, 0); sf:SetPoint("BOTTOMRIGHT", -18, 0)
    local child = CreateFrame("Frame", nil, sf); child:SetSize(childW, childH); sf:SetScrollChild(child)
    -- the modern arrow-less scrollbar (auto-hides when content fits) is the lib's now; it wires the
    -- mousewheel + scroll hooks + refresh and sets sf.RefreshScrollBar. We keep SBF's own scroll-child
    -- width reflow (layout, not theme), and call the lib's refresh on resize.
    Theme.AttachScrollBar(sf, page)
    sf:SetScript("OnSizeChanged", function()
      child:SetWidth(math.max(childW, sf:GetWidth()))
      if sf.RefreshScrollBar then sf.RefreshScrollBar() end
    end)
    return child
  end

  -- ===== PAGE: Profile (slot rows + custom buttons) =====
  local pBtn = pages.buttons
  -- order on this page (top -> bottom): profile bar (profile/name/bind rows) -> a separator -> the GEAR
  -- block (equipment set + Equipment-mgr, then the fishing-pole drop box) ->
  -- scrollable slot list. The old master "Single Button Fishing" banner (Action key, Loot bind, Two-button
  -- toggle, mouse double-click row) was removed from this page: the Action key + Loot bind + mouse pickers
  -- live on the Keybinds tab, and the mouse/two-button/debug toggles moved to Settings -> Interface options.
  -- MBAR_H stays as a zero-height placeholder so the profile bar + gear-block offsets need no rewiring (the
  -- profile bar simply anchors to the page top now); BAR_H reserves the profile bar band.
  local MBAR_H = 0        -- (was the master banner band) now 0 — banner removed; profile bar sits at the page top
  local BAR_H  = 126      -- profile bar band (profile row + separator + name row + bind-here row + a couple bind-list rows)
  local GEAR_TOP = MBAR_H + BAR_H   -- y-base (negated below) for the gear block that sits beneath the profile bar
  local refreshProfileBar   -- forward decl: defined after rebuildRows; called by CRUD + on OnShow

  -- Save / Revert: edits go to a working copy (SBF.working); the engine fishes with it. Save commits
  -- it back to the stored profile; Revert discards (reloads the working copy from the profile). Save is
  -- disabled until there's an unsaved edit (SBF.IsDirty). Both refresh that enabled state. They live in
  -- the profile bar's row 2 (grouped with Name + Set-as-default); their anchors are set below once the
  -- Set-as-default button (defBtn) exists. Created here so the updateSaveState wiring is ready early.
  local revertBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
  revertBtn:SetSize(72, 22); revertBtn:SetText("Revert"); Theme.Button(revertBtn)
  local saveBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
  saveBtn:SetSize(72, 22); saveBtn:SetPoint("RIGHT", revertBtn, "LEFT", -6, 0); saveBtn:SetText("Save"); Theme.Button(saveBtn)
  local function updateSaveState()   -- BOTH Save and Revert are meaningful only while dirty
    local dirty = SBF.IsDirty and SBF.IsDirty() or false
    saveBtn:SetEnabled(dirty)
    revertBtn:SetEnabled(dirty)
  end
  saveBtn:SetScript("OnClick", function()
    if SBF.SaveWorking then SBF.SaveWorking() end
    updateSaveState()
  end)
  saveBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Save these slot edits to the profile")
    GameTooltip:AddLine("Until you Save, edits live only in the working copy.", 1, 1, 1, true); GameTooltip:Show()
  end)
  saveBtn:SetScript("OnLeave", GameTooltip_Hide)
  panel._updateSaveState = updateSaveState   -- so the dirty-marking sites can refresh it

  -- The fishing slots table (working copy). The fishing/interact slots are ensured to exist here because the
  -- slot list + Two-button mode rely on them. The master "One Button Fishing" key + Loot bind + mouse pickers
  -- that used to sit in a banner here now live on the Keybinds tab; the mouse/two-button/debug toggles live on
  -- Settings -> Interface options. masterKeyBtn (forward-declared at file scope) stays nil here — its Keybinds
  -- `after` callbacks all guard with `if masterKeyBtn then ...`, so a nil button is safe.
  local slots = SBF.ActiveSlots()
  slots.fishing = slots.fishing or {}
  slots.interact = slots.interact or {}
  -- forward decl: refreshLootUI() (defined after the slot list exists) rebuilds the slot list to match
  -- requireTwoButtons (adds/removes the separate interact row). Also published as panel._refreshLootUI so the
  -- relocated Two-button toggle on the Settings page can reach it.
  local refreshLootUI

  -- the slot list scrolls (12 slots + custom buttons is taller than the window). It sits below the gear
  -- block (separator + gear row + description + fishing-pole row), which occupies ~108px under the bar band.
  local GEAR_BLOCK_H = 90    -- gear block height: separator + gear row + pole row + the under-pole separator
  local bsf = CreateFrame("ScrollFrame", "SBFButtonsScroll", pBtn)   -- bare ScrollFrame: NO built-in (arrowed) bar
  bsf:SetPoint("TOPLEFT", 2, -GEAR_TOP - GEAR_BLOCK_H); bsf:SetPoint("BOTTOMRIGHT", -20, 2)
  local bchild = CreateFrame("Frame", nil, bsf); bchild:SetSize(512, 1); bsf:SetScrollChild(bchild)
  -- modern thin scrollbar (no arrows, auto-hides when the list fits) via the lib; it wires the
  -- mousewheel + scroll hooks + refresh and sets bsf.RefreshScrollBar. SBF keeps the slot-list layout.
  Theme.AttachScrollBar(bsf, pBtn)
  local function reLayoutScroll()                        -- scroll child fills the frame; icon strips re-wrap to the width
    local w = bsf:GetWidth()
    if not w or w < 1 then return end
    bchild:SetWidth(math.max(490, w - 18))
    for _, rerender in ipairs(catalogStripRenders) do rerender() end
    if bsf.RefreshScrollBar then bsf.RefreshScrollBar() end
  end
  -- Theme.Window owns the frame's OnSizeChanged (a frame has only one), and calls our onResize on every size
  -- change. Route the Buttons-page slot-scroll reflow + the Settings columns reflow through here so resizing
  -- still re-wraps the slot list and re-places the two-column layout exactly as the old OnSizeChanged did.
  function panel._onWindowResize()
    reLayoutScroll()
    if panel._colReflow then panel._colReflow() end
  end
  local slotRows = {}
  -- dynamic layout: rows are variable-height (catalog trays grow), so position everything by each
  -- row's _height and resize the scrollchild to fit.
  local function reflowSlots()
    local yy = 0
    for _, rr in ipairs(slotRows) do
      rr:ClearAllPoints(); rr:SetPoint("TOPLEFT", 0, yy)
      yy = yy - (rr._height or ROW_H)
    end
    bchild:SetHeight(math.max(-yy + 16, 1))
  end

  local displayOrder = {}                                  -- the list reads in `display` order, not table/priority order
  for _, s in ipairs(ns.SLOTS) do displayOrder[#displayOrder + 1] = s end
  table.sort(displayOrder, function(a, b) return (a.display or 99) < (b.display or 99) end)
  -- (re)build every slot row from the CURRENT working copy (SBF.ActiveSlots()). Called at first build
  -- and after Revert — Revert swaps in a fresh working-copy table, so the rows must rebind to the new
  -- def tables (the old rows held the discarded copy's defs). Hides old rows + clears the per-strip
  -- collapse/render registries so they don't reference the hidden frames.
  local function rebuildRows()
    for _, rr in ipairs(slotRows) do rr:Hide() end
    wipe(slotRows); wipe(catalogStrips); wipe(catalogStripRenders)
    local cur = SBF.ActiveSlots()
    for _, s in ipairs(displayOrder) do
      -- Interact/Loot is a built-in DEFAULT (interact-loot); its ACTION isn't user-editable — that override
      -- was a footgun, so it's removed from the slot list. Only its KEYBIND remains (Keybinds tab). Looting
      -- still works via the Action key's dynamic INTERACTTARGET override (Core.DesiredOverride). Re-exposing
      -- the action override is a future opt-in (votable). The engine still reads its default. Cast Fishing IS
      -- shown again (a row whose default renders a dim Fishing icon); the engine reads its default too.
      if s.id ~= "interact" then
        -- combat/heal live PER-CHARACTER (SBF.CharSlots, via SBF.SlotDef); every other slot comes from
        -- the active profile's working copy. Editing the row then writes the per-character table directly,
        -- so combat/heal edits persist per-character with no profile Save round-trip.
        local def = SBF.SlotDef(s.id) or cur[s.id]
        if not (s.id == "combat" or s.id == "heal") then cur[s.id] = cur[s.id] or {}; def = cur[s.id] end
        slotRows[#slotRows + 1] = MakeRow(bchild, 0, def, s.label, s, reflowSlots)
      end
    end
    reflowSlots()
  end
  rebuildRows()

  -- refreshLootUI() — reconciles the slot list with requireTwoButtons: it adds/removes the separate interact
  -- (Loot) slot row from the list. The keyboard Loot bind + the mouse Loot picker now live on the Keybinds
  -- tab (refreshed via panel._refreshKeysPage). Called on page OnShow and by the relocated Two-button toggle
  -- on Settings -> Interface options (via panel._refreshLootUI).
  refreshLootUI = function()
    rebuildRows()                                           -- add/remove the interact slot row in the list
    reLayoutScroll()
  end
  panel._refreshLootUI = refreshLootUI   -- reachable from the Settings-page Two-button toggle (same Build() scope)
  refreshLootUI()

  -- ===== Profile-page min-size contribution =====
  -- The window min-size was derived ONLY from the Settings page (cols:ApplyMinSize). The Profile page never
  -- contributed, so shrinking to that floor let the Profile content overflow: the profile bar's CRUD row ran
  -- off the RIGHT, and the fixed profile+gear/pole block ran off the BOTTOM. We now derive a Profile-page min
  -- and fold it (as a max) into the window resize floor so it can never shrink below what the page needs on
  -- EITHER axis.
  --   width  : rightmost fixed element on the profile bar's CRUD row (Remove) / the Save+Revert pair on row 2,
  --            measured at runtime (page-relative) so it tracks layout changes instead of brittle pixel math.
  --   height : the fixed profile+gear/pole block depth (GEAR_TOP + GEAR_BLOCK_H) below the page top, plus the
  --            chrome above the page and a minimum slot-list allowance, so the pole/bind-here area always shows
  --            with at least a couple of slot rows beneath it.
  local CHROME_ABOVE_PAGE = 78   -- window chrome above the page: Theme.Window header band (34) + page top offset (44, makePage's -44)
  local PAGE_BOTTOM_INSET = 38   -- makePage anchors the page BOTTOMRIGHT at +38
  local MIN_LIST_H        = 90   -- keep at least ~2 slot rows visible under the fixed block
  -- Default until the runtime measurement lands (one deferred frame): a width covering the profile bar's CRUD
  -- row (Profile dropdown + Add/Duplicate/Remove) plus the deterministic height. Pre-measure fallback only;
  -- computeButtonsMin refines width from the real button positions.
  local BTN_DEFAULT_W = 420
  panel._buttonsMin = { w = BTN_DEFAULT_W, h = 560 }
  -- forward-declared so computeButtonsMin (below) closes over the REAL locals — they're assigned further down
  -- in the CRUD-row build (~line 620). Without this they'd resolve to nil globals inside the closure and the
  -- Profile page's width floor would silently measure nothing (only revertBtn, declared earlier, was captured).
  local remBtn, dupBtn
  local function computeButtonsMin()
    -- WIDTH: max right edge of the candidate rightmost profile-bar elements, relative to the page's left,
    -- + margin. remBtn ends the CRUD row; revertBtn ends the Save/Revert pair on row 2 (both always exist by
    -- the time this deferred fn runs). dupBtn is folded in too as the widest mid-row button.
    local pageLeft = pBtn:GetLeft()
    if pageLeft then
      local rightmost = 0
      for _, el in ipairs({ remBtn, revertBtn, dupBtn }) do
        if el and el:IsShown() then
          local r = el:GetRight()
          if r then rightmost = math.max(rightmost, r - pageLeft) end
        end
      end
      if rightmost > 0 then
        -- page width ≈ panel width - panelVsPage(42); require the content (+ a 20px margin) to fit the page.
        panel._buttonsMin.w = math.ceil(rightmost + 20 + 42)
      end
    end
    -- HEIGHT: fixed block depth + chrome + a minimum list height (deterministic from the layout constants).
    panel._buttonsMin.h = math.ceil(CHROME_ABOVE_PAGE + (GEAR_TOP + GEAR_BLOCK_H) + MIN_LIST_H + PAGE_BOTTOM_INSET)
    if panel._applyWindowMin then panel._applyWindowMin() end   -- re-fold into the resize floor now we have real numbers
  end
  panel._computeButtonsMin = computeButtonsMin

  -- Revert wiring (saveBtn/revertBtn were created up top, before reflowSlots/rebuildRows existed):
  -- discard the working copy's edits, rebuild the rows from the reverted copy, refresh enabled state.
  revertBtn:SetScript("OnClick", function()
    if SBF.RevertWorking then SBF.RevertWorking() end
    rebuildRows()
    if SBF.Apply then SBF.Apply() end
    updateSaveState()
    if refreshProfileBar then refreshProfileBar() end   -- redraw bindings/name from the reverted copy
  end)
  revertBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Discard unsaved slot edits")
    GameTooltip:AddLine("Reloads the slots from the saved profile.", 1, 1, 1, true); GameTooltip:Show()
  end)
  revertBtn:SetScript("OnLeave", GameTooltip_Hide)
  updateSaveState()

  -- ===== profile bar (directly below the master keybind banner) =====
  -- Create / switch / rename / remove profiles + choose the default, all manual (location bindings are
  -- Phase 4). Its band sits MBAR_H below the page top (under the Single Button Fishing banner).
  -- Row 1 (pick/create/delete): [Profile:] selector  Add  Duplicate  Remove
  --   ── separator line ──
  -- Row 2 (edit THIS profile):  [Name:] editbox  [Set as default]  Save  Revert
  -- A single refreshProfileBar() rebuilds the dropdown options + shown text, syncs the rename editbox,
  -- and sets enabled state on Remove / Set-default (both disabled when the current == default).
  local function curProfileId() return (SBF.working and SBF.working.id) or SBF.Store().activeProfile end
  local function curProfileName()
    local id = curProfileId()
    -- the working copy holds the TENTATIVE (unsaved) name for the active profile, so the Name field,
    -- dropdown shown text and "Active:" indicator all reflect an in-progress rename before Save.
    if SBF.working and SBF.working.id == id and SBF.working.name then return SBF.working.name end
    local DB = SBF.Store()
    local p = DB.profiles and DB.profiles[id]
    return (p and p.name) or "?"
  end

  -- helper: a font-string label made hoverable so the whole control+label gets the tooltip (project rule)
  local function barTip(frame, tipTitle, tipBody)
    frame:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(tipTitle)
      if tipBody then GameTooltip:AddLine(tipBody, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
  end
  local function labelHover(fs, w, tipTitle, tipBody)   -- font strings aren't mouse-enabled; cover the word too
    local z = CreateFrame("Frame", nil, pBtn); z:EnableMouse(true)
    z:SetPoint("LEFT", fs, "LEFT", -2, 0); z:SetSize((w or fs:GetStringWidth() or 40) + 6, 22)
    barTip(z, tipTitle, tipBody)
  end

  local plbl = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  plbl:SetPoint("TOPLEFT", 8, -8 - MBAR_H); plbl:SetText("Profile:")

  local profileDD = CreateFrame("DropdownButton", nil, pBtn, "WowStyle1DropdownTemplate")
  profileDD:SetSize(180, 22); profileDD:SetPoint("LEFT", plbl, "RIGHT", 6, 0); Theme.SkinDropdown(profileDD)

  -- the four CRUD buttons, laid out left-to-right after the dropdown
  local addBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
  addBtn:SetSize(48, 22); addBtn:SetPoint("LEFT", profileDD, "RIGHT", 8, 0); addBtn:SetText("Add"); Theme.Button(addBtn)
  dupBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")   -- assigns the forward-declared upvalue
  dupBtn:SetSize(76, 22); dupBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0); dupBtn:SetText("Duplicate"); Theme.Button(dupBtn)
  remBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")   -- assigns the forward-declared upvalue
  remBtn:SetSize(62, 22); remBtn:SetPoint("LEFT", dupBtn, "RIGHT", 4, 0); remBtn:SetText("Remove"); Theme.Button(remBtn)

  -- profile SCOPE toggle (Warband default vs Individual): isolates THIS character's profile set. Sits at
  -- the right end of CRUD row 1. Checked = Individual (this character keeps its own separate profiles);
  -- unchecked = Warband (profiles shared account-wide). Combat/heal are always per-character regardless.
  local SCOPE_TIP_TITLE = "Profile scope"
  local SCOPE_TIP_BODY  = "Warband = these profiles are shared across all your characters (default). "
    .. "Individual = this character keeps its own separate set of profiles. "
    .. "Combat & heal slots are always per-character regardless."
  local indivChk = CreateFrame("CheckButton", nil, pBtn, "UICheckButtonTemplate")
  indivChk:SetSize(22, 22); indivChk:SetPoint("LEFT", remBtn, "RIGHT", 14, 0); Theme.Checkbox(indivChk)
  local indivLbl = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  indivLbl:SetPoint("LEFT", indivChk, "RIGHT", 2, 0); indivLbl:SetText("Individual"); Theme.Font(indivLbl, "text")
  barTip(indivChk, SCOPE_TIP_TITLE, SCOPE_TIP_BODY)                 -- tooltip on the box
  labelHover(indivLbl, indivLbl:GetStringWidth(), SCOPE_TIP_TITLE, SCOPE_TIP_BODY)   -- ...and the word
  -- forward-declared sync (defined after refreshProfileBar exists); re-checks the box to match the live scope.
  local syncScope
  indivChk:SetScript("OnClick", function(self)
    local want = self:GetChecked() and true or false
    -- changing scope swaps the WHOLE visible profile set, so confirm first (a misclick shouldn't surprise).
    self:SetChecked(SBF.IsIndividual())   -- snap back; the real flip happens only on confirm
    SBF._scopePopup = SBF._scopePopup or {}
    SBF._scopePopup.want = want
    SBF._scopePopup.apply = function()
      if SBF.SetScope then SBF.SetScope(want) end
      if rebuildRows then rebuildRows() end
      if refreshProfileBar then refreshProfileBar() end
      if updateSaveState then updateSaveState() end
      if syncScope then syncScope() end
    end
    StaticPopup_Show(want and "SBF_SCOPE_TO_INDIVIDUAL" or "SBF_SCOPE_TO_WARBAND")
  end)

  -- separator between row 1 and row 2 (thin divider spanning the content width — same faint white as
  -- the section-header dividers used elsewhere on the Settings page)
  local sepLine = pBtn:CreateTexture(nil, "ARTWORK")
  sepLine:SetPoint("TOPLEFT", 8, -32 - MBAR_H); sepLine:SetPoint("TOPRIGHT", -20, -32 - MBAR_H)
  sepLine:SetHeight(1); sepLine:SetColorTexture(unpack(Theme.colors.divider))

  -- row 2: rename editbox + Set-as-default + Save + Revert (all four grouped: "edit THIS profile")
  local nlbl = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  nlbl:SetPoint("TOPLEFT", 8, -42 - MBAR_H); nlbl:SetText("Name:")
  local nameEb = CreateFrame("EditBox", nil, pBtn, "InputBoxTemplate")
  nameEb:SetSize(180, 20); nameEb:SetPoint("LEFT", nlbl, "RIGHT", 10, 0); nameEb:SetAutoFocus(false); Theme.EditBox(nameEb)
  local defBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
  defBtn:SetSize(110, 22); defBtn:SetPoint("LEFT", nameEb, "RIGHT", 12, 0); defBtn:SetText("Set as default"); Theme.Button(defBtn)
  -- Save / Revert finish row 2 (anchors deferred from their creation above, now that defBtn exists).
  -- saveBtn was given a placeholder RIGHT-anchor to revertBtn at creation; clear it and re-anchor the
  -- pair left-to-right off defBtn so there's no circular dependency.
  saveBtn:ClearAllPoints(); saveBtn:SetPoint("LEFT", defBtn, "RIGHT", 12, 0)
  revertBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)

  -- refreshGear: forward-declared here (used by refreshProfileBar + the gear widgets' closures); the gear
  -- block + widgets are built BELOW the bind section (between the bind row and the slot list).
  local refreshGear

  -- ===== row 3: location bindings for THIS profile =====
  -- Bind the selected profile to a level of where you're standing, so the auto-swap engine activates it
  -- when you return. The location hierarchy is VARIABLE-DEPTH (SBF.LocationCascade): one Bind button per
  -- level, rebuilt each refresh. Bindings COMMIT INSTANTLY to the stored profile (not save-gated, no
  -- dirty flag): auto-swap re-resolves on every cast press from the STORED bindings, so a save-gated
  -- binding would let the very next cast swap you back to Default. Save/Revert never touch bindings.
  -- Most-specific (deepest) match wins at resolve time.
  local blbl = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  -- y is 6px lower than the bind-button row's top so the short label centers vertically on the 22px buttons
  -- (the buttons anchor to blbl with a +4 offset below, keeping their absolute position unchanged).
  blbl:SetPoint("TOPLEFT", 8, -74 - MBAR_H); blbl:SetText("Bind here:")

  local bindList                 -- forward decl: the list-rebuild fn, defined below; called by refreshProfileBar
  local placeGearBlock           -- forward decl: positions the gear block + slot scroll below the bind section
  local bindExtra = 0            -- px the (variable-height) bind section overflows its reserved band; the gear
                                 -- block + slot list are pushed DOWN by this so bindings never lay over them

  -- pool of reusable Bind buttons (one per cascade level; extras hidden). Never recreated, so no leak.
  local bindBtns = {}
  local function bindButton(i)
    local b = bindBtns[i]
    if not b then
      b = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
      b:SetHeight(22); Theme.Button(b)
      b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Bind location")
        GameTooltip:AddLine(self._tip or "", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      b:HookScript("OnLeave", GameTooltip_Hide)
      bindBtns[i] = b
    end
    return b
  end

  -- pool of reusable bound-location list rows ("<kind>: <value>  [x]"; extras hidden). Never recreated.
  local bindRows = {}
  local function bindRow(i)
    local row = bindRows[i]
    if not row then
      row = CreateFrame("Frame", nil, pBtn)
      row:SetSize(360, 16)
      row.fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      row.fs:SetPoint("LEFT", 0, 0); row.fs:SetJustifyH("LEFT")
      row.x = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.x:SetSize(18, 16); row.x:SetText("x"); Theme.Button(row.x)
      bindRows[i] = row
    end
    return row
  end

  -- bind the clicked location to the CURRENT profile — unless it's the default (contradictory: default is
  -- the fallback). For default, prompt for a name and make a NEW profile (duplicated from default) bound to
  -- the clicked level instead. curProfileId() is read at click time (no stale capture).
  local function doBind(name, kind, mapID)
    if curProfileId() == SBF.Store().defaultProfile then
      SBF._profilePopup.prefill = name or ""
      SBF._profilePopup.onName = function(text)
        text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then text = name or "New profile" end
        local nid = SBF.AddProfile(text, SBF.Store().defaultProfile)
        if not nid then return end
        -- bind first (instant commit to the stored profile), then activate — the new profile is born
        -- already bound here, so the auto-swap engine holds it from the first cast.
        SBF.AddBinding(nid, name, kind, mapID)
        SBF.ActivateProfile(nid)
        rebuildRows()
        if SBF.Apply then SBF.Apply() end
        updateSaveState(); refreshProfileBar()
      end
      StaticPopup_Show("SBF_BIND_DEFAULT")
      return
    end
    local ok, err = SBF.AddBinding(curProfileId(), name, kind, mapID)
    if not ok then UIErrorsFrame:AddMessage(err or "Couldn't bind.", 1, 0.3, 0.3); return end
    bindList()   -- no markDirty: bindings commit instantly (auto-swap must hold this profile NOW)
  end

  bindList = function()
    local id = curProfileId()
    local casc = (SBF.LocationCascade and SBF.LocationCascade()) or {}
    -- (re)lay the Bind buttons with WRAPPING: chain left->right off "Bind here:", wrapping to a new row
    -- (aligned under the first button) whenever the next button would overflow the content width. Hide
    -- extras from a deeper spot. The pool is never CreateFrame'd in-loop, so no leak.
    local LEFT0 = 8 + (blbl:GetStringWidth() or 56) + 8   -- x of the first button (after "Bind here:")
    local RIGHT_MARGIN = 20
    local GAPX, ROWY = 4, 24
    local avail = (pBtn:GetWidth() or 540) - RIGHT_MARGIN
    local x, rowIdx = LEFT0, 0
    for i, level in ipairs(casc) do
      local b = bindButton(i)
      b:SetText(level.name)
      local w = math.max(60, (b:GetFontString() and b:GetFontString():GetStringWidth() or 40) + 20)
      b:SetWidth(w)
      if i > 1 and (x + w) > avail then rowIdx = rowIdx + 1; x = LEFT0 end   -- wrap before placing
      b:ClearAllPoints()
      -- +4 (vs blbl's lowered TOPLEFT) re-raises the row to its intended position; net effect: the buttons
      -- sit where they always did, but blbl is now vertically centered on them instead of riding high.
      b:SetPoint("TOPLEFT", blbl, "TOPLEFT", (x - 8), 4 - rowIdx * ROWY)   -- blbl x is 8; offset from it
      x = x + w + GAPX
      b._tip = ("Bind this profile to the %s \"%s\". Applies immediately — no Save needed."):format(level.kind or "location", level.name)
      local name, kind, mapID = level.name, level.kind, level.mapID
      b:SetScript("OnClick", function() doBind(name, kind, mapID) end)
      b:Show()
    end
    for i = #casc + 1, #bindBtns do bindBtns[i]:Hide() end
    local btnRows = (#casc > 0) and (rowIdx + 1) or 0   -- rows of buttons actually drawn

    -- (re)lay the bound-locations list BELOW the last button row (so it never overlaps the buttons).
    -- Rebuilt every call (fixes the "bound but not shown" bug — bind/remove/profile-switch route here).
    local listTopY = -2 - btnRows * ROWY    -- y offset from blbl's bottom-left
    local DB = SBF.Store()
    local p = DB.profiles and DB.profiles[id]
    local binds = (p and p.bindings) or {}   -- stored profile IS the truth (bindings commit instantly)
    for i, bnd in ipairs(binds) do
      local row = bindRow(i)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", blbl, "BOTTOMLEFT", 4, listTopY - (i - 1) * 17)
      row.fs:SetText(Theme.Accent((bnd.kind or "?") .. ":") .. " " .. (bnd.value or "?"))
      row.x:ClearAllPoints()
      row.x:SetPoint("LEFT", row.fs, "RIGHT", 6, 0)
      local value = bnd.value
      row.x:SetScript("OnClick", function()
        SBF.RemoveBinding(curProfileId(), value)   -- curProfileId() read at click time; commits instantly
        bindList()
      end)
      row:Show()
    end
    for i = #binds + 1, #bindRows do bindRows[i]:Hide() end

    -- "Protect" the bind area: it's variable-height (button rows + one row per binding), but the gear block +
    -- slot list below sit at a fixed GEAR_TOP. Measure how far the section's bottom overflows GEAR_TOP and
    -- push everything below DOWN by that, so multiple bindings flow the page instead of laying over the gear.
    -- (px from page top; blbl TOPLEFT y = 74 + MBAR_H; LABEL_H/row pitch match the anchors above.)
    local LABEL_H, BIND_GAP = 14, 8
    local btnBottom  = 18 + (math.max(btnRows, 1) - 1) * ROWY                       -- bottom of the lowest button row, rel blbl top
    local listBottom = (#binds > 0) and (LABEL_H + 18 + btnRows * ROWY + (#binds - 1) * 17) or 0
    local sectionBottom = (74 + MBAR_H) + math.max(btnBottom, listBottom)
    bindExtra = math.max(0, sectionBottom + BIND_GAP - GEAR_TOP)
    if placeGearBlock then placeGearBlock() end
  end
  labelHover(blbl, 56, "Bind here", "Bind this profile to a level of where you're standing so it auto-activates when you return. The most specific (deepest) match wins. Bindings apply immediately — they don't need Save (and Revert won't undo them).")

  -- ===== gear block (below the bind-here section, above the slot list) =====
  -- A separator, then the per-profile gear row (equipment set + Equipment-mgr), and the fishing-pole drop
  -- box (sized to MATCH the slot-list icons, ICON=37, and left-aligned to the slot rows' icon column at
  -- STRIP_X). All anchors offset from GEAR_TOP so the block reflows beneath the profile bar band.
  -- The GLOBAL gear controls (restore + keybinds) live in Settings.
  local gsep = pBtn:CreateTexture(nil, "ARTWORK")
  gsep:SetPoint("TOPLEFT", 8, -GEAR_TOP - 6); gsep:SetPoint("TOPRIGHT", -20, -GEAR_TOP - 6)
  gsep:SetHeight(1); gsep:SetColorTexture(unpack(Theme.colors.divider))

  -- gear row: "Gear set:" label + equipment-set dropdown + Equipment-mgr button
  local glbl = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  glbl:SetPoint("TOPLEFT", 8, -GEAR_TOP - 16); glbl:SetText("Gear set:")
  local gearDD = CreateFrame("DropdownButton", nil, pBtn, "WowStyle1DropdownTemplate")
  gearDD:SetSize(150, 22); gearDD:SetPoint("LEFT", glbl, "RIGHT", 6, 0); Theme.SkinDropdown(gearDD)
  gearDD:SetupMenu(function(_dd, root)
    root:CreateRadio("(none)",
      function() return not (SBF.working and SBF.working.equipSet) end,
      function() if SBF.working then SBF.working.equipSet = nil; markDirty() end; if refreshGear then refreshGear() end end)
    for _, name in ipairs((SBF.EquipmentSetNames and SBF.EquipmentSetNames()) or {}) do
      root:CreateRadio(name,
        function() return SBF.working and SBF.working.equipSet == name end,
        function() if SBF.working then SBF.working.equipSet = name; markDirty() end; if refreshGear then refreshGear() end end)
    end
  end)
  barTip(gearDD, "Equipment set", "The Blizzard equipment set this profile wears. Equipped on the first action press after switching to this profile; restored when you stop (manual or idle). Manage sets in the character pane.")
  labelHover(glbl, 56, "Gear set", "This profile's equipment set + fishing pole. Equipped on the first action press after you switch to this profile; restored when you stop.")

  -- Equipment-mgr button: open the character pane AND select the Equipment Manager sidebar (retail
  -- PaperDollSidebarTab3 = Stats(1)/Titles(2)/Equipment Manager(3)). Only force the sidebar when opening
  -- (don't fight a user who toggles it closed); falls back to the plain character pane if neither path exists.
  local emBtn = CreateFrame("Button", nil, pBtn, "UIPanelButtonTemplate")
  emBtn:SetSize(140, 22); emBtn:SetPoint("LEFT", gearDD, "RIGHT", 6, 0); emBtn:SetText("Equipment Manager"); Theme.Button(emBtn)
  emBtn:SetScript("OnClick", function()
    -- Edit flow: equip the profile's gear FIRST (so you're editing the configured set — and it snapshots
    -- your normal gear if you weren't already in it), then flag that we're editing so SBF suspends auto-equip
    -- (per-press + zone) and won't fight your edits. The CharacterFrame OnHide hook (set up once below)
    -- clears the flag and restores your pre-fishing gear when you close the window.
    -- Only enter the edit session when the profile actually manages gear (set/pole). For a no-gear profile
    -- (e.g. Default) there's nothing to put on or restore, so just open the manager without the flag.
    local w = SBF.working
    if w and (w.equipSet or w.pole) and SBF.EquipProfileGear then
      SBF.EquipProfileGear()
      SBF._emEditing = true
    end
    -- "Is the pane open?" must test CharacterFrame, NOT PaperDollFrame — PaperDollFrame's own shown-flag can
    -- read true even while its parent CharacterFrame is closed, which previously made us skip ToggleCharacter
    -- and open nothing. Gate on CharacterFrame so we reliably open; only ToggleCharacter when it won't close.
    if not (CharacterFrame and CharacterFrame:IsShown()) then
      ToggleCharacter("PaperDollFrame")            -- closed -> open to PaperDoll
    elseif not (PaperDollFrame and PaperDollFrame:IsShown()) then
      ToggleCharacter("PaperDollFrame")            -- open on another tab -> switch to PaperDoll (won't close)
    end
    -- Select the Equipment Manager sidebar AFTER the frame lays out its sidebar tabs (best-effort on top).
    -- Tab3 = Equipment Manager (Stats=1/Titles=2/EM=3). Click the real tab first (full handler); else the fn.
    C_Timer.After(0, function()
      if PaperDollSidebarTab3 and PaperDollSidebarTab3:IsShown() then
        pcall(function() PaperDollSidebarTab3:Click() end)
      elseif PaperDollFrame_SetSidebar then
        pcall(PaperDollFrame_SetSidebar, 3)
      end
    end)
  end)
  barTip(emBtn, "Open equipment manager", "Open the character pane's Equipment Manager tab to edit this profile's set. SBF puts you in the set to edit, then restores your normal gear when you close the window.")

  -- Hook CharacterFrame OnHide ONCE: when the pane closes during an SBF-initiated edit session, clear the
  -- editing flag and restore the pre-fishing gear (the snapshot). _emEditing is set ONLY by our button, so
  -- a normal (non-SBF) open/close of the character pane does nothing here.
  if CharacterFrame and not SBF._emHooked then
    SBF._emHooked = true
    CharacterFrame:HookScript("OnHide", function()
      if SBF._emEditing then
        SBF._emEditing = false
        if SBF.RestoreNormalGear then SBF.RestoreNormalGear() end
      end
    end)
  end

  -- fishing-pole row: a "Fishing pole:" label + a drop box sized to MATCH the slot-list icons (ICON=37),
  -- left-aligned to the slot rows' icon column (STRIP_X). Drop a pole to set SBF.working.pole; right-click clears.
  local plbl2 = pBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  plbl2:SetPoint("TOPLEFT", 8, -GEAR_TOP - 44); plbl2:SetText("Fishing pole:")
  local poleBtn = CreateFrame("Button", nil, pBtn, "BackdropTemplate")
  poleBtn:SetSize(ICON, ICON); poleBtn:SetPoint("TOPLEFT", STRIP_X + 2, -GEAR_TOP - 38)   -- ICON matches the slot icons; +2px nudge to align with the slot rows' icon column
  poleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  styleSlot(poleBtn)
  poleBtn.icon = poleBtn:CreateTexture(nil, "ARTWORK"); poleBtn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  poleBtn.icon:SetPoint("TOPLEFT", 2, -2); poleBtn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  poleBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  local function setPole(id)
    if SBF.working then SBF.working.pole = id; markDirty() end
    if refreshGear then refreshGear() end
  end
  poleBtn:SetScript("OnReceiveDrag", function()
    local kind, d1, d2 = GetCursorInfo()
    if kind == "item" then local iid = GetItemInfoInstant(d2 or d1); if iid then setPole(iid); ClearCursor() end end
  end)
  poleBtn:SetScript("OnClick", function(_, click)
    if click == "RightButton" then setPole(nil)
    else
      local kind, d1, d2 = GetCursorInfo()
      if kind == "item" then local iid = GetItemInfoInstant(d2 or d1); if iid then setPole(iid); ClearCursor() end end
    end
  end)
  poleBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local pole = SBF.working and SBF.working.pole
    if pole then GameTooltip:SetItemByID(pole)
    else GameTooltip:SetText("Fishing pole"); GameTooltip:AddLine("Drag a pole here to equip it with this profile; right-click to clear.", 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  poleBtn:SetScript("OnLeave", GameTooltip_Hide)
  labelHover(plbl2, 70, "Fishing pole", "The pole this profile equips (into the profession tool slot) on the first action press after switching. Right-click the box to clear.")

  -- separator under the fishing-pole row, dividing the gear block from the slot list below (matches the
  -- other separators' faint-white style/width). The scroll frame's top (GEAR_BLOCK_H) sits just under it.
  local gsep2 = pBtn:CreateTexture(nil, "ARTWORK")
  gsep2:SetPoint("TOPLEFT", 8, -GEAR_TOP - 82); gsep2:SetPoint("TOPRIGHT", -20, -GEAR_TOP - 82)
  gsep2:SetHeight(1); gsep2:SetColorTexture(unpack(Theme.colors.divider))

  -- re-sync the gear widgets to the active profile's working-copy values (called from refreshProfileBar)
  refreshGear = function()
    local w = SBF.working
    if gearDD.SetText then gearDD:SetText((w and w.equipSet) or "(none)") end
    local pole = w and w.pole
    local tex = pole and (select(5, GetItemInfoInstant(pole)))
    poleBtn.icon:SetTexture(tex or ""); poleBtn.icon:SetShown(tex ~= nil)
  end

  -- (The active-profile "Active: <name>" indicator moved UP to the window header — headerProfileFS, created
  -- with fishFS — so it shows on every tab and while collapsed. refreshProfileBar updates it there now.)

  -- keep the Individual checkbox matching the live scope (called on every bar refresh + after a scope flip).
  syncScope = function() indivChk:SetChecked(SBF.IsIndividual()) end

  -- refreshProfileBar: the single re-sync point (declared as the page-scope forward local up top)
  refreshProfileBar = function()
    local id = curProfileId()
    local isDefault = (id == SBF.Store().defaultProfile)
    -- dropdown shown text: current profile's name (+ "(default)" when it IS the default)
    local shown = curProfileName()
    if isDefault then shown = shown .. " (default)" end
    if profileDD.SetText then profileDD:SetText(shown) end
    nameEb:SetText(curProfileName())
    remBtn:SetEnabled(not isDefault)   -- the default may not be removed
    defBtn:SetEnabled(not isDefault)   -- already-default can't be re-set
    if syncScope then syncScope() end  -- reflect Warband/Individual scope on the checkbox
    if bindList then bindList() end    -- re-list this profile's location bindings
    if refreshGear then refreshGear() end   -- re-sync gear-set dropdown + pole picker to the active profile
    -- active-profile readout now lives in the window header; only meaningful with multiple profiles, so it's
    -- hidden in simple mode (just the Default profile) and shown with the live name in advanced mode.
    local adv = SBFDB.advancedMode ~= false
    headerProfileFS:SetShown(adv)
    if adv then headerProfileFS:SetText("Active: " .. Theme.Accent(curProfileName())) end
    -- bindList re-Show()s the bind buttons/rows; re-apply mode visibility so simple mode stays hidden.
    if panel and panel._relaySimpleMode then panel._relaySimpleMode() end
  end

  -- selecting a profile from the dropdown. If there are unsaved edits, confirm before discarding them
  -- (Phase-3 interim: ActivateProfile LoadWorking-discards the working copy; Phase 4 adds the richer
  -- save/discard/save-for-zone prompt). Cancel resets the shown text back to the current profile.
  local function doActivate(id)
    if SBF.ActivateProfile then SBF.ActivateProfile(id) end
    rebuildRows()
    if SBF.Apply then SBF.Apply() end
    updateSaveState()
    refreshProfileBar()
  end
  local function selectProfile(id)
    if id == curProfileId() then return end
    if SBF.IsDirty and SBF.IsDirty() then
      SBF._profilePopup.onSwitch = function() doActivate(id) end
      SBF._profilePopup.onSwitchCancel = function() refreshProfileBar() end   -- snap the label back
      StaticPopup_Show("SBF_SWITCH_DIRTY")
    else
      doActivate(id)
    end
  end
  profileDD:SetupMenu(function(_dd, root)
    local _ddDefault = SBF.Store().defaultProfile
    for _, e in ipairs((SBF.ProfileList and SBF.ProfileList()) or {}) do
      local label = e.name
      if e.id == _ddDefault then label = label .. " (default)" end
      root:CreateRadio(label,
        function() return e.id == curProfileId() end,
        function() selectProfile(e.id) end)
    end
  end)
  barTip(profileDD, "Active profile", "Switch which saved fishing profile is active. The default profile (shown with \"(default)\") is the location fallback.")
  labelHover(plbl, 44, "Active profile", "Switch which saved fishing profile is active. The default profile (shown with \"(default)\") is the location fallback.")

  -- shared: create a profile from `fromId` (nil = default) named `name`, activate + rebuild + refresh.
  local function createAndActivate(name, fromId)
    if not SBF.AddProfile then return end
    local id = SBF.AddProfile(name, fromId)
    if not id then return end
    SBF.ActivateProfile(id); rebuildRows()
    if SBF.Apply then SBF.Apply() end
    updateSaveState(); refreshProfileBar()
  end

  -- Add: prompt for a name (blank -> "New profile"), then create a fresh profile (a copy of the
  -- default's slots, per SBF.AddProfile) and switch to it.
  addBtn:SetScript("OnClick", function()
    SBF._profilePopup.onName = function(text)
      text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      createAndActivate(text ~= "" and text or "New profile")
    end
    StaticPopup_Show("SBF_NEW_PROFILE")
  end)
  barTip(addBtn, "Add profile", "Create a new profile (a copy of the default). You'll be asked to name it.")

  -- Duplicate: prompt with the name prefilled to "<current> copy", then copy the CURRENT profile
  -- (name + slots) and switch to the copy.
  dupBtn:SetScript("OnClick", function()
    local fromId = curProfileId()
    SBF._profilePopup.prefill = curProfileName() .. " copy"
    SBF._profilePopup.onName = function(text)
      text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
      createAndActivate(text ~= "" and text or (curProfileName() .. " copy"), fromId)
    end
    StaticPopup_Show("SBF_DUP_PROFILE")
  end)
  barTip(dupBtn, "Duplicate profile", "Copy the current profile (slots and all) under a new name and switch to it.")

  -- Remove: confirm, then remove the current profile. RemoveProfile refuses the default and any
  -- missing id (returns false + a message); on success it falls the active profile back to the default.
  remBtn:SetScript("OnClick", function()
    local id = curProfileId()
    SBF._profilePopup.onRemove = function()
      local ok, err = SBF.RemoveProfile(id)
      if not ok then
        UIErrorsFrame:AddMessage(err or "Couldn't remove that profile.", 1, 0.3, 0.3)
        return
      end
      rebuildRows()
      if SBF.Apply then SBF.Apply() end
      updateSaveState(); refreshProfileBar()
    end
    StaticPopup_Show("SBF_REMOVE_PROFILE", curProfileName())
  end)
  barTip(remBtn, "Remove profile", "Delete the current profile (after confirming). The default profile can't be removed.")

  -- Rename: a name edit is a TENTATIVE working-copy change (like slots/gear/bindings) — it marks dirty so
  -- Save AND Revert light up, and only persists on Save. applyRename does the value work WITHOUT ClearFocus
  -- (so the focus-lost path can reuse it without recursing). Commits on Enter OR focus loss.
  local function applyRename(self)
    local t = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" and SBF.working then SBF.working.name = t; markDirty() end
    refreshProfileBar()
  end
  nameEb:SetScript("OnEnterPressed", function(self) applyRename(self); self:ClearFocus() end)
  nameEb:SetScript("OnEditFocusLost", applyRename)                          -- commit when you click/tab away
  nameEb:SetScript("OnEscapePressed", function(self) self:SetText(curProfileName()); self:ClearFocus() end)
  barTip(nameEb, "Profile name", "Rename the current profile. Press Enter or click away to apply; the change is saved with the profile's other edits via Save.")
  labelHover(nlbl, 40, "Profile name", "Rename the current profile. Press Enter or click away to apply; the change is saved with the profile's other edits via Save.")

  -- Set as default: make the current profile the location fallback. The "(default)" suffix moves, the
  -- old default becomes removable, and this button + Remove update their enabled state.
  defBtn:SetScript("OnClick", function()
    if SBF.SetDefaultProfile then SBF.SetDefaultProfile(curProfileId()) end
    refreshProfileBar()
  end)
  barTip(defBtn, "Set as default", "Make this the default profile — the one used when no location binding matches. Only one profile is the default.")

  -- ===== Simple/Advanced mode =====
  -- ADVANCED (advancedMode true, default): the full profile bar + bind section show, gear block sits below
  -- the BAR_H band as built. SIMPLE (false): hide all profile-management + binding UI (a casual user just
  -- uses the Default profile), and COLLAPSE the gear block + slot list UP into the freed band so there's no
  -- empty gap. The master keybind banner, the Gear row, the description and the slot rows always show.
  -- Profile-management widgets hidden in simple mode (everything in the profile bar + the bind section):
  local profileUI = { plbl, profileDD, addBtn, dupBtn, remBtn, sepLine, nlbl, nameEb, defBtn,
                      saveBtn, revertBtn, blbl }
  -- gear-block + scroll widgets whose y-anchor is offset from GEAR_TOP; relaid with the active topShift.
  -- { frame, baseY } where baseY is the y the widget uses at topShift == 0 (advanced).
  local gearBlock = {
    { gsep,    -GEAR_TOP - 6 }, { glbl, -GEAR_TOP - 16 },
    { plbl2,   -GEAR_TOP - 44 }, { poleBtn, -GEAR_TOP - 38 }, { gsep2, -GEAR_TOP - 82 },
  }
  -- placeGearBlock: position the gear block + slot-scroll. topShift pulls them UP by the hidden profile band
  -- in SIMPLE mode; bindExtra pushes them DOWN by however far the (variable-height) bind section overflowed
  -- GEAR_TOP in ADVANCED mode (set by bindList). gearDD/emBtn anchor off glbl (LEFT) so they follow along.
  placeGearBlock = function()
    local simple = (SBFDB.advancedMode == false)
    local topShift = simple and BAR_H or 0
    local push = simple and 0 or bindExtra        -- bind UI is hidden in simple mode, so no push there
    for _, g in ipairs(gearBlock) do
      g[1]:ClearAllPoints()
      local y = g[2] + topShift - push
      if g[1] == gsep or g[1] == gsep2 then                      -- separators span the width (TOPLEFT+TOPRIGHT)
        g[1]:SetPoint("TOPLEFT", 8, y); g[1]:SetPoint("TOPRIGHT", -20, y)
      elseif g[1] == poleBtn then
        g[1]:SetPoint("TOPLEFT", STRIP_X + 2, y)
      else
        g[1]:SetPoint("TOPLEFT", 8, y)
      end
    end
    -- gsep is the rule that divides the profile bar from the gear set, so it's only meaningful in ADVANCED.
    -- In SIMPLE the profile bar is hidden, so hide it too — otherwise it dangles above the folded-up gear row.
    gsep:SetShown(not simple)
    -- the scope toggle (Individual) stays available in BOTH modes (hence it's not in profileUI). In ADVANCED it
    -- rides the profile bar next to Remove; in SIMPLE the bar is gone, so park it on the gear row — right of the
    -- Equipment Manager button — so it sits with the gear set instead of floating where the hidden Remove was.
    indivChk:ClearAllPoints()
    if simple then indivChk:SetPoint("LEFT", emBtn, "RIGHT", 16, 0)
    else           indivChk:SetPoint("LEFT", remBtn, "RIGHT", 14, 0) end
    bsf:ClearAllPoints()
    bsf:SetPoint("TOPLEFT", 2, -GEAR_TOP - GEAR_BLOCK_H + topShift - push); bsf:SetPoint("BOTTOMRIGHT", -20, 2)
    if reLayoutScroll then reLayoutScroll() end
  end

  local function relaySimpleMode()
    local simple = (SBFDB.advancedMode == false)
    for _, w in ipairs(profileUI) do w:SetShown(not simple) end
    -- bind buttons + bound-location rows are POOLED: bindList shows only the live ones (the current cascade's
    -- buttons + THIS profile's bindings) and HIDES the rest. So in SIMPLE mode hide the whole pool; in ADVANCED
    -- re-run bindList to restore the CORRECT per-entry visibility. (The old blanket SetShown(true) here re-showed
    -- stale/empty pool entries bindList had just hidden — that caused the Default profile to keep showing the
    -- last-viewed profile's binding, and a faint empty button under the last real cascade button.) bindList
    -- ALSO sets bindExtra + calls placeGearBlock; the simple branch resets it + places directly.
    if simple then
      for _, b in ipairs(bindBtns) do b:Hide() end
      for _, r in ipairs(bindRows) do r:Hide() end
      bindExtra = 0
      placeGearBlock()
    elseif bindList then
      bindList()
    end
  end
  panel._relaySimpleMode = relaySimpleMode

  -- Refresh hook for auto-swap: Profiles.DoSwap calls this after loading a new working copy so the open
  -- window mirrors the swapped-in profile (dropdown text, rows, Save state, the bindings list). No-op when
  -- the window isn't built / not shown.
  function SBF.RefreshOptions()
    if not (panel and panel:IsShown()) then return end
    if refreshLootUI then refreshLootUI() else rebuildRows() end   -- rebuild + reconcile loot UI with the mode
    refreshProfileBar()
    updateSaveState()
    relaySimpleMode()    -- keep mode visibility/anchors current after a swap or rebuild
  end

  refreshProfileBar()
  relaySimpleMode()      -- apply the initial mode visibility + layout

  -- ===== PAGE: Settings (behavior toggles + sound + opacity) =====
  -- ===== PAGE: Settings (behavior toggles + sound + opacity) — ONE declarative box tree =====
  -- The whole page is a GECTheme.Layout box tree rooted on the scroll child: sections auto-stack, each
  -- section auto-sizes to its content, and NO row carries a hand y-offset (the old chk/chkFull/head/cols
  -- + clampHelpZones/reflowFullRows scaffolding is gone). Plain checkboxes are `check` leaves (their
  -- whole-row help hover-zone is baked in); coupled controls (editboxes, the opacity slider, the sound
  -- dropdown+Test groups, buttons) are their EXISTING widgets hosted via { frame = w } so their custom
  -- commit/clamp/tooltip logic is untouched (Bucket B: host, don't rebuild). Two-column rows are a
  -- { dir="row" } of two grow columns; conditional groups toggle via node.hidden + root:Invalidate().
  local pBe = attachPageScroll(pages.behavior, 490, 1)   -- box tree drives the scroll-child height
  SBFDB.mouse = SBFDB.mouse or {}

  -- native help as a render-fn: draws SBF's titled tooltip (accent title + gray body) into the leaf's
  -- baked whole-row hover zone, so tooltips match ns.opt.helpTip exactly (the other pages' look).
  local function optHelp(key)
    if not key then return nil end
    return function(owner)
      local h = SBF.GetHelp and SBF.GetHelp(key); if not h then return end
      GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
      GameTooltip:SetText(h.title or key, accentRGB())
      if h.body then GameTooltip:AddLine(h.body, 0.85, 0.85, 0.85, true) end
      GameTooltip:Show()
    end
  end
  local function C(label, get, set, key) return { label = label, get = get, set = set, help = optHelp(key) } end

  -- forward decls (referenced by set closures; defined once refs/root exist below)
  local refreshInterfaceOpts, refreshProfileToggles
  local root, refs

  -- ---- hosted coupled editboxes (kept as-is, positioned by the tree) ----
  local function makeEdit(width, initial)
    local e = CreateFrame("EditBox", nil, pBe, "InputBoxTemplate")
    e:SetSize(width, 20); e:SetAutoFocus(false); Theme.EditBox(e); e:SetText(initial)
    return e
  end
  -- click speed (Interface options): mouse double-click window, clamped 0.20-0.60, custom tooltip
  local mdf = makeEdit(44, string.format("%.2f", SBFDB.mouse.doubleSec or 0.4))
  local function commitMDF(self)
    local n = tonumber(self:GetText())
    if n then n = math.max(0.2, math.min(0.6, n)); SBFDB.mouse.doubleSec = n end
    self:SetText(string.format("%.2f", SBFDB.mouse.doubleSec or 0.4))
  end
  mdf:SetScript("OnEnterPressed", function(s) commitMDF(s); s:ClearFocus() end)
  mdf:SetScript("OnEditFocusLost", commitMDF)
  mdf:SetScript("OnEscapePressed", function(s) commitMDF(s); s:ClearFocus() end)
  mdf:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Double-click window (sec)")
    GameTooltip:AddLine("How fast the two presses must be to count as a double-click (0.20-0.60). "
      .. "Lower = faster; higher = more forgiving. Default 0.40.", 1, 1, 1, true); GameTooltip:Show()
  end)
  mdf:SetScript("OnLeave", GameTooltip_Hide)
  -- cast-fail back-off (Fishing behavior)
  local cbf = makeEdit(40, tostring(SBFDB.castBackoff or 1.5))
  local function commitCBF(self)
    local n = tonumber(self:GetText()); if n and n >= 0 then SBFDB.castBackoff = n end
    self:SetText(tostring(SBFDB.castBackoff or 1.5))
  end
  cbf:SetScript("OnEnterPressed", function(s) commitCBF(s); s:ClearFocus() end)
  cbf:SetScript("OnEditFocusLost", commitCBF)
  cbf:SetScript("OnEscapePressed", function(s) commitCBF(s); s:ClearFocus() end)
  helpTip(cbf, "set.castBackoff")
  -- idle-restore delay (Profile advanced mode)
  local irf = makeEdit(50, tostring(SBFDB.idleRestoreSeconds or 30))
  local function commitIRF(self)
    local n = tonumber(self:GetText()); if n and n >= 1 then SBFDB.idleRestoreSeconds = math.floor(n) end
    self:SetText(tostring(SBFDB.idleRestoreSeconds or 30))
  end
  irf:SetScript("OnEnterPressed", function(s) commitIRF(s); s:ClearFocus() end)
  irf:SetScript("OnEditFocusLost", commitIRF)
  irf:SetScript("OnEscapePressed", function(s) commitIRF(s); s:ClearFocus() end)
  helpTip(irf, "set.idleRestore")

  -- ---- Optimizations: Focus-audio settings button ----
  local faBtn = Theme.MakeButton(pBe, 130, "Audio settings\226\128\166",
    function() if SBF.ShowFocusAudio then SBF.ShowFocusAudio() end end)
  faBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Focus audio settings")
    GameTooltip:AddLine("Set the sound levels SBF switches to while fishing (master/SFX/music/ambience/dialog).", 1, 1, 1, true); GameTooltip:Show()
  end)
  faBtn:SetScript("OnLeave", GameTooltip_Hide)

  -- ---- Visuals: opacity slider (+ live % readout) and Reset-window button ----
  local oVal   -- the % readout note's fontstring (filled from refs after layout); closure reads it live
  local function oshow(v) if oVal then oVal:SetText(string.format("%d%%", math.floor(v * 100 + 0.5))) end end
  local osl = Theme.Slider(pBe, {
    name = "SBFBgSlider", width = 190, min = 0, max = 1, steps = 20, value = SBFDB.bgAlpha or 0.94,
    onChange = function(v) SBFDB.bgAlpha = v; oshow(v); panel.ApplyBg() end,
  })
  helpTip(osl, "set.bgAlpha")
  local rw = Theme.MakeButton(pBe, 130, "Reset window", ResetWindow)

  -- ---- Audio feedback: the 5 sound rows (check + skinned dropdown + Test), each returned as a row spec ----
  local function kit(name, fb) return (SOUNDKIT and SOUNDKIT[name]) or fb end
  local SOUND_CHOICES = {
    { label = "Ready Check ding", id = kit("READY_CHECK", 8960) },
    { label = "Raid warning",     id = kit("RAID_WARNING", 8959) },
    { label = "Level up",         id = 888 },
    { label = "Auction open",     id = kit("AUCTION_WINDOW_OPEN", 5274) },
    { label = "Map ping",         id = kit("MAP_PING", 3175) },
    { label = "Quest failed",     id = kit("IG_QUEST_FAILED", 847) },
    { label = "Yay",              filePath = "Interface\\AddOns\\SBF\\sounds\\YAY.mp3" },
    { label = "Custom file (sounds/cast.ogg)", file = true },
  }
  local NAMED_SOUND_FILES = {}
  for _, o in ipairs(SOUND_CHOICES) do if o.filePath then NAMED_SOUND_FILES[o.filePath] = true end end
  -- Aligned checkbox|selector table: give every sound row's CHECK cell the same fixed width = the widest
  -- of the 5 labels (measured now), so column 2 (dropdown + Test) starts at the same x on every row and
  -- the whole thing left-packs (no right-binding). Rows stay single row boxes, so they can't drift.
  local SOUND_LABELS = { "Fishing start", "Cast fail", "No fish hooked", "Expired (ran full, no bite)", "Patiently Rewarded" }
  local _lw = pBe:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); _lw:Hide()
  local _widest = 0
  for _, s in ipairs(SOUND_LABELS) do _lw:SetText(s); _widest = math.max(_widest, _lw:GetStringWidth() or 0) end
  local SOUND_CHECK_W = math.ceil(26 + _widest + 8)   -- indent(0)+CB_HIT(24)+gap(2) + widest label + pad
  local function soundRowSpec(label, keys, play, key)
    local dd = CreateFrame("DropdownButton", nil, pBe, "WowStyle1DropdownTemplate")
    dd:SetSize(190, 22); Theme.SkinDropdown(dd)
    dd:SetupMenu(function(_dd, rootMenu)
      local fileVar = keys.enable .. "File"
      for _, o in ipairs(SOUND_CHOICES) do
        rootMenu:CreateRadio(o.label,
          function()
            if o.filePath then return SBFDB[keys.mode] == "file" and SBFDB[fileVar] == o.filePath end
            if o.file then return SBFDB[keys.mode] == "file" and not NAMED_SOUND_FILES[SBFDB[fileVar]] end
            return SBFDB[keys.mode] ~= "file" and SBFDB[keys.id] == o.id
          end,
          function()
            if o.filePath then SBFDB[keys.mode] = "file"; SBFDB[fileVar] = o.filePath
            elseif o.file then SBFDB[keys.mode] = "file"
              if NAMED_SOUND_FILES[SBFDB[fileVar]] then SBFDB[fileVar] = (SBF.DB_DEFAULTS and SBF.DB_DEFAULTS[fileVar]) or "" end
            else SBFDB[keys.mode] = "kit"; SBFDB[keys.id] = o.id end
            if play then play() end
          end)
      end
    end)
    local t = Theme.MakeButton(pBe, 46, "Test", function() if play then play() end end); t:SetHeight(20)
    return { dir = "row", align = "center",
      -- basis = shared check-column width so every dropdown starts at the same x (aligned table, left-packed)
      { check = { label = label, get = function() return SBFDB[keys.enable] end,
                  set = function(v) SBFDB[keys.enable] = v end, help = optHelp(key) }, basis = SOUND_CHECK_W },
      { frame = dd }, { frame = t },
    }
  end

  -- ---- the declarative tree (visual order top -> bottom) ----
  local tree = {
    gap = "section", pad = { t = 8, r = 10, b = 12, l = 4 },

    { section = "Interface options",
      { dir = "row",
        { check = C("Two-button mode (separate cast & loot)",
            function() return SBFDB.requireTwoButtons end,
            function(v)
              SBFDB.requireTwoButtons = v and true or nil
              if panel._refreshLootUI then panel._refreshLootUI() end
              if panel._refreshKeysPage then panel._refreshKeysPage() end
              if SBF.Apply then SBF.Apply() end
            end, "set.twoButton"), grow = 1 },
        { check = C("Enable controller (gamepad) support",
            function() return SBFDB.gamepadEnable and true or false end,
            function(v)
              SBFDB.gamepadEnable = v and true or false
              if v then
                local ok = pcall(SetCVar, "GamePadEnable", "1")
                print("|cff45c4a0SBF|r controller support " .. (ok and "enabled" or "couldn't set the CVar")
                  .. " — if controller buttons don't bind yet, |cffffd100/reload|r once. See |cffffd100/sbf controller|r.")
              end
              if panel._refreshKeysPage then panel._refreshKeysPage() end
            end, "set.gamepadEnable"), grow = 1, id = "gamepad" },
      },
      { dir = "row",
        { check = C("Use mouse (double-click)",
            function() return SBFDB.mouse.enabled end,
            function(v)
              SBFDB.mouse.enabled = v and true or false
              if refreshInterfaceOpts then refreshInterfaceOpts() end
              if panel._refreshKeysPage then panel._refreshKeysPage() end
              if SBF.MouseApply then SBF.MouseApply() end
            end, "set.useMouse"), id = "useMouse" },   -- no grow: the click-speed group sits grouped next to this checkbox
        { dir = "row", align = "center", id = "clickSpeed", hidden = not (SBFDB.mouse.enabled and true or false),
          { note = { text = "click speed:", color = "text" } }, { frame = mdf }, { note = { text = "sec", color = "text" } },
        },
      },
    },

    { section = "Fishing behavior",
      { check = C("Sit before each cast",
          function() return SBFDB.sitBeforeCast end, function(v) SBFDB.sitBeforeCast = v end, "set.sitBeforeCast"), id = "sit" },
      { check = C("Auto-dismount to fish  (never while flying)",
          function() return SBFDB.autoDismount end, function(v) SBFDB.autoDismount = v end, "set.autoDismount") },
      { dir = "row", align = "center",
        { note = { text = "Cast-fail back-off", color = "text",
                   onBuild = function(fs) helpLabel(fs, "set.castBackoff") end } },
        { frame = cbf }, { note = { text = "sec", color = "text" } },
      },
    },

    { section = "Item pickers",
      { dir = "row",
        { check = C("Show toys I don't own",
            function() return SBFDB.showUnownedToys ~= false end, function(v) SBFDB.showUnownedToys = v end, "set.showUnownedToys"), grow = 1 },
        { check = C("Show items not in my bags",
            function() return SBFDB.showUnownedItems ~= false end, function(v) SBFDB.showUnownedItems = v end, "set.showUnownedItems"), grow = 1 },
      },
      { check = C("Show Warband items",
          function() return SBFDB.showWarbandItems ~= false end, function(v) SBFDB.showWarbandItems = v end, "set.showWarbandItems") },
    },

    { section = "Optimizations",
      { check = C("Ultra fast loot  (grab everything instantly, no loot window)",
          function() return SBFDB.fastLoot end,
          function(v) SBFDB.fastLoot = v and true or false; if SBF.ApplyFastLoot then SBF.ApplyFastLoot() end end, "set.fastLoot") },
      { dir = "row",
        { check = C("Focus fishing",
            function() return SBFDB.focusAudio and SBFDB.focusAudio.enabled end,
            function(v) SBFDB.focusAudio = SBFDB.focusAudio or {}; SBFDB.focusAudio.enabled = v
              if not v and SBF.RestoreAudio then SBF.RestoreAudio() end
            end, "set.focusAudio") },   -- no grow: left-pack so the Audio-settings button sits next to the checkbox
        { frame = faBtn },
      },
      { check = C("Log gathered loot (chests & containers you open)",
          function() return SBFDB.gatherLoot ~= false end, function(v) SBFDB.gatherLoot = v and true or false end, "set.gatherLoot") },
    },

    { section = "Profile advanced mode",
      { check = C("Enable advanced mode",
          function() return SBFDB.advancedMode ~= false end,
          function(v) SBFDB.advancedMode = v
            if panel and panel._relaySimpleMode then panel._relaySimpleMode() end
            if refreshProfileToggles then refreshProfileToggles() end
            if SBF._welcomeRefreshAdvanced then SBF._welcomeRefreshAdvanced() end
          end, "set.advancedMode"), id = "adv" },
      { id = "advSub", hidden = (SBFDB.advancedMode == false),
        { check = C("Auto-swap profiles by location",
            function() return SBFDB.autoSwap ~= false end, function(v) SBFDB.autoSwap = v end, "set.autoSwap") },
        { check = C("Flash on profile swap",
            function() return SBFDB.swapFlash ~= false end, function(v) SBFDB.swapFlash = v end, "set.swapFlash") },
        { dir = "row", align = "center",
          { check = C("Auto-restore gear when idle",
              function() return SBFDB.idleRestoreEnabled end, function(v) SBFDB.idleRestoreEnabled = v end, "set.idleRestore") },   -- no grow: left-pack the "After [n] sec idle" group next to the checkbox
          { dir = "row", align = "center",
            { note = { text = "After", color = "text", onBuild = function(fs) helpLabel(fs, "set.idleRestore") end } },
            { frame = irf }, { note = { text = "sec idle", color = "text" } },
          },
        },
      },
    },

    { section = "Audio feedback",
      -- a SINGLE left-aligned column: all 5 sound rows stacked, each row left-packed (check with no grow,
      -- then dropdown + Test next to it). A half-width column couldn't fit a check+dropdown+Test row.
      soundRowSpec("Fishing start", { enable = "castSound", mode = "castSoundMode", id = "castSoundId" }, SBF.PlayCastSound, "set.castSound"),
      soundRowSpec("Cast fail", { enable = "castFailSound", mode = "castFailSoundMode", id = "castFailSoundId" }, SBF.PlayCastFailSound, "set.castFailSound"),
      soundRowSpec("No fish hooked", { enable = "noFishSound", mode = "noFishSoundMode", id = "noFishSoundId" }, SBF.PlayNoFishSound, "set.noFishSound"),
      soundRowSpec("Expired (ran full, no bite)", { enable = "expiredSound", mode = "expiredSoundMode", id = "expiredSoundId" }, SBF.PlayExpiredSound, "set.expiredSound"),
      soundRowSpec("Patiently Rewarded", { enable = "prSound", mode = "prSoundMode", id = "prSoundId" }, SBF.PlayPRSound, "set.prSound"),
    },

    { section = "Visuals",
      { dir = "row", align = "center",
        { note = { text = "Window opacity", color = "text", onBuild = function(fs) helpLabel(fs, "set.bgAlpha") end } },
        { frame = osl }, { note = { text = "0%", color = "textDim" }, id = "oval" }, { frame = rw },
      },
    },
  }

  -- (The dev-only "Debugging" section — debug log, decision trace, footing, mouse debug, theme preview —
  -- lives on the dev-only Debug tab, which is stripped from the public build.)

  root, refs = Theme.Layout(pBe, tree, { setParentHeight = true, settle = pBe })
  oVal = refs.oval
  oshow(SBFDB.bgAlpha or 0.94)
  SBF._sitCheck = refs.sit
  -- SBF._footingCheck is set from the dev-only Debug tab (stripped from the public build), so it stays nil here.

  -- conditional groups: toggle a box's node.hidden then relayout so siblings re-stack (replaces the old
  -- per-widget SetShown bookkeeping). refs.<id> for a container is its Box handle.
  local function setHidden(box, hidden) if box and box.node then box.node.hidden = hidden and true or false end end
  refreshInterfaceOpts = function()
    local on = SBFDB.mouse.enabled and true or false
    setHidden(refs.clickSpeed, not on)
    if on then mdf:SetText(string.format("%.2f", SBFDB.mouse.doubleSec or 0.4)) end
    if root then root:Invalidate() end
  end
  refreshProfileToggles = function()
    setHidden(refs.advSub, SBFDB.advancedMode == false)
    if root then root:Invalidate() end
  end

  -- external refresh hooks (the Welcome panel flips these settings and calls these so an OPEN Settings
  -- window updates live). Re-check the boxes from their live values, then re-run the show/hide.
  panel._refreshInputChecks = function()
    if refs.useMouse then refs.useMouse:SetChecked(SBFDB.mouse and SBFDB.mouse.enabled and true or false) end
    if refs.gamepad then refs.gamepad:SetChecked(SBFDB.gamepadEnable and true or false) end
    refreshInterfaceOpts()
  end
  panel._refreshAdvancedMode = function()
    if refs.adv then refs.adv:SetChecked(SBFDB.advancedMode ~= false) end
    refreshProfileToggles()
  end

  -- ===== window min-size (Settings page) =====
  panel._settingsMin = { w = 560, h = 300 }   -- Settings-page derived floor (filled by _applyMinWidth)
  -- Apply the window's resize floor as the MAX of the Settings-page min and the Buttons-page min, on BOTH
  -- axes — so neither page can be shrunk to where its content overflows. Grows the window if it's smaller.
  function panel._applyWindowMin()
    if SBFDB and SBFDB.collapsed then return end   -- no-op while collapsed (see the Buttons-page note)
    local bm = panel._buttonsMin or { w = 0, h = 0 }
    local sm = panel._settingsMin or { w = 560, h = 300 }
    local wMin = math.max(sm.w or 560, bm.w or 0)
    local hMin = math.max(sm.h or 300, bm.h or 0)
    if panel.SetResizeBounds then panel:SetResizeBounds(wMin, hMin)
    elseif panel.SetMinResize then panel:SetMinResize(wMin, hMin) end
    if (panel:GetWidth() or 0) < wMin then panel:SetWidth(wMin) end
    if (panel:GetHeight() or 0) < hMin then panel:SetHeight(hMin) end
  end
  -- WIDTH from the box tree's bubbled MinWidth (widest label that can't wrap smaller) + panel insets +
  -- scrollbar (42), floored at 560. HEIGHT stays a FIXED 300 floor: this page is a SCROLL CHILD that
  -- deliberately overflows, so we must NOT derive height from content. Folds into _applyWindowMin.
  panel._applyMinWidth = function()
    local wMin = math.max(560, math.ceil((root and root:MinWidth() or 0) + 42))
    panel._settingsMin = { w = wMin, h = 300 }
    panel._applyWindowMin()
  end
  panel._colReflow = function() if root then root:Layout() end end   -- back-compat: relayout the page

  -- initial layout + lock in the min-size
  root:Layout()
  panel._applyMinWidth()


  -- ===== PAGE: Log (every cast outcome, newest first; live) =====
  local pLog = pages.log
  local logHead = pLog:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  logHead:SetPoint("TOPLEFT", 4, -2); logHead:SetText(Theme.Accent("Fishing log"))
  -- No "Clear log" button by design: the log is the raw history and stays non-destructive — it is NEVER
  -- trimmed (the field below only caps how many recent lines are DISPLAYED). "Reset stats" starts the Stats
  -- fresh WITHOUT touching this log. (Matches Haul, which also has no log-delete.)
  -- saved-line count (updated by RefreshLog) + an editable history cap. The "show actions" filter is
  -- now a chip inside the GECStoreView widget (action chip replaces the old standalone checkbox).
  local logCountLbl = pLog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  logCountLbl:SetPoint("TOPRIGHT", -8, 0); logCountLbl:SetJustifyH("RIGHT")
  logCountLbl:SetText(#SBF.FishLog() .. " logged")
  local logMaxEb = CreateFrame("EditBox", nil, pLog, "InputBoxTemplate")
  logMaxEb:SetSize(46, 18); logMaxEb:SetAutoFocus(false); logMaxEb:SetNumeric(true); Theme.EditBox(logMaxEb)
  logMaxEb:SetPoint("RIGHT", logCountLbl, "LEFT", -8, 0); logMaxEb:SetText(tostring(SBFDB.fishlogMax or 150))
  local logMaxLbl = pLog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  logMaxLbl:SetPoint("RIGHT", logMaxEb, "LEFT", -4, 0); logMaxLbl:SetText("show")
  local function commitLogMax(s)
    local n = tonumber(s:GetText())
    if n and n >= 1 then
      SBFDB.fishlogMax = math.floor(n)
      if SBF.RefreshLog then SBF.RefreshLog() end   -- DISPLAY cap only; the raw log is never trimmed
    end
    s:SetText(tostring(SBFDB.fishlogMax or 150))
  end
  logMaxEb:SetScript("OnEnterPressed", function(s) commitLogMax(s); s:ClearFocus() end)
  logMaxEb:SetScript("OnEditFocusLost", commitLogMax)
  logMaxEb:SetScript("OnEscapePressed", function(s) commitLogMax(s); s:ClearFocus() end)
  logMaxEb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Lines to show")
    GameTooltip:AddLine("How many of the most recent log lines to DISPLAY. The full log is always kept (never trimmed). Default 150.", 1, 1, 1, true); GameTooltip:Show()
  end)
  logMaxEb:SetScript("OnLeave", GameTooltip_Hide)
  -- Shared log-viewer widget: chip row (per-kind show/hide) + scrolling text body. The `action` chip
  -- replaces the old standalone "show actions" checkbox; persistence is via SBFDB.logActions.
  -- semantic per-outcome colors (carry meaning -> kept as-is); only `buff` follows the theme accent.
  -- `buff` is the Midnight "a special chest dropped" NOTIFICATION (the Patiently-Rewarded watcher) — labeled
  -- CHEST. Its stored kind stays "buff" for back-compat (old entries still render). `gathered` = container /
  -- GameObject loot opened outside a fishing channel (chests, fished-up openables); olive, distinct from all.
  local KIND_COLOR = { caught = "33ff33", expired = "aaaaaa", missed = "ffaa44", interrupt = "ff6060", castfail = "ff8844", action = "7fb0e6", buff = "ffcf40", skill = "d0a0ff", gathered = "c0d860",   -- skill = Haul's lavender
    start = "45c4a0", stop = "ff6060", pause = "ffaa44", resume = "45c4a0", fold = "c080ff", include = "808080", exclude = "a0a0a0" }   -- session lifecycle markers
  local KIND_LABEL = { caught = "CAUGHT", expired = "expired", missed = "MISSED", interrupt = "interrupt", castfail = "cast-fail", action = "", buff = "CHEST", skill = "SKILL UP", gathered = "GATHERED",
    start = "start", stop = "stop", pause = "pause", resume = "resume", fold = "fold", include = "incl", exclude = "excl" }
  local GSV = LibStub("GECStoreView-1.0")
  local SBF_KINDS = {}
  for k, lab in pairs(KIND_LABEL) do SBF_KINDS[k] = { label = lab, color = KIND_COLOR[k] or "ffffff" } end
  local function sbfDetail(e)
    local s = ""
    if (e.k == "caught" or e.k == "gathered") and (e.items or e.link or e.name) then
      local function one(fi)   -- quality-colored link (else plain name) + xN when stacked
        local item = (fi.link and GSV.ColorItemLink(fi.link)) or ("|cffffffff" .. (fi.name or "?") .. "|r")
        return item .. ((fi.count and fi.count > 1) and (" x" .. fi.count) or "")
      end
      if e.items then                                  -- multi-item catch: list every item the cast landed
        local parts = {}
        for i = 1, #e.items do parts[i] = one(e.items[i]) end
        s = table.concat(parts, ", ")
      else
        s = one(e)                                     -- single item (e carries id/name/link/count)
      end
    elseif e.k == "buff" and e.name then
      s = "|cffffcf40" .. "chest drop|r |cff808080(" .. e.name .. ")|r"   -- Midnight special-chest notification (Patiently Rewarded)
    elseif e.k == "action" and e.spell then
      s = "|cff7fb0e6" .. e.spell .. "|r"             -- the action that fired (B2)
    elseif e.k == "interrupt" and e.cause then
      local nice = e.cause == "moving" and "movement" or e.cause   -- combat / movement / jump / unknown
      s = "|cffff6060(" .. nice .. ")|r"               -- WHY the cast was cut short
    elseif e.k == "skill" then
      -- Haul's skill-up color (d0a0ff lavender). Plain "to <level>" — the old ▲ glyph (\226\150\178) isn't
      -- in WoW's font, so it rendered as a tofu box.
      s = "|cffd0a0ff" .. (e.name or "Fishing") .. (e.lvl and (" to " .. e.lvl) or "") .. "|r"
    end
    if e.dur then s = s .. string.format("  |cff88cc88%.1fs|r", e.dur) end   -- channel time; for a catch = cast -> loot
    return s
  end
  -- per-kind tally line (Haul-style summary). The richer per-fish catch breakdown is a future tab.
  local SBF_SUMMARY_ORDER = { "caught", "gathered", "expired", "missed", "interrupt", "castfail", "action", "buff", "skill" }
  local function sbfSummary()
    local log, n = SBF.FishLog(), {}
    for i = 1, #log do local k = log[i].k; n[k] = (n[k] or 0) + 1 end
    local parts = {}
    for _, k in ipairs(SBF_SUMMARY_ORDER) do
      if n[k] then
        local word = (KIND_LABEL[k] and KIND_LABEL[k] ~= "" and KIND_LABEL[k]:lower()) or k   -- "buff" -> "chest"
        parts[#parts + 1] = "|cff" .. (KIND_COLOR[k] or "ffffff") .. n[k] .. "|r " .. word
      end
    end
    return #parts > 0 and table.concat(parts, " · ") or "no entries"
  end
  -- ===== Columnar log: declarative columns rendered via GECStoreView -> Theme.AccordionList =====
  -- Standard column set: Time · Character · Kind · Item(flex, icon+link) · Count · Cast · Sub-zone · Location.
  -- Haul uses the SAME component with its own column list (kept consistent in style, different in content).
  local logStore = LibStub("GECStore-1.0")
  -- Column colors mirror the old text log (time gray, sub-zone blue, location gray, cast green); the
  -- character + kind + item cells carry their own inline |cff (class / per-kind / item-quality), which wins
  -- over the column base color. NO flex column: every column auto-sizes to its content and packs left, so
  -- the table only extends as far right as the columns need (no stretching to the window edge).
  local SBF_LOG_COLUMNS = {
    { key = "time",    align = "LEFT",  max = 64,  color = "808080" },
    { key = "char",    align = "LEFT",  max = 96 },                            -- class-colored inline
    { key = "kind",    align = "LEFT",  max = 74 },                            -- per-kind color inline
    { key = "item",    align = "LEFT",  max = 240 },                           -- item link (inline quality color)
    { key = "count",   align = "RIGHT", max = 48,  color = "ffd97f", optional = true },
    { key = "cast",    align = "RIGHT", max = 54,  color = "88cc88", optional = true },   -- the timer
    { key = "subzone", align = "LEFT",  max = 130, color = "66ccff", optional = true },
    { key = "loc",     align = "RIGHT", max = 130, color = "808080", optional = true },
  }
  local function logKindCell(rec)
    local lab = KIND_LABEL[rec.k]; if not lab or lab == "" then lab = rec.k or "" end
    return "|cff" .. (KIND_COLOR[rec.k] or "ffffff") .. lab .. "|r"
  end
  local function logCharCell(rec)
    local info = rec.ch and logStore.CharInfo and logStore.CharInfo(rec.ch)
    if not info then return (rec.ch and ("char " .. rec.ch)) or "" end
    local cc = RAID_CLASS_COLORS and info.class and RAID_CLASS_COLORS[info.class]
    return "|c" .. ((cc and cc.colorStr) or "ffcccccc") .. (info.name or "?") .. "|r"
  end
  local function logSubzoneCell(rec)
    local casc = rec.p and logStore.PlaceInfo and logStore.PlaceInfo(rec.p)
    return (casc and #casc > 0 and casc[#casc].name) or ""
  end
  local function logLocCell(rec)
    local s = (rec.x and rec.y) and string.format("%.1f, %.1f", rec.x, rec.y) or ""
    if rec.h then s = (s ~= "" and (s .. " \194\183 ") or "") .. rec.h .. "\194\176" end   -- " · 270°"
    return s
  end
  -- One record -> one or more rows. A multi-item catch expands to one row per DISTINCT item (identical
  -- items merge, summing count). Non-catch rows put their kind-detail in the Item column.
  -- DEV row tooltip (SBF.IsDev only): dump a log record's FULL raw data set on hover, so rows can be
  -- correlated by shared metadata (src.objID, ch, p, …) — the same aid Haul's Log tab gives. Nested tables
  -- (src, items) are expanded and indented. Non-dev users are unaffected (the row keeps its plain item tip).
  local function tipDump(tbl, indent)
    local keys = {}
    for kk in pairs(tbl) do keys[#keys + 1] = kk end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, kk in ipairs(keys) do
      local v = tbl[kk]
      if type(v) == "table" then
        GameTooltip:AddLine(indent .. tostring(kk) .. ":", 0.55, 0.75, 1)
        tipDump(v, indent .. "   ")
      else
        GameTooltip:AddDoubleLine(indent .. tostring(kk), tostring(v), 0.6, 0.6, 0.6, 1, 1, 1)
      end
    end
  end
  local function sbfLogRowTip(row, rec, link)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if link then GameTooltip:SetHyperlink(link)
    else GameTooltip:SetText("|cff66ccffevent: " .. tostring(rec.k or "?") .. "|r") end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff66ccfffull data set|r  |cff808080(dev)|r")
    tipDump(rec, "")
    GameTooltip:Show()
  end
  -- stamp the dev metadata tooltip onto every row of a record (only in dev mode). Each row keeps its own
  -- item link so the item tooltip still leads, with the data set appended below it.
  local function stampDevTip(rows, rec)
    if not (SBF.IsDev and SBF.IsDev()) then return rows end
    for _, r in ipairs(rows) do
      local link = r.link
      r.onEnter = function(rowFrame) sbfLogRowTip(rowFrame, rec, link) end
    end
    return rows
  end
  local function sbfLogRows(rec)
    local base = {
      time    = rec.t and date("%H:%M:%S", rec.t) or "",
      char    = logCharCell(rec),
      kind    = logKindCell(rec),
      cast    = rec.dur and string.format("%.1fs", rec.dur) or "",
      subzone = logSubzoneCell(rec),
      loc     = logLocCell(rec),
    }
    if rec.k == "caught" or rec.k == "gathered" then   -- both carry id/name/link/count(/items): one row per distinct item
      local list, order, byKey = rec.items or { rec }, {}, {}
      for _, fi in ipairs(list) do
        local key = fi.id or fi.link or fi.name or "?"
        if byKey[key] then byKey[key].count = (byKey[key].count or 1) + (fi.count or 1)
        else byKey[key] = { id = fi.id, link = fi.link, name = fi.name, count = fi.count or 1 }; order[#order + 1] = byKey[key] end
      end
      local rows = {}
      for _, fi in ipairs(order) do
        local rcols = { time = base.time, char = base.char, kind = base.kind, cast = base.cast, subzone = base.subzone, loc = base.loc }
        rcols.item  = (fi.link and GSV.ColorItemLink(fi.link)) or ("|cffffffff" .. (fi.name or ("item " .. tostring(fi.id or "?"))) .. "|r")
        rcols.count = (fi.count and fi.count > 0) and ("x" .. fi.count) or ""
        rows[#rows + 1] = { cols = rcols, link = fi.link }
      end
      if #rows == 0 then rows[1] = { cols = base } end
      return stampDevTip(rows, rec)
    end
    if rec.k == "action" and rec.spell then base.item = "|cff7fb0e6" .. rec.spell .. "|r"
    elseif rec.k == "buff" and rec.name then base.item = "|cffffcf40chest drop|r |cff808080(" .. rec.name .. ")|r"
    elseif rec.k == "interrupt" and rec.cause then
      base.item = "|cffff6060(" .. (rec.cause == "moving" and "movement" or rec.cause) .. ")|r"
    elseif rec.k == "castfail" and rec.cause then
      local nice = (rec.cause == "los" and "line of sight") or (rec.cause == "nowater" and "no fishable water")
        or (rec.cause == "shallow" and "too shallow") or rec.cause
      base.item = "|cffff8844(" .. nice .. ")|r"
    elseif rec.k == "skill" then
      -- Haul's skill color (d0a0ff); "to <level>" instead of the un-renderable ▲ glyph (tofu box).
      base.item = "|cffd0a0ff" .. (rec.name or "Fishing") .. (rec.lvl and (" to " .. rec.lvl) or "") .. "|r"
    -- session lifecycle markers (from streams.markers, merged into the log by stream() below)
    elseif rec.k == "start"  then base.item = "|cff45c4a0started run|r" .. (rec.who and ("  |cff808080" .. tostring(rec.who) .. "|r") or "")
    elseif rec.k == "stop"   then base.item = "|cffff6060stopped run|r" .. (rec.reason and ("  |cff808080(" .. rec.reason .. ")|r") or "")
    elseif rec.k == "pause"  then base.item = "|cffffaa44paused|r"
    elseif rec.k == "resume" then base.item = "|cff45c4a0resumed|r"
    elseif rec.k == "fold"   then base.item = "|cffc080fffolded in s" .. tostring(rec.fromsid or "?"):sub(-4) .. "|r" .. (rec.via and ("  |cff808080(" .. rec.via .. ")|r") or "")
    end
    return stampDevTip({ { cols = base } }, rec)
  end
  -- Plain-text search haystack for one record: kind label ("caught"/"skill up"/…), item/fish names,
  -- spell/buff name, fishing skill LEVEL (so "226" matches), interrupt cause, and the sub-zone. No color
  -- codes or item links — just the words, matched case-insensitively as a substring by GECStoreView.
  local function sbfSearchText(rec)
    local parts = {}
    local lab = KIND_LABEL[rec.k]
    parts[#parts + 1] = (lab and lab ~= "" and lab) or rec.k or ""
    if rec.k == "caught" or rec.k == "gathered" then
      local list = rec.items or { rec }
      for _, fi in ipairs(list) do if fi.name then parts[#parts + 1] = fi.name end end
    elseif rec.k == "action" and rec.spell then parts[#parts + 1] = rec.spell
    elseif rec.k == "buff" and rec.name then parts[#parts + 1] = rec.name
    elseif rec.k == "skill" then
      parts[#parts + 1] = rec.name or "Fishing"
      if rec.lvl then parts[#parts + 1] = tostring(rec.lvl) end
    elseif rec.k == "interrupt" and rec.cause then parts[#parts + 1] = rec.cause
    end
    local sz = logSubzoneCell(rec); if sz ~= "" then parts[#parts + 1] = sz end
    return table.concat(parts, " ")
  end
  -- Kept as a NAMED opts table (not an inline literal) so the "show" field can update maxLines live — the
  -- lib reads opts.maxLines fresh on each Refresh. (dot-call: Create is a plain function, not a method.)
  local logViewOpts = {
    stream           = function()
      -- merge the fishing events with the session lifecycle MARKERS (streams.markers) into ONE chronological
      -- list, so start/stop/pause/resume/fold show inline with catches. STABLE sort by t: time() is 1-second
      -- resolution, so a stop + the next start can share a timestamp; the markers stream is appended in TRUE
      -- order, so same-second entries keep it (an unstable sort would scramble start-before-stop). Record +
      -- server are unaffected — Resolve reads stream order, never a t-sort; display-only.
      local ev = SBF.FishLog()
      local mk = (SBFData and SBFData.streams and SBFData.streams.markers) or {}
      local out = {}
      for i = 1, #ev do out[#out + 1] = ev[i] end
      for i = 1, #mk do out[#out + 1] = mk[i] end
      local ord = {}
      for i = 1, #out do ord[i] = i end
      table.sort(ord, function(a, b)
        local ta, tb = out[a].t or 0, out[b].t or 0
        if ta ~= tb then return ta < tb end
        return a < b
      end)
      local sorted = {}
      for i = 1, #ord do sorted[i] = out[ord[i]] end
      return sorted
    end,
    kinds            = SBF_KINDS,
    columns          = SBF_LOG_COLUMNS,
    toRows           = sbfLogRows,
    theme            = Theme,
    formatDetail     = sbfDetail,   -- (text-mode fallback; unused while columns are set)
    summary          = sbfSummary,
    hidden           = function() return { action = (SBFDB.logActions == false) } end,
    onToggleKind     = function(k, isHidden) if k == "action" then SBFDB.logActions = not isHidden end end,
    maxLines         = tonumber(SBFDB.fishlogMax) or 150,   -- DISPLAY cap only; the raw log is never trimmed
    searchText       = sbfSearchText,                       -- enables the Log-tab search bar (whole-log)
    searchMode       = function() return SBFDB.logSearchMode or "highlight" end,
    onSearchMode     = function(m) SBFDB.logSearchMode = m end,
  }
  local logView = LibStub("GECStoreView-1.0").Create(pLog, logViewOpts)
  logView.frame:SetPoint("TOPLEFT", 0, -26); logView.frame:SetPoint("BOTTOMRIGHT", 0, 0)
  function SBF.RefreshLog()
    if not (pLog and pLog:IsShown()) then return end
    logViewOpts.maxLines = tonumber(SBFDB.fishlogMax) or 150   -- re-read the display cap each refresh
    logView:Refresh()
    logCountLbl:SetText(#SBF.FishLog() .. " logged")            -- total kept (the raw log is never trimmed)
  end

  -- ===== PAGE: Stats (permanent rollup + on-the-fly period views; reuses the Log tab's KIND_COLOR + GSV) =====
  -- The Stats page is fully DATA-DRIVEN: every period/segment/sort/expand change rebuilds the body top->bottom.
  -- To avoid create-per-refresh GC churn we acquire from small per-type widget pools (fontstrings, bar textures,
  -- skinned buttons, and bare hit-area buttons), then hide the surplus after each pass. Everything lives in one
  -- scroll child so headline + lists scroll together when the (resizable) window is short.
  -- Wrapped in an immediately-invoked nested function: WoW Lua caps a single function at 200 locals and Build()
  -- is huge, so the Stats page gets its OWN scope — its ~40 locals no longer count against Build()'s tally.
  -- It closes over pages / attachPageScroll / GSV / KIND_COLOR (Build upvalues); SBF.RefreshStats stays global.
  local function buildStatsPage()
  local pStats = pages.stats
  local statsChild = attachPageScroll(pStats, 470, 1)   -- height is set per-render from the laid-out content
  -- runtime view state (NOT persisted): All-time is always the default on (re)build, per the design.
  local statsPeriod, statsSeg, statsFishSort = "all", "fish", "count"
  local statsZoneOpen = {}                                -- [zoneKey] = true while a zone row is expanded
  -- character FILTER row — a multi-select dropdown pinned at the TOP of the page, modeled on the Log tab's
  -- GECStoreView character filter (same WowStyle1 dropdown, Select all / Select none, a checkbox per char
  -- with the CURRENT character pinned topmost; checked = SHOWN). Created ONCE here (the body below is a
  -- pooled top->bottom rebuild, so these persistent widgets must live OUTSIDE the pools). Selection is a
  -- HIDDEN-set (matching GECStoreView): empty = all shown; all-hidden = none shown (a representable empty
  -- state — a pure shown-set couldn't express "none"). The filter applies on TOP of every period/segment.
  local statsGECStore = LibStub("GECStore-1.0")
  local statsCharHidden = {}                              -- [ch] = true means HIDDEN; empty = all characters shown
  local charLbl = statsChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  charLbl:SetPoint("TOPLEFT", 6, -4); charLbl:SetText(Theme.Accent("Character"))
  -- resolve a ch index to a display name via the GECStore registry; falls back to "char N" before its
  -- identity is interned.
  local function charLabel(ch)
    local info = statsGECStore.CharInfo and statsGECStore.CharInfo(ch)
    return (info and info.name) or ("char " .. tostring(ch))
  end
  -- ordered { value=ch, text=name } option list: the CURRENT character first, the rest sorted after.
  local function charOptions()
    local cur = statsGECStore.CharIndex and statsGECStore.CharIndex()
    local order, seen = {}, {}
    if cur then order[#order + 1] = cur; seen[cur] = true end
    local rest = {}
    for _, ch in ipairs((SBF.Stats and SBF.Stats.CharList()) or {}) do
      if not seen[ch] then seen[ch] = true; rest[#rest + 1] = ch end
    end
    table.sort(rest)
    for _, ch in ipairs(rest) do order[#order + 1] = ch end
    local out = {}
    for _, ch in ipairs(order) do out[#out + 1] = { value = ch, text = charLabel(ch) } end
    return out
  end
  -- button summary: "All characters" (all shown) / "No characters" (none) / "<name>" (exactly one) / "N characters".
  local function charDDText()
    local o = charOptions()
    local shown, lastShown = 0, nil
    for _, it in ipairs(o) do if not statsCharHidden[it.value] then shown = shown + 1; lastShown = it.text end end
    if shown == #o then return "All characters" end
    if shown == 0 then return "No characters" end
    if shown == 1 then return lastShown end
    return shown .. " characters"
  end
  local statsCharDD = CreateFrame("DropdownButton", nil, statsChild, "WowStyle1DropdownTemplate")
  Theme.SkinDropdown(statsCharDD)
  statsCharDD:SetSize(170, 22)
  statsCharDD:SetPoint("LEFT", charLbl, "RIGHT", 8, 0)
  statsCharDD:SetDefaultText(charDDText())
  statsCharDD:SetupMenu(function(_dd, menu)
    local o = charOptions()
    menu:CreateButton("Select all", function()
      wipe(statsCharHidden)                                -- empty hidden-set = every character shown
      statsCharDD:SetDefaultText(charDDText()); SBF.RefreshStats(); statsCharDD:GenerateMenu()
      return MenuResponse and MenuResponse.Refresh
    end)
    menu:CreateButton("Select none", function()
      for _, it in ipairs(o) do statsCharHidden[it.value] = true end
      statsCharDD:SetDefaultText(charDDText()); SBF.RefreshStats(); statsCharDD:GenerateMenu()
      return MenuResponse and MenuResponse.Refresh
    end)
    menu:CreateDivider()
    for _, it in ipairs(o) do
      local v = it.value
      menu:CreateCheckbox(it.text,
        function() return not statsCharHidden[v] end,      -- checked = shown
        function()
          statsCharHidden[v] = (not statsCharHidden[v]) or nil   -- toggle shown <-> hidden
          statsCharDD:SetDefaultText(charDDText()); SBF.RefreshStats(); statsCharDD:GenerateMenu()
        end)
    end
  end)
  -- refresh the button summary as new characters appear / selection changes (called from RefreshStats).
  local function refreshCharDD() statsCharDD:SetDefaultText(charDDText()) end
  -- whole-element tooltip on the (persistent) character dropdown — set once at build.
  statsCharDD:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Character filter")
    GameTooltip:AddLine("Show stats for one or more characters. All-time merges the selected characters; uncheck to exclude. Your current character is pinned on top.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  statsCharDD:HookScript("OnLeave", GameTooltip_Hide)
  -- auto-refresh lifecycle. "live" redraws on each logged event (driven from Core.logFishEvent); a numeric
  -- mode runs a repeating timer WHILE the page is shown; "off" = manual only. Armed on page-show and on a
  -- mode change, cancelled on hide — so it never ticks against a closed window.
  local statsTicker
  local function stopStatsTicker() if statsTicker then statsTicker:Cancel(); statsTicker = nil end end
  local function startStatsTicker()
    stopStatsTicker()
    local secs = tonumber(SBFDB.statsRefresh)             -- nil for "live"/"off"
    if secs and pStats:IsShown() then statsTicker = C_Timer.NewTicker(secs, function() SBF.RefreshStats() end) end
  end
  pStats:HookScript("OnShow", startStatsTicker)
  pStats:HookScript("OnHide", stopStatsTicker)
  -- widget pools + their per-render cursors
  local statsFS, statsTex, statsBtn, statsHit, statsTip = {}, {}, {}, {}, {}
  local fsN, texN, btnN, hitN, tipN = 0, 0, 0, 0, 0
  local function fsAcquire(template)
    template = template or "GameFontHighlight"
    fsN = fsN + 1
    local fs = statsFS[fsN]
    if not fs then fs = statsChild:CreateFontString(nil, "ARTWORK", template); statsFS[fsN] = fs end
    fs:SetFontObject(template)                            -- also resets color to the template default (cleans a pooled reuse)
    fs:ClearAllPoints(); fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP"); fs:SetWordWrap(false); fs:SetWidth(0); fs:Show()
    return fs
  end
  local function texAcquire()
    texN = texN + 1
    local t = statsTex[texN]
    if not t then t = statsChild:CreateTexture(nil, "ARTWORK"); statsTex[texN] = t end
    t:ClearAllPoints(); t:Show(); return t
  end
  local function btnAcquire(w, text)                       -- skinned (visible) button — chips / segments / reset
    btnN = btnN + 1
    local b = statsBtn[btnN]
    if not b then b = CreateFrame("Button", nil, statsChild, "UIPanelButtonTemplate"); Theme.Button(b); statsBtn[btnN] = b end
    b:SetSize(w, 22); b:SetText(text or ""); b:ClearAllPoints(); b:SetScript("OnClick", nil); b:SetScript("OnEnter", nil); b:SetScript("OnLeave", nil); b:Enable()
    if b._jgPaint then b._jgPaint() end   -- reset to the NORMAL navy fill + text every acquire (clears a prior render's active fill); toggles re-paint active after
    b:Show()
    return b
  end
  -- Active/selected paint for the segmented toggles (period chips, By fish/zone, sort). The ACTIVE one
  -- INVERTS — filled with the theme accent + dark text — so the current selection is unmistakable; the old
  -- accent-text-only cue was far too subtle. Called AFTER btnAcquire (which resets to normal via _jgPaint),
  -- so the active fill wins. Inactive buttons keep the normal navy fill/text from that reset.
  local TOGGLE_ON_TEXT = { 0.05, 0.06, 0.09 }   -- near-black: reads cleanly on the bright accent fill
  local function paintToggle(b, active)
    if active and b._jgbg then
      local r, g, bl = Theme.HexToRGB(Theme.accentHex)
      b._jgbg:SetBackdropColor(r, g, bl, 0.92)                       -- filled accent background
      b._jgbg:SetBackdropBorderColor(r, g, bl, 1)
      local fs = b.GetFontString and b:GetFontString()
      if fs then fs:SetTextColor(unpack(TOGGLE_ON_TEXT)) end          -- dark label on the bright fill
    end
  end
  local function hitAcquire(w, h)                           -- bare transparent click target (zone-row expander)
    hitN = hitN + 1
    local b = statsHit[hitN]
    if not b then b = CreateFrame("Button", nil, statsChild); statsHit[hitN] = b end
    b:SetSize(w, h); b:ClearAllPoints(); b:SetScript("OnClick", nil); b:Show(); return b
  end
  -- pooled mouseover hit-area for whole-element tooltips (covers a number+label rect, a header, a row). Per
  -- project rule the hover target spans the whole element, not a tiny box. title/body captured per acquire.
  local function tipAcquire(w, h, title, body)
    tipN = tipN + 1
    local t = statsTip[tipN]
    if not t then t = CreateFrame("Frame", nil, statsChild); t:EnableMouse(true); statsTip[tipN] = t end
    t:SetSize(w, h); t:ClearAllPoints()
    t:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(title)
      if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", GameTooltip_Hide)
    t:Show(); return t
  end
  -- pooled ITEM-tooltip hover: covers a fish-name row and shows the real item tooltip (raw link preferred,
  -- itemID fallback). Reuses the statsTip pool so it's rewound/hidden with the rest. This is what puts a
  -- tooltip on every fish NAME in the By-fish list and the expanded By-zone rows.
  local function itemTipAcquire(w, h, link, id)
    tipN = tipN + 1
    local t = statsTip[tipN]
    if not t then t = CreateFrame("Frame", nil, statsChild); t:EnableMouse(true); statsTip[tipN] = t end
    t:SetSize(w, h); t:ClearAllPoints()
    t:SetScript("OnEnter", function(self)
      if not (link or id) then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetItemByID(id) end
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", GameTooltip_Hide)
    t:Show(); return t
  end
  -- attach a whole-element tooltip directly to a pooled (non-protected) button — chips / segments / sort /
  -- reset. Safe: these aren't secure/protected frames, so script hooks can't taint a click here.
  local function setBtnTip(b, title, body)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(title)
      if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
  end
  -- tooltip text (title, body) for the Stats-page controls. Defined once; keyed for lookup in the render.
  local PERIOD_TIP = {
    all     = { "All-time", "Your permanent totals — kept across every session and never lost (the log is never deleted). Resets only via the Reset button." },
    session = { "This session", "Activity since the current session started (start a new session to re-baseline it; kept across /reload). Computed live from the fishing log." },
    today   = { "Today", "Activity since local midnight, across all of today's logins. Computed live from the fishing log (back as far as the log buffer holds)." },
  }
  local HEADLINE_TIP = {
    ["fish"]        = { "Fish caught", "Total items caught — a single cast can land several, and every item counts (gray junk included)." },
    ["casts"]       = { "Casts", "Fishing attempts that hit the water: caught + expired + missed + interrupted. Cast-fails (never started) aren't counted." },
    ["avg cast"]    = { "Average cast time", "Average line-in-water time per cast (time fished ÷ casts) — how long a cast runs before it resolves, on average." },
    ["catch rate"]  = { "Catch rate", "Casts that landed a catch ÷ total casts. Always 100% or less." },
    ["time fished"] = { "Time fished", "Actual line-in-water time: the sum of every cast's channel length (cast → catch or expire). This is NOT how long you've been logged in — looting, travel, and the gaps between casts are not counted." },
    ["fish / hr"]   = { "Fish per hour", "Total fish ÷ time fished (line-in-water hours), so it reflects your fishing rate, not wall-clock time." },
  }
  -- Sort-toggle tooltips. Worded to read in BOTH the By-fish list and the By-zone view (it reorders the zones and
  -- the fish inside an expanded zone the same way), so "caught" here means total items.
  local SORT_TIP = {
    count   = { "Sort by count", "Most caught first (by total items)." },
    name    = { "Sort by name", "Alphabetical." },
    recent  = { "Sort by recent", "Most recent first." },
    quality = { "Sort by quality", "Best quality first (Epic → … → gray)." },
  }
  -- the confirm popup's accept handler (file-scoped dialog -> this closure): reset, then re-render. Never logs.
  SBF._statsResetPopup.onReset = function() if SBF.Stats then SBF.Stats.Reset() end; if SBF.RefreshStats then SBF.RefreshStats() end end
  -- small formatters
  local function fmtDur(s)
    s = math.floor((s or 0) + 0.5)
    if s <= 0 then return "0m" end
    local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m" end
    return s .. "s"
  end
  local function localMidnight() local d = date("*t"); d.hour, d.min, d.sec = 0, 0, 0; return time(d) end
  -- Item quality (0 = Poor/gray … 4 = Epic …). The LIVE read is authoritative whenever the item is cached
  -- (GetItemInfo returns nil only when not yet loaded), so we read it FIRST and HEAL the stored value back
  -- onto the rollup item. Early captures could persist a bad 0 (a cache race at loot time), which would
  -- otherwise pin a white catch like Ambiguous Rock (quality 1) into the Vendor-trash bucket forever — this
  -- self-repairs it on the next render. Only when the item is uncached do we trust the last-known stored q;
  -- nil => unknown => list it individually (NEVER treated as trash). Deliberately NOT C_Item.GetItemQualityByID
  -- (it reports 0/Poor for uncached items — the original cause of the vanished white entries).
  local function itemQuality(id, it)
    local q = select(3, GetItemInfo((it and it.link) or id))
    if q ~= nil then if it then it.q = q end return q end         -- live read: authoritative, heals the stored value
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end   -- uncached: async warm; regroups on a later refresh
    -- Uncached fallback: trust a stored NON-zero quality, but NEVER a stored 0 — a captured 0 can be a cache
    -- race at loot time, and trusting it would keep a white catch (e.g. Ambiguous Rock) hidden in Vendor trash
    -- until the item happens to cache. An unknown/suspect-zero lists individually (worst case: a gray shows on
    -- its own for a moment until its real quality loads, which is far better than hiding a real fish).
    if it and it.q and it.q > 0 then return it.q end
    return nil
  end
  -- A catch row's share of its own group, as a dimmed "(xx%)" prefix sitting just left of the count. Denominator
  -- is the group total (whole By-fish list, or one zone's items). Integer percent rounded to nearest; a non-zero
  -- count that rounds to 0 shows "(<1%)" so it never reads as a misleading "0%". Empty when the group is empty.
  local function pctTag(n, denom)
    if not denom or denom <= 0 then return "" end
    local p = math.floor((n / denom) * 100 + 0.5)
    local txt = (p == 0 and n > 0) and "(<1%)" or ("(" .. p .. "%)")
    return "|cff808080" .. txt .. "|r "
  end

  function SBF.RefreshStats()
    if not (pStats and pStats:IsShown()) then return end
    fsN, texN, btnN, hitN, tipN = 0, 0, 0, 0, 0      -- rewind every pool; surplus widgets are hidden at the end
    local W = statsChild:GetWidth(); if W < 10 then W = 470 end
    local PAD = 6
    refreshCharDD()                         -- keep the filter button summary current as new characters appear (cheap)
    local y = -32                           -- running TOP cursor (negative = downward); starts BELOW the fixed character-filter row
    -- resolve the SHOWN set for the data layer: nil when every known char is shown (full-history top-level
    -- rollup), else a {[ch]=true} set of the shown chars (merged per-char slices; an empty set = none shown).
    local chSet = nil
    do
      local o = charOptions()
      local anyHidden = false
      for _, it in ipairs(o) do if statsCharHidden[it.value] then anyHidden = true; break end end
      if anyHidden then
        chSet = {}
        for _, it in ipairs(o) do if not statsCharHidden[it.value] then chSet[it.value] = true end end
      end
    end
    local roll = (SBF.Stats and SBF.Stats.GetSet(statsPeriod, chSet)) or { kinds = {}, items = {}, zones = {} }
    local kc = roll.kinds or {}

    -- 1) period chips ------------------------------------------------------------------------------------
    local periods = { { "all", "All-time" }, { "session", "This session" }, { "today", "Today" } }
    local px = PAD
    for _, pr in ipairs(periods) do
      local key, lab = pr[1], pr[2]
      local b = btnAcquire(98, lab)
      b:SetPoint("TOPLEFT", px, y)
      paintToggle(b, statsPeriod == key)
      b:SetScript("OnClick", function() statsPeriod = key; SBF.RefreshStats() end)
      local pt = PERIOD_TIP[key]; if pt then setBtnTip(b, pt[1], pt[2]) end
      px = px + 102
    end
    y = y - 26
    -- covered-span subtext
    local span = fsAcquire("GameFontHighlightSmall"); span:SetPoint("TOPLEFT", PAD, y)
    local spanText
    if statsPeriod == "all" then
      spanText = roll.firstT and ("since " .. date("%m/%d/%y", roll.firstT)) or "no activity recorded yet"
    elseif statsPeriod == "session" then
      spanText = "this session (since it started)"
      -- show the OPEN session's id so you can tell which session these live numbers belong to (you can
      -- start a new one via the GEC-Console SBF.Session.new button; the id changes when you do).
      local S = SBF.Session and SBF.Session()
      local sid = S and S.Sid and S:Sid()
      if sid then spanText = spanText .. "   |cff808080session " .. tostring(sid) .. "|r" end
    else
      spanText = "since midnight"
      if roll.firstT and roll.firstT > localMidnight() + 60 then
        spanText = spanText .. " — earliest shown " .. date("%H:%M", roll.firstT) .. " (log buffer starts later)"
      end
    end
    span:SetText(spanText); Theme.Font(span, "textDim")
    y = y - 18

    -- 2) headline row ------------------------------------------------------------------------------------
    local successCasts = kc.caught or 0                                               -- casts that landed a catch (per-cast)
    local casts = (kc.caught or 0) + (kc.expired or 0) + (kc.missed or 0) + (kc.interrupt or 0)   -- a "cast" = line hit the water
    local totalFish = 0
    for _, it in pairs(roll.items or {}) do totalFish = totalFish + (it.n or 0) end   -- ITEM total (a cast can land several)
    local rate = casts > 0 and string.format("%d%%", math.floor(successCasts / casts * 100 + 0.5)) or "—"   -- cast-based, stays <=100%
    local secs = roll.totalDur or 0
    local avgCast = casts > 0 and string.format("%.1fs", secs / casts) or "—"   -- average line-in-water time per cast
    local fph = secs > 0 and string.format("%.1f", totalFish / (secs / 3600)) or "—"
    local blocks = {
      { tostring(totalFish), "fish" }, { tostring(casts), "casts" }, { avgCast, "avg cast" },
      { rate, "catch rate" }, { fmtDur(secs), "time fished" }, { fph, "fish / hr" },
    }
    local bw = math.max(76, (W - PAD * 2) / #blocks)
    for i, b in ipairs(blocks) do
      local bx = PAD + (i - 1) * bw
      local num = fsAcquire("GameFontNormalLarge"); num:SetPoint("TOPLEFT", bx, y); num:SetWidth(bw); num:SetJustifyH("CENTER"); num:SetText(Theme.Accent(b[1]))
      local lab = fsAcquire("GameFontHighlightSmall"); lab:SetPoint("TOPLEFT", bx, y - 22); lab:SetWidth(bw); lab:SetJustifyH("CENTER"); lab:SetText(b[2]); Theme.Font(lab, "textDim")
      local ht = HEADLINE_TIP[b[2]]; if ht then tipAcquire(bw, 40, ht[1], ht[2]):SetPoint("TOPLEFT", bx, y) end   -- hover covers the number AND its label
    end
    y = y - 50

    -- divider + 3) event tally bars ----------------------------------------------------------------------
    local div1 = texAcquire(); div1:SetPoint("TOPLEFT", PAD, y); div1:SetSize(W - PAD * 2, 1); div1:SetColorTexture(unpack(Theme.colors.divider)); y = y - 10
    local eh = fsAcquire("GameFontNormal"); eh:SetPoint("TOPLEFT", PAD, y); eh:SetText(Theme.Accent("Events"))
    tipAcquire(120, 16, "Cast outcomes", "caught = landed loot · expired = ran full length, no bite · missed = clicked too early/late · interrupt = cut short · cast-fail = never started (not aimed at water)."):SetPoint("TOPLEFT", PAD, y)
    y = y - 18
    local tallyOrder = { "caught", "expired", "missed", "interrupt", "castfail" }
    local trows, maxN = {}, 0
    for _, kk in ipairs(tallyOrder) do local n = kc[kk] or 0; if n > 0 then trows[#trows + 1] = { kk, n }; if n > maxN then maxN = n end end end
    table.sort(trows, function(a, b) return a[2] > b[2] end)
    if #trows == 0 then
      local e = fsAcquire(); e:SetPoint("TOPLEFT", PAD + 4, y); e:SetText("No events recorded for this period."); Theme.Font(e, "textDim"); y = y - 18
    else
      local LBLW, NUMW = 66, 44
      local barX = PAD + LBLW
      local barMax = math.max(50, W - PAD * 2 - LBLW - NUMW)
      for _, r in ipairs(trows) do
        local kk, n = r[1], r[2]
        local col = KIND_COLOR[kk] or "ffffff"
        local lbl = fsAcquire(); lbl:SetPoint("TOPLEFT", PAD, y); lbl:SetWidth(LBLW); lbl:SetText("|cff" .. col .. kk .. "|r")
        local bg = texAcquire(); bg:SetPoint("TOPLEFT", barX, y - 1); bg:SetSize(barMax, 12); bg:SetColorTexture(1, 1, 1, 0.06)
        local fill = texAcquire(); fill:SetPoint("TOPLEFT", barX, y - 1); fill:SetSize(math.max(2, barMax * (n / maxN)), 12)
        fill:SetColorTexture(Theme.HexToRGB(col)); fill:SetAlpha(0.85)
        local cnt = fsAcquire(); cnt:SetPoint("TOPLEFT", barX + barMax + 6, y); cnt:SetText("|cff" .. col .. n .. "|r")
        y = y - 16
      end
    end
    -- interrupt cause breakdown (combat vs movement vs jump) — a dim sub-line under the bars. "unknown" is the
    -- remainder (kc.interrupt minus the categorized causes) so it always reconciles to the interrupt total.
    if (kc.interrupt or 0) > 0 then
      local ic = roll.interrupts or {}
      local cc, mv, jp = ic.combat or 0, ic.moving or 0, ic.jump or 0
      local unk = (kc.interrupt or 0) - cc - mv - jp
      local parts = {}
      if cc > 0 then parts[#parts + 1] = "combat " .. cc end
      if mv > 0 then parts[#parts + 1] = "movement " .. mv end
      if jp > 0 then parts[#parts + 1] = "jump " .. jp end
      if unk > 0 then parts[#parts + 1] = "unknown " .. unk end
      if #parts > 0 then
        local sub = fsAcquire("GameFontHighlightSmall"); sub:SetPoint("TOPLEFT", PAD + 8, y)
        sub:SetText("|cff" .. (KIND_COLOR.interrupt or "ff6060") .. "interrupts|r  " .. table.concat(parts, "   ·   "))
        Theme.Font(sub, "textDim")
        tipAcquire(W - PAD * 2 - 8, 15, "Why casts were interrupted", "combat = pulled into combat mid-cast · movement = you moved · jump · unknown = cause couldn't be determined. Detected during the cast."):SetPoint("TOPLEFT", PAD + 8, y)
        y = y - 15
      end
    end
    y = y - 6

    -- divider + 4) segmented By fish | By zone ---------------------------------------------------------
    local div2 = texAcquire(); div2:SetPoint("TOPLEFT", PAD, y); div2:SetSize(W - PAD * 2, 1); div2:SetColorTexture(unpack(Theme.colors.divider)); y = y - 10
    local segF = btnAcquire(72, "By fish")
    segF:SetPoint("TOPLEFT", PAD, y); paintToggle(segF, statsSeg == "fish"); segF:SetScript("OnClick", function() statsSeg = "fish"; SBF.RefreshStats() end)
    setBtnTip(segF, "By fish", "Every distinct item caught, with counts. Sort by count, name, most-recent, or quality.")
    local segZ = btnAcquire(72, "By zone")
    segZ:SetPoint("TOPLEFT", PAD + 76, y); paintToggle(segZ, statsSeg == "zone"); segZ:SetScript("OnClick", function() statsSeg = "zone"; SBF.RefreshStats() end)
    setBtnTip(segZ, "By zone", "Catches grouped by continent → zone (sub-areas merged). Sort reorders the zones; click a zone to expand its top fish.")
    do                                                           -- the sort toggle drives BOTH the fish list and the zone view
      local sl = fsAcquire("GameFontHighlightSmall"); sl:SetPoint("TOPLEFT", PAD + 160, y + 4); sl:SetText("sort:"); Theme.Font(sl, "textDim")
      local sx = PAD + 192
      for _, s in ipairs({ "count", "name", "recent", "quality" }) do
        local b = btnAcquire(58, s)
        b:SetPoint("TOPLEFT", sx, y); paintToggle(b, statsFishSort == s); b:SetScript("OnClick", function() statsFishSort = s; SBF.RefreshStats() end)
        local st = SORT_TIP[s]; if st then setBtnTip(b, st[1], st[2]) end
        sx = sx + 60
      end
    end
    y = y - 28

    if statsSeg == "fish" then
      -- distinct-fish list (quality-colored hoverable links + count), sorted per the toggle. All Poor/gray
      -- (quality 0) items collapse into a single "Vendor trash" row to save space — they still count in totals.
      local list, trashN, trashKinds, trashLast = {}, 0, 0, 0
      for id, it in pairs(roll.items or {}) do
        local q = itemQuality(id, it)
        if q == 0 then
          trashN = trashN + (it.n or 0); trashKinds = trashKinds + 1
          if (it.last or 0) > trashLast then trashLast = it.last or 0 end
        else
          list[#list + 1] = { id = id, it = it, q = q or 1 }   -- unknown quality sorts as Common(1)
        end
      end
      if trashN > 0 then list[#list + 1] = { trash = true, n = trashN, kinds = trashKinds, last = trashLast, q = 0 } end
      if #list == 0 then
        local e = fsAcquire(); e:SetPoint("TOPLEFT", PAD + 4, y); e:SetText("No fish recorded for this period."); Theme.Font(e, "textDim"); y = y - 18
      else
        local function rN(r) return r.trash and r.n or (r.it and r.it.n or 0) end
        table.sort(list, function(a, b)
          if a.trash ~= b.trash then return b.trash end   -- Vendor trash always sinks to the bottom, any sort
          if statsFishSort == "name" then
            return (a.trash and "Vendor trash" or (a.it and a.it.name or "")) < (b.trash and "Vendor trash" or (b.it and b.it.name or ""))
          elseif statsFishSort == "recent" then
            return (a.trash and a.last or (a.it and a.it.last or 0)) > (b.trash and b.last or (b.it and b.it.last or 0))
          elseif statsFishSort == "quality" then
            if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end   -- best quality first
            return rN(a) > rN(b)                                                  -- tie-break by count
          else return rN(a) > rN(b) end
        end)
        for _, row in ipairs(list) do
          local label, count
          if row.trash then
            label = "|cff9d9d9dVendor trash|r |cff808080(" .. row.kinds .. (row.kinds == 1 and " kind)" or " kinds)") .. "|r"
            count = row.n
          else
            local it = row.it
            label = (it.link and GSV.ColorItemLink(it.link)) or ("|cffffffff" .. (it.name or ("item " .. tostring(row.id))) .. "|r")
            count = it.n or 0
          end
          local fs = fsAcquire(); fs:SetPoint("TOPLEFT", PAD + 4, y); fs:SetWidth(W - PAD * 2 - 96); fs:SetText(label)
          -- percent is this fish's share of the WHOLE By-fish list (= the period's totalFish), dimmed left of the count
          local cnt = fsAcquire(); cnt:SetPoint("TOPRIGHT", statsChild, "TOPRIGHT", -PAD, y); cnt:SetJustifyH("RIGHT"); cnt:SetText(pctTag(count, totalFish) .. Theme.Accent(count))
          if row.trash then tipAcquire(W - PAD * 2 - 6, 16, "Vendor trash", "All gray (Poor) junk lumped into one row to save space — still counted in your totals."):SetPoint("TOPLEFT", PAD + 4, y)
          else itemTipAcquire(W - PAD * 2 - 6, 16, row.it and row.it.link, row.id):SetPoint("TOPLEFT", PAD + 4, y) end   -- item tooltip on the fish name
          y = y - 16
        end
      end
    else
      -- zone list grouped under continent headers; each zone row is click-to-expand to its top fish.
      local conts = {}
      for zoneKey, z in pairs(roll.zones or {}) do
        local cName = z.cont or "Unknown"
        local c = conts[cName]; if not c then c = { name = cName, zones = {} }; conts[cName] = c end
        -- precompute the zone's sort keys (lists are tiny): total items caught (the count/percent denominator),
        -- best fish quality, display name, and newest activity. itemQuality also heals the stored q as a side benefit.
        local nItems, bestQ = 0, -1
        for id, n in pairs(z.items or {}) do
          nItems = nItems + n
          local q = itemQuality(id, (roll.items or {})[id]); if q and q > bestQ then bestQ = q end
        end
        c.zones[#c.zones + 1] = { key = zoneKey, z = z, nItems = nItems, bestQ = bestQ,
          name = (z.zone and z.zone ~= "" and z.zone) or "(unknown zone)", lastT = z.lastT or 0 }
      end
      local clist = {}
      for _, c in pairs(conts) do clist[#clist + 1] = c end
      if #clist == 0 then
        local e = fsAcquire(); e:SetPoint("TOPLEFT", PAD + 4, y); e:SetText("No zones recorded for this period."); Theme.Font(e, "textDim"); y = y - 18
      else
        table.sort(clist, function(a, b) return a.name < b.name end)
        for _, c in ipairs(clist) do
          local chh = fsAcquire("GameFontNormal"); chh:SetPoint("TOPLEFT", PAD, y); chh:SetText(Theme.Accent(c.name)); y = y - 18
          -- zones within this continent follow the active sort toggle (continents themselves stay alphabetical above)
          table.sort(c.zones, function(a, b)
            if statsFishSort == "name" then
              return a.name < b.name
            elseif statsFishSort == "recent" then
              if a.lastT ~= b.lastT then return a.lastT > b.lastT end   -- newest zone first; zones with no lastT (0) sink last
              return a.nItems > b.nItems
            elseif statsFishSort == "quality" then
              if a.bestQ ~= b.bestQ then return a.bestQ > b.bestQ end    -- best-quality fish in the zone first
              return a.nItems > b.nItems                                 -- tie-break by count
            else return a.nItems > b.nItems end                          -- count: total items caught in the zone
          end)
          for _, zr in ipairs(c.zones) do
            local z = zr.z; local zk = z.kinds or {}
            local zCaught = zk.caught or 0
            local zCasts = (zk.caught or 0) + (zk.expired or 0) + (zk.missed or 0) + (zk.interrupt or 0)
            local zName = (z.zone and z.zone ~= "" and z.zone) or "(unknown zone)"
            local open = statsZoneOpen[zr.key]
            local zfs = fsAcquire(); zfs:SetPoint("TOPLEFT", PAD + 10, y); zfs:SetWidth(W - PAD * 2 - 96); zfs:SetText((open and "− " or "+ ") .. zName)
            local zc = fsAcquire("GameFontHighlightSmall"); zc:SetPoint("TOPRIGHT", statsChild, "TOPRIGHT", -PAD, y); zc:SetJustifyH("RIGHT")
            zc:SetText("|cff" .. (KIND_COLOR.caught or "33ff33") .. zCaught .. "|r / " .. zCasts)
            local hit = hitAcquire(W - PAD * 2 - 6, 15); hit:SetPoint("TOPLEFT", PAD + 6, y + 1)
            hit:SetScript("OnClick", function() statsZoneOpen[zr.key] = not statsZoneOpen[zr.key]; SBF.RefreshStats() end)
            y = y - 16
            if open then
              local fl, ztrash = {}, 0
              for id, n in pairs(z.items or {}) do
                local gi = (roll.items or {})[id]
                local q = itemQuality(id, gi)
                if q == 0 then ztrash = ztrash + n else fl[#fl + 1] = { id = id, n = n, gi = gi, q = q or 1 } end   -- lump grays
              end
              -- expanded fish follow the SAME toggle, treating this zone as its own group (recent uses each fish's
              -- GLOBAL last-caught time — per-zone-per-fish recency isn't tracked; see the design's known limitation).
              table.sort(fl, function(a, b)
                if statsFishSort == "name" then
                  return ((a.gi and a.gi.name) or ("item " .. a.id)) < ((b.gi and b.gi.name) or ("item " .. b.id))
                elseif statsFishSort == "recent" then
                  return ((a.gi and a.gi.last) or 0) > ((b.gi and b.gi.last) or 0)
                elseif statsFishSort == "quality" then
                  if (a.q or 0) ~= (b.q or 0) then return (a.q or 0) > (b.q or 0) end   -- best quality first
                  return a.n > b.n                                                      -- tie-break by count
                else return a.n > b.n end
              end)
              if #fl == 0 and ztrash == 0 then
                local e = fsAcquire(); e:SetPoint("TOPLEFT", PAD + 26, y); e:SetText("(no catalogued fish here)"); Theme.Font(e, "textDim"); y = y - 15
              else
                -- each fish's percent is its share of THIS ZONE's items (zr.nItems), computed independently per zone
                for i = 1, math.min(8, #fl) do                 -- top 8 real fish keeps the expansion compact
                  local f = fl[i]
                  local gi = (roll.items or {})[f.id]
                  local link = (gi and gi.link and GSV.ColorItemLink(gi.link)) or ("|cffffffff" .. ((gi and gi.name) or ("item " .. tostring(f.id))) .. "|r")
                  local ffs = fsAcquire(); ffs:SetPoint("TOPLEFT", PAD + 26, y); ffs:SetWidth(W - PAD * 2 - 96); ffs:SetText(link)
                  local fc = fsAcquire(); fc:SetPoint("TOPRIGHT", statsChild, "TOPRIGHT", -PAD, y); fc:SetJustifyH("RIGHT"); fc:SetText(pctTag(f.n, zr.nItems) .. Theme.Accent(f.n))
                  itemTipAcquire(W - PAD * 2 - 24, 15, gi and gi.link, f.id):SetPoint("TOPLEFT", PAD + 26, y)   -- item tooltip on the zone-fish name
                  y = y - 15
                end
                if ztrash > 0 then                             -- Vendor trash always pinned at the bottom
                  local ffs = fsAcquire(); ffs:SetPoint("TOPLEFT", PAD + 26, y); ffs:SetWidth(W - PAD * 2 - 96); ffs:SetText("|cff9d9d9dVendor trash|r")
                  local fc = fsAcquire(); fc:SetPoint("TOPRIGHT", statsChild, "TOPRIGHT", -PAD, y); fc:SetJustifyH("RIGHT"); fc:SetText(pctTag(ztrash, zr.nItems) .. Theme.Accent(ztrash))
                  y = y - 15
                end
              end
            end
          end
        end
      end
    end

    -- 5) reset all-time stats (confirm-gated; the only path that clears the rollup) + refresh-rate cycle ---
    y = y - 12
    local reset = btnAcquire(150, "Reset all-time stats"); reset:SetPoint("TOPLEFT", PAD, y)
    reset:SetScript("OnClick", function() StaticPopup_Show("SBF_RESET_STATS") end)
    setBtnTip(reset, "Reset stats", "Starts your stats fresh from now — all-time, Today, and This session all reset to zero and rebuild as you fish. Your fishing log keeps its full history (it is never deleted).")
    -- refresh-rate cycle button (right of Reset): Live -> 1s -> 2s -> 5s -> Off -> (wrap). "Live" updates on
    -- each catch; the numeric modes poll on a timer; "Off" is manual-only. Click advances + persists the mode.
    local REFRESH_MODES = { "live", 1, 2, 5, "off" }
    local REFRESH_LABEL = { live = "Live", ["1"] = "1s", ["2"] = "2s", ["5"] = "5s", off = "Off" }
    local curMode = tostring(SBFDB.statsRefresh or "live")
    local rr = btnAcquire(120, "Refresh: " .. (REFRESH_LABEL[curMode] or "Live"))
    rr:SetPoint("LEFT", reset, "RIGHT", 8, 0)
    rr:SetScript("OnClick", function()
      local idx = 1
      for i, m in ipairs(REFRESH_MODES) do if tostring(m) == tostring(SBFDB.statsRefresh or "live") then idx = i; break end end
      SBFDB.statsRefresh = REFRESH_MODES[(idx % #REFRESH_MODES) + 1]   -- next mode (wraps)
      startStatsTicker()                                              -- (re)arm or cancel the poll timer for the new mode
      SBF.RefreshStats()                                              -- redraw now (updates this button's own label too)
    end)
    rr:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Stats refresh rate")
      GameTooltip:AddLine("How often this page updates: |cffffd100Live|r redraws on every catch, |cffffd1001s/2s/5s|r poll on a timer, |cffffd100Off|r only updates when you click a button. Click to cycle.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    rr:SetScript("OnLeave", GameTooltip_Hide)
    y = y - 32

    -- hide pooled surplus from a previous (taller) render, then size the scroll child to the content.
    for i = fsN + 1, #statsFS do statsFS[i]:Hide() end
    for i = texN + 1, #statsTex do statsTex[i]:Hide() end
    for i = btnN + 1, #statsBtn do statsBtn[i]:Hide() end
    for i = hitN + 1, #statsHit do statsHit[i]:Hide() end
    for i = tipN + 1, #statsTip do statsTip[i]:Hide() end
    statsChild:SetHeight(math.max(-y + 8, 1))
    local sf = statsChild:GetParent()
    if sf and sf.RefreshScrollBar then sf.RefreshScrollBar() end
  end
  -- reflow on window resize while the tab is open (bars/columns track the new width). The scroll FRAME's
  -- size is window-driven (our SetHeight on the CHILD can't retrigger it), so this can't loop.
  statsChild:GetParent():HookScript("OnSizeChanged", function()
    if pStats:IsShown() and SBF.RefreshStats then SBF.RefreshStats() end
  end)
  end       -- buildStatsPage
  buildStatsPage()

  -- ===== PAGE: Skill Book (per-expansion fishing skill, read from the GECStore professions cache) =====
  do
    local pSkill = attachPageScroll(pages.skillbook, 420, 500)
    local sbStore = LibStub("GECStore-1.0")
    Theme.SectionHeader(pSkill, 4, -8, "Fishing skill by expansion")
    -- Character selector (single-select; defaults to the current character): view any character's skill book.
    local sbSelectedChar   -- nil = current character
    local function sbCurIdx() return sbSelectedChar or (sbStore.CharIndex and sbStore.CharIndex()) end
    local function sbDDText()
      local idx = sbCurIdx()
      local info = idx and sbStore.CharInfo and sbStore.CharInfo(idx)
      return (info and info.name) or "Current"
    end
    local charLbl = pSkill:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    charLbl:SetPoint("TOPLEFT", 6, -34); charLbl:SetText(Theme.Accent("Character"))
    local charDD = CreateFrame("DropdownButton", nil, pSkill, "WowStyle1DropdownTemplate")
    Theme.SkinDropdown(charDD); charDD:SetSize(170, 22)
    charDD:SetPoint("LEFT", charLbl, "RIGHT", 8, 0)
    charDD:SetDefaultText(sbDDText())
    charDD:SetupMenu(function(_dd, menu)
      for _, c in ipairs(SBF.SkillBookChars() or {}) do
        local idx = c.idx
        menu:CreateRadio(c.name,
          function() return sbCurIdx() == idx end,
          function()
            sbSelectedChar = idx
            charDD:SetDefaultText(sbDDText())
            if SBF.RefreshSkillBook then SBF.RefreshSkillBook() end
          end)
      end
    end)
    charDD:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Character")
      GameTooltip:AddLine("View another character's fishing skill (each one's data is cached the first time it opens Professions). Your current character is pinned on top.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    charDD:HookScript("OnLeave", GameTooltip_Hide)
    -- Short intro over the list (broken across lines so it's not one crammed run).
    local note = pSkill:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 6, -62); note:SetWidth(380); note:SetJustifyH("LEFT"); note:SetSpacing(3)
    note:SetText("Fishing level / max in each expansion.\n\"—\" means no skill in that line yet.")
    -- one row per expansion (created once; RefreshSkillBook fills them). Two columns: name | level/max.
    local SB_ROW_TOP, SB_ROW_H = -100, 22
    local skillRows = {}
    for i = 1, #SBF.SKILLBOOK_ORDER do
      local y = SB_ROW_TOP - (i - 1) * SB_ROW_H
      local nm = pSkill:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      nm:SetPoint("TOPLEFT", 12, y); nm:SetJustifyH("LEFT")
      local vl = pSkill:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      vl:SetPoint("TOPLEFT", 210, y); vl:SetJustifyH("LEFT")
      skillRows[i] = { name = nm, val = vl }
    end
    -- Bottom action block: separated from the list (a divider + padding so it isn't crammed against the rows),
    -- with the Open Professions button + its "load/refresh live" caption beside it.
    local listBottom = SB_ROW_TOP - #SBF.SKILLBOOK_ORDER * SB_ROW_H   -- y just under the last row
    local divider = pSkill:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.10); divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 8, listBottom - 12); divider:SetPoint("TOPRIGHT", pSkill, "TOPRIGHT", -8, listBottom - 12)
    -- Opening the fishing journal warms the per-expansion skill cache. A protected cast can only run
    -- from a hardware click on a SecureActionButton, so both buttons below use the secure template +
    -- click registration, not a plain OnClick. Theme.Button is taint-safe here (native highlight
    -- texture, no OnEnter/OnMouseDown hooks), so styling doesn't kill the cast.

    -- Register the click edge that MATCHES ActionButtonUseKeyDown (via GECBind, exactly like the fishing
    -- button) + a debug PostClick. A hardcoded "AnyUp" silently DROPS the protected cast on a key-DOWN client
    -- — THAT is why these two buttons worked on the desktop (CVar=0) but not the laptop (CVar=1). GECBind
    -- re-syncs the edge on CVAR_UPDATE so it can't drift. Fallback to AnyUp only if the lib is somehow absent.
    local function secureClicks(b)
      local GB = _G.LibStub and _G.LibStub:GetLibrary("GECBind-1.0", true)
      if GB and GB.RegisterSecureClicks then GB.RegisterSecureClicks(b) else b:RegisterForClicks("AnyUp") end
      b:HookScript("PostClick", function()
        if SBFDB.debug then
          print(("|cff45c4a0SBF|r |cff33ff33skillbook click fired|r (%s) — ActionButtonUseKeyDown=%s edge=%s")
            :format(b:GetName() or "?", tostring(GetCVar and GetCVar("ActionButtonUseKeyDown")),
              (GB and GB.RegisterSecureClicks) and "GECBind(matched)" or "AnyUp(fallback)"))
        end
      end)
    end

    -- These two buttons use SecureActionButtonTemplate, so EVERYTHING about them — SetAttribute, the secure
    -- click registration, even SetPoint/SetSize on a protected frame — is a PROTECTED action WoW BLOCKS in
    -- combat. If the options window is FIRST built mid-fight (you clicked the minimap in combat), doing this
    -- inline aborts the whole Build() and the window never shows (the "minimap button does nothing in combat"
    -- bug). Fix: they live in their OWN builder that simply isn't called in combat. The rest of the window
    -- builds + opens normally; this little region draws the instant combat ends. You can't cast the journal in
    -- combat anyway, so nothing is lost. Idempotent (journalBtnsDone) so the deferred call can't double-build.
    local journalBtnsDone = false
    local function buildJournalButtons()
      if journalBtnsDone or InCombatLockdown() then return end
      journalBtnsDone = true
      -- Button 1 — "Open Fishing Journal": casts it and LEAVES it open.
      local openBtn = CreateFrame("Button", "SBFSkillJournalBtn", pSkill, "SecureActionButtonTemplate, UIPanelButtonTemplate")
      openBtn:SetSize(150, 22); openBtn:SetPoint("TOPLEFT", 12, listBottom - 26)
      openBtn:SetText("Open Fishing Journal"); Theme.Button(openBtn)
      secureClicks(openBtn)
      openBtn:SetAttribute("type", "macro")
      openBtn:SetAttribute("macrotext", "/cast Fishing Journal")
      local openNote = pSkill:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
      openNote:SetPoint("LEFT", openBtn, "RIGHT", 12, 0); openNote:SetWidth(200); openNote:SetJustifyH("LEFT"); openNote:SetSpacing(2)
      openNote:SetText("Opens your journal to load / refresh the skill data live (once per character).")

      -- Button 2 — "Refresh Skill (flash)": casts the journal, then immediately closes it. The cast opens
      -- the ProfessionsFrame (loading Blizzard_Professions if needed) and fires TRADE_SKILL_LIST_UPDATE,
      -- which is exactly when the per-expansion data becomes readable and the GECStore cache warms. A
      -- hidden listener catches that event and hides the frame ONE tick later (C_Timer.After 0) so the
      -- cache-reading handlers run first — the user sees only a brief flash, and the Skill Book warms.
      -- PostClick fires AFTER the secure action completes, so setting the flag there doesn't taint the cast.
      local warmBtn = CreateFrame("Button", "SBFSkillWarmBtn", pSkill, "SecureActionButtonTemplate, UIPanelButtonTemplate")
      warmBtn:SetSize(150, 22); warmBtn:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -8)
      warmBtn:SetText("Refresh Skill (flash)"); Theme.Button(warmBtn)
      secureClicks(warmBtn)
      warmBtn:SetAttribute("type", "macro")
      warmBtn:SetAttribute("macrotext", "/cast Fishing Journal")
      warmBtn:HookScript("PostClick", function() SBF._journalAutoClose = true end)
      local warmNote = pSkill:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
      warmNote:SetPoint("LEFT", warmBtn, "RIGHT", 12, 0); warmNote:SetWidth(200); warmNote:SetJustifyH("LEFT"); warmNote:SetSpacing(2)
      warmNote:SetText("Flashes the journal open+closed to warm the skill data without leaving it up.")
    end
    if InCombatLockdown() then   -- first-built mid-fight: draw these the moment combat drops
      local waiter = CreateFrame("Frame")
      waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
      waiter:SetScript("OnEvent", function(self) self:UnregisterEvent("PLAYER_REGEN_ENABLED"); buildJournalButtons() end)
    else
      buildJournalButtons()
    end

    -- The auto-close listener (created once). Only acts when WE initiated the open via the flash button.
    if not SBF._journalWarmer then
      local w = CreateFrame("Frame")
      w:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
      w:SetScript("OnEvent", function()
        if not SBF._journalAutoClose then return end
        SBF._journalAutoClose = nil
        C_Timer.After(0, function()
          if _G.ProfessionsFrame and _G.ProfessionsFrame:IsShown() then
            HideUIPanel(_G.ProfessionsFrame)
          end
          if SBF.RefreshSkillBook then SBF.RefreshSkillBook() end
        end)
      end)
      SBF._journalWarmer = w
    end
    -- Fill the rows from the SELECTED character's cache (defaults to the current character). The "(here)"
    -- current-zone marker only makes sense for yourself, so it's suppressed when viewing another character.
    function SBF.RefreshSkillBook()
      charDD:SetDefaultText(sbDDText())                                    -- keep the label current
      local viewSelf = (not sbSelectedChar) or (sbSelectedChar == (sbStore.CharIndex and sbStore.CharIndex()))
      local rows = SBF.SkillBookFor(sbSelectedChar)
      for i, r in ipairs(skillRows) do
        local d = rows and rows[i]
        if not d then
          r.name:SetText(""); r.val:SetText("")
        else
          r.name:SetText(d.label .. ((d.current and viewSelf) and "  |cff45c4a0(here)|r" or ""))
          if d.has then
            r.name:SetTextColor(1, 1, 1)
            r.val:SetText((d.level or 0) .. "/" .. (d.max or d.level or 0)); r.val:SetTextColor(1, 1, 1)
          else
            r.name:SetTextColor(0.5, 0.5, 0.5)
            r.val:SetText("—"); r.val:SetTextColor(0.5, 0.5, 0.5)
          end
        end
      end
    end
  end

  -- ===== PAGE: About (banner / name / version / tagline / website / re-open welcome) =====
  -- Per the launch plan: brand + name + version, a copyable Website link, and "Show welcome screen". The
  -- donate/vote ask stays on the WEBSITE (Blizzard policy) — the addon only ever links out, never asks.
  -- ABOUT_URL is the single editable string here; update it once the brand domain is finalized.
  local ABOUT_URL = "https://goblineng.co"
  do
    -- scrollable About page: the scroll child's width tracks the window, so the banner can be edge-to-edge and
    -- resize with it; the page scrolls when a wide (hence tall) banner pushes the content below the fold.
    local pAbout = attachPageScroll(pages.about, 480, 460)
    local ver = (((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata)("SBF", "Version")) or "?"
    local BANNER_ASPECT = 512 / 279   -- the cropped band's aspect (~1.835:1) — width / this = height
    local BANNER_MAX_W = 512          -- native band width; never upscale past it (so it can't dominate the page)
    local BANNER_TOP = 8

    -- Goblin Engineering Company banner (goblin + brand — so no separate brand text). CENTERED; layoutAbout
    -- sizes it to min(window, native 512) wide and keeps its aspect, so it scales down on a narrow window but
    -- never blows up past its native size. 512x512 TGA (WoW can't load PNG); SetTexCoord crops to the band.
    local banner = pAbout:CreateTexture(nil, "ARTWORK")
    banner:SetPoint("TOP", pAbout, "TOP", 0, -BANNER_TOP)
    banner:SetTexture("Interface\\AddOns\\SBF\\art\\goblin.tga")
    banner:SetTexCoord(0, 1, 0.2266, 0.7715)

    local title = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", banner, "BOTTOM", 0, -10); title:SetText(Theme.Accent("Single-Button Fishing"))

    local verFS = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    verFS:SetPoint("TOP", title, "BOTTOM", 0, -4)
    verFS:SetText("Version " .. tostring(ver) .. (SBF.ChannelBadge and SBF.ChannelBadge() or ""))   -- badge dev/prerelease/local
    Theme.Font(verFS, "textDim")

    -- tagline — EXACTLY the welcome screen's line: same brand-gold colour code (e8c679) + wording, per request.
    local tag = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    tag:SetPoint("TOP", verFS, "BOTTOM", 0, -14)
    tag:SetText("|cffe8c679The only fishing add-on that does it all.|r")

    -- the "does it all automatically" one-liner (restored): everything the single key handles for you.
    local desc = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOP", tag, "BOTTOM", 0, -8); desc:SetWidth(440); desc:SetJustifyH("CENTER")
    desc:SetText("One key runs your whole fishing loop — cast, wait, loot, recast — and handles your food, "
      .. "drink, lures, chum, buffs, the dinghy, and fighting back when something attacks you, all automatically.")
    Theme.Font(desc, "textDim")

    local div = pAbout:CreateTexture(nil, "ARTWORK")
    div:SetPoint("TOP", desc, "BOTTOM", 0, -14); div:SetSize(430, 1); div:SetColorTexture(unpack(Theme.colors.divider))

    -- Website invite (no copy-hint — the field auto-selects on click): point people at the brand site for the
    -- other add-ons + the roadmap they can vote on. The vote/donate ASK itself stays on the site (Blizzard).
    local wlbl = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    wlbl:SetPoint("TOP", div, "BOTTOM", 0, -12); wlbl:SetWidth(440); wlbl:SetJustifyH("CENTER")
    wlbl:SetText("Check out our other add-ons, and vote on what we build next:")
    Theme.Font(wlbl, "text")

    local urlEb = CreateFrame("EditBox", nil, pAbout, "InputBoxTemplate")
    urlEb:SetSize(300, 22); urlEb:SetPoint("TOP", wlbl, "BOTTOM", 0, -6)
    urlEb:SetAutoFocus(false); urlEb:SetFontObject("ChatFontNormal"); Theme.EditBox(urlEb)
    urlEb:SetText(ABOUT_URL); urlEb:SetCursorPosition(0)
    urlEb:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    urlEb:SetScript("OnTextChanged", function(s, user) if user then s:SetText(ABOUT_URL); s:HighlightText() end end)  -- read-only: snap back on any edit
    urlEb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    urlEb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)

    local wbtn = CreateFrame("Button", nil, pAbout, "UIPanelButtonTemplate")
    wbtn:SetSize(190, 24); wbtn:SetPoint("TOP", urlEb, "BOTTOM", 0, -16); wbtn:SetText("Show welcome screen"); Theme.Button(wbtn)
    wbtn:SetScript("OnClick", function() if SBF.ShowWelcome then SBF.ShowWelcome() end end)

    -- Licensing — the short version of LICENSE.txt (proprietary Goblin Engineering Company license; the embedded
    -- Libs/ are separately MIT). Just the notice + a pointer to the file for the full terms — no external ask.
    local licDiv = pAbout:CreateTexture(nil, "ARTWORK")
    licDiv:SetPoint("TOP", wbtn, "BOTTOM", 0, -18); licDiv:SetSize(430, 1); licDiv:SetColorTexture(unpack(Theme.colors.divider))

    local licHdr = pAbout:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    licHdr:SetPoint("TOP", licDiv, "BOTTOM", 0, -10); licHdr:SetText(Theme.Accent("License"))

    local licCopy = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    licCopy:SetPoint("TOP", licHdr, "BOTTOM", 0, -6); licCopy:SetWidth(440); licCopy:SetJustifyH("CENTER")
    licCopy:SetText("© 2026 Goblin Engineering Company. All rights reserved.")
    Theme.Font(licCopy, "text")

    local licBody = pAbout:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    licBody:SetPoint("TOP", licCopy, "BOTTOM", 0, -6); licBody:SetWidth(440); licBody:SetJustifyH("CENTER")
    licBody:SetText("Free to install, use, and read the source. You may not redistribute, re-host, publish "
      .. "modified or derivative versions, or use this code commercially without written permission. Embedded "
      .. "libraries under Libs\\ are separately MIT-licensed under their own terms. See LICENSE.txt for full terms.")
    Theme.Font(licBody, "textDim")

    -- keep the banner edge-to-edge + aspect-correct on resize, widen the divider to match, and grow the scroll
    -- child so the content below the (possibly tall) banner scrolls into reach. ~215px = the fixed stack below.
    local function layoutAbout()
      local sf = pAbout:GetParent()
      local sw = (sf and sf:GetWidth()) or 0
      if sw <= 1 then return end
      pAbout:SetWidth(sw)                                      -- child fills the scroll frame so TOP-anchored content
                                                               -- centres on FIRST show (not just after a resize)
      local bw = math.min(BANNER_MAX_W, sw - 24)               -- cap at native width; only shrinks on a narrow window
      banner:SetSize(bw, bw / BANNER_ASPECT)
      local dw = math.min(BANNER_MAX_W, sw - 60)
      div:SetWidth(dw); licDiv:SetWidth(dw)                     -- both dividers track the window width
      pAbout:SetHeight(BANNER_TOP + banner:GetHeight() + 400)  -- fixed stack below (desc + invite + url + button + license)
      if sf.RefreshScrollBar then sf.RefreshScrollBar() end
    end
    pAbout:HookScript("OnSizeChanged", layoutAbout)
    pages.about:HookScript("OnShow", function() C_Timer.After(0, layoutAbout) end)
    layoutAbout()
  end

  -- ===== PAGE: Keybinds (aligned COLUMN table: every bindable action + its bindings) =====
  -- Columns: <action label> | Keyboard | [Mouse] | [Controller]. Keyboard shows on every row; Mouse and
  -- Controller appear ONLY on the two main actions — fishing (Action) and interact (Loot) — and only when
  -- that mode is enabled (Mouse = SBFDB.mouse.enabled; Controller = controller enabled). Toggling either
  -- re-lays the table (relayout) so there are no holes. Every editor reuses the existing capture widgets —
  -- MakeKeybindButton (mode "key"/"pad" -> SBFDB.binds / bindsCtrl), MakeGameBindButton (the loot
  -- INTERACTTARGET game bind), and MakeMouseButton (the Buttons-page mouse picker) — so this tab and the
  -- per-slot popups stay in sync. The Controller cells are built defensively (capture is pcall-guarded).
  local pKeysChild = attachPageScroll(pages.keys, 470, 1)
  do
    local ROW_DY = 28                  -- vertical step between rows
    local CELL_W = 104                 -- width of each bind cell (button)
    local KCOL_GAP = 6                 -- gap between columns
    local LABEL_W = 140                -- Action column (label) width on the left
    local X0 = LABEL_W + 6             -- x of the FIRST bind column (after the label column)
    local headers = {}                 -- header label per column key, repositioned on relayout
    local items = {}                   -- sections + rows in BUILD ORDER; relayout walks this, assigning on-screen
                                       -- y by accumulating only the VISIBLE ones (a hidden row/section adds no
                                       -- height). Each entry: { kind="section"|"row", ref=<the record>, h=<step> }.
                                       -- ref(section) = { h, ln, devOnly }; ref(row) = { lbl, cells, isLoot, devOnly }.
    local SECTION_DY = 26              -- vertical step a section header consumes (matches sectionAt's y advance)
    local y = -2

    -- which optional columns are live right now (a column is "active" only if its mode is on AND at least
    -- one row carries that cell — mouse/ctrl cells exist only on the fishing + interact rows).
    -- Gate the Controller column on SBF's OWN setting only: the "Enable controller" toggle deliberately leaves
    -- the global GamePadEnable CVar on when unticked (the user may use a gamepad elsewhere), so a CVar fallback
    -- here would show the column even when SBF's controller support is OFF.
    local function ctrlEnabled()
      return SBFDB.gamepadEnable and true or false
    end
    local function colsActive()
      return {
        key1 = true,
        mouse = (SBFDB.mouse and SBFDB.mouse.enabled) and true or false,
        ctrl = ctrlEnabled(),
      }
    end

    -- (No drag-to-bar macro: a bar macro's /click can't carry the protected cast for our INSECURE smart
    -- button — only the override-click from a real keybind/PAD token casts. The macro would just be a silent
    -- no-op, so it's intentionally absent. Fishing is bound by key/controller below.)

    local intro = pKeysChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 4, y); intro:SetPoint("TOPRIGHT", -4, y); intro:SetJustifyH("LEFT")
    intro:SetText("Set a key or controller button for any SBF action. "
      .. "(Controller: enable it in Settings, then press a pad button here.)")
    y = y - 30

    -- the header row (one font string per column, repositioned/shown on relayout). No "Action" header — the
    -- left label column is self-explanatory. Built LARGE (so the column titles read as a header, not floating
    -- text) with a divider line under the whole row to ground it. "Keyboard" replaces the old "Key 1".
    local hdrY = y
    for _, key in ipairs({ "key1", "mouse", "ctrl" }) do
      local h = pKeysChild:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
      h:SetText(({ key1 = "Keyboard", mouse = "Mouse", ctrl = "Controller" })[key])
      h:SetTextColor(accentRGB())
      headers[key] = h
    end
    local hdrLine = pKeysChild:CreateTexture(nil, "ARTWORK")   -- underline grounding the header row (dev-only, like the headers)
    hdrLine:SetHeight(1); hdrLine:SetColorTexture(unpack(Theme.colors.divider))
    hdrLine:SetPoint("TOPLEFT", 4, hdrY - 20); hdrLine:SetPoint("TOPRIGHT", -8, hdrY - 20)
    y = y - 30
    local contentTop = y               -- on-screen y where the FIRST section/row starts (relayout walks from here)

    -- a section header (accent title + faint divider). Recorded into `items` (build order); relayout places it
    -- by the accumulating walk and hides it when not visible (devOnly in non-dev, or all section headers in non-dev).
    local function sectionAt(text, devOnly)
      local h = pKeysChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
      h:SetText(Theme.Accent(text))
      local ln = pKeysChild:CreateTexture(nil, "ARTWORK")
      ln:SetHeight(1); ln:SetColorTexture(unpack(Theme.colors.divider))
      local sec = { h = h, ln = ln, devOnly = devOnly and true or false }
      items[#items + 1] = { kind = "section", ref = sec, h = SECTION_DY }
      y = y - SECTION_DY
    end

    -- build ONE table row. `opt` declares which bind cell each column gets:
    --   key1       = the Key 1 editor (MakeKeybindButton "key" on binds, OR MakeGameBindButton for loot).
    --                Every row has one — keyboard is bindable for every action.
    --   mouseField = a MakeMouseButton field ("fishButton"/"lootButton") — only the fishing/interact rows
    --                set this; a nil omits the Mouse cell (slot/gear rows leave that column blank).
    --   ctrl       = true to add a Controller cell (MakeKeybindButton "pad" on bindsCtrl) — only the
    --                fishing/interact rows set this; slot/gear rows have no Controller cell.
    -- All cells are created up front; relayout positions/show-hides them by the active columns.
    local function tableRow(slotId, labelText, opt)
      opt = opt or {}
      local lbl = pKeysChild:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      lbl:SetWidth(LABEL_W); lbl:SetJustifyH("LEFT")
      lbl:SetText(labelText)
      local cells = {}
      -- Key 1 (keyboard, every row). nativeCmd rows (fishing cast, interact loot) bind the NATIVE Key Bindings
      -- command — the single source of truth shared with WoW's menu + ConsolePort. Every other row uses SBF's
      -- internal override store (dev-only slot/gear keybinds, never exposed to the native menu).
      if opt.nativeCmd then
        cells.key1 = MakeNativeBindButton(pKeysChild, 0, 0, opt.nativeCmd, CELL_W, opt.after, "key")
      else
        cells.key1 = MakeKeybindButton(pKeysChild, 0, 0, slotId, CELL_W, opt.after, "key", "binds")
      end
      -- Mouse (only fishing/interact define a field)
      if opt.mouseField then
        cells.mouse = MakeMouseButton(pKeysChild, 0, 0, opt.mouseField, CELL_W, opt.mouseAllowNone)
      end
      -- Controller (gamepad) — only the two main actions get a pad cell. nativeCmd rows bind the pad button
      -- to the same native command (its second key slot); other rows use the internal bindsCtrl store.
      if opt.ctrl then
        if opt.nativeCmd then
          cells.ctrl = MakeNativeBindButton(pKeysChild, 0, 0, opt.nativeCmd, CELL_W, opt.after, "pad")
        else
          cells.ctrl = MakeKeybindButton(pKeysChild, 0, 0, slotId, CELL_W, opt.after, "pad", "bindsCtrl")
        end
      end
      local row = { lbl = lbl, cells = cells,
        isLoot = opt.lootGameBind and true or false, devOnly = opt.devOnly and true or false }
      items[#items + 1] = { kind = "row", ref = row, h = ROW_DY }
      y = y - ROW_DY
      return row
    end

    -- Main: master One Button Fishing key + the Loot / Interact game bind (two-button mode only).
    sectionAt("Main")
    tableRow("fishing", "Action /Cast", {
      nativeCmd = SBF.FISHING_CMD,   -- native "Action / Cast" binding — shared with WoW's menu + ConsolePort
      mouseField = "fishButton", mouseAllowNone = false, ctrl = true,
      after = function()
        if masterKeyBtn then masterKeyBtn:SetText(BindText("fishing")) end
      end,
    })
    -- Loot / Interact: BOTH cells are the native Blizzard INTERACTTARGET game bind (keyboard + controller),
    -- so they match WoW's own "Interact With Target". lootGameBind keeps the row hidden outside two-button
    -- mode (single-button mode loots via the dynamic override on the Action key).
    tableRow("interact", "Loot / Interact",
      { lootGameBind = true, nativeCmd = "INTERACTTARGET",
        mouseField = "lootButton", mouseAllowNone = false, ctrl = true })

    -- Gear: the two global gear pseudo-actions (NOT slots in ns.SLOTS — bound by id like the rest).
    -- DEV-ONLY: a normal user only needs the two Main keybinds; per-slot + gear keybinds are a dev nicety.
    sectionAt("Gear", true)
    tableRow("equipGear", "Equip profile gear", { devOnly = true })
    tableRow("restoreGear", "Restore normal gear", { devOnly = true })

    -- Slots: every keyable slot in display order. Skip fishing/interact (their rows are under Main). DEV-ONLY.
    sectionAt("Slots", true)
    local ordered = {}
    for _, s in ipairs(ns.SLOTS) do ordered[#ordered + 1] = s end
    table.sort(ordered, function(a, b) return (a.display or 99) < (b.display or 99) end)
    for _, s in ipairs(ordered) do
      if s.id ~= "fishing" and s.id ~= "interact" then
        tableRow(s.id, s.label, { devOnly = true })
      end
    end

    -- relayout: compute the visible columns + their x, then WALK items in build order assigning on-screen y by
    -- accumulating only the VISIBLE ones (a hidden item adds no height). Visibility:
    --   * devOnly sections/rows (Gear + Slots) hide for a non-dev user — SBF is one-button fishing, the per-slot
    --     and gear keybinds are a dev nicety;
    --   * the loot row hides outside two-button mode (single-button loots via the dynamic override);
    --   * in non-dev only the Main rows remain, so we hide ALL section headers (the lone "Main" header is
    --     redundant) for a clean two-row list.
    -- This single accumulating pass subsumes the old loot-row "lift everything below" hack.
    local function relayout()
      local dev = SBF.IsDev()
      local act = colsActive()
      local twoBtn = SBFDB.requireTwoButtons and true or false
      local lootHidden = not twoBtn
      -- left-to-right column order; assign x only to active columns
      local order = { "key1", "mouse", "ctrl" }
      local colX, x = {}, X0
      for _, key in ipairs(order) do
        if act[key] then colX[key] = x; x = x + CELL_W + KCOL_GAP end
      end
      -- headers: position active ones, hide the rest. Hide ALL column headers in non-dev (only Main shows there
      -- and the header row reads cleaner without it) — keep them in dev.
      for _, key in ipairs(order) do
        local h = headers[key]
        if dev and act[key] then h:ClearAllPoints(); h:SetPoint("TOPLEFT", colX[key], hdrY); h:Show()
        else h:Hide() end
      end
      hdrLine:SetShown(dev)

      local rowVisible = function(r) return not ((r.devOnly and not dev) or (r.isLoot and lootHidden)) end
      local secVisible = function(_) return dev end   -- non-dev: hide every section header (Main is redundant)

      -- start y: just below the header row in dev; reclaim the (now-hidden) header row's space in non-dev so
      -- the two Main rows sit right under the intro line with no empty gap.
      local cy = dev and contentTop or hdrY
      local bottom = cy
      for _, it in ipairs(items) do
        if it.kind == "section" then
          local sec = it.ref
          if secVisible(sec) then
            sec.h:ClearAllPoints(); sec.h:SetPoint("TOPLEFT", 4, cy); sec.h:Show()
            sec.ln:ClearAllPoints()
            sec.ln:SetPoint("TOPLEFT", 4, cy - 16); sec.ln:SetPoint("TOPRIGHT", -8, cy - 16); sec.ln:Show()
            cy = cy - it.h
          else
            sec.h:Hide(); sec.ln:Hide()
          end
        else                                         -- row
          local r = it.ref
          if rowVisible(r) then
            r.lbl:ClearAllPoints(); r.lbl:SetPoint("TOPLEFT", 4, cy - 3); r.lbl:Show()
            for _, key in ipairs(order) do
              local c = r.cells[key]
              if c then
                -- re-read the underlying binding so a value set elsewhere (e.g. the welcome's mouse picker)
                -- shows here instead of the stale text the cell was created with.
                if c._refresh then c._refresh() end
                if act[key] then c:ClearAllPoints(); c:SetPoint("TOPLEFT", colX[key], cy); c:Show()
                else c:Hide() end
              end
            end
            cy = cy - it.h
            if cy < bottom then bottom = cy end
          else
            r.lbl:Hide(); for _, c in pairs(r.cells) do c:Hide() end
          end
        end
      end
      pKeysChild:SetHeight(math.max(10, -bottom + 12))
    end
    panel._refreshKeysPage = relayout
    relayout()
  end

  panel:HookScript("OnShow", function()
    SBFDB.shown = true; updateSaveState()
    if refreshProfileBar then refreshProfileBar() end
    -- Do NOT rebuild the slot rows here. refreshLootUI() calls rebuildRows(), which CreateFrames a fresh row
    -- (+ its catalog-strip buttons) per slot every open — and WoW frames never GC, so every /sbf open leaked
    -- ~11 rows and their children. That rebuild is also vestigial: the interact row it managed was removed
    -- from the slot list, and the strips already re-render below via the deferred reLayoutScroll. The rows
    -- built once at Build() (and rebound by the profile/Revert paths) are still valid. (Keybind Loot row is
    -- reconciled by _refreshKeysPage.)
    if panel._refreshKeysPage then panel._refreshKeysPage() end   -- reconcile the Keybinds tab's Loot row too
    C_Timer.After(0, reLayoutScroll)                              -- re-renders every catalog strip in place (no new frames)
    -- re-derive the min-size + re-place columns once shown (font metrics / page width are reliable now).
    -- computeButtonsMin first (measures the Buttons-page extents now they're laid out), then _applyMinWidth
    -- (Settings min) — both fold into _applyWindowMin so the floor is the MAX of both pages on each axis.
    -- SKIP entirely while collapsed: the content is hidden so the measurements are invalid/zero (they'd
    -- overwrite the stored mins with garbage), and enforcing the floor would grow + un-collapse the window.
    -- The stored mins from the last expanded state stay valid until the next expand.
    C_Timer.After(0, function()
      if SBFDB and SBFDB.collapsed then return end
      if panel._computeButtonsMin then panel._computeButtonsMin() end
      if panel._applyMinWidth then panel._applyMinWidth() end
      if panel._colReflow then panel._colReflow() end
    end)
  end)
  panel:HookScript("OnHide", function() SBFDB.shown = false end)
  local startTab = SBFDB.optTab or "buttons"
  ShowTab(startTab)
end

function SBF.InitOptions()
  if not panel then Build() end
end

function SBF.ShowOptions()
  if not panel then Build() end
  panel:Show(); panel:Raise()
  if SBFDB.collapsed and panel._setCollapsed then panel._setCollapsed(true) end
end

-- Open the window (building it if needed) AND switch to a named tab (e.g. "buttons"). Used by the
-- dirty-on-leave prompt's "Open" button so the user lands on the slot/profile page to review edits.
function SBF.OpenToTab(key)
  SBF.ShowOptions()
  if key then
    SBFDB.optTab = key
    if panel and panel._showTab then panel._showTab(key) end
  end
end

-- recover a window whose resize grip ended up off-screen: reset size + recentre. Reachable
-- from the "Reset window" button and the /sbf window slash command.
function SBF.ResetWindow()
  if not panel then Build() end
  if panel._resetWindow then panel._resetWindow() end
  panel:Show(); panel:Raise()
end

function SBF.ToggleOptions()
  if not panel then Build() end
  if panel:IsShown() then panel:Hide() else SBF.ShowOptions() end
end


-- ===== Focus fishing audio settings (the "Audio settings…" popup) =====
-- A small movable frame: 5 volume sliders (master/SFX/music/ambience/dialog) writing SBFDB.focusAudio.*.
-- PREVIEW: while the popup is open it applies the focus preset LIVE so you hear your changes as you drag
-- (snapshot on open, restore on close) — unless focus audio is genuinely applied (mid-fishing), in which
-- case edits just re-apply that CVar and we don't touch the on/off state. Music/ambience ENABLE is forced
-- on by the preset, so the volume slider is the single control (no separate enable checkboxes).
local focusAudioFrame
function SBF.ShowFocusAudio()
  local function fa() SBFDB.focusAudio = SBFDB.focusAudio or {}; return SBFDB.focusAudio end
  local function live() return (SBF.CharGear and SBF.CharGear().audioOn) or SBF._audioPreview end  -- CVars are live?
  if not focusAudioFrame then
    local f = CreateFrame("Frame", "SBFFocusAudio", UIParent, "BackdropTemplate")
    focusAudioFrame = f
    -- 5 sliders. The MinimalSliderWithSteppersTemplate has ~TPL_TOP_PAD px of INTERNAL top padding above
    -- its visible track (the frame top sits well above the bar), so anchoring the frame AT the label
    -- baseline already yields ~TPL_TOP_PAD of visual gap. We want a TIGHT label->track gap (about half the
    -- old spacing) with the dominant break BETWEEN rows. So: target a small VIS_GAP, derive the frame-top
    -- offset = max(0, VIS_GAP - TPL_TOP_PAD) (the template padding already covers most of it), and put the
    -- big break below via INTER_ROW. Same INTER_ROW applies below the last slider before the button bar.
    local TOP = 56            -- y of the first slider's label
    local TPL_TOP_PAD = 12    -- the template's internal top padding (frame top -> visible track)
    local VIS_GAP = 18        -- desired VISUAL gap label -> track (matches the opacity slider's -6 offset)
    local LBL_GAP = math.max(0, VIS_GAP - TPL_TOP_PAD)   -- extra frame-top offset beyond the template padding
    local SLIDER_H = 24       -- the template's full rendered height (track + stepper hit area)
    local INTER_ROW = 26      -- slider BOTTOM -> next row's label (the dominant, between-rows gap)
    local ROW_GAP = LBL_GAP + SLIDER_H + INTER_ROW   -- label-to-label pitch
    f._lastSliderBottom = TOP + (5 - 1) * ROW_GAP + LBL_GAP + SLIDER_H   -- y-depth of the 5th slider's bottom
    f:SetSize(320, f._lastSliderBottom + INTER_ROW + 38)   -- + the same row gap below the last + the button bar
    f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    do local bg = Theme.colors.panelBg; f:SetBackdropColor(bg[1], bg[2], bg[3], 0.97) end
    f:SetBackdropBorderColor(unpack(Theme.colors.panelBorder))
    tinsert(UISpecialFrames, "SBFFocusAudio")
    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10); title:SetText(Theme.Accent("Focus fishing audio"))
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", 2, 2)
    local note = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 12, -28); note:SetWidth(296); note:SetJustifyH("LEFT")
    note:SetText("Sound levels SBF switches to while fishing — you hear changes live here. Restored when you close.")

    f._sliders = {}
    -- one labelled 0-100% slider bound to fa()[key]; live-applies the CVar while the preview/fishing is on.
    local function slider(i, label, key)
      local y = -(TOP + (i - 1) * ROW_GAP)                 -- this row's LABEL baseline
      local l = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      l:SetPoint("TOPLEFT", 14, y); l:SetText(label)
      local val = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      val:SetPoint("TOPRIGHT", -14, y)
      local sl = CreateFrame("Frame", nil, f, "MinimalSliderWithSteppersTemplate")
      -- Anchor the frame top just below the label baseline (LBL_GAP). The template's ~TPL_TOP_PAD internal
      -- top padding means the visible TRACK lands ~LBL_GAP+TPL_TOP_PAD below the label — about half the old
      -- spacing — so the label hugs its slider, and INTER_ROW puts the dominant break before the next row.
      sl:SetWidth(290); sl:SetPoint("TOPLEFT", 16, y - LBL_GAP)
      Theme.SkinSlider(sl)   -- palette thumb/stepper tint ONLY; keep the custom Init/callback/anchor + live-CVar preview
      local function show(v) val:SetText(string.format("%d%%", math.floor(v * 100 + 0.5))) end
      pcall(function()
        sl:Init(fa()[key] or 0, 0, 1, 20, {})
        sl:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
          fa()[key] = v; show(v)
          if live() and SBF.SetFocusCVar then SBF.SetFocusCVar(key, v) end   -- audible while preview/fishing
        end, sl)
      end)
      show(fa()[key] or 0)
      f._sliders[key] = { sl = sl, show = show }
    end
    slider(1, "Master", "master")
    slider(2, "Sound effects", "sfx")
    slider(3, "Music", "music")
    slider(4, "Ambience", "ambience")
    slider(5, "Dialog", "dialog")

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(130, 22); reset:SetPoint("BOTTOMLEFT", 12, 10); reset:SetText("Reset to default"); Theme.Button(reset)
    reset:SetScript("OnClick", function()
      local d = { master = 1.0, sfx = 1.0, music = 0.0, ambience = 0.0, dialog = 0.3 }
      for k, v in pairs(d) do
        fa()[k] = v
        if live() and SBF.SetFocusCVar then SBF.SetFocusCVar(k, v) end
      end
      -- re-assert the forced music/ambience enables so a fresh preset is audible
      if live() and SBF._applyPresetCVars then SBF._applyPresetCVars(fa()) end
      f._sync()
    end)
    local doneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    doneBtn:SetSize(80, 22); doneBtn:SetPoint("BOTTOMRIGHT", -12, 10); doneBtn:SetText("Close"); Theme.Button(doneBtn)
    doneBtn:SetScript("OnClick", function() f:Hide() end)

    -- re-sync every slider from saved values (used on open + after Reset)
    function f._sync()
      for key, s in pairs(f._sliders) do pcall(function() s.sl:SetValue(fa()[key] or 0) end); s.show(fa()[key] or 0) end
    end

    -- PREVIEW lifecycle: on OnHide (covers Close button, Escape via UISpecialFrames, and any hide), if we
    -- started a preview, restore the player's snapshot and clear the flag. Never touch a genuine on-fish
    -- apply (CharGear().audioOn) — that's restored by the normal stop/idle/login path. Guarded so a second
    -- hide can't double-restore.
    f:SetScript("OnHide", function()
      if SBF._audioPreview then
        SBF._audioPreview = nil
        if SBF._restoreAudioCVars then SBF._restoreAudioCVars() end
      end
    end)
  end
  -- OPEN: start a live preview unless focus audio is already genuinely applied (mid-fishing). Snapshot the
  -- player's current CVars, then apply the preset so the sliders are audible. If audioOn is already true,
  -- leave it alone (edits re-apply live anyway) and don't start/again-snapshot a preview.
  if not (SBF.CharGear and SBF.CharGear().audioOn) and not SBF._audioPreview then
    if SBF._snapshotAudio then SBF._snapshotAudio() end
    if SBF._applyPresetCVars then SBF._applyPresetCVars(fa()) end
    SBF._audioPreview = true
  end
  focusAudioFrame._sync()
  focusAudioFrame:Show(); focusAudioFrame:Raise()
end
