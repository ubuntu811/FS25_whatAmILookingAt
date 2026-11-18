--[[
    WailaAreaIndex.lua

    Backs one type name's worth of WailaDeclaredArea instances (one index
    per type, same as WailaFieldIndex backs "field") -- created on demand
    by Waila.registerArea the first time a mod registers that type, not
    something a mod builds itself. Just a linear scan: declared areas are
    expected to be few and player-position-sized (a test rig, a parking
    lot, a flower patch), not a field-sweep-scale count, so this doesn't
    need WailaFieldGridScanner's grid/budget machinery at all.
]]

WailaAreaIndex = {}
local WailaAreaIndex_mt = Class(WailaAreaIndex)

-- Explicit marker checked by Waila.registerArea instead of :isa() --
-- :isa() is a native engine function (confirmed via decompile: no Lua-
-- level definition exists to inspect), and every working example of it in
-- this codebase checks a mod class against a base-game one, never two
-- purely mod-defined classes against each other. Rather than assume that
-- untested case behaves the same, a plain field sidesteps the question
-- entirely.
WailaAreaIndex.MARKER = "WailaAreaIndex"

function WailaAreaIndex.new(typeName)
    local self = setmetatable({}, WailaAreaIndex_mt)
    self.className = WailaAreaIndex.MARKER
    self.typeName = typeName
    self.areas = {}
    return self
end

-- Upsert by wailaID, not a bare append -- restoring the same persisted
-- area twice (e.g. two Waila.reloadAll() cycles in one session, each
-- re-running WailaFieldIndex:loadFromXML) has to land on the SAME entry,
-- not a growing pile of duplicates. area.wailaID == nil (a caller that
-- didn't go through Waila.registerArea's id assignment) always appends,
-- same as before this existed.
function WailaAreaIndex:add(area)
    if area.wailaID ~= nil then
        for i, existing in ipairs(self.areas) do
            if existing.wailaID == area.wailaID then
                self.areas[i] = area
                return
            end
        end
    end
    table.insert(self.areas, area)
end

function WailaAreaIndex:remove(area)
    for i, existing in ipairs(self.areas) do
        if existing == area then
            table.remove(self.areas, i)
            return
        end
    end
end

-- Public: first declared area of this type covering (x, z), or nil.
-- "First" only matters if a mod overlaps two areas of its own same type,
-- which is a mod-authoring choice, not something this index resolves.
function WailaAreaIndex:get(x, z)
    for _, area in ipairs(self.areas) do
        if area:getIsPosInside(x, z) then
            return area
        end
    end
    return nil
end

function WailaAreaIndex:getAll()
    return self.areas
end

-- Public: drops every area of this type at once. For a mod that only
-- ever wants "one area of my own type at a time" (WailaDebugTools' test
-- rig, see placeFoliageTestRig) -- clearing by type instead of tracking
-- one instance-field reference also correctly handles an area that got
-- restored from waila.xml on load, which no in-memory reference points
-- to yet.
function WailaAreaIndex:clear()
    self.areas = {}
end
