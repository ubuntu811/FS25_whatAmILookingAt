--[[
    WailaMapLayersTab.lua

    Debug hub tab "Map layers": one row per map layer (forest, trails, roads,
    buildings) showing its colour, opacity, visibility and what the scan
    detected for it on this map; buttons edit the selected layer. Colour uses
    the base game's own picker (ColorPickerDialog: the vehicle shop's list /
    custom RGB / favourites dialog), settings live in WailaMapSettings and are
    saved per savegame. Opacity and visibility act at once (TaskMap reads them
    every frame); a colour change re-colours the existing overlays from their
    bitmaps, no rescan.
]]

WailaMapLayersTab = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [MapLayersTab] " .. formatString, ...)
end

-- Swatches for the picker's list page, sRGB hex -> the linear values the
-- picker and WailaMapSettings use.
local SWATCH_HEX = {
    0x404040, 0x808080, 0xC0C0C0, 0xF0F0F0, 0x8B3A2B, 0xC8B48C,
    0x6B4A2B, 0x1E4D2B, 0x3CB44B, 0x2E5FA3, 0xE8832A, 0xE8D43A,
}
local function swatches()
    local list = {}
    for _, hex in ipairs(SWATCH_HEX) do
        local r = math.floor(hex / 65536) % 256
        local g = math.floor(hex / 256) % 256
        local b = hex % 256
        table.insert(list, { (r / 255) ^ 2.2, (g / 255) ^ 2.2, (b / 255) ^ 2.2 })
    end
    return list
end
WailaMapLayersTab.swatches = swatches

-- What the scan found for this layer on this map (nil-safe: before the first
-- scan of a session nothing is known).
local function describeDetection(layer)
    local tracer = g_currentMission ~= nil and g_currentMission.wailaTrailTracer or nil
    if layer == "road" then
        if tracer ~= nil and tracer.roadSource ~= nil then
            return tracer.roadSource
        end
        return "not scanned yet"
    elseif layer == "forest" then
        if tracer ~= nil and tracer.learnedForestKeys ~= nil then
            if tracer.learnedForestKeys > 0 then
                return string.format("trees + %d floor layer(s)", tracer.learnedForestKeys)
            end
            return "trees only"
        end
        return "not scanned yet"
    elseif layer == "tree" then
        return "every trunk (overlap query), dots; not saved, rescan after a restart"
    elseif layer == "water" then
        return "WATER planes above the terrain (digging a pond shows up)"
    elseif layer == "trail" then
        return "worn dirt / gravel"
    end
    return "building + tall static colliders"
end

function WailaMapLayersTab.getItems()
    local items = {}
    for i, layer in ipairs(WailaMapSettings.LAYERS) do
        table.insert(items, { layer = layer, index = i })
    end
    return items
end

function WailaMapLayersTab.describeItem(item)
    local layer = item.layer
    local v = WailaMapSettings.get(layer)
    local state = string.format("%s  opacity %d%% (scroll)  %s%s",
        WailaMapSettings.colorToHex(v.color), math.floor(v.alpha * 100 + 0.5),
        v.visible and "shown" or "hidden", WailaMapSettings.isDefault(layer) and "" or "  changed")
    -- detection next to the name (the secondary line is only so wide)
    return WailaMapSettings.LABELS[layer] .. "  -  " .. describeDetection(layer), state
end

-- Colour chip on the row: the layer's colour as picked (opaque so the hue reads; dimmed
-- when the layer is hidden). Opacity stays in the text.
function WailaMapLayersTab.getItemColor(item)
    local v = WailaMapSettings.get(item.layer)
    return v.color[1], v.color[2], v.color[3], v.visible and 1 or 0.25
end

local function refreshHub(index)
    local hub = WailaDebugHubDialog ~= nil and WailaDebugHubDialog.instance or nil
    if hub ~= nil and hub.refreshItems ~= nil then
        hub:refreshItems(index)
    end
end

-- ColorPickerDialog.show calls this as callback(target, colorIndex, args, customColor):
-- colorIndex = a swatch from the list page, customColor.customColor = {r, g, b}
-- (linear) from the custom page; both nil when the player backed out.
function WailaMapLayersTab.onColorPicked(self, colorIndex, args, customColor)
    local layer = args.layer
    local color = nil
    if colorIndex ~= nil then
        color = swatches()[colorIndex]
    elseif customColor ~= nil then
        color = customColor.customColor
    end
    if color == nil then
        return
    end
    WailaMapSettings.setColor(layer, color[1], color[2], color[3])
    log("%s colour -> %s", layer, WailaMapSettings.colorToHex(WailaMapSettings.get(layer).color))
    if g_currentMission ~= nil and g_currentMission.wailaTrailTracer ~= nil then
        g_currentMission.wailaTrailTracer.recolorOverlays()
    end
    refreshHub(args.index)
end

local function pickColor(item)
    if ColorPickerDialog == nil or ColorPickerDialog.INSTANCE == nil then
        log("pick colour: the base game's ColorPickerDialog is not available")
        return
    end
    local current = WailaMapSettings.get(item.layer).color
    -- args: layer + row, handed back to onColorPicked. No material selector
    -- (overlays have no gloss), custom RGB and favourites pages enabled.
    ColorPickerDialog.show(WailaMapLayersTab.onColorPicked, WailaMapLayersTab, { layer = item.layer, index = item.index },
        swatches(), nil, nil, { current[1], current[2], current[3] }, true, false, true)
end

-- Mouse wheel over a row (see WailaDebugHubDialog:mouseEvent): up = more opaque
function WailaMapLayersTab.onScroll(item, delta)
    WailaMapSettings.stepAlpha(item.layer, delta * WailaMapSettings.ALPHA_STEP)
end

function WailaMapLayersTab.register()
    Waila.registerDebugTab({
        id = "maplayers",
        label = "Map layers",
        icon = Utils.getFilename("gui/icons/terrain.dds", FS25WhatAmILookingAt.MOD_DIRECTORY),
        getItems = WailaMapLayersTab.getItems,
        describeItem = WailaMapLayersTab.describeItem,
        onScroll = WailaMapLayersTab.onScroll,
        getItemColor = WailaMapLayersTab.getItemColor,
        buttons = {
            { label = "Pick colour", callback = pickColor },
            { label = "More opaque", callback = function(item) WailaMapSettings.stepAlpha(item.layer, WailaMapSettings.ALPHA_STEP) end },
            { label = "Less opaque", callback = function(item) WailaMapSettings.stepAlpha(item.layer, -WailaMapSettings.ALPHA_STEP) end },
            { label = "Show / hide", callback = function(item) WailaMapSettings.setVisible(item.layer, not WailaMapSettings.get(item.layer).visible) end },
            { label = "Reset", callback = function(item)
                WailaMapSettings.reset(item.layer)
                if g_currentMission ~= nil and g_currentMission.wailaTrailTracer ~= nil then
                    g_currentMission.wailaTrailTracer.recolorOverlays()
                end
            end },
        },
    })
end
