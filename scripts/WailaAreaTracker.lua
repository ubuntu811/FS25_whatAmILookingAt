--[[
    WailaAreaTracker.lua

    Fires AREA_ENTERED/AREA_LEFT on g_messageCenter when the local player's
    position transitions in or out of ANY registered Waila.indices type --
    not just declared areas, "field" falls out of the same loop for free,
    same generality Waila.getTypes already has. Polling, not a native
    engine trigger volume -- confirmed this session (TerraFarm's own
    MachineWorkArea checks position on-demand too, no trigger involved) that
    nothing in this ecosystem uses real trigger nodes for ad-hoc runtime
    areas; those need actual authored i3d collision geometry, which a
    Lua-declared box/polygon doesn't have. Cost is one :get(x, z) per
    registered type per tick -- negligible at the realistic scale here (a
    handful of areas), not worth a timer/interval the way
    WailaFieldIndex's much heavier vehicle-tracking uses one.

    Player-only for now -- vehicle-area tracking would need its own pass
    (per-vehicle position loop, same shape), not built until something
    actually needs it. WailaFieldIndex already owns vehicle/field-boundary
    tracking separately; this doesn't duplicate or replace that.
]]

WailaAreaTracker = {}
local WailaAreaTracker_mt = Class(WailaAreaTracker)

WailaAreaTracker.AREA_ENTERED = nextMessageTypeId()
WailaAreaTracker.AREA_LEFT = nextMessageTypeId()

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

function WailaAreaTracker.new()
    local self = setmetatable({}, WailaAreaTracker_mt)
    self.currentAreas = {}
    return self
end

-- currentAreas caches the actual matched object (not just true/a type
-- name) so the LEFT event can hand back what was there -- by the time a
-- leave is detected the player has already moved off that position, so
-- re-querying Waila.indices[type]:get(x, z) at the NEW position would
-- just return nil instead of the area that was actually left.
function WailaAreaTracker:update(dt)
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return
    end

    local x, _, z = getWorldTranslation(g_localPlayer.rootNode)

    local newAreas = {}
    for typeName, index in pairs(Waila.indices) do
        local match = index:get(x, z)
        if match ~= nil then
            newAreas[typeName] = match
            if self.currentAreas[typeName] == nil then
                -- Unconditional lifesign at the publish site itself, not
                -- just whatever a subscriber happens to log on its own
                -- end -- any mod can subscribe to this (Waila.events.
                -- areaEntered), so "did WAILA actually fire this" needs
                -- to be independently confirmable from "did the
                -- subscriber handle it correctly".
                log("[AreaTracker] firing AREA_ENTERED type='%s'", tostring(typeName))
                g_messageCenter:publish(WailaAreaTracker.AREA_ENTERED, typeName, match)
            end
        end
    end

    for typeName, area in pairs(self.currentAreas) do
        if newAreas[typeName] == nil then
            log("[AreaTracker] firing AREA_LEFT type='%s'", tostring(typeName))
            g_messageCenter:publish(WailaAreaTracker.AREA_LEFT, typeName, area)
        end
    end

    self.currentAreas = newAreas
end
