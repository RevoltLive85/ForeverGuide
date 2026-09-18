-- ============================================================
-- ForeverGuide / Keybinds.lua
-- Names and global functions for Bindings.xml
-- (Esc -> Options -> Key Bindings -> AddOns -> ForeverGuide).
-- ============================================================

local _, ns = ...

BINDING_HEADER_FOREVERGUIDE = "ForeverGuide"
BINDING_NAME_FOREVERGUIDE_TOGGLE = "Show / hide the guide window"
BINDING_NAME_FOREVERGUIDE_PICKER = "Pick a guide / auto mode"
BINDING_NAME_FOREVERGUIDE_ARROW = "Toggle the direction arrow"
BINDING_NAME_FOREVERGUIDE_SKIP = "Skip the current step"
BINDING_NAME_FOREVERGUIDE_BACK = "Back one step"
BINDING_NAME_FOREVERGUIDE_MODE = "Switch guide / auto mode"
BINDING_NAME_FOREVERGUIDE_WRONG = "Report the current step as wrong"

local function guarded(name, fn)
    _G[name] = function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ns.ReportOnce("key:" .. name, err) end
    end
end

guarded("ForeverGuide_ToggleWindow", function() ns.UI:Toggle() end)
guarded("ForeverGuide_TogglePicker", function() ns.UI:TogglePicker() end)
guarded("ForeverGuide_ToggleArrow", function()
    ns.Arrow:SetEnabled(not (ns.db.ui.arrow and ns.db.ui.arrow.enabled ~= false))
end)
guarded("ForeverGuide_Skip", function() ns.Guide:Skip() end)
guarded("ForeverGuide_Back", function() ns.Guide:Back() end)
guarded("ForeverGuide_ToggleMode", function()
    ns.Tracker:SetMode(ns.char.mode == "auto" and "guide" or "auto")
end)
guarded("ForeverGuide_ReportWrong", function() ns.Commands:Run("wrong") end)
