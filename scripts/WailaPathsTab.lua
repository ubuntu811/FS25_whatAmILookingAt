--[[
    WailaPathsTab.lua

    Debug hub tab "Paths": every path in WailaPathStore (recorded drives, imported roads, ...), what it
    is, how long, which way it runs; a button removes the selected one. Paths are saved with the game.
]]

WailaPathsTab = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] [PathsTab] " .. formatString, ...)
end

function WailaPathsTab.getItems()
    local items = {}
    for _, path in ipairs(WailaPathStore.getAll()) do
        -- the map's own splines (hundreds, rebuilt every session) are not listed
        if not path.transient then
            items[#items + 1] = { path = path }
        end
    end
    return items
end

function WailaPathsTab.describeItem(item)
    local path = item.path
    local title = path.name ~= "" and path.name or string.format("%s path", path.kind)
    local primary = string.format("#%d  %s", path.id, title)
    local secondary = string.format("%s  %d points, %.0f m, %s, width %.1f m",
        path.source ~= "" and path.source or path.kind, #path.points, WailaPathStore.length(path.points),
        path.oneWay and "one way" or "both ways", path.width)
    return primary, secondary
end

function WailaPathsTab.register()
    Waila.registerDebugTab({
        id = "paths",
        label = "Paths",
        icon = Utils.getFilename("gui/icons/terrain.dds", FS25WhatAmILookingAt.MOD_DIRECTORY),
        getItems = WailaPathsTab.getItems,
        describeItem = WailaPathsTab.describeItem,
        buttons = {
            { label = "Delete path", instant = true, callback = function(item)
                local removed = WailaPathStore.remove(item.path.id)
                log("delete path %d: %s", item.path.id, removed and "removed" or "not found")
            end },
        },
    })
end
