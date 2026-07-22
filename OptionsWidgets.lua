-- OptionsWidgets.lua — the reusable SBF options UI toolkit, extracted from Options.lua.
-- Loads BEFORE Options.lua. Everything Build() still calls is published on `ns.opt`
-- (re-bound to local names at the top of Options.lua, so call sites there are unchanged).
-- The window handle itself lives in Options.lua and is reached here via ns.opt.panel.
local ADDON, ns = ...

-- Shared GECTheme handle (per-addon palette via SBFDB.themePreset). Every access through this proxy
-- first re-activates SBF's preset, so reading Theme.colors.X always returns SBF's palette — even from a
-- closure that runs later (mirrors the taint-safe-widgets / closure-capture rule).
local Theme = LibStub("GECTheme-1.0").ForAddon(
  function() return (SBFDB and SBFDB.themePreset) or "everforest" end,
  function(v) SBFDB.themePreset = v end)

-- Shared keybinding lib (native-binding capture cell + conflict prompt). Used for the fishing/interact cells.
local GECBind = LibStub:GetLibrary("GECBind-1.0")

ns.opt = ns.opt or {}

-- ---- SBF-local palette helpers (Stage 1: recolor-only; structure unchanged) ----
-- Apply the unselected / selected slot-cell look from the palette. Called at paint time (incl. from
-- later-running render closures), so each call re-activates SBF's preset via the Theme proxy before
-- reading colors — no stale/cross-addon palette can leak in.
local function paintSlot(b, selected)   -- generic icon/action/custom cell fill+border
  local c = Theme.colors
  if selected then
    b:SetBackdropColor(unpack(c.slotFillSelected)); b:SetBackdropBorderColor(unpack(c.slotBorderSelected))
  else
    b:SetBackdropColor(unpack(c.slotFill)); b:SetBackdropBorderColor(unpack(c.slotBorder))
  end
end
-- accent as r,g,b (for the few APIs that take RGB, not a "|cff" hex string — tooltips, fontstrings)
local function accentRGB() return Theme.HexToRGB(Theme.accentHex) end

-- mark the working copy dirty AND refresh the Save button's enabled state (panel._updateSaveState is
-- set when the Buttons page is built). One helper so every slot-config edit site stays a one-liner.
-- SIMPLE mode (advancedMode == false): Save/Revert are hidden, so AUTO-COMMIT each edit to the active
-- profile right after marking dirty — a casual user's changes stick without a Save button.
local function markDirty(def)
  -- combat/heal live in SBF.CharSlots (per-character), NOT in the profile working copy — their edits
  -- persist immediately on the live table, so they must NOT mark the working copy dirty or light up Save.
  -- Char-slot defs carry an `id`; profile slot defs don't, so an id of "combat"/"heal" identifies them.
  if def and (def.id == "combat" or def.id == "heal") then return end
  if SBF.MarkDirty then SBF.MarkDirty() end
  if SBFDB.advancedMode == false and SBF.SaveWorking then SBF.SaveWorking() end
  local panel = ns.opt.panel
  if panel and panel._updateSaveState then panel._updateSaveState() end
end
local catalogStrips = {}   -- each slot strip registers a collapse fn; leaving the Buttons tab folds them all
local catalogStripRenders = {}   -- each strip registers its render fn; called on window resize to re-wrap icons

local IGNORE_KEYS = {
  LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
  LALT = true, RALT = true, UNKNOWN = true,
}

local function ItemTexture(item)
  if not item or item == "" then return nil end
  return select(5, GetItemInfoInstant(item))
end

local function ClearDef(def)
  def.item, def.spell, def.macro, def.toy, def.icon = nil, nil, nil, nil, nil
end

-- per-slot DEFAULT icon: when an action slot has no user content, show a dim (desaturated) icon that reads
-- as intentionally-defaulted instead of a blank box. fishing -> the Fishing spell icon; combat -> a generic
-- gear icon (the seeded /targetenemy + Single-Button Assistant default); everything else (incl. heal) -> none.
local FISHING_SPELL_ID = 131474
local function DefaultSlotTexture(slotId, def)
  if slotId == "fishing" then
    if def.item or def.spell or def.toy or (def.macro and def.macro ~= "") then return nil end
    return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(FISHING_SPELL_ID)) or nil
  elseif slotId == "combat" then
    local empty = not (def.item or def.spell or def.toy or (def.macro and def.macro ~= ""))
    if empty or def.macro == ns.DEFAULT_COMBAT_MACRO then return "Interface\\Icons\\Trade_Engineering" end
  end
  return nil
end

function ns.UpdateItemIcon(b, def)
  local tex = def.icon
  if not tex then
    if def.item then tex = ItemTexture(def.item)
    elseif def.spell and C_Spell and C_Spell.GetSpellTexture then tex = C_Spell.GetSpellTexture(def.spell)
    elseif def.toy and C_Item and C_Item.GetItemIconByID then tex = C_Item.GetItemIconByID(def.toy) end
  end
  local isDefault = false
  if not tex then                       -- no real content: fall back to a dim per-slot default (fishing/combat)
    local dtex = DefaultSlotTexture(b.slotId, def)
    if dtex then tex = dtex; isDefault = true end
  end
  b._isDefault = isDefault
  b.icon:SetTexture(tex or "")
  b.icon:SetShown(tex ~= nil)   -- empty slot (heal, cleared) shows just the border
  b.icon:SetDesaturated(isDefault)   -- real content is full-color; a default reads dimmed
  if b.SetBackdropBorderColor then   -- action/custom slots: accent frame when something's in them (like a selected cell)
    paintSlot(b, tex ~= nil)         -- a default icon still looks "filled" (accent border on) — it reads as set
  end
end

-- accept whatever's on the cursor: item, spell, macro (copies its body), or toy
function ns.PlaceCursor(def, b, onChange)
  local kind, d1, d2, d3 = GetCursorInfo()
  if not kind then return end
  ClearDef(def)
  if kind == "item" then
    def.item = d2 or ("item:" .. tostring(d1)); def.icon = ItemTexture(def.item)
  elseif kind == "spell" then
    def.spell = d3
    if C_Spell and C_Spell.GetSpellTexture then def.icon = C_Spell.GetSpellTexture(d3) end
  elseif kind == "macro" then
    local _, icon, body = GetMacroInfo(d1)
    def.macro = body; def.icon = icon
  elseif kind == "toy" then
    def.toy = d1
    if C_Item and C_Item.GetItemIconByID then def.icon = C_Item.GetItemIconByID(d1) end
  else
    return   -- unsupported cursor type
  end
  ClearCursor()
  ns.UpdateItemIcon(b, def)
  markDirty(def)   -- dropped an item/spell/macro/toy into a slot -> unsaved edit (skipped for char-slots)
  if onChange then onChange() end
  if SBF.Apply then SBF.Apply() end
end

------------------------------------------------------------ catalog tray ----
-- Inline icon tray: each catalog slot shows its picked items (def.items, an ordered
-- "run it out" list) as icons that wrap 10-per-row in a band BELOW the slot's line-1
-- controls. The deposit "+" square opens a flyout strip of OWNED options (click to
-- toggle); dragging a bag item onto it also adds. Right-click a tray icon to remove.
-- PHASE 1: firing still runs off def.item, mirrored to the FIRST tray item — nothing
-- about fishing changes yet; run-it-out / random land in the firing path in phase 2.
local CATALOG_SLOT = {
  food = "food", drink = "drink", bobber = "bobber", oversized = "oversized", lure = "lure",
  poleenchant = "poleenchant", chum1 = "chum_skill", chum2 = "chum_perception", boat = "boat",
  -- the fireAll Buffs slot: its own catalog key, so the flyout shows ONLY items dropped into Buffs (tagged
  -- slots.buffs), like every other slot — NOT every learned item. (It used to be "_all" = flood the flyout
  -- with everything learned, which pulled in lure/chum/food items meant for other slots. A curated
  -- "suggested buffs" list is a separate future feature.)
  buffs = "buffs",
}
ns.CATALOG_SLOT = CATALOG_SLOT
-- Spells that work like a dinghy (cast underwater, float, fish, knocked down on hit). Shown as built-in
-- suggestions in the Boat flyout so priests/monks discover them. Add future ones here. IDs verified in-game.
-- Always-available water-walk / falling-boat SPELLS the Boat flyout offers on EVERY character (greyed if the
-- class can't cast it). These are class abilities, not items, so they never come from the item catalog — this
-- list is the ONLY thing that keeps them from vanishing per-character once removed.
local BOAT_SPELLS = { 546, 1706, 3714, 125883 }   -- Water Walking (Sham), Levitate (Priest), Path of Frost (DK), Zen Flight (Monk)
ns.BOAT_SPELLS = BOAT_SPELLS
local ROW_H, TRAY_COLS, ICON, GAP = 44, 9, 37, 6   -- ICON 37 = game-standard (bag / action-bar) icon size

-- flat modern slot: dark fill + a thin cool border that fills the cell EXACTLY. Used by every icon
-- button (cells, empty handle, action/custom slots) so empty and filled share one frame at full size.
local SLOT_BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 2, insets = { left = 2, right = 2, top = 2, bottom = 2 },
}
local function styleSlot(b)
  b:SetBackdrop(SLOT_BACKDROP)
  paintSlot(b, false)   -- palette slotFill + slotBorder (unselected look)
end

-- mouseover help: pull the entry from Help.lua by key (at hover time, so /reload updates it).
local function helpTip(frame, key)
  if not key then return end
  frame:HookScript("OnEnter", function(self)
    local h = SBF.GetHelp and SBF.GetHelp(key); if not h then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(h.title or key, accentRGB())
    if h.body then GameTooltip:AddLine(h.body, 0.85, 0.85, 0.85, true) end
    GameTooltip:Show()
  end)
  frame:HookScript("OnLeave", GameTooltip_Hide)
end
-- make a font label hoverable for help (font strings aren't mouse-enabled on their own)
local function helpLabel(fs, key)
  if not key then return end
  local z = CreateFrame("Frame", nil, fs:GetParent()); z:EnableMouse(true)
  z:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 2); z:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -2)
  helpTip(z, key)
end

-- one section-header fixture (accent title + a faint divider line) used by every settings page, so
-- sections look identical everywhere. Body routes through Theme.SectionHeader (accent title + base font);
-- we then re-span its returned underline FULL WIDTH (the lib draws a fixed-width line) to keep SBF's look.
local function sectionHeader(parent, y, text)
  local _, ln = Theme.SectionHeader(parent, 4, y, text)
  if ln then
    ln:ClearAllPoints()
    ln:SetPoint("TOPLEFT", 4, y - 16); ln:SetPoint("TOPRIGHT", -8, y - 16)
    ln:SetColorTexture(unpack(Theme.colors.divider))   -- lib uses a brighter line; keep SBF's faint divider
  end
end

local function slotIcon(e)
  local sid = ns.spellEntry and ns.spellEntry(e)
  if sid then return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)) or 134400 end
  return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e))
    or (GetItemIcon and GetItemIcon(e)) or 134400
end
local function slotLink(id) local _, l = GetItemInfo(id); return l or ("item:" .. id) end

local function inItems(def, id)
  for _, x in ipairs(def.items or {}) do if x == id then return true end end
end
local function addItem(def, id)
  def.items = def.items or {}
  if not inItems(def, id) then def.items[#def.items + 1] = id end
end
local function removeItem(def, id)
  local out = {}
  for _, x in ipairs(def.items or {}) do if x ~= id then out[#out + 1] = x end end
  def.items = out
end
-- move fromId next to toId in the run-it-out order. `after` = dropped on the RIGHT half of the
-- target (place after it) vs the left half (before it).
local function reorderItems(def, fromId, toId, after)
  if fromId == toId or not def.items then return end
  local fromIdx
  for i, x in ipairs(def.items) do if x == fromId then fromIdx = i; break end end
  if not fromIdx then return end
  table.remove(def.items, fromIdx)
  local toIdx
  for i, x in ipairs(def.items) do if x == toId then toIdx = i; break end end
  if not toIdx then table.insert(def.items, fromId); return end
  table.insert(def.items, after and (toIdx + 1) or toIdx, fromId)
end

-- a cursor-following "ghost" icon so a drag looks like you're holding the item
local dragGhost
local function ensureGhost()
  if dragGhost then return dragGhost end
  dragGhost = CreateFrame("Frame", nil, UIParent)
  dragGhost:SetSize(30, 30); dragGhost:SetFrameStrata("TOOLTIP"); dragGhost:EnableMouse(false)
  dragGhost.tex = dragGhost:CreateTexture(nil, "OVERLAY"); dragGhost.tex:SetAllPoints()
  dragGhost.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  dragGhost:SetScript("OnUpdate", function(self)
    local x, y = GetCursorPosition(); local s = UIParent:GetEffectiveScale()
    self:ClearAllPoints(); self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
  end)
  dragGhost:Hide()
  return dragGhost
end
-- mirror the first tray item into the legacy single def.item so today's firing works
local function syncDefItem(def)
  local first = def.items and def.items[1]
  local sid = first and ns.spellEntry and ns.spellEntry(first)
  if sid then def.spell = sid; def.item, def.macro, def.toy = nil, nil, nil
  elseif first then def.item = slotLink(first); def.macro = nil; def.toy = nil; def.spell = nil
  elseif def.items then def.item = nil end
  if SBF.Apply then SBF.Apply() end
end

-- The unified inline strip (right of the name). COLLAPSED shows only the SELECTED items
-- (def.items, an ordered "run it out" list) as clean icons; one empty slot when none.
-- Click an icon (or the empty slot) -> it EXPANDS to show every owned candidate (selected
-- = bright + glow, unselected = dim); click to toggle. Click the strip again to collapse —
-- unselected vanish. The LAST cell is the "R" random toggle, icon-styled and butted against
-- the list. The strip IS both the picker and the display. Returns the row height.
local STRIP_X = 120
local function buildCatalogSlot(r, def, slotKey, reflow)
  def.items = def.items or {}
  if #def.items == 0 and def.item then                 -- migrate a legacy single item in
    local id = GetItemInfoInstant(def.item); if id then def.items[1] = id end
  end
  local catSlot = CATALOG_SLOT[slotKey]
  local slotDef = ns.SlotDef and ns.SlotDef(slotKey)   -- descriptor: gates random + the repeat field
  local expanded, cells, render, dragFrom = false, {}, nil, nil
  local layoutCols = TRAY_COLS                           -- live column count, recomputed each render from the scroll width

  local strip = CreateFrame("Button", nil, r)
  strip:SetPoint("TOPLEFT", STRIP_X, -4); strip:RegisterForDrag("LeftButton")
  strip:SetScript("OnClick", function() expanded = not expanded; render() end)
  local function receiveDrop()                           -- shared by the strip, the empty handle, and cells
    local kind, d1, d2, d3 = GetCursorInfo()
    local entry, learnId
    if kind == "spell" and slotDef and slotDef.allowsSpell then
      local sid = d3 or d2 or d1          -- spell cursor: the spellID return; index varies by client (VERIFY)
      entry = sid and ("spell:" .. sid) or nil
    else
      local id = (kind == "item" and GetItemInfoInstant(d2 or d1)) or (kind == "toy" and d1)
      entry, learnId = id, id
    end
    if entry then
      addItem(def, entry); syncDefItem(def); render(); ClearCursor()
      markDirty()           -- item/spell added -> unsaved edit
      if learnId and ns.LearnItem then ns.LearnItem(learnId, catSlot) end   -- only real items grow the catalog
    end
  end
  strip:SetScript("OnReceiveDrag", receiveDrop)

  -- how many icons fit across the CURRENT scroll width (the scroll child grows with the window)
  local function colsFor()
    local content = r:GetParent()
    local avail = ((content and content:GetWidth()) or 512) - STRIP_X - 10
    return math.max(1, math.floor(avail / (ICON + GAP)))
  end
  local function place(b, idx)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", idx % layoutCols * (ICON + GAP), -math.floor(idx / layoutCols) * (ICON + GAP))
    b:Show()
  end
  local function cell(i)
    if cells[i] then return cells[i] end
    local b = CreateFrame("Button", nil, strip, "BackdropTemplate"); b:SetSize(ICON, ICON)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- drag a SELECTED icon onto another to reorder the run-it-out order. On release we find the
    -- cell under the cursor (left half = drop before it, right half = after). No re-render during
    -- the drag (that cancels it), and no cursor item, so it won't conflict with bag drops.
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
      if not inItems(def, self.id) then return end
      dragFrom = self.id; self.icon:SetAlpha(0.3)
      local g = ensureGhost(); g.tex:SetTexture(self.icon:GetTexture()); g:Show()
    end)
    b:SetScript("OnDragStop", function(self)
      self.icon:SetAlpha(1); if dragGhost then dragGhost:Hide() end
      if not dragFrom then return end
      local cx = GetCursorPosition()
      for _, c in ipairs(cells) do
        if c:IsShown() and c.id and c ~= self and inItems(def, c.id) and c:IsMouseOver() then
          local mid = (c:GetLeft() + c:GetWidth() / 2) * c:GetEffectiveScale()
          reorderItems(def, dragFrom, c.id, cx > mid)
          markDirty()       -- reordered the run-it-out list -> unsaved edit
          break
        end
      end
      dragFrom = nil; syncDefItem(def); render()
    end)
    styleSlot(b)                                              -- flat dark fill + thin border, identical empty or filled
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("TOPLEFT", 2, -2); b.icon:SetPoint("BOTTOMRIGHT", -2, 2)   -- inside the border
    b.hl = b:CreateTexture(nil, "OVERLAY"); b.hl:SetAllPoints()
    b.hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square"); b.hl:SetBlendMode("ADD")   -- square, matches the square border
    b.buffDot = b:CreateTexture(nil, "OVERLAY"); b.buffDot:SetSize(8, 8)   -- green = buff learned
    b.buffDot:SetPoint("BOTTOMRIGHT", -1, 1); b.buffDot:SetColorTexture(0.2, 1, 0.2); b.buffDot:Hide()
    b.countFS = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")   -- bag stack count (bottom-left); items only
    b.countFS:SetPoint("BOTTOMLEFT", 2, 1); b.countFS:SetJustifyH("LEFT"); b.countFS:Hide()
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:SetScript("OnReceiveDrag", receiveDrop)            -- drop a bag item onto a cell to add it
    cells[i] = b
    return b
  end

  -- the MODE cell: same size as the item icons, cycling cycle -> deplete -> random on click
  -- (random skipped when the slot doesn't allow it). Each mode has its own glyph + colour so the
  -- active firing mode reads at a glance:
  --   cycle   "C" cyan  = a different item each cast (variety, A->B->C->A)
  --   deplete "D" amber = use the first owned until it's gone, then advance ("run it out")
  --   random  "R" green = a random owned one each cast (never the immediate previous)
  local MODE_GLYPH = { cycle = "C", deplete = "D", random = "R" }
  local MODE_TIP = {
    cycle = "Cycle: a different item each cast (A->B->C->A).",
    deplete = "Deplete: use the first owned item until it's gone, then advance (\"run it out\").",
    random = "Random: a random owned item each cast (never the immediately-previous one).",
  }
  -- paint colours per mode: { border{r,g,b}, fill{r,g,b}, text{r,g,b} }. The three modes stay visually
  -- distinct (cycle = cool/cyan, deplete = accent/amber, random = green), but are built from the palette
  -- at paint time so they track the active preset: deplete follows the theme accent; all fills are tinted
  -- toward the preset's slotFill so a light preset doesn't get a near-black cell.
  local function modeCol(m)
    local ar, ag, ab = accentRGB()
    if m == "deplete" then return { ar, ag, ab,  ar * 0.18, ag * 0.14, ab * 0.05,  ar, ag, ab * 0.55 } end
    if m == "random"  then return { 0.45, 0.85, 0.45,  0.05, 0.14, 0.05,  0.55, 1.00, 0.55 } end
    return                     { 0.40, 0.72, 0.95,  0.04, 0.10, 0.16,  0.55, 0.80, 1.00 }   -- cycle
  end
  local function curMode() return (ns.SlotMode and slotDef and ns.SlotMode(slotDef, def)) or def.mode or "cycle" end
  local function nextMode(m)
    if m == "cycle" then return "deplete" end
    if m == "deplete" then return (slotDef and slotDef.allowsRandom) and "random" or "cycle" end
    return "cycle"   -- random -> cycle
  end
  local rbtn = CreateFrame("Button", nil, strip, "BackdropTemplate"); rbtn:SetSize(ICON, ICON)
  styleSlot(rbtn)                                          -- flat frame, matching the icon cells
  rbtn.hl = rbtn:CreateTexture(nil, "OVERLAY"); rbtn.hl:SetAllPoints()
  rbtn.hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square"); rbtn.hl:SetBlendMode("ADD")
  rbtn.txt = rbtn:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge"); rbtn.txt:SetPoint("CENTER")
  local function paintR()
    local m = curMode()
    local c = modeCol(m)
    rbtn:SetBackdropBorderColor(c[1], c[2], c[3], 1); rbtn:SetBackdropColor(c[4], c[5], c[6], 0.7)
    rbtn.txt:SetTextColor(c[7], c[8], c[9]); rbtn.txt:SetText(MODE_GLYPH[m] or "C")
    rbtn.hl:Show()
  end
  rbtn:SetScript("OnClick", function() def.mode = nextMode(curMode()); markDirty(); render() end)
  rbtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Firing mode")
    GameTooltip:AddLine(MODE_TIP[curMode()] or "", 1, 1, 1, true)
    GameTooltip:AddLine("Click to change mode.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  rbtn:SetScript("OnLeave", GameTooltip_Hide)

  -- (the chum "throw N" burst count moved OFF the row into the right-click slot config — see ShowSlotConfig)

  -- the empty / collapse handle: one icon-sized empty square. Click toggles expand/collapse.
  local ehandle = CreateFrame("Button", nil, strip, "BackdropTemplate"); ehandle:SetSize(ICON, ICON)
  styleSlot(ehandle)
  ehandle:SetScript("OnClick", function()
    local ck = GetCursorInfo()
    if ck == "item" or ck == "toy" then receiveDrop(); return end  -- held item dropped -> add it
    expanded = not expanded; render()
  end)
  ehandle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(expanded and "Click to collapse" or "Fill this slot")
    if not expanded then
      local kinds = (slotDef and slotDef.allowsSpell) and "item, toy, macro, or spell" or "item, toy, or macro"
      GameTooltip:AddLine("Drag an " .. kinds .. " here to fill it.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  ehandle:SetScript("OnLeave", GameTooltip_Hide)
  ehandle:SetScript("OnReceiveDrag", receiveDrop)        -- empty slot: drop a bag item to add it

  local function ownedOf(id)
    local sid = ns.spellEntry and ns.spellEntry(id)
    if sid then return (IsSpellKnown and IsSpellKnown(sid)) or false end   -- spell entry: "owned" = you know it
    return (GetItemCount(id) or 0) > 0 or (type(PlayerHasToy) == "function" and PlayerHasToy(id)) or false
  end
  local function showUnowned(source)                   -- governed by the two Settings checkboxes
    if source == "toy" then return SBFDB.showUnownedToys ~= false end
    return SBFDB.showUnownedItems ~= false
  end
  -- 3-tier picker visibility (see Settings → Item pickers): carrying it (bags) always shows; an account
  -- collectible you OWN (a toy/boat, or a known spell) shows when "Show Warband items" is on; something you
  -- don't own shows (grayed) when its show-unowned toggle is on. Returns show(bool), owned(bool).
  local function pickShow(id, source)
    local sid = ns.spellEntry and ns.spellEntry(id)
    if sid then
      if IsSpellKnown and IsSpellKnown(sid) then return SBFDB.showWarbandItems ~= false, true end
      return showUnowned(source or "item"), false
    end
    if (GetItemCount(id) or 0) > 0 then return true, true end                       -- in bags → always
    if type(PlayerHasToy) == "function" and PlayerHasToy(id) then                   -- account collectible you own
      return SBFDB.showWarbandItems ~= false, true
    end
    return showUnowned(source), false                                               -- unowned → grayed if toggle on
  end
  local function entries()                              -- {id, owned}; collapsed = selected only
    local out, seen = {}, {}
    -- selected items ALWAYS show (even if you no longer own them — grayed out as a reminder)
    for _, id in ipairs(def.items) do out[#out + 1] = { id = id, owned = ownedOf(id) }; seen[id] = true end
    if expanded then                                    -- expanded adds the rest of the catalog
      for _, it in ipairs((ns.OwnedCatalog and ns.OwnedCatalog(catSlot)) or {}) do
        if not seen[it.id] then
          local show, owned = pickShow(it.id, it.source)
          if show then
            out[#out + 1] = { id = it.id, owned = owned, learned = it.learned,
              zoneOk = it.zoneOk, maps = it.maps, allZones = it.allZones }; seen[it.id] = true
          end
        end
      end
      if slotKey == "boat" then                          -- built-in dinghy SUGGESTIONS (expanded only):
        for _, b in ipairs(ns.KNOWN_BOATS or {}) do       -- the curated boat toys (gated like everything else)
          if not seen[b.id] then
            local show, owned = pickShow(b.id, "toy")
            if show then out[#out + 1] = { id = b.id, owned = owned }; seen[b.id] = true end
          end
        end
        for _, sid in ipairs(BOAT_SPELLS) do              -- + the dinghy-like spells
          local key = "spell:" .. sid
          if not seen[key] then
            local show, owned = pickShow(key, "item")
            if show then out[#out + 1] = { id = key, owned = owned, spell = true }; seen[key] = true end
          end
        end
      end
    end
    return out
  end

  -- FORGET a learned (dropped-in) item: drop it from this profile's run-it-out list AND un-remember it
  -- as a candidate for THIS slot in the account-wide item DB (clear its slots[catSlot] tag), so a wrong-slot
  -- drop stops haunting the strip. Every slot (Buffs included now) is a real per-slot tag, so this no longer
  -- needs the old "_all = delete the whole record" special case. Only called for self.learned items.
  local function forgetItem(id)
    id = tonumber(id) or id
    removeItem(def, id); syncDefItem(def)
    local items = SBF.OutputDB and SBF.OutputDB("items")
    local rec = items and items[id]
    if rec and rec.slots and catSlot then rec.slots[catSlot] = nil end   -- un-tag this slot (account-wide)
    markDirty(); render()
  end

  render = function()
    layoutCols = colsFor()                               -- re-wrap to the current scroll width
    for _, b in ipairs(cells) do b:Hide() end
    rbtn:Hide(); ehandle:Hide()
    local list = entries()
    local idx = 0
    -- lead with an empty handle when nothing is selected, so every real icon stays selectable
    if #list == 0 or (expanded and #def.items == 0) then
      place(ehandle, idx); idx = idx + 1
    end
    for i, e in ipairs(list) do
      local b = cell(i)
      local id, owned = e.id, e.owned
      local active = inItems(def, id)                   -- highlighted = in the run-it-out list
      local isHandle = (idx == 0)                       -- the first cell is the expand/collapse toggle
      b.icon:Show(); b.icon:SetTexture(slotIcon(id)); b.icon:SetDesaturated(not owned)
      b:SetAlpha(owned and 1 or 0.4); b.hl:SetShown(active)
      paintSlot(b, active)   -- SELECTED = accent frame + warm fill; else flat slot look (palette-sourced)
      b.id, b.owned = id, owned
      local sid = ns.spellEntry and ns.spellEntry(id)
      if sid then
        b.learned, b.zoneOk, b.maps, b.allZones = nil, true, nil, nil   -- spells aren't zone-bound
        b.buffName = nil; b.buffDot:Hide()
        b.icon:SetVertexColor(1, 1, 1)
      else
        b.learned, b.zoneOk, b.maps, b.allZones = e.learned, e.zoneOk, e.maps, e.allZones
        b.buffName = (ns.knownBoatBuff and ns.knownBoatBuff(id))   -- curated boat: hardcoded buff (not the scrambled learned one)
          or (SBF.ItemKnow(id) and SBF.ItemKnow(id).buff)          -- else per-item buff; green dot = learned
        b.buffDot:SetShown(b.buffName ~= nil)
        -- orange tint = learned in-game but NOT confirmed for this zone (may not work here)
        if e.learned and not e.zoneOk then b.icon:SetVertexColor(1, 0.6, 0.25)
        else b.icon:SetVertexColor(1, 1, 1) end
      end
      -- bag stack count in the bottom-left corner — ONLY for real inventory items (consumables: chum/food/
      -- drink/lure/bobber). Spells and toys (boats) have no bag stack, so GetItemCount is 0 -> hidden.
      local count = (not sid) and GetItemCount and GetItemCount(id) or 0
      if count and count > 0 then b.countFS:SetText(count); b.countFS:Show() else b.countFS:Hide() end
      b:SetScript("OnEnter", function(self)
        local sid2 = ns.spellEntry and ns.spellEntry(self.id)
        if sid2 then
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetSpellByID(sid2)
          GameTooltip:AddLine(inItems(def, self.id) and "right-click: remove" or "left-click: add", 0.7, 0.7, 0.7)
          if not (IsSpellKnown and IsSpellKnown(sid2)) then GameTooltip:AddLine("You don't know this spell", 0.8, 0.5, 0.5) end
          GameTooltip:Show(); return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.id)
        local bags = GetItemCount(self.id) or 0
        if self.owned then
          GameTooltip:AddLine(bags > 0 and ("In bags: " .. bags) or "Owned (toy box)", 0.4, 1, 0.4)
        else
          GameTooltip:AddLine("You don't own this", 0.6, 0.6, 0.6)
        end
        GameTooltip:AddLine(inItems(def, self.id) and "right-click: remove" or "left-click: add", 0.7, 0.7, 0.7)
        if self.buffName then GameTooltip:AddLine("Buff: " .. self.buffName, 0.3, 1, 0.3)
        else GameTooltip:AddLine("Buff: not learned yet (cast it once)", 0.6, 0.6, 0.45) end
        if self.learned then
          if self.allZones then
            GameTooltip:AddLine("Works in all zones", 0.4, 1, 0.4)
          else
            local zs = {}; for _, n in pairs(self.maps or {}) do zs[#zs + 1] = n end
            GameTooltip:AddLine("Used in: " .. table.concat(zs, ", "), 0.6, 0.8, 1, true)
            if not self.zoneOk then GameTooltip:AddLine("|cffffaa00!|r not confirmed in THIS zone — may not work here") end
          end
          GameTooltip:AddLine("shift-click: forget (un-learn from this slot)", 1, 0.5, 0.5)
          GameTooltip:AddLine("shift-right-click: toggle works-in-all-zones", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
      end)
      b:SetScript("OnClick", function(self, button)
        local ck = GetCursorInfo()
        if ck == "item" or ck == "toy" then receiveDrop(); return end  -- held item dropped on a cell -> add
        if IsShiftKeyDown() and button == "RightButton" then           -- shift+right: works-in-all-zones (learned only)
          if self.learned and SBF.ItemKnow and SBF.ItemKnow(self.id) then
            local rec = SBF.ItemKnow(self.id)
            rec.allZones = (not rec.allZones) or nil        -- mark works-everywhere (silences the zone warning)
            rec.source = "user-added"
            render()
          end
          return
        end
        if button == "RightButton" then                 -- right-click removes from the run-it-out list, but KEEPS it
          if ns.LearnItem and not (ns.spellEntry and ns.spellEntry(self.id)) then
            ns.LearnItem(self.id, catSlot)              -- memorized as a candidate, so it stays in the expanded flyout
          end                                           -- (never truly vanishes); only shift-click forgets it
          removeItem(def, self.id); syncDefItem(def)
          markDirty()       -- item removed -> unsaved edit
          render(); return
        end
        if IsShiftKeyDown() and self.learned then        -- shift+left: FORGET a dropped-in item from this slot
          forgetItem(self.id); return
        end
        if not expanded then expanded = true; render(); return end   -- collapsed: any click expands
        if isHandle then expanded = false; render(); return end       -- expanded: first icon collapses
        if not inItems(def, self.id) then                             -- add (owned or not — firing skips a missing one)
          addItem(def, self.id); syncDefItem(def)
          markDirty()                    -- item added -> unsaved edit
        end
        render()
      end)
      place(b, idx); idx = idx + 1
    end
    -- the mode cell shows whenever there are items (or the strip is expanded), so the active firing
    -- mode is always visible. (The chum "throw N" burst count lives in the right-click config now.)
    -- fireAll slots (Buffs) have NO mode — keeping all buffs up IS the behaviour — so hide the cell.
    if (not (slotDef and slotDef.fireAll)) and (expanded or #def.items > 0) then
      place(rbtn, idx); paintR(); idx = idx + 1
    end
    local rows = math.max(math.ceil(idx / layoutCols), 1)
    local cols = math.min(math.max(idx, 1), layoutCols)
    strip:SetSize(cols * (ICON + GAP), rows * (ICON + GAP))
    r._height = math.max(ROW_H, rows * (ICON + GAP) + 12)
    r:SetHeight(r._height)
    if reflow then reflow() end
  end

  catalogStrips[#catalogStrips + 1] = function() if expanded then expanded = false; render() end end
  catalogStripRenders[#catalogStripRenders + 1] = render   -- re-wrap on window resize

  -- LIVE per-item buff badge: a buff is LEARNED on the first cast while this window is open, so the green
  -- "learned" dot + tooltip name would otherwise only appear after a close/reopen. Poll ~2x/sec and update
  -- the shown item cells IN PLACE — no render() (that re-wraps the whole strip and flickers). Item cells
  -- only; spells carry no learned buff. Cheap: only touches cells whose buff actually changed.
  strip._buffTick = 0
  strip:SetScript("OnUpdate", function(self, e)
    self._buffTick = self._buffTick + e
    if self._buffTick < 0.5 then return end
    self._buffTick = 0
    for _, b in ipairs(cells) do
      if b:IsShown() and b.id and not (ns.spellEntry and ns.spellEntry(b.id)) then
        local bn = (ns.knownBoatBuff and ns.knownBoatBuff(b.id))
                or (SBF.ItemKnow(b.id) and SBF.ItemKnow(b.id).buff)
        if bn ~= b.buffName then b.buffName = bn; b.buffDot:SetShown(bn ~= nil) end
      end
    end
  end)

  render()
  return r._height
end
ns.buildCatalogSlot = buildCatalogSlot

-- an item-slot square (indented "drop here" look even when empty), built by hand
-- since ItemButtonTemplate isn't inheritable here. Drag item/spell/macro/toy on;
-- right-click clears.
local function MakeItemButton(parent, x, y, def, onChange, slotId)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b.slotId = slotId                                        -- lets UpdateItemIcon render a dim default for fishing/combat
  b:SetSize(ICON, ICON); b:SetPoint("TOPLEFT", x, y)        -- match the catalog icon cells (37px, same flat frame)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  styleSlot(b)                                              -- flat dark fill + thin border, identical empty or filled
  b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.icon:SetPoint("TOPLEFT", 2, -2); b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")   -- square, matches the square border
  b:SetScript("OnReceiveDrag", function() ns.PlaceCursor(def, b, onChange) end)
  b:SetScript("OnClick", function(self, click)
    if click == "RightButton" then
      def.items = nil   -- also clear the multi-select model
      ClearDef(def); ns.UpdateItemIcon(b, def)
      markDirty(def)        -- action slot cleared -> unsaved edit (skipped for char-slots)
      if onChange then onChange() end; if SBF.Apply then SBF.Apply() end
    else
      ns.PlaceCursor(def, b, onChange)
    end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self._isDefault and self.slotId == "fishing" then        -- dim fishing-icon default
      GameTooltip:SetText("Cast Fishing — default")
      GameTooltip:AddLine("Casts Fishing (wrapped with your sit/cast settings). Drag a macro/item here to override.", 0.8, 0.8, 0.8, true)
    elseif self._isDefault and self.slotId == "combat" then     -- dim gear-icon default
      GameTooltip:SetText("Combat — default")
      GameTooltip:AddLine("Targets the nearest enemy, then casts Single-Button Assistant. Drag your own macro here, or right-click to clear back to default.", 0.8, 0.8, 0.8, true)
    elseif def.item then GameTooltip:SetHyperlink(def.item)
    elseif def.spell and GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(def.spell)
    elseif def.macro then
      GameTooltip:SetText("Macro"); GameTooltip:AddLine(def.macro, 1, 1, 1, true)
    else
      GameTooltip:SetText("Drag an item, spell, macro, or toy here")
      GameTooltip:AddLine("right-click to clear", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  ns.UpdateItemIcon(b, def)
  return b
end
ns.MakeItemButton = MakeItemButton   -- exposed so the Welcome panel reuses the real action-slot widget

-- friendly label for a gamepad PAD token (e.g. "PADA" -> "Gamepad A"). Falls back to the raw
-- token for anything not in the map, so an unknown/region-specific button still shows usably.
local PAD_LABEL = {
  PAD1 = "Gamepad 1", PAD2 = "Gamepad 2", PAD3 = "Gamepad 3", PAD4 = "Gamepad 4",
  PAD5 = "Gamepad 5", PAD6 = "Gamepad 6",
  PADA = "Gamepad A", PADB = "Gamepad B", PADX = "Gamepad X", PADY = "Gamepad Y",
  PADDUP = "D-Pad Up", PADDDOWN = "D-Pad Down", PADDLEFT = "D-Pad Left", PADDRIGHT = "D-Pad Right",
  PADDPADUP = "D-Pad Up", PADDPADDOWN = "D-Pad Down", PADDPADLEFT = "D-Pad Left", PADDPADRIGHT = "D-Pad Right",
  PADLSHOULDER = "Left Shoulder (LB)", PADRSHOULDER = "Right Shoulder (RB)",
  PADLTRIGGER = "Left Trigger (LT)", PADRTRIGGER = "Right Trigger (RT)",
  PADLSTICK = "Left Stick (click)", PADRSTICK = "Right Stick (click)",
  PADLSTICKUP = "Left Stick Up", PADLSTICKDOWN = "Left Stick Down",
  PADLSTICKLEFT = "Left Stick Left", PADLSTICKRIGHT = "Left Stick Right",
  PADRSTICKUP = "Right Stick Up", PADRSTICKDOWN = "Right Stick Down",
  PADRSTICKLEFT = "Right Stick Left", PADRSTICKRIGHT = "Right Stick Right",
  PADPADDLE1 = "Paddle 1", PADPADDLE2 = "Paddle 2", PADPADDLE3 = "Paddle 3", PADPADDLE4 = "Paddle 4",
  PADSYSTEM = "System", PADSOCIAL = "Social (Menu/View)", PADBACK = "Back/Select", PADFORWARD = "Start/Menu",
}
-- present a stored binding for display: render a bare gamepad token via PAD_LABEL, else show it as-is.
local function PrettyBind(binding)
  if not (binding and binding ~= "") then return "Set key" end
  if type(binding) == "string" and binding:match("^PAD") then return PAD_LABEL[binding] or binding end
  return binding
end

-- keybinds now live in SBFDB.binds[slotId] (lifted out of the per-slot config). These helpers key
-- off the slot id, not the slot's config table.
-- Multi-binding: an action can hold THREE bindings — Key 1 (SBFDB.binds, back-compat), an optional
-- Key 2 (SBFDB.binds2), and a Controller button (SBFDB.bindsCtrl). The keybind editor is parameterized
-- by which store it reads/writes (`storeName`, default "binds") so each column edits its own table.
local function bindStore(storeName)
  storeName = storeName or "binds"
  SBFDB[storeName] = SBFDB[storeName] or {}
  return SBFDB[storeName]
end
local function BindTextFrom(storeName, slotId)
  local t = SBFDB[storeName or "binds"]
  local b = t and t[slotId]
  return PrettyBind((b and b ~= "" and b) or nil)   -- friendly PAD label for gamepad tokens; "Set key" when unbound
end
local function BindText(slotId) return BindTextFrom("binds", slotId) end

-- warn (don't block) if the captured combo is already a live NON-SBF game binding, so you know SBF will be
-- shadowing (not stealing) it. SBF-owned collisions (other slots / fishing) are NOT handled here — those are a
-- hard conflict resolved by the confirm prompt in finish(); this is only the soft "you're shadowing X" FYI.
local function WarnKeyConflict(combo)
  if not (combo and GetBindingAction) then return end
  local action = GetBindingAction(combo, true)
  if action and action ~= "" and not action:match("^CLICK SBF") then
    print("|cff45c4a0SBF|r heads-up: |cffffd100" .. combo .. "|r is also bound to |cffffffff"
      .. GECBind.BindingName(action) .. "|r — SBF will override it while active.")
  end
end

-- Friendly label for a slot id (Pole Enchant, Chum, …); falls back to the raw id (gear pseudo-actions etc.).
local function SlotLabel(id)
  local d = ns.SlotDef and ns.SlotDef(id)
  return (d and d.label) or id
end
-- Every OTHER SBF-owned slot key as a { [combo] = label } map, for GECBind.Conflict. Spans all three internal
-- stores (binds/binds2/bindsCtrl) and every slot, EXCLUDING the exact cell being edited, so re-capturing the
-- same cell's own key never self-conflicts.
local function SlotConflictExtra(exceptSlot, exceptStore)
  local extra = {}
  for _, store in ipairs({ "binds", "binds2", "bindsCtrl" }) do
    local t = SBFDB[store]
    if t then
      for id, v in pairs(t) do
        if v and v ~= "" and not (store == exceptStore and id == exceptSlot) then extra[v] = SlotLabel(id) end
      end
    end
  end
  return extra
end

-- MakeKeybindButton(parent, x, y, slotId, w, after [, mode] [, storeName])
--   mode      "key" = capture KEYBOARD only (ignore gamepad), "pad" = capture GAMEPAD only (ignore keys),
--             "both"/nil = current behavior (either). The captured value is stored either way.
--   storeName which SBFDB table to read/write: "binds" (Key 1, default), "binds2" (Key 2), "bindsCtrl"
--             (Controller). Keeps all existing callers — which pass neither — on binds/both unchanged.
-- Controller capture is fully pcall-guarded so a client without the gamepad API never breaks the keyboard path.
local function MakeKeybindButton(parent, x, y, slotId, w, after, mode, storeName)
  mode = mode or "both"
  storeName = storeName or "binds"
  local kb = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  kb:SetSize(w or 130, 20); kb:SetPoint("TOPLEFT", x, y); kb:SetText(BindTextFrom(storeName, slotId))
  kb:SetNormalFontObject("GameFontNormalSmall")   -- fit a long combo in a small button; set on the BUTTON (not the
  -- fontstring) so a hover/enable state change can't swap the template's bigger normal font back in
  -- tear down capture + refresh label + re-apply (the shared tail of every finish path).
  local function teardown(s)
    s:EnableKeyboard(false); s:SetPropagateKeyboardInput(true)
    s:SetScript("OnKeyDown", nil); s:SetScript("OnGamePadButtonDown", nil)
    pcall(function() if s.EnableGamePadButton then s:EnableGamePadButton(false) end end)   -- stop grabbing gamepad input
    s:SetText(BindTextFrom(storeName, slotId))
    if after then after() end
    -- delay so the key/button you just pressed (and its release) doesn't fire the newly-set binding right away
    if SBF.Apply then C_Timer.After(0.4, SBF.Apply) end
  end
  -- shared finish: capture a key/gamepad token, but CHECK FOR CONFLICTS before writing it. An SBF-owned
  -- collision (another slot's key, or the fishing key) is a HARD conflict — one key can't drive two secure
  -- buttons — so we prompt (GECBind's game-style "already bound — reassign?" dialog) and, on accept, free the
  -- key from wherever it was first. A plain NON-SBF game binding is only shadowed (not stolen), so it just
  -- gets a soft heads-up. This is what stops a slot key from silently stomping the fishing cast.
  local function finish(s, token, isPad)
    local store = bindStore(storeName)
    if token == "ESCAPE" then store[slotId] = nil; teardown(s); return end
    local combo = isPad and token or SBF.ComboString(token)
    local extra = SlotConflictExtra(slotId, storeName)
    local label, rawAction = GECBind.Conflict(combo, slotId, extra)   -- extra=other SBF slots; native=game binds
    local sbfOwned = label and (rawAction == nil or rawAction:match("^CLICK SBF"))
    if sbfOwned then
      GECBind.ConfirmRebind(combo, label,
        function() SBF.FreeCombo(combo); store[slotId] = combo; teardown(s) end,   -- reassign here
        function() teardown(s) end)                                                -- cancel: leave as-was
    else
      store[slotId] = combo; teardown(s)
      if label then WarnKeyConflict(combo) end   -- non-SBF game binding: shadow FYI only
    end
  end
  kb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  kb:SetScript("OnClick", function(self, click)
    if click == "RightButton" then   -- right-click clears the binding (unlearn -> back to "Set key")
      local store = bindStore(storeName); store[slotId] = nil
      self:SetText(BindTextFrom(storeName, slotId))
      if after then after() end
      if SBF.Apply then SBF.Apply() end
      return
    end
    self:SetText(mode == "pad" and "press a controller button..." or "press key or button...")
    if mode ~= "pad" then   -- keyboard capture (key / both)
      self:EnableKeyboard(true); self:SetPropagateKeyboardInput(false)
      self:SetScript("OnKeyDown", function(s, keyName)
        if not IGNORE_KEYS[keyName] then finish(s, keyName, false) end
      end)
    end
    if mode ~= "key" then   -- gamepad capture (pad / both) — guarded; no-op on clients without the API
      pcall(function() if self.EnableGamePadButton then self:EnableGamePadButton(true) end end)
      self:SetScript("OnGamePadButtonDown", function(s, button)
        if button and button ~= "" then finish(s, button, true) end   -- button is a PAD token, e.g. "PADA"
      end)
    end
    -- "pad" mode: let Escape still cancel/clear via the keyboard, without recording typed keys as a bind.
    if mode == "pad" then
      self:EnableKeyboard(true); self:SetPropagateKeyboardInput(false)
      self:SetScript("OnKeyDown", function(s, keyName)
        if keyName == "ESCAPE" then finish(s, "ESCAPE", false) end   -- Esc clears; other keys ignored in pad mode
      end)
    end
  end)
  Theme.Button(kb)   -- taint-safe flat skin (native highlight, no script hooks) — doesn't touch the label/capture path
  return kb
end
ns.MakeKeybindButton = MakeKeybindButton   -- exposed so the Welcome panel reuses the real keybind-capture widget

-- a button that sets/shows a GAME keybinding (the Blizzard Key Bindings menu), e.g.
-- "INTERACTTARGET". Press it then a combo to bind; Esc clears. Persists via SaveBindings.
local function MakeGameBindButton(parent, x, y, command, w)
  local function cur() return PrettyBind(GetBindingKey(command) or "Set key") end
  local kb = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  kb:SetSize(w or 110, 20); kb:SetPoint("TOPLEFT", x, y); kb:SetText(cur())
  kb:SetNormalFontObject("GameFontNormalSmall")   -- pin on the button so a state change can't grow the label
  local function finish(s, token, isPad)
    s:EnableKeyboard(false); s:SetPropagateKeyboardInput(true)
    s:SetScript("OnKeyDown", nil); s:SetScript("OnGamePadButtonDown", nil)
    pcall(function() if s.EnableGamePadButton then s:EnableGamePadButton(false) end end)
    if token == "ESCAPE" then
      local k = GetBindingKey(command); if k then SetBinding(k) end   -- unbind
    elseif isPad then SetBinding(token, command)                      -- PAD token: no modifiers
    else SetBinding(SBF.ComboString(token), command) end
    if SaveBindings then SaveBindings(GetCurrentBindingSet()) end
    s:SetText(cur())
  end
  kb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  kb:SetScript("OnClick", function(self, click)
    if InCombatLockdown() then return end
    if click == "RightButton" then   -- right-click clears the game binding (unlearn -> back to "Set key")
      local k = GetBindingKey(command); if k then SetBinding(k) end
      if SaveBindings then SaveBindings(GetCurrentBindingSet()) end
      self:SetText(cur())
      return
    end
    self:SetText("press key or button...")
    self:EnableKeyboard(true); self:SetPropagateKeyboardInput(false)
    pcall(function() if self.EnableGamePadButton then self:EnableGamePadButton(true) end end)
    self:SetScript("OnKeyDown", function(s, keyName)
      if not IGNORE_KEYS[keyName] then finish(s, keyName, false) end
    end)
    self:SetScript("OnGamePadButtonDown", function(s, button)
      if button and button ~= "" then finish(s, button, true) end
    end)
  end)
  Theme.Button(kb)   -- taint-safe flat skin (native highlight, no script hooks) — doesn't touch SetBinding/capture
  return kb
end
ns.MakeGameBindButton = MakeGameBindButton   -- exposed so the Welcome panel reuses the real loot/INTERACTTARGET game-bind widget

-- a bind cell backed by a NATIVE binding command — now just the shared GECBind capture widget (the single
-- source of truth + the "already bound, reassign?" conflict prompt all live in the lib). kind "key" = keyboard
-- combo, "pad" = controller button, each owning one of the command's two native key slots. Used for the
-- fishing cast (SBF.FISHING_CMD) and the interact/loot controller (INTERACTTARGET). Theme.Button is passed as
-- the skin so the cell matches SBF. Signature kept so the keybinds-page rows + Welcome panel call it unchanged.
local function MakeNativeBindButton(parent, x, y, command, w, after, kind)
  local b = GECBind.CreateButton(parent, {
    command = command, kind = kind, width = w, skin = Theme.Button,
    -- after a native bind change, re-run Apply so the OVERRIDE-click trigger is rebuilt for the new key
    -- (the native binding is the source of truth; the override is what actually fires the cast). Delayed so
    -- the just-pressed key doesn't immediately fire the freshly-bound action.
    after = function()
      if after then after() end
      if SBF.Apply then C_Timer.After(0.3, SBF.Apply) end
    end,
  })
  b:SetPoint("TOPLEFT", x, y)
  return b
end
ns.MakeNativeBindButton = MakeNativeBindButton   -- exposed so the Welcome panel reuses the native fishing/interact cells

-- human-readable label for a BUTTON1..BUTTON5 token (shown on the mouse pickers)
local MOUSE_LABEL = {
  BUTTON1 = "Left Button", BUTTON2 = "Right Button", BUTTON3 = "Middle Button",
  BUTTON4 = "Button 4", BUTTON5 = "Button 5",
}
local function MouseBtnText(token, allowNone)
  if not token or token == "" then return allowNone and "(none)" or "Set button" end
  return MOUSE_LABEL[token] or token
end

-- A button that captures a MOUSE press to set SBFDB.mouse[field] to a BUTTON1..BUTTON5 token (mirrors
-- MakeKeybindButton, but listens for mouse buttons instead of keys). Two-stage so the click that ARMS
-- capture isn't itself recorded: a left-click arms it ("click a button..."); the NEXT press of ANY of the
-- 5 buttons is recorded. For `allowNone` (the optional loot picker) a right-click while idle clears it.
-- `after` re-renders dependent UI.
local MOUSE_CLICK_TOKEN = { LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
  Button4 = "BUTTON4", Button5 = "BUTTON5" }
local function MakeMouseButton(parent, x, y, field, w, allowNone, after)
  local mb = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  mb:SetSize(w or 110, 20); mb:SetPoint("TOPLEFT", x, y)
  mb:SetNormalFontObject("GameFontNormalSmall")   -- pin on the button so a state change can't grow the label
  local mfs = mb:GetFontString()
  -- swapping the font object can drop the template's centering; re-anchor the label to fill + center it
  mfs:ClearAllPoints(); mfs:SetPoint("CENTER"); mfs:SetJustifyH("CENTER"); mfs:SetJustifyV("MIDDLE")
  local function cur() return MouseBtnText(SBFDB.mouse and SBFDB.mouse[field], allowNone) end
  mb:SetText(cur())
  -- register all 5 buttons (down edge) so any of them can be captured once armed
  mb:RegisterForClicks("LeftButtonDown", "RightButtonDown", "MiddleButtonDown", "Button4Down", "Button5Down")
  local capturing = false
  mb:SetScript("OnClick", function(self, mouseButton)
    SBFDB.mouse = SBFDB.mouse or {}
    if not capturing then
      if mouseButton == "RightButton" then     -- right-click clears the binding (unlearn -> back to "Set button")
        SBFDB.mouse[field] = nil; self:SetText(cur())
        if after then after() end
        if SBF.MouseApply then SBF.MouseApply() end
        return
      end
      capturing = true; self:SetText("click a button...")     -- arm; the NEXT press (ANY button) is recorded
      return
    end
    -- Armed: the NEXT press is the binding — INCLUDING right-click, so the Right Button can be bound. (To
    -- CLEAR instead, right-click while NOT armed.) Down-edge only, so one press sets it cleanly.
    local token = MOUSE_CLICK_TOKEN[mouseButton]              -- captured press -> BUTTONn token
    -- dup-button guard (two-button mode): the Action and Loot buttons must differ. Reject (with an error
    -- message) a button already assigned to the OTHER action instead of silently double-binding it.
    local otherField = (field == "fishButton") and "lootButton" or "fishButton"
    if SBFDB.requireTwoButtons and token and token == SBFDB.mouse[otherField] then
      capturing = false; self:SetText(cur())
      local otherName = (otherField == "fishButton") and "Action" or "Loot"
      UIErrorsFrame:AddMessage("That button is already the " .. otherName .. " button.", 1, 0.3, 0.3)
      return
    end
    SBFDB.mouse[field] = token
    capturing = false; self:SetText(cur())
    if after then after() end
    if SBF.MouseApply then SBF.MouseApply() end
  end)
  mb._refresh = function() mb:SetText(cur()) end
  Theme.Button(mb)   -- taint-safe flat skin; called AFTER the font-object swap + CENTER re-anchor so the centered label is preserved
  return mb
end
ns.MakeMouseButton = MakeMouseButton   -- exposed so the Welcome panel reuses the real mouse-button picker widget

-- Per-slot config popup (every built-in slot). Right-clicking the name opens it; right-clicking the SAME
-- slot again (or the themed X / Esc) closes it. ONE shared popup is reused for every slot — right-clicking
-- a different slot just re-targets it — so walking the slots never trails a pile of windows to dismiss.
-- It carries an active/inactive checkbox (mirrors the name toggle) and, for rotation slots that track an
-- effect, the recast threshold + chum throw count + per-item buff editor. Keybinds live on the Keybinds
-- tab now, not here. `paint` repaints the row name's active color. The popup reads its CURRENT target from
-- p._def/p._paint/p._slotId (set each open) so every handler tracks whatever slot it's pointed at.
local cfgPopup
local function buildCfgPopup()
  local p = CreateFrame("Frame", "SBFSlotCfg", ns.opt.panel, "BackdropTemplate")
  local PAD = (Theme.metrics and Theme.metrics.pad) or 14   -- theme content inset: same padding L and R
  p:SetSize(280, 120)
  p:SetFrameStrata("DIALOG"); p:SetToplevel(true)
  p:SetBackdrop({                                  -- modern flat retail (matches the main window, raised)
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  p:SetBackdropColor(unpack(Theme.colors.bodyBg))
  p:SetBackdropBorderColor(unpack(Theme.colors.panelBorder))
  p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
  p:SetScript("OnDragStart", p.StartMoving)
  p:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- remember where you dropped it, in UIParent coords (scale-corrected) so it reopens in the same spot
    local s = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
    SBFDB.slotCfgPos = { self:GetLeft() * s, self:GetTop() * s }
  end)
  local pHead = p:CreateTexture(nil, "ARTWORK")          -- header band, matching the main window
  pHead:SetPoint("TOPLEFT", 1, -1); pHead:SetPoint("TOPRIGHT", -1, -1); pHead:SetHeight(28)
  pHead:SetColorTexture(unpack(Theme.colors.headerBand))
  p.title = p:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  p.title:SetPoint("LEFT", pHead, "LEFT", 12, 0)
  local close = Theme.CloseButton(p, function() p:Hide() end)   -- themed navy X (replaces the red Blizzard X)
  close:SetPoint("RIGHT", pHead, "RIGHT", -4, 0)

  -- ---- Content: a Theme.Layout (Box/flexbox) tree hosted in pBody (below the header band). The tree owns
  -- ALL layout — symmetric PAD, the recast row, the chum "Throw" field, and the per-item buff list — so no
  -- widget here carries a hardcoded x/y and the padding matches the rest of the themed UI. The popup shrinks
  -- to fit: WIDTH = the tree's natural width, HEIGHT = its measured height (p.Relayout), so a plain slot
  -- (Active only) is small and chum grows to fit its extra field + buff rows. ----
  local pBody = CreateFrame("Frame", nil, p)
  pBody:SetPoint("TOPLEFT", 1, -29)                          -- under the 28px header band (+1px top border)
  -- Keep the popup height glued to the body: the Box drives pBody's height, and a wrapping note can settle
  -- its true height a frame late — so whenever the body's height changes, resize the popup to match.
  pBody:HookScript("OnSizeChanged", function(_, _, h)
    if p:IsShown() and h and h > 1 then p:SetHeight(29 + math.ceil(h) + 1) end
  end)

  -- recast / throw editboxes stay hand-built (commit-on-focus-lost + validate), just HOSTED in the tree.
  local rf = CreateFrame("EditBox", nil, pBody, "InputBoxTemplate")
  rf:SetSize(40, 20); rf:SetAutoFocus(false); Theme.EditBox(rf)
  local function commitRF(self)   -- apply only; ClearFocus is the caller's job (avoids focus-lost recursion)
    local def = p._def; if not def then return end
    local n = tonumber(self:GetText()); if n and n >= 0 then def.refresh = n; markDirty() end
    self:SetText(tostring(def.refresh or 5))
  end
  rf:SetScript("OnEnterPressed", function(s) commitRF(s); s:ClearFocus() end)
  rf:SetScript("OnEditFocusLost", commitRF)                 -- commit when you click/tab away
  rf:SetScript("OnEscapePressed", function(s) commitRF(s); s:ClearFocus() end)
  p.recastField = rf

  local tf = CreateFrame("EditBox", nil, pBody, "InputBoxTemplate")
  tf:SetSize(34, 20); tf:SetAutoFocus(false); tf:SetNumeric(true); Theme.EditBox(tf)
  local function commitT(self)   -- apply only; caller clears focus (avoids focus-lost recursion)
    local def = p._def; if not def then return end
    local n = math.max(1, math.floor(tonumber(self:GetText()) or 1)); def["repeat"] = n
    markDirty()        -- chum burst count -> unsaved edit
    self:SetText(tostring(n))
  end
  tf:SetScript("OnEnterPressed", function(s) commitT(s); s:ClearFocus() end)
  tf:SetScript("OnEditFocusLost", commitT)
  tf:SetScript("OnEscapePressed", function(s) commitT(s); s:ClearFocus() end)
  tf:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Throw count (burst)")
    GameTooltip:AddLine("How many to throw in a burst when due — one per key press — then fish until the buff runs low.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  tf:SetScript("OnLeave", GameTooltip_Hide)
  p.repeatField = tf

  local tree = {
    dir = "column", pad = PAD, gap = "row",
    -- Active/inactive (mirrors clicking the name on the row); get/set read the CURRENT target each click.
    { check = { label = "Active",
        get = function() return not (p._def and p._def.skip) end,
        set = function(v)
          local def = p._def; if not def then return end
          def.skip = (not v) and true or nil
          markDirty(def)        -- active/inactive toggle -> unsaved edit (skipped for char-slots)
          if p._paint then p._paint() end
          if SBF.Apply then SBF.Apply() end
        end }, id = "active" },
    -- BUFFABLE group (hidden for non-effect slots): recast threshold, the chum "Throw" burst, + buff list.
    { id = "buffGroup", dir = "column", gap = "row",
      { id = "recastRow", dir = "row", align = "center", gap = 6,
        { note = { text = "Recast under", color = "text" } },
        { frame = rf },
        { note = { text = "sec left", color = "text" } },
        { id = "throwGroup", dir = "row", align = "center", gap = 6,   -- chum-only (allowsRepeat)
          { note = { text = "Throw", color = "text" } },
          { frame = tf },
        },
      },
      { id = "buffList", dir = "column", gap = 4, align = "stretch" },  -- filled per slot: header + hint + rows
    },
  }
  local root, refs = Theme.Layout(pBody, tree, { setParentHeight = true, settle = pBody })
  p._root, p._refs = root, refs
  p.active = refs.active
  p.buffRows = {}

  -- build (once, pooled) a per-item buff row: icon swatch + a buff-name editbox. The Box stretches the row
  -- to the content width, so the editbox anchors LEFT..RIGHT and fills whatever width the popup settles at.
  local function makeBuffRow(i)
    local row = CreateFrame("Frame", nil, pBody); row:SetSize(10, 26)
    row.swatch = CreateFrame("Frame", nil, row, "BackdropTemplate"); row.swatch:SetSize(24, 24)
    row.swatch:SetPoint("LEFT", 0, 0); styleSlot(row.swatch)   -- same flat frame as the icon cells
    paintSlot(row.swatch, true)   -- selected look = a picked item (accent frame + warm fill)
    row.icon = row.swatch:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("TOPLEFT", 2, -2); row.icon:SetPoint("BOTTOMRIGHT", -2, 2); row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.swatch:EnableMouse(true)                            -- hover the icon -> the item's tooltip
    row.swatch:SetScript("OnEnter", function(self)
      if not row.id then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local sidR = ns.spellEntry and ns.spellEntry(row.id)
      if sidR then GameTooltip:SetSpellByID(sidR) else GameTooltip:SetItemByID(row.id) end
      GameTooltip:Show()
    end)
    row.swatch:SetScript("OnLeave", GameTooltip_Hide)
    row.eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.eb:SetHeight(18); row.eb:SetPoint("LEFT", 34, 0); row.eb:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.eb:SetAutoFocus(false); row.eb:SetFontObject("GameFontHighlightSmall"); Theme.EditBox(row.eb)
    row.eb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    row.eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    row.eb:SetScript("OnTextChanged", function(s, user)
      if user then
        local rec = SBF.ItemKnow(row.id)
        if s:GetText() ~= "" then SBF.ObserveItem(row.id, { buff = s:GetText() })
        elseif rec then rec.buff = nil end
      end
    end)
    row.eb:SetScript("OnMouseUp", function(s, button)
      if button == "RightButton" then
        local rec = SBF.ItemKnow(row.id); if rec then rec.buff = nil end
        s:SetText(""); s:ClearFocus()
      end
    end)
    return row
  end

  -- (re)fill the per-item buff list for the current target: a "Per-item buffs:" header, a hint tuned to the
  -- actual rows, then one hosted row per item. Cleared + re-added each show (Box:Add builds fresh leaves, so
  -- the hint's wrapped height is always correct). Rows are pooled + reset narrow so they never inflate width.
  function p.RebuildBuffs()
    local def = p._def
    local list = refs.buffList
    list:Clear()
    local rows, anyFixed, anyEditable = {}, false, false   -- fixed = curated boat / spell (locked); editable = learnable
    for i, id in ipairs((def and def.items) or {}) do
      local row = p.buffRows[i] or makeBuffRow(i)
      p.buffRows[i] = row
      row:SetWidth(10)                                       -- reset narrow: the buff hint drives width, not a stale row
      row.id = id
      row.icon:SetTexture(slotIcon(id))
      local sidR = ns.spellEntry and ns.spellEntry(id)
      local fixedBuff = (sidR and ns.spellName(sidR)) or (ns.knownBoatBuff and ns.knownBoatBuff(id))
      if fixedBuff then
        row.eb:SetText(fixedBuff); row.eb:Disable()          -- spell/curated boat: buff is fixed, not a per-item override
        anyFixed = true
      else
        row.eb:Enable(); row.eb:SetText((SBF.ItemKnow(id) and SBF.ItemKnow(id).buff) or "")
        anyEditable = true
      end
      rows[#rows + 1] = row
    end
    -- accurate hint for THIS slot's actual rows: don't say "type to correct" when every row is locked.
    local hint
    if anyFixed and not anyEditable then
      hint = "These are built-in buffs (curated boats / spells) — fixed, nothing to edit."
    elseif anyFixed then
      hint = "Empty = not learned yet (cast it once). Type to correct; right-click to relearn. "
        .. "Greyed rows (curated boats / spells) are built-in and can't be edited."
    else
      hint = "Empty = not learned yet (cast it once). Type to correct; right-click to relearn."
    end
    -- Cap the hint paragraph to the recast row's width so it WRAPS to the visible content instead of
    -- demanding the theme's default note-max (~320) and ballooning the popup. The recast row (the widest
    -- real control row) is what drives the popup width; the hint just folds to fit under it.
    local capW = math.max(160, math.ceil(refs.recastRow:NaturalWidth()))
    list:Add({ note = { text = "Per-item buffs:", color = "text" } })
    list:Add({ note = { text = hint, color = "textDim" }, maxWidth = capW })
    for _, row in ipairs(rows) do list:Add({ frame = row, height = 26, align = "stretch" }) end
  end

  -- Size the popup to its content: WIDTH = the tree's natural width (+ side borders), HEIGHT = the measured
  -- box height (+ header + borders). The Box provides the symmetric PAD; nothing here is hand-placed.
  function p.Relayout()
    local natW = math.max(180, math.ceil(root:NaturalWidth()))
    pBody:SetWidth(natW)
    root:Layout()                                            -- lay out at that width; setParentHeight sets pBody height
    local bodyH = math.max(1, math.ceil(pBody:GetHeight() or 1))
    p:SetSize(natW + 2, 29 + bodyH + 1)                      -- +2 side borders; header band (29) + body + bottom border
  end

  -- LIVE refresh while open: re-read the Active state and each editable buff row from the engine every ~0.4s,
  -- so a buff learned/detected (or an active toggle from elsewhere) shows without reopening the popup. Skips a
  -- field you're actively typing in (never fights your edit) and locked (spell/curated-boat) rows.
  p:SetScript("OnUpdate", function(self, e)
    self._acc = (self._acc or 0) + e
    if self._acc < 0.4 then return end
    self._acc = 0
    if p.active and p._def then p.active:SetChecked(not p._def.skip) end
    for _, row in ipairs(p.buffRows) do
      if row:IsShown() and row.id and row.eb:IsEnabled() and not row.eb:HasFocus() then
        local learned = (SBF.ItemKnow and SBF.ItemKnow(row.id) and SBF.ItemKnow(row.id).buff) or ""
        if learned ~= row.eb:GetText() then row.eb:SetText(learned) end
      end
    end
  end)

  tinsert(UISpecialFrames, "SBFSlotCfg")                    -- Esc closes it
  cfgPopup = p
  return p
end

local function ShowSlotConfig(def, src, anchor, paint)
  local p = cfgPopup or buildCfgPopup()
  if p:IsShown() and p._slotId == src.id then p:Hide(); return end   -- right-click the same slot again = close
  p._def, p._src, p._paint, p._slotId = def, src, paint, src.id
  -- "buffable" (recast threshold + per-item buff editor) = a rotation slot that tracks an effect (aura OR
  -- the pole enchant). Derived from the descriptor.
  local sd = ns.SlotDef and ns.SlotDef(src.id)
  local buffable = sd and sd.effect ~= nil
  local throwable = (buffable and sd and sd.allowsRepeat) and true or false
  local refs = p._refs
  local function setHidden(box, hidden) if box and box.node then box.node.hidden = hidden and true or false end end
  p.title:SetText(src.label .. "  |cff888888(drag)|r")
  p.active:SetChecked(not def.skip)
  setHidden(refs.buffGroup, not buffable)                    -- whole recast+buffs block toggles as one box
  setHidden(refs.throwGroup, not throwable)                 -- the chum-only "Throw" field
  -- Per-item buff editor HIDDEN for now (2026-07-20): editing the display NAME is low-value (the buffSpell ID
  -- is the real identity, and the learned name is a guess of which aura fired). Data is still collected
  -- silently (learnBuff -> ObserveItem) and flows to the website, which is the surface that matters today.
  -- To restore, drop the `setHidden(refs.buffList, true)` and re-enable the `p.RebuildBuffs()` call below;
  -- RebuildBuffs/makeBuffRow are intentionally kept for the future dev item-knowledge inspector.
  setHidden(refs.buffList, true)
  if buffable then
    p.recastField:SetText(tostring(def.refresh or 5))
    if throwable then p.repeatField:SetText(tostring(def["repeat"] or 1)) end
  end
  refs.buffList:Clear()
  p.Relayout()                                              -- shrink-to-fit width + height for THIS slot
  -- Open at the REMEMBERED spot (its saved top-left), not inline beside the row, so walking the slots
  -- keeps the popup parked where you left it. First time (no saved pos) it appears beside the slot row.
  p:ClearAllPoints()
  local pos = SBFDB.slotCfgPos
  if pos and pos[1] and pos[2] then
    p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
  elseif anchor then
    p:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 10, 6)
  else
    p:SetPoint("CENTER")
  end
  p:Show(); p:Raise()
end

-- one slot row bound to def. Layout L->R: [label] [item/strip] [buff-to-watch] — keys + active live
-- in the right-click config popup. (ROW_H is declared near the top so the catalog tray can see it.)
local function MakeRow(parent, y, def, labelText, src, reflow)
  local r = CreateFrame("Frame", nil, parent)
  r:SetPoint("TOPLEFT", 0, y); r:SetSize(510, ROW_H)
  r._height = ROW_H
  local catalog = src and src.id and CATALOG_SLOT[src.id]          -- inline icon strip

  -- click the NAME to toggle active/inactive; grayed = inactive (skip). Per-slot detail (keys/buffs)
  -- lives in the right-click config popup, so the name carries active/inactive — no checkbox.
  local lblBtn = CreateFrame("Button", nil, r)
  lblBtn:SetPoint("TOPLEFT", 8, -8); lblBtn:SetSize(104, 22)
  local lbl = lblBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  lbl:SetPoint("LEFT"); lbl:SetWidth(104); lbl:SetJustifyH("LEFT"); lbl:SetText(labelText)
  local function paint() local c = def.skip and 0.45 or 1; lbl:SetTextColor(c, c, c) end
  paint()
  lblBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  lblBtn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then        -- right-click opens this slot's config popup
      ShowSlotConfig(def, src, self, paint); return
    end
    def.skip = (not def.skip) and true or nil; paint()
    markDirty(def)        -- active/inactive toggle -> unsaved edit (skipped for char-slots)
    if SBF.Apply then SBF.Apply() end
  end)
  lblBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(def.skip and "Inactive — left-click to activate" or "Active — left-click to deactivate")
    GameTooltip:AddLine("right-click: configure (active / key)", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  lblBtn:SetScript("OnLeave", GameTooltip_Hide)

  if catalog then
    r._height = ns.buildCatalogSlot(r, def, src.id, reflow)
  else
    -- action slot (fishing/interact/combat/heal): a drop field for an item/spell/macro/toy
    -- (right-click clears). Key + active live in the right-click config popup, not on the row.
    -- Pass the slot id so the button can render a dim "default" icon when on its built-in default.
    MakeItemButton(r, 120, -2, def, nil, src and src.id)
  end

  -- buff-to-watch field (consumables): recasts when this buff drops; auto-fills when
  -- the slot learns it, and you can type/correct it here instead of /sbf setbuff. Catalog slots use
  -- the inline strip + the popup's per-item buff editor, so no inline buff field here (every
  -- effect-tracking slot is a catalog slot, so this branch is effectively reserved for any future
  -- non-catalog effect slot). "buffable" derives from the descriptor's `effect` now.
  local srcSd = src and src.id and ns.SlotDef and ns.SlotDef(src.id)
  if srcSd and srcSd.effect ~= nil and not (src.id and CATALOG_SLOT[src.id]) then
    local key = src.id
    local bf = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
    -- stretch to the row's right edge (nothing else sits on these consumable rows) instead of a fixed width
    bf:SetHeight(18); bf:SetPoint("TOPLEFT", 166, -13); bf:SetPoint("RIGHT", r, "RIGHT", -16, 0); bf:SetAutoFocus(false); Theme.EditBox(bf)
    bf:SetFontObject("GameFontHighlightSmall")
    bf:SetText((SBF.WatchedBuff and SBF.WatchedBuff(key)) or def.buff or "")
    bf:SetScript("OnTextChanged", function(self, user)
      if user then
        local t = self:GetText()
        def.buff = (t ~= "" and t) or nil
        def.buffSpell = nil                 -- typed name: spellId unknown -> track by name (re-learns on next cast)
        if t == "" then def.buffFor = nil end
        markDirty()         -- buff-to-watch edit -> unsaved edit
      end
    end)
    bf:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    bf:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- right-click = unlearn now (force a freshly-swapped item to re-learn immediately)
    bf:SetScript("OnMouseUp", function(self, button)
      if button == "RightButton" then
        if SBF.ClearLearnedBuff then SBF.ClearLearnedBuff(key) else def.buff, def.buffFor, def.buffSpell = nil, nil, nil end
        markDirty()          -- cleared the slot's learned buff -> unsaved edit
        self:SetText(""); self:ClearFocus()
        print("|cff45c4a0SBF|r cleared " .. key .. " buff (slot + item cache) — re-learns on next cast.")
      end
    end)
    -- live-fill with the buff the engine is watching (learned name, or the raft/toy
    -- name) so you SEE what it detected. Don't touch it while you're typing.
    local acc = 0
    bf:HookScript("OnUpdate", function(self, e)
      acc = acc + e; if acc < 0.5 then return end; acc = 0
      if self:HasFocus() then return end
      local watched = (SBF.WatchedBuff and SBF.WatchedBuff(key)) or ""
      if watched ~= self:GetText() then self:SetText(watched) end
    end)
    bf:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Buff to watch")
      GameTooltip:AddLine("Recasts when this buff is gone/low. Auto-fills when detected; type to override; right-click to unlearn now.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    bf:SetScript("OnLeave", GameTooltip_Hide)
  end

  return r
end

-- ===== published to Options.lua (re-bound to locals there) =====
ns.opt.accentRGB            = accentRGB
ns.opt.markDirty            = markDirty
ns.opt.styleSlot            = styleSlot
ns.opt.helpTip              = helpTip
ns.opt.helpLabel            = helpLabel
ns.opt.sectionHeader        = sectionHeader
ns.opt.MakeRow              = MakeRow
ns.opt.MakeKeybindButton    = MakeKeybindButton
ns.opt.MakeGameBindButton   = MakeGameBindButton
ns.opt.MakeNativeBindButton = MakeNativeBindButton
ns.opt.MakeMouseButton      = MakeMouseButton
ns.opt.ShowSlotConfig       = ShowSlotConfig
ns.opt.BindText             = BindText
ns.opt.catalogStrips        = catalogStrips
ns.opt.catalogStripRenders  = catalogStripRenders
ns.opt.STRIP_X              = STRIP_X
ns.opt.ROW_H                = ROW_H
ns.opt.ICON                 = ICON
