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

    Three SmoothLists (topics / items / actions), not fixed-slot button
    rows anywhere. Two earlier passes tried buttons -- a fixed tab-button
    row (besides looking wrong, cramming N unrelated actions into one row
    visually made them all look bound to the same generic "confirm" key)
    and a fixed 2-button footer for actions (capped at 2, however many a
    tab actually wanted to offer). A list scales to any count via its own
    scrollbar, so every column now uses the exact same interaction:
    select a row. Selecting a topic switches which items show; selecting
    an item just remembers it; selecting an action runs it against
    whatever item is currently selected.

    self.isRefreshing guards against a real, confirmed-via-log infinite
    recursion: SmoothList:reloadData(true) auto-selects row 1, which
    fires onListSelectionChanged even with no click involved.
    refreshItems() reloads BOTH itemList and actionList -- itemList's
    auto-select sets self.selectedItem, and actionList's auto-select
    (now that selectedItem is non-nil) then actually RAN the action,
    which called refreshItems() again, which reloaded both lists again,
    auto-selected again, ran the action again -- a real stack overflow,
    not hypothetical (crashed the game twice). The flag is true only
    during refreshItems()'s own two reloadData calls, so a genuine user
    click (which never happens while we're mid-refresh) still works
    normally; only the self-triggered echo gets ignored.
]]

WailaDebugHubDialog = {}
local WailaDebugHubDialog_mt = Class(WailaDebugHubDialog, ScreenElement)

WailaDebugHubDialog.GUI_NAME = "WailaDebugHubDialog"

function WailaDebugHubDialog.new(customMt)
    local self = ScreenElement.new(nil, customMt or WailaDebugHubDialog_mt)
    self.tabs = {}
    self.activeTabIndex = 1
    self.items = {}
    self.selectedItem = nil
    self.isRefreshing = false
    return self
end

function WailaDebugHubDialog:onOpen()
    WailaDebugHubDialog:superClass().onOpen(self)
    self.tabs = Waila.debugTabs
    self.topicList:setDataSource(self)
    self.topicList:reloadData(true)
    self:setActiveTab(1)
end

function WailaDebugHubDialog:getActiveTab()
    return self.tabs[self.activeTabIndex]
end

local function activeButtons(self)
    local tab = self:getActiveTab()
    return (tab ~= nil and tab.buttons) or {}
end

function WailaDebugHubDialog:setActiveTab(index)
    self.activeTabIndex = index
    self:refreshItems()
end

function WailaDebugHubDialog:refreshItems()
    self.selectedItem = nil
    local tab = self:getActiveTab()
    self.items = (tab ~= nil and tab.getItems()) or {}

    self.isRefreshing = true
    self.itemList:setDataSource(self)
    self.itemList:reloadData(true)
    self.actionList:setDataSource(self)
    self.actionList:reloadData(true)
    self.isRefreshing = false
end

-- All three lists share these three datasource methods -- the "list"
-- param (part of the base-game SmoothList datasource protocol) says
-- which one is actually asking.
function WailaDebugHubDialog:getNumberOfItemsInSection(list, section)
    if list == self.topicList then
        return #self.tabs
    end
    if list == self.actionList then
        return #activeButtons(self)
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

    if list == self.actionList then
        local descriptor = activeButtons(self)[index]
        cell:getAttribute("label"):setText(descriptor ~= nil and descriptor.label or "")
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
    -- Ignore selection echoes caused by our OWN reloadData calls inside
    -- refreshItems -- see the header comment for the real recursion this
    -- was causing.
    if self.isRefreshing then
        return
    end

    if list == self.topicList then
        self:setActiveTab(index)
        return
    end

    if list == self.actionList then
        local descriptor = activeButtons(self)[index]
        if descriptor ~= nil and descriptor.callback ~= nil and self.selectedItem ~= nil then
            descriptor.callback(self.selectedItem)
            self:refreshItems()
        end
        return
    end

    self.selectedItem = self.items[index]
end

function WailaDebugHubDialog:onClickClose()
    g_gui:closeDialogByName(WailaDebugHubDialog.GUI_NAME)
end
