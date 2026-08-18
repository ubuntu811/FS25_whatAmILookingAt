--[[
    WailaDeclaredArea.lua

    A plain declared region any mod can register through WAILA without
    touching density maps at all -- Waila.registerArea({ type = "...",
    polygon = ..., metadata = {...} }). Rice fields proved the underlying
    trick (a Polygon2D with getIsPosInside), this just makes that trick
    available generically instead of being wired specifically into
    WailaFieldGridScanner's rice-field special case.

    Either polygon (a Polygon2D, see scripts/collections/Polygon2D.lua) or
    box ({minX, maxX, minZ, maxZ}, cheaper for simple rectangular zones
    like a parking area) is expected -- not both. metadata is a free-form
    flat table, dumped as-is by dumpHudJson/dumpLogJson alongside type,
    same "arbitrary key/value" contract WailaField.jobs' entries already
    use for job-specific data.
]]

WailaDeclaredArea = {}
local WailaDeclaredArea_mt = Class(WailaDeclaredArea)

function WailaDeclaredArea.new(data)
    local self = setmetatable({}, WailaDeclaredArea_mt)
    -- Stable identity, assigned by Waila.registerArea (generated if the
    -- caller didn't supply one) -- lets WailaAreaIndex:add recognize "this
    -- is the same area again" (e.g. restored twice from waila.xml, once
    -- per Waila.reloadAll() cycle) and replace it in place instead of
    -- appending a duplicate. See Waila.lua's header comment for the full
    -- story of why this exists.
    self.wailaID = data.wailaID
    self.type = data.type
    self.polygon = data.polygon
    self.box = data.box
    self.metadata = data.metadata or {}
    -- Optional: lets a mod bind a "press [key] to X" action to this area,
    -- shown/enabled only while the player is inside it (see
    -- WailaAreaTracker.AREA_ENTERED/AREA_LEFT and
    -- FS25WhatAmILookingAt:onAreaEntered). actionCallback(area) runs on
    -- press -- both nil for an area that's just informational.
    self.actionLabel = data.actionLabel
    self.actionCallback = data.actionCallback
    return self
end

function WailaDeclaredArea:getIsPosInside(x, z)
    if self.polygon ~= nil then
        return WailaUtil.getIsPosInsidePolygon(self.polygon, x, z)
    end
    if self.box ~= nil then
        return x >= self.box.minX and x <= self.box.maxX and z >= self.box.minZ and z <= self.box.maxZ
    end
    return false
end

function WailaDeclaredArea:toTable()
    local result = { type = self.type }
    for key, value in pairs(self.metadata) do
        result[key] = value
    end
    return result
end

function WailaDeclaredArea:dumpHudJson()
    return self:toTable()
end

function WailaDeclaredArea:dumpLogJson()
    return self:toTable()
end

-- Debug-only visualization -- immediate-mode, has to be called every frame
-- an area should stay visible, same as any other engine debug draw. Line
-- still renders white in-game regardless of the r/g/b passed here -- cause
-- not yet found. Ruled out: DebugUtil.drawDebugLine/drawDebugAreaRectangle
-- never passing the native function's trailing "solid" argument (first
-- guess, wrong -- TerraFarm's PolygonEditor.lua calls the exact same
-- native drawDebugLine with solid=false and gets real colors, confirmed
-- via Editor.lua's LINE_DEFAULT/LINE_SELECTED being distinct gray/green,
-- not white). solid kept false here to match their proven-working call
-- rather than the disproven guess. Only the box case is wired for now --
-- polygon areas (rice fields, if ever registered this way) would need the
-- same per-edge loop over self.polygon's points instead, not built until
-- something needs it.
function WailaDeclaredArea:drawDebug(r, g, b)
    if self.box == nil then
        return
    end

    local box = self.box
    local corners = {
        { box.minX, box.minZ },
        { box.maxX, box.minZ },
        { box.maxX, box.maxZ },
        { box.minX, box.maxZ },
    }

    for i = 1, 4 do
        local x1, z1 = corners[i][1], corners[i][2]
        local x2, z2 = corners[i % 4 + 1][1], corners[i % 4 + 1][2]
        local y1 = getTerrainHeightAtWorldPos(g_terrainNode, x1, 0, z1) + 0.1
        local y2 = getTerrainHeightAtWorldPos(g_terrainNode, x2, 0, z2) + 0.1
        drawDebugLine(x1, y1, z1, r, g, b, x2, y2, z2, r, g, b, false)
    end
end
