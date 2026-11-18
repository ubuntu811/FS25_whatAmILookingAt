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
WailaDebugHubDialog.MAX_ACTION_BUTTONS = 14

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
    -- tabs that change what they list (Map layers) ask the open hub to refresh
    WailaDebugHubDialog.instance = self
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
    -- ten opacity steps for the selector (Map layers); the tab maps state N to N / 10
    if self.opacityOption ~= nil then
        local texts = {}
        for i = 1, 10 do
            texts[i] = string.format("%d%%", i * 10)
        end
        self.opacityOption:setTexts(texts)
    end
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
-- A tab marks related buttons with the same button.group; where the group changes the hub leaves one empty slot (a gap, no button). Buttons without a group (every older tab) stay as they are.
function WailaDebugHubDialog.withGaps(buttons)
    local out, previous = {}, nil
    for _, button in ipairs(buttons) do
        if previous ~= nil and previous.group ~= nil and button.group ~= nil and previous.group ~= button.group then
            out[#out + 1] = { spacer = true }
        end
        out[#out + 1] = button
        previous = button
    end
    return out
end

local function activeButtons(self)
    local tab = self:getActiveTab()
    local item = self.selectedItem
    -- tab.getButtons(item) -> the buttons for the selected row (a tab whose row has its own choices lists them: IW's Weathering tab); else the tab's fixed list
    local buttons = (tab ~= nil and tab.getButtons ~= nil and item ~= nil and tab.getButtons(item)) or (tab ~= nil and tab.buttons) or {}
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
        return WailaDebugHubDialog.withGaps(combined)
    end

    return WailaDebugHubDialog.withGaps(buttons)
end

function WailaDebugHubDialog:setActiveTab(index)
    self.activeTabIndex = index
    self.doneActionIndex = nil
    self.doneActionUntil = nil
    self:refreshItems()
end

-- keepIndex (optional): re-select that row after the reload, so a tab that
-- edits the selected item (Map layers: opacity steps) does not jump back to row 1.
function WailaDebugHubDialog:refreshItems(keepIndex)
    self.selectedItem = nil
    self.hoverIndex = nil
    local tab = self:getActiveTab()
    self.items = (tab ~= nil and tab.getItems()) or {}

    self.isRefreshingItems = true
    self.itemList:setDataSource(self)
    self.itemList:reloadData(true)
    if keepIndex ~= nil and keepIndex > 1 and keepIndex <= #self.items then
        pcall(self.itemList.setSelectedIndex, self.itemList, keepIndex, true)
    end
    self.isRefreshingItems = false

    self:updateActionButtons()
end

local function actionButtonElement(self, index)
    return self["actionButton" .. index]
end

-- Fixed slots, unused ones hidden. "Done" overrides the normal label for
-- whichever slot most recently ran (see runAction/update()).
function WailaDebugHubDialog:updateActionButtons()
    self:updateBigPreview()
    local buttons = activeButtons(self)

    for i = 1, WailaDebugHubDialog.MAX_ACTION_BUTTONS do
        local button = actionButtonElement(self, i)
        if button ~= nil then
            local descriptor = buttons[i]
            if descriptor ~= nil and descriptor.spacer then
                descriptor = nil                                    -- (a gap between two groups: nothing to show)
            end
            button:setVisible(descriptor ~= nil)
            if descriptor ~= nil then
                button:setText(i == self.doneActionIndex and "Done" or descriptor.label)
            end
            -- a button with a layerId (a terrain layer id) gets that layer's picture left of it
            local icon = self["buttonIcon" .. i]
            if icon ~= nil then
                local shown = false
                if descriptor ~= nil and descriptor.layerId ~= nil and g_terrainNode ~= nil and icon.setTerrainLayer ~= nil then
                    shown = pcall(icon.setTerrainLayer, icon, g_terrainNode, descriptor.layerId)
                end
                icon:setVisible(shown)
            end
        end
    end
    self:updateOpacityOption()
end

-- The arrow selector under the buttons: shown when the active tab can read and set the selected
-- item's opacity (tab.getOpacity(item) -> 0..1, tab.setOpacity(item, 0..1)).
function WailaDebugHubDialog:updateOpacityOption()
    local option = self.opacityOption
    if option == nil then
        return
    end
    local tab = self:getActiveTab()
    local item = self.selectedItem
    local show = tab ~= nil and tab.getOpacity ~= nil and tab.setOpacity ~= nil and item ~= nil
    option:setVisible(show)
    if self.opacityTitle ~= nil then
        self.opacityTitle:setVisible(show)
    end
    if show then
        local state = math.max(1, math.min(10, math.floor(tab.getOpacity(item) * 10 + 0.5)))
        option:setState(state)
    end
end

function WailaDebugHubDialog:onClickOpacityOption(state)
    local tab = self:getActiveTab()
    local item = self.selectedItem
    if tab == nil or tab.setOpacity == nil or item == nil then
        return
    end
    local ok, err = pcall(tab.setOpacity, item, state / 10)
    if not ok then
        log("opacity selector on '%s' FAILED: %s", tostring(tab.id), tostring(err))
    end
    self:refreshItems(self.itemList ~= nil and self.itemList.selectedIndex or nil)
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

    -- optional colour chip: tab.getItemColor(item) -> r, g, b (linear), alpha (default 1)
    local swatch = cell:getAttribute("swatch")
    if swatch ~= nil then
        local r, g, b, a
        if tab ~= nil and item ~= nil and tab.getItemColor ~= nil then
            r, g, b, a = tab.getItemColor(item)
        end
        swatch:setVisible(r ~= nil)
        if r ~= nil then
            a = a or 1
            swatch:setImageColor(nil, r, g, b, a)
            swatch:setImageColor(GuiOverlay.STATE_SELECTED, r, g, b, a)
        end
    end

    -- optional terrain layer picture instead of the chip: tab.getItemLayer(item) -> the terrain layer id (the game's TerrainLayer element draws its texture)
    local terrain = cell:getAttribute("terrain")
    if terrain ~= nil then
        local layerId = nil
        if tab ~= nil and item ~= nil and tab.getItemLayer ~= nil and g_terrainNode ~= nil then
            layerId = tab.getItemLayer(item)
        end
        local shown = false
        if layerId ~= nil and terrain.setTerrainLayer ~= nil then
            shown = pcall(terrain.setTerrainLayer, terrain, g_terrainNode, layerId)
        end
        terrain:setVisible(shown)
        local swatch = cell:getAttribute("swatch")
        if shown and swatch ~= nil then
            swatch:setVisible(false)
        end
    end

    -- optional ten-segment meter: tab.getItemMeter(item) -> fraction 0..1 (and dim = true to grey it out)
    local fraction, dim
    if tab ~= nil and item ~= nil and tab.getItemMeter ~= nil then
        fraction, dim = tab.getItemMeter(item)
    end
    local lit = fraction ~= nil and math.floor(fraction * 10 + 0.5) or 0
    for i = 1, 10 do
        local segment = cell:getAttribute("seg" .. i)
        if segment ~= nil then
            segment:setVisible(fraction ~= nil)
            if fraction ~= nil then
                local level = i <= lit and (dim and 0.45 or 0.85) or 0.22
                segment:setImageColor(nil, level, level, level, 1)
                segment:setImageColor(GuiOverlay.STATE_SELECTED, level, level, level, 1)
            end
        end
    end
end

-- Mouse wheel over a row of a tab that defines onScroll(item, delta) (Map layers: opacity):
-- wheel up = +1, down = -1, applied to the HOVERED row. Caught before the list sees it,
-- because the list would use the same wheel to scroll / move the selection.
function WailaDebugHubDialog:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if isDown and not eventUsed and self.itemList ~= nil then
        local delta = 0
        if Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP) then
            delta = 1
        elseif Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN) then
            delta = -1
        end
        local tab = self:getActiveTab()
        local list = self.itemList
        if delta ~= 0 and tab ~= nil and tab.onScroll ~= nil
            and GuiUtils.checkOverlayOverlap(posX, posY, list.absPosition[1], list.absPosition[2], list.absSize[1], list.absSize[2]) then
            local over = list:getElementAtScreenPosition(posX, posY)
            local index = over ~= nil and over.indexInSection or nil
            local item = index ~= nil and self.items[index] or nil
            if item ~= nil then
                local ok, err = pcall(tab.onScroll, item, delta)
                if not ok then
                    log("scroll on '%s' FAILED: %s", tostring(tab.id), tostring(err))
                end
                self:refreshItems(index)
                return true
            end
        end
    end
    return WailaDebugHubDialog:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
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
    self:updateBigPreview()
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

    local keepIndex = self.itemList ~= nil and self.itemList.selectedIndex or nil
    local ok, err = pcall(descriptor.callback, self.selectedItem)
    if not ok then
        log("click action %d: '%s' callback FAILED: %s", index, tostring(descriptor.label), tostring(err))
    end

    -- "Done" is for actions whose result is not visible right there (a dump to the log); an action
    -- that visibly changes the row (colour, hide, reset) marks itself instant and skips it
    local instant = descriptor.instant == true or (self.selectedItem ~= nil and self.selectedItem.instant == true)
    if not instant then
        self.doneActionIndex = index
        self.doneActionUntil = DONE_DISPLAY_MS
    end
    self:refreshItems(keepIndex)
end

-- The picture bottom right under the action buttons: tab.getItemPreview(item) -> { cols = 8, rows = 8, layers = { id or false ... } } (row by row: a mosaic of terrain layer pictures, an assembly of layers) for the row
-- selected (PREVIEW_ON_HOVER: the one under the mouse); else the big picture of the row's own layer (tab.getItemLayer). Tabs with neither show nothing.
WailaDebugHubDialog.PREVIEW_CELLS = 64
WailaDebugHubDialog.PREVIEW_ON_HOVER = false     -- the picture follows the selected row (true: the row under the mouse)
function WailaDebugHubDialog:updateBigPreview()
    local big = self.terrainBig
    if big == nil then
        return
    end
    local tab = self:getActiveTab()
    local item = WailaDebugHubDialog.PREVIEW_ON_HOVER and self.hoverIndex ~= nil and self.items ~= nil and self.items[self.hoverIndex] or self.selectedItem
    local preview = nil
    local layerId = nil
    if tab ~= nil and item ~= nil and g_terrainNode ~= nil then
        if tab.getItemPreview ~= nil then
            preview = tab.getItemPreview(item)
        end
        if preview == nil and tab.getItemLayer ~= nil then
            layerId = tab.getItemLayer(item)
        end
    end
    local anyCell = false
    for k = 1, WailaDebugHubDialog.PREVIEW_CELLS do
        local cell = self["terrainCell" .. k]
        if cell ~= nil then
            local id = preview ~= nil and preview.layers[k] or nil
            local shown = id ~= nil and id ~= false and cell.setTerrainLayer ~= nil and pcall(cell.setTerrainLayer, cell, g_terrainNode, id)
            cell:setVisible(shown == true)
            anyCell = anyCell or shown == true
        end
    end
    local shown = layerId ~= nil and big.setTerrainLayer ~= nil and pcall(big.setTerrainLayer, big, g_terrainNode, layerId)
    big:setVisible(shown == true)
    -- tab.getItemImage(item) -> a picture file (a $data path is fine), when the row has no terrain picture
    local imageShown = false
    if self.itemImage ~= nil then
        local filename = nil
        if not shown and not anyCell and tab ~= nil and item ~= nil and tab.getItemImage ~= nil then
            local ok, result = pcall(tab.getItemImage, item)
            filename = ok and result or nil
        end
        if filename ~= self.lastImageFilename then
            self.lastImageFilename = filename
            print(string.format("[WhatAmILookingAt] [DebugHub] row picture: %s", tostring(filename)))
        end
        if filename ~= nil then
            self.itemImage:setImageFilename(filename)
            imageShown = true
        end
        self.itemImage:setVisible(imageShown)
    end
    -- a plant icon sits on a black tile of its own (the profile's colour, no runtime colour call), the terrain pictures in the light frame
    if self.itemBackdrop ~= nil then
        self.itemBackdrop:setVisible(imageShown)
    end
    if self.previewFrame ~= nil then
        self.previewFrame:setVisible(not imageShown and (shown == true or (preview ~= nil and anyCell)))
    end
end

function WailaDebugHubDialog:onListHighlightChanged(list, section, index)
    if list ~= self.itemList then
        return
    end
    self.hoverIndex = index
    self:updateBigPreview()
end

-- A double click on a row of a tab that defines onDoubleClick(item): that row's default action (IW's Textures tab: use a set, open a type, add a layer). Other tabs ignore it: their first button may be a delete.
-- The list's own double click (onDoubleClick) never showed up in the log, so clicks are timed here as well: two clicks on the same row within DOUBLE_CLICK_MS are a double click. Both ways end in
-- onItemDoubleClick, which ignores a second call within 600 ms (when the engine's fires too, the action runs once).
WailaDebugHubDialog.DOUBLE_CLICK_MS = 400
function WailaDebugHubDialog:onItemClick(list, section, index)
    if list ~= self.itemList then
        return
    end
    local now = g_time or 0
    local last = self.lastRowClick
    if last ~= nil and last.index == index and now >= last.time and now - last.time <= WailaDebugHubDialog.DOUBLE_CLICK_MS then
        self.lastRowClick = nil
        self:onItemDoubleClick(list, section, index)
        return
    end
    self.lastRowClick = { index = index, time = now }
end

function WailaDebugHubDialog:onItemDoubleClick(list, section, index)
    if list ~= self.itemList then
        return
    end
    local now = g_time or 0
    if self.lastDoubleClick ~= nil and now >= self.lastDoubleClick and now - self.lastDoubleClick < 600 then
        return
    end
    self.lastDoubleClick = now
    local tab = self:getActiveTab()
    local item = self.items[index]
    if tab == nil or tab.onDoubleClick == nil or item == nil then
        return
    end
    self.selectedItem = item
    log("double click on row %d of '%s'", index, tostring(tab.id))
    local keepIndex = self.itemList ~= nil and self.itemList.selectedIndex or nil
    local ok, err = pcall(tab.onDoubleClick, item)
    if not ok then
        log("double click on '%s' FAILED: %s", tostring(tab.id), tostring(err))
    end
    self:refreshItems(keepIndex)
end

function WailaDebugHubDialog:onClickAction1() runAction(self, 1) end
function WailaDebugHubDialog:onClickAction2() runAction(self, 2) end
function WailaDebugHubDialog:onClickAction3() runAction(self, 3) end
function WailaDebugHubDialog:onClickAction4() runAction(self, 4) end
function WailaDebugHubDialog:onClickAction5() runAction(self, 5) end
function WailaDebugHubDialog:onClickAction6() runAction(self, 6) end
function WailaDebugHubDialog:onClickAction7() runAction(self, 7) end
function WailaDebugHubDialog:onClickAction8() runAction(self, 8) end
function WailaDebugHubDialog:onClickAction9() runAction(self, 9) end
function WailaDebugHubDialog:onClickAction10() runAction(self, 10) end
function WailaDebugHubDialog:onClickAction11() runAction(self, 11) end
function WailaDebugHubDialog:onClickAction12() runAction(self, 12) end
function WailaDebugHubDialog:onClickAction13() runAction(self, 13) end
function WailaDebugHubDialog:onClickAction14() runAction(self, 14) end

-- Auto-reverts "Done" back to its normal label after DONE_DISPLAY_MS.
function WailaDebugHubDialog:update(dt)
    WailaDebugHubDialog:superClass().update(self, dt)

    -- the selected row can be busy (item.isBusy(): a long scan): when that changes by itself (the scan starts, ends) the rows and the button are loaded again, so "Running ..." comes and goes without a click
    local item = self.selectedItem
    if item ~= nil and item.isBusy ~= nil then
        local ok, busy = pcall(item.isBusy)
        busy = ok and busy == true
        if self.busyItem ~= item then
            self.busyItem, self.lastBusy = item, busy
        elseif busy ~= self.lastBusy then
            self.lastBusy = busy
            self:refreshItems(self.itemList ~= nil and self.itemList.selectedIndex or nil)
        end
    else
        self.busyItem, self.lastBusy = nil, nil
    end

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

-- Back (the button and ESC): a tab that defines onBack() gets to go up one level first (it returns true when it did: IW's Textures tab, from the layers to the types to the sets); only when it does not,
-- or has nothing above, the hub closes.
function WailaDebugHubDialog:onClickClose()
    local tab = self:getActiveTab()
    if tab ~= nil and tab.onBack ~= nil then
        local ok, handled = pcall(tab.onBack)
        if ok and handled then
            self:refreshItems()
            return
        end
    end
    g_gui:closeDialogByName(WailaDebugHubDialog.GUI_NAME)
end
