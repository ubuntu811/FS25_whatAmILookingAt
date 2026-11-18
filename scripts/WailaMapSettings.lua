--[[
    WailaMapSettings.lua

    Per-savegame look of the map layers (forest, trails, roads, buildings):
    colour, opacity, visible. Defaults live here; what the player changed is
    written to <savegame>/wailaMapSettings.xml on every change (a handful of
    numbers, no need to batch). The debug hub's "Map layers" tab edits this;
    WailaTrailTracer reads the colours when it (re)generates an overlay, TaskMap
    reads opacity / visibility every frame through the tracer's accessors.

    Colours are linear RGB 0..1, the same convention the base game's colour
    picker hands back, so a picked colour goes straight in.
]]

WailaMapSettings = {}

WailaMapSettings.FILENAME = "wailaMapSettings.xml"
WailaMapSettings.LAYERS = { "water", "forest", "tree", "trail", "road", "building" }
WailaMapSettings.LABELS = { water = "Water", forest = "Forest", tree = "Trees", trail = "Trails", road = "Roads", building = "Buildings" }
WailaMapSettings.ALPHA_STEP = 0.1
WailaMapSettings.MIN_ALPHA = 0.05

local DEFAULTS = {
    water = { color = { 0.05, 0.2, 0.45 }, alpha = 0.7, visible = true },
    forest = { color = { 0.02, 0.2, 0.04 }, alpha = 0.1, visible = true },
    tree = { color = { 0.05, 0.5, 0.08 }, alpha = 0.9, visible = true },
    trail = { color = { 0.15, 0.15, 0.15 }, alpha = 0.5, visible = true },
    road = { color = { 0.12, 0.12, 0.12 }, alpha = 1.0, visible = true },
    building = { color = { 0.55, 0.5, 0.45 }, alpha = 1.0, visible = true },
}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [MapSettings] " .. formatString, ...)
end

local function copyDefault(layer)
    local d = DEFAULTS[layer]
    return { color = { d.color[1], d.color[2], d.color[3] }, alpha = d.alpha, visible = d.visible }
end

local values = {}
for _, layer in ipairs(WailaMapSettings.LAYERS) do
    values[layer] = copyDefault(layer)
end

local function clamp01(v)
    return math.max(0, math.min(1, v))
end

function WailaMapSettings.get(layer)
    return values[layer]
end

function WailaMapSettings.isDefault(layer)
    local v, d = values[layer], DEFAULTS[layer]
    return v.alpha == d.alpha and v.visible == d.visible
        and v.color[1] == d.color[1] and v.color[2] == d.color[2] and v.color[3] == d.color[3]
end

-- ===== Edits (each one saves) =====
function WailaMapSettings.setColor(layer, r, g, b)
    values[layer].color = { clamp01(r), clamp01(g), clamp01(b) }
    WailaMapSettings.save()
end

function WailaMapSettings.setAlpha(layer, alpha)
    values[layer].alpha = math.max(WailaMapSettings.MIN_ALPHA, math.min(1, alpha))
    WailaMapSettings.save()
end

function WailaMapSettings.stepAlpha(layer, delta)
    -- rounded so ten steps of 0.1 land on exact tenths
    local alpha = math.floor((values[layer].alpha + delta) * 100 + 0.5) / 100
    WailaMapSettings.setAlpha(layer, alpha)
end

function WailaMapSettings.setVisible(layer, visible)
    values[layer].visible = visible == true
    WailaMapSettings.save()
end

function WailaMapSettings.reset(layer)
    values[layer] = copyDefault(layer)
    WailaMapSettings.save()
end

-- "#rrggbb" in display (sRGB) terms, for the readout next to a layer
function WailaMapSettings.colorToHex(color)
    local function channel(v)
        return math.floor(clamp01(v) ^ (1 / 2.2) * 255 + 0.5)
    end
    return string.format("#%02X%02X%02X", channel(color[1]), channel(color[2]), channel(color[3]))
end

-- ===== Persistence =====
local function filePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil or info.savegameDirectory == nil then
        return nil
    end
    return info.savegameDirectory .. "/" .. WailaMapSettings.FILENAME
end

function WailaMapSettings.save()
    local path = filePath()
    if path == nil then
        return false
    end
    -- only layers that differ from the defaults are worth a line, but writing
    -- all four keeps the file readable and hand-editable
    local xmlFile = XMLFile.create("wailaMapSettings", path, "wailaMapSettings")
    if xmlFile == nil then
        log("save: XMLFile.create failed for %s", path)
        return false
    end
    for i, layer in ipairs(WailaMapSettings.LAYERS) do
        local key = string.format("wailaMapSettings.layer(%d)", i - 1)
        local v = values[layer]
        xmlFile:setString(key .. "#name", layer)
        xmlFile:setString(key .. "#color", string.format("%.4f %.4f %.4f", v.color[1], v.color[2], v.color[3]))
        xmlFile:setFloat(key .. "#alpha", v.alpha)
        xmlFile:setBool(key .. "#visible", v.visible)
    end
    xmlFile:save()
    xmlFile:delete()
    return true
end

function WailaMapSettings.load()
    for _, layer in ipairs(WailaMapSettings.LAYERS) do
        values[layer] = copyDefault(layer)
    end
    local path = filePath()
    if path == nil then
        return false
    end
    local xmlFile = XMLFile.loadIfExists("wailaMapSettings", path)
    if xmlFile == nil then
        return false
    end
    for _, key in xmlFile:iterator("wailaMapSettings.layer") do
        local layer = xmlFile:getString(key .. "#name")
        local v = values[layer]
        if v ~= nil then
            local colorString = xmlFile:getString(key .. "#color")
            if colorString ~= nil then
                local r, g, b = colorString:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*$")
                r, g, b = tonumber(r), tonumber(g), tonumber(b)
                if r ~= nil and g ~= nil and b ~= nil then
                    v.color = { clamp01(r), clamp01(g), clamp01(b) }
                end
            end
            local alpha = xmlFile:getFloat(key .. "#alpha")
            if alpha ~= nil then
                v.alpha = math.max(WailaMapSettings.MIN_ALPHA, math.min(1, alpha))
            end
            local visible = xmlFile:getBool(key .. "#visible")
            if visible ~= nil then
                v.visible = visible
            end
        end
    end
    xmlFile:delete()
    log("loaded map layer settings from %s", path)
    return true
end
