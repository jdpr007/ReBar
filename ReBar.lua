-------------------------------------------------------------------------------
-- ReBar.lua  v3.3
-- Overlays percentage text on the Personal Resource Display (PRD).
-- WoW 12.0.5. No libraries. Minimal. Click-through.
--
-- Group-size note: this addon only ever reads the PLAYER's own PRD bars and
-- never iterates party/raid members, so its cost is constant regardless of
-- group size (1 to 40 players) - it does the same tiny amount of work always.
--
-- Secret-value note: UnitHealthPercent / UnitPowerPercent can return protected
-- "secret" values during some encounters. All reads are pcall-guarded and fall
-- back to ratio math; if a value is secret and unusable, the text simply isn't
-- updated that tick rather than erroring. Display-only, so this degrades
-- gracefully.
--
-- Frame paths (confirmed working, matching the PRDNumbers reference addon):
--   PRD frame:   _G.PersonalResourceDisplayFrame
--   Health bar:  PersonalResourceDisplayFrame.HealthBarsContainer.healthBar
--   Power bar:   PersonalResourceDisplayFrame.PowerBar
--   Alt power:   PersonalResourceDisplayFrame.AlternatePowerBar
--
-- Overlay model (also from the reference): a child frame parented directly to
-- each bar at frame level +1 with a FontString. No strata overrides, no
-- reparenting to UIParent, no screen-coordinate math. The overlay reference is
-- stored ON the bar (bar.ReBarOverlay) so re-caching updates in place
-- instead of rebuilding (which avoids the rapid create/destroy error loop).
--
-- SLASH: /rebar   options    /rebar debug   toggle debug    /rebar scan   re-cache
-------------------------------------------------------------------------------

local ADDON_NAME = "ReBar"

local DEFAULTS = {
    enabled    = true,
    debug      = false,
    fontSize   = 12,
    fontPath   = "Fonts\\FRIZQT__.TTF",
    fontFlags  = "OUTLINE",
    colorR     = 1.0,
    colorG     = 1.0,
    colorB     = 1.0,
    showHealth = true,
    showPower  = true,
    showAlt    = true,
}

local THROTTLE = 0.10  -- text refresh interval (10 Hz)

local db          = nil
local initialized = false
local tickElapsed = 0

-- Cached bar references (Blizzard StatusBars)
local cached = { health = nil, power = nil, alt = nil }

-------------------------------------------------------------------------------
local function Dbg(...) if db and db.debug then print("|cff00ccff[ReBar]|r", ...) end end
local function Msg(...) print("|cff00ccff[ReBar]|r", ...) end
local function ApplyDefaults(t, d) for k, v in pairs(d) do if t[k] == nil then t[k] = v end end end

-------------------------------------------------------------------------------
-- PRD frame accessors (the proven named-member paths)
-------------------------------------------------------------------------------
local function GetPRD()
    return _G.PersonalResourceDisplayFrame
end

local function FindHealthBar()
    local prd = GetPRD()
    if not prd then return nil end
    local c = prd.HealthBarsContainer
    return c and c.healthBar or nil
end

local function FindPowerBar()
    local prd = GetPRD()
    return prd and (prd.PowerBar or prd.powerBar) or nil
end

local function FindAltPowerBar()
    local prd = GetPRD()
    return prd and (prd.AlternatePowerBar or prd.alternatePowerBar) or nil
end

-------------------------------------------------------------------------------
-- CreateOverlay: attach (or update) a text overlay on a bar.
-- The overlay reference lives on the bar itself, so calling this repeatedly is
-- cheap and safe - it updates the existing overlay instead of making new ones.
-------------------------------------------------------------------------------
local function CreateOverlay(bar)
    if not bar then return end

    if bar.ReBarOverlay then
        -- Already has an overlay; just refresh font
        if db then
            bar.ReBarText:SetFont(db.fontPath, db.fontSize, db.fontFlags)
        end
        return
    end

    -- Child frame parented to the bar, one level above it (matches reference).
    -- No strata override: the bar's own strata is correct, and +1 level keeps
    -- our text above the bar's fill texture.
    local overlay = CreateFrame("Frame", nil, bar)
    overlay:SetAllPoints(bar)
    overlay:SetFrameLevel((bar:GetFrameLevel() or 0) + 1)
    overlay:EnableMouse(false)
    overlay:SetMouseClickEnabled(false)

    local text = overlay:CreateFontString(nil, "OVERLAY")
    text:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    if db then
        text:SetFont(db.fontPath, db.fontSize, db.fontFlags)
    end

    bar.ReBarOverlay = overlay
    bar.ReBarText    = text
    Dbg("Overlay created on", bar:GetName() or "(unnamed)")
end

-------------------------------------------------------------------------------
-- SetText: write percent text on a bar's overlay
-------------------------------------------------------------------------------
local function SetText(bar, pct, show)
    if not bar or not bar.ReBarText then return end
    if show and pct then
        bar.ReBarText:SetText(string.format("%.0f%%", pct))
        bar.ReBarText:SetTextColor(db.colorR, db.colorG, db.colorB)
    else
        bar.ReBarText:SetText("")
    end
end

-------------------------------------------------------------------------------
-- CacheBars: resolve all PRD bars and ensure overlays exist on them
-------------------------------------------------------------------------------
local function CacheBars()
    cached.health = FindHealthBar()
    cached.power  = FindPowerBar()
    cached.alt    = FindAltPowerBar()

    if cached.health then CreateOverlay(cached.health) end
    if cached.power  then CreateOverlay(cached.power)  end
    if cached.alt    then CreateOverlay(cached.alt)    end

    Dbg("CacheBars: health=" .. tostring(cached.health ~= nil) ..
        " power=" .. tostring(cached.power ~= nil) ..
        " alt=" .. tostring(cached.alt ~= nil))
end

-------------------------------------------------------------------------------
-- Percentage helpers (use the modern UnitHealthPercent/UnitPowerPercent if
-- present - they handle "secret"/protected values - else fall back to ratios)
-------------------------------------------------------------------------------
local function HealthPct()
    -- UnitHealthPercent(unit [, usePredicted [, curve]]); curve ScaleTo100 -> 0..100
    if UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
        local ok, pct = pcall(UnitHealthPercent, "player", true, CurveConstants.ScaleTo100)
        if ok and pct then return pct end
    end
    local max = UnitHealthMax("player")
    if max and max > 0 then return UnitHealth("player") / max * 100 end
    return nil
end

local function PowerPct(powerType)
    -- UnitPowerPercent(unit, powerType [, usePredicted [, curve]])
    if UnitPowerPercent and CurveConstants and CurveConstants.ScaleTo100 then
        local ok, pct = pcall(UnitPowerPercent, "player", powerType, true, CurveConstants.ScaleTo100)
        if ok and pct then return pct end
    end
    local max = UnitPowerMax("player", powerType)
    if max and max > 0 then return UnitPower("player", powerType) / max * 100 end
    return nil
end

local function BarPct(bar)
    -- For alternate/class bars, read the bar's own value (pcall-guarded)
    local ok, lo, hi = pcall(function() return bar:GetMinMaxValues() end)
    local okv, val = pcall(function() return bar:GetValue() end)
    if ok and okv and hi and hi > 0 then return val / hi * 100 end
    return nil
end

-------------------------------------------------------------------------------
-- OnUpdate: refresh text at THROTTLE Hz
-------------------------------------------------------------------------------
local function OnUpdate(_, dt)
    if not db or not db.enabled then return end
    tickElapsed = tickElapsed + (dt or 0)
    if tickElapsed < THROTTLE then return end
    tickElapsed = 0

    if cached.health then
        SetText(cached.health, HealthPct(), db.showHealth)
    end
    if cached.power then
        SetText(cached.power, PowerPct(UnitPowerType("player")), db.showPower)
    end
    if cached.alt then
        SetText(cached.alt, BarPct(cached.alt), db.showAlt)
    end
end

-------------------------------------------------------------------------------
-- Options panel
-------------------------------------------------------------------------------
local optionsPanel
local function BuildOptionsPanel()
    optionsPanel = CreateFrame("Frame", "ReBarOptions", UIParent, "BackdropTemplate")
    optionsPanel:SetSize(340, 250)
    optionsPanel:SetPoint("CENTER")
    optionsPanel:SetMovable(true)
    optionsPanel:EnableMouse(true)
    optionsPanel:RegisterForDrag("LeftButton")
    optionsPanel:SetScript("OnDragStart", optionsPanel.StartMoving)
    optionsPanel:SetScript("OnDragStop",  optionsPanel.StopMovingOrSizing)
    optionsPanel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    optionsPanel:Hide()

    local title = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -12); title:SetText("ReBar Options")
    local closeBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    local y = -44
    local function CB(lbl, getV, setV)
        local cb = CreateFrame("CheckButton", nil, optionsPanel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, y); cb.text:SetText(lbl); cb:SetChecked(getV())
        cb:SetScript("OnClick", function(s) setV(s:GetChecked()) end); y = y - 28
    end
    local function SL(lbl, lo, hi, step, getV, setV)
        local fs = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, y); fs:SetText(lbl); y = y - 20
        local sl = CreateFrame("Slider", nil, optionsPanel, "OptionsSliderTemplate")
        sl:SetPoint("TOPLEFT", 16, y); sl:SetWidth(300)
        sl:SetMinMaxValues(lo, hi); sl:SetValueStep(step); sl:SetValue(getV())
        sl.Low:SetText(tostring(lo)); sl.High:SetText(tostring(hi))
        sl:SetScript("OnValueChanged", function(s, v)
            setV(math.floor(v / step + 0.5) * step)
            -- Re-apply font to existing overlays
            for _, bar in pairs(cached) do
                if bar and bar.ReBarText then
                    bar.ReBarText:SetFont(db.fontPath, db.fontSize, db.fontFlags)
                end
            end
        end); y = y - 36
    end

    CB("Enable ReBar", function() return db.enabled end, function(v)
        db.enabled = v
        if not v then for _, bar in pairs(cached) do if bar and bar.ReBarText then bar.ReBarText:SetText("") end end end
    end)
    CB("Show % on Health Bar", function() return db.showHealth end, function(v) db.showHealth = v end)
    CB("Show % on Power Bar",  function() return db.showPower  end, function(v) db.showPower  = v end)
    CB("Show % on Alternate/Class Bar", function() return db.showAlt end, function(v) db.showAlt = v end)
    CB("Debug Mode", function() return db.debug end, function(v) db.debug = v end)
    SL("Font Size", 8, 24, 1, function() return db.fontSize end, function(v) db.fontSize = v end)

    local hint = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOM", 0, 14)
    hint:SetText("|cffaaaaaa/rebar|r panel   |cffaaaaaa/rebar debug|r debug   |cffaaaaaa/rebar scan|r re-cache")
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_REBAR1 = "/rebar"
SlashCmdList["REBAR"] = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if not db then Msg("Not ready yet."); return end
    if cmd == "debug" then
        db.debug = not db.debug
        Msg("Debug " .. (db.debug and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        local prd = GetPRD()
        Msg("PersonalResourceDisplayFrame = " .. tostring(prd))
        Msg("HealthBar = " .. tostring(FindHealthBar()))
        Msg("PowerBar = " .. tostring(FindPowerBar()))
        Msg("AltPowerBar = " .. tostring(FindAltPowerBar()))
        CacheBars()
    elseif cmd == "scan" then
        CacheBars()
        Msg("Re-cached. health=" .. tostring(cached.health ~= nil) ..
            " power=" .. tostring(cached.power ~= nil))
    else
        if not optionsPanel then BuildOptionsPanel() end
        if optionsPanel:IsShown() then optionsPanel:Hide() else optionsPanel:Show() end
    end
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------
local Frame = CreateFrame("Frame", "ReBar_EventFrame", UIParent)
Frame:RegisterEvent("ADDON_LOADED")
Frame:RegisterEvent("PLAYER_LOGIN")
Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
Frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
Frame:RegisterEvent("PLAYER_TALENT_UPDATE")
Frame:RegisterEvent("UNIT_DISPLAYPOWER")

local function Start()
    if initialized then return end
    initialized = true
    -- Defer slightly so the PRD frame is built (matches reference's 0.1s defer)
    C_Timer.After(0.1, function()
        CacheBars()
        if not Frame.hookedUpdate then
            Frame.hookedUpdate = true
            Frame:SetScript("OnUpdate", OnUpdate)
        end
    end)
end

Frame:SetScript("OnEvent", function(_, event, unit)
    if event == "ADDON_LOADED" then
        if unit ~= ADDON_NAME then return end
        ReBarDB = ReBarDB or {}
        db = ReBarDB
        ApplyDefaults(db, DEFAULTS)

    elseif event == "PLAYER_LOGIN" then
        Msg("v3.3 loaded. |cffFFD700/rebar|r options   |cffFFD700/rebar debug|r diagnose")
        Start()

    elseif event == "PLAYER_ENTERING_WORLD"
        or event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "PLAYER_TALENT_UPDATE"
        or (event == "UNIT_DISPLAYPOWER" and unit == "player") then
        -- PRD bars can be rebuilt by Blizzard on these; re-cache after a beat
        if initialized then
            C_Timer.After(0.5, CacheBars)
        else
            Start()
        end
    end
end)
