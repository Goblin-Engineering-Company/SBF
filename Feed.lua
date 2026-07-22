-- Feed.lua — publish SBF's live state as a GECData feed (the typed-token convention), so any
-- GECData consumer (e.g. the Gadgets addon) can render {sbf.<token>} live. SHIPPING file (not dev).
--
-- The feed name "SBF" slugs to "sbf", so {sbf.state}, {sbf.skill}, {sbf.perception}, etc. resolve
-- through the matching GECTemplate type on the consumer side. Sub-names mirror Haul's {sbf.*}
-- (Window.lua) 1:1 so templates are portable across addons. The producer only needs LibStub +
-- CallbackHandler + LDB + GECData; the typed rendering happens consumer-side (no GECTemplate here).
-- (No `local ADDON, ns = ...` here — this file uses neither the addon name nor the namespace.)

local Data = LibStub and LibStub:GetLibrary("GECData-1.0", true)
if not Data or not Data.Provide then return end

local feed = Data.Provide("SBF", {
  type = "data source",
  text = "Single-Button Fishing",
  icon = "Interface\\Icons\\trade_fishing",
  -- declared token types: each value renders through the matching GECTemplate type.
  -- skill / skill.bonus are PRE-COLORED strings (own |c escapes) → "raw" (verbatim, not recolored).
  tokenTypes = {
    state = "text", profile = "text", next = "text",
    perception = "number",
    skill = "raw",                 -- GetFishing() is a pre-colored "109/300 (+116)" string
    ["skill.level"] = "number",
    ["skill.max"]   = "number",
    ["skill.bonus"] = "raw",       -- pre-colored "+N" green, or ""
  },
  -- dynamic tokens: recomputed every render (the consumer pulls these on its refresh tick).
  GetToken = function(name)
    if name == "state"      then return SBF.GetState and SBF.GetState() end
    if name == "profile"    then return SBF.GetProfile and SBF.GetProfile() end
    if name == "next"       then return SBF.GetNext and SBF.GetNext() end
    if name == "perception" then return SBF.GetPerception and SBF.GetPerception() end
    if name == "skill"      then return SBF.GetFishing and SBF.GetFishing() end
    if name:match("^skill%.") and SBF.FishingSkill then
      local lvl, mx, mod = SBF.FishingSkill()
      if name == "skill.level" then return lvl end
      if name == "skill.max"   then return mx or lvl end
      if name == "skill.bonus" then return (mod and mod > 0) and ("|cff33ff33+" .. mod .. "|r") or "" end
    end
  end,
  -- interactivity (LDB convention; routed by a GECData consumer's hot-span, e.g. a Gadgets bar):
  -- left-click a {sbf.*} span → open SBF's options window (same action as the minimap button).
  OnClick = function(_, button)
    if button == "LeftButton" and SBF.ToggleOptions then SBF.ToggleOptions() end
  end,
  OnTooltipShow = function(tt)
    tt:AddLine("Single-Button Fishing")
    tt:AddLine("State: " .. (SBF.GetState and SBF.GetState() or "?"))
    tt:AddLine("Skill: " .. (SBF.GetFishing and SBF.GetFishing() or "?"))
    tt:AddLine("Perception: " .. tostring(SBF.GetPerception and SBF.GetPerception() or 0))
    tt:AddLine("Next: " .. (SBF.GetNext and SBF.GetNext() or "?"))
  end,
})

-- Keep the LDB display TEXT live too, so the feed also works in any generic LDB display (a broker
-- bar), not just our typed tokens. NOTE: GECData.Provide returns a HANDLE { object = <LDB obj>, Set },
-- NOT the LDB object — so the live text must be written to feed.object.text (writing feed.text would
-- be inert). Guarded on feed.object.
if feed and feed.object and C_Timer then
  C_Timer.NewTicker(1, function()
    local st = (SBF.GetState and SBF.GetState()) or ""
    local sk = (SBF.GetFishing and SBF.GetFishing()) or ""
    feed.object.text = (st ~= "" and (st .. "  ") or "") .. sk
  end)
end
