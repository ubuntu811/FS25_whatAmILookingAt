--[[
    WailaDebugHubDialog.lua

    Single shared debug/tools screen -- replaces what used to be two
    separate things: the OptionDialog-based "WAILA Debug Tools" menu and
    WailaAreaListDialog (list+delete for declared areas). One shared
    keybind (Shift+L). Same shape as the base game's own in-game map
    Hotspots menu: a topics list on the left (VEHICLES/COMBINES/... there,
    registered debug tabs here), selecting one shows its content in the
    middle. See Waila.registerDebugTab for the tab contract -- WAILA
    registers its own five built-in tabs (General/Terrain/Foliage/Field/
    Declared Areas, split along its existing module boundaries) in
    FS25WhatAmILookingAt:loadMap() through that same public API, exactly
    as any other of ubuntu811's own mods could via
    g_currentMission.waila.registerDebugTab(...).

    Topics and items are SmoothLists (genuinely open-ended counts, a
    scrollbar is the right tool). Actions are FIXED BUTTON SLOTS, not a
    third list -- that was tried and confirmed broken live, repeatedly:
    a SmoothList conflates "select" (move the highlight) with "activate
    this now", and clicking a non-default row kept running whatever was
    PREVIOUSLY selected instead of the one actually clicked -- a real
    engine-level click-vs-select ambiguity, not reliably fixable from
    this side. A plain Button's onClick has been rock solid all session
    with none of that ambiguity, and the action list is always small/
    bounded (typically 1-4 per tab) unlike the topic list, so fixed
    slots (MAX_ACTION_BUTTONS, unused ones hidden) are the right fit
    here -- same idea as the old footer-button approach, just with more
    headroom than the original 2-button cap.
]]

WailaDebugHubDialog = {}
local WailaDebugHubDialog_mt = Class(WailaDebugHubDialog, ScreenElement)

WailaDebugHubDialog.GUI_NAME = "WailaDebugHubDialog"
WailaDebugHubDialog.MAX_ACTION_BUTTONS = 6

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [DebugHub] " .. formatString, ...)
end

-- Milliseconds -- confirmed real, safe hook (GuiElement:update(dt) in
-- the base game, dataS/scripts/gui/elements/GuiElement.lua, handles
-- fade transitions + recursing into children; overriding it here and
-- calling superClass() first, same pattern as onOpen, preserves that).
-- dt is milliseconds in this codebase's own convention (see
-- FS25WhatAmILookingAt's pointIntervalMs/areaIntervalMs).
local DONE_DISPLAY_MS = 2000

function WailaDebugHubDialog.new(customMt)
    local self = ScreenElement.new(nil, customMt or WailaDebugHubDialog_mt)
    self.tabs = {}
    self.activeTabIndex = 1
    self.items = {}
    self.selectedItem = nil
    -- True only during refreshItems()'s own itemList:reloadData call --
    -- that auto-selects row 1 and fires onListSelectionChanged even
    -- with no click involved, which would otherwise wipe doneActionIndex
    -- before "Done" is ever shown (confirmed live).
    self.isRefreshingItems = false
    -- Which action slot (index into activeButtons(self)) most recently
    -- ran, shown as "Done" instead of its normal label until
    -- DONE_DISPLAY_MS elapses (see update()) or the next tab switch/
    -- item selection -- whichever comes first. Cheap feedback that
    -- something happened, since most of these actions just log to
    -- log.txt with no other visible effect.
    self.doneActionIndex = nil
    self.doneActionUntil = nil
    return self
end

function WailaDebugHubDialog:onOpen()
    WailaDebugHubDialog:superClass().onOpen(self)
    self.tabs = Waila.debugTabs
    self.topicList:setDataSource(self)
    self.topicList:reloadData(true)
    -- Restores whatever tab was active, not a hardcoded 1 -- closing
    -- the dialog just hides this same Lua instance, it doesn't reset
    -- it, so the topic list widget itself still visually remembers its
    -- last selected row across a close/reopen. activeTabIndex defaults
    -- to 1 in .new() anyway, so this is still 1 on the very first open.
    self:setActiveTab(self.activeTabIndex)
end

function WailaDebugHubDialog:getActiveTab()
    return self.tabs[self.activeTabIndex]
end

-- Tab-level buttons (e.g. Declared Areas' "Delete"), plus one more if the
-- CURRENTLY SELECTED item resolves an actionLabel/actionCallback -- the
-- same fields WailaDeclaredArea areas used to also drive a dedicated
-- "press [key] to X" world action (WAILA_AREA_ACTION, removed as a pure
-- duplicate of this button once the hub existed -- see
-- WailaDebugTools.new's "Reset foliage test rig" type registration).
-- Reusing that data here instead of a separate per-item-button mechanism
-- means any area with a world action automatically gets it reachable
-- from the hub too, not just by standing in the area. Waila.
-- resolveAreaField, not a bare item.actionLabel read -- falls back to a
-- type-level registration for an item restored from waila.xml with no
-- function fields of its own.
local function activeButtons(self)
    local tab = self:getActiveTab()
    local buttons = (tab ~= nil and tab.buttons) or {}
    local item = self.selectedItem
    -- item ~= nil, not "and"-chained into actionLabel/actionCallback --
    -- when item is nil, "item ~= nil and X" evaluates to the BOOLEAN
    -- false (not nil), and false ~= nil is true in Lua, so the old
    -- "if actionLabel ~= nil" check below wrongly treated a nil item as
    -- "has a real action" -- confirmed live, a phantom button literally
    -- labeled "false" appeared whenever nothing was selected.
    local actionLabel = nil
    local actionCallback = nil
    if item ~= nil then
        actionLabel = Waila.resolveAreaField(item, "actionLabel")
        actionCallback = Waila.resolveAreaField(item, "actionCallback")
    end

    if actionLabel ~= nil and actionCallback ~= nil then
        local combined = {}
        for _, button in ipairs(buttons) do
            table.insert(combined, button)
        end
        table.insert(combined, {
            label = actionLabel,
            callback = function(selectedItem) Waila.resolveAreaField(selectedItem, "actionCallback")(selectedItem) end,
        })
        return combined
    end

    return buttons
end

function WailaDebugHubDialog:setActiveTab(index)
    self.activeTabIndex = index
    self.doneActionIndex = nil
    self.doneActionUntil = nil
    self:refreshItems()
end

function WailaDebugHubDialog:refreshItems()
    self.selectedItem = nil
    local tab = self:getActiveTab()
    self.items = (tab ~= nil and tab.getItems()) or {}

    self.isRefreshingItems = true
    self.itemList:setDataSource(self)
    self.itemList:reloadData(true)
    self.isRefreshingItems = false

    self:updateActionButtons()
end

local function actionButtonElement(self, index)
    return self["actionButton" .. index]
end

-- Fixed slots, unused ones hidden. "Done" overrides the normal label for
-- whichever slot most recently ran (see runAction/update()).
function WailaDebugHubDialog:updateActionButtons()
    local buttons = activeButtons(self)

    for i = 1, WailaDebugHubDialog.MAX_ACTION_BUTTONS do
        local button = actionButtonElement(self, i)
        if button ~= nil then
            local descriptor = buttons[i]
            button:setVisible(descriptor ~= nil)
            if descriptor ~= nil then
                button:setText(i == self.doneActionIndex and "Done" or descriptor.label)
            end
        end
    end
end

-- Only the topic list is a datasource-driven SmoothList now -- the item
-- list still is too (see the XML), actions are plain buttons handled
-- below by onClickActionN instead.
function WailaDebugHubDialog:getNumberOfItemsInSection(list, section)
    if list == self.topicList then
        return #self.tabs
    end
    return #self.items
end

function WailaDebugHubDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.topicList then
        local tab = self.tabs[index]
        cell:getAttribute("label"):setText(tab ~= nil and tab.label or "")
        local icon = cell:getAttribute("icon")
        if icon ~= nil then
            icon:setImageFilename(tab ~= nil and tab.icon or nil)
        end
        return
    end

    local tab = self:getActiveTab()
    local item = self.items[index]
    local primary, secondary = "", nil
    if tab ~= nil and item ~= nil then
        primary, secondary = tab.describeItem(item)
    end
    -- Every item shows its OWN tab's icon, not a per-item one -- avoids
    -- needing a separate icon asset per debug action, and every item
    -- genuinely does belong to the tab it's listed under.
    local icon = cell:getAttribute("icon")
    if icon ~= nil then
        icon:setImageFilename(tab ~= nil and tab.icon or nil)
    end
    cell:getAttribute("primary"):setText(primary or "")
    cell:getAttribute("secondary"):setText(secondary or "")
end

function WailaDebugHubDialog:onListSelectionChanged(list, section, index)
    if list == self.topicList then
        self:setActiveTab(index)
        return
    end

    -- Only clear "Done" for a genuine new click, not the item list's own
    -- auto-select echo during refreshItems() (that echo fires on EVERY
    -- refresh, including the one right after an action runs -- clearing
    -- unconditionally here would wipe "Done" before it's ever shown).
    if not self.isRefreshingItems then
        self.doneActionIndex = nil
        self.doneActionUntil = nil
    end
    self.selectedItem = self.items[index]
    self:updateActionButtons()
end

-- Real lifesign at the dispatch point, not a temp diagnostic -- this is
-- the one place WAILA hands off to whatever a tab registered (its own
-- action, or another mod's via Waila.registerDebugTab), so it always
-- logs the handoff, independent of whether the callback itself logs
-- anything -- makes a misbehaving callback clearly "something
-- downstream of here", not "did this even trigger". pcall'd -- a bad
-- callback used to abort this whole handler silently on error, no
-- feedback at all, indistinguishable from "ran but did nothing".
local function runAction(self, index)
    local descriptor = activeButtons(self)[index]
    log("click action %d: descriptor=%s selectedItem=%s",
        index, tostring(descriptor and descriptor.label), tostring(self.selectedItem and self.selectedItem.wailaID))

    if descriptor == nil or descriptor.callback == nil or self.selectedItem == nil then
        return
    end

    local ok, err = pcall(descriptor.callback, self.selectedItem)
    if not ok then
        log("click action %d: '%s' callback FAILED: %s", index, tostring(descriptor.label), tostring(err))
    end

    self.doneActionIndex = index
    self.doneActionUntil = DONE_DISPLAY_MS
    self:refreshItems()
end

function WailaDebugHubDialog:onClickAction1() runAction(self, 1) end
function WailaDebugHubDialog:onClickAction2() runAction(self, 2) end
function WailaDebugHubDialog:onClickAction3() runAction(self, 3) end
function WailaDebugHubDialog:onClickAction4() runAction(self, 4) end
function WailaDebugHubDialog:onClickAction5() runAction(self, 5) end
function WailaDebugHubDialog:onClickAction6() runAction(self, 6) end

-- Auto-reverts "Done" back to its normal label after DONE_DISPLAY_MS.
function WailaDebugHubDialog:update(dt)
    WailaDebugHubDialog:superClass().update(self, dt)

    if self.doneActionIndex == nil then
        return
    end

    self.doneActionUntil = self.doneActionUntil - dt
    if self.doneActionUntil <= 0 then
        self.doneActionIndex = nil
        self.doneActionUntil = nil
        self:updateActionButtons()
    end
end

function WailaDebugHubDialog:onClickClose()
    g_gui:closeDialogByName(WailaDebugHubDialog.GUI_NAME)
end
