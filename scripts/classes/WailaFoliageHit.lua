--[[
    WailaFoliageHit.lua

    Typed result class for one entry of WailaFoliageInspector:inspectPoint()
    -- that method returns a LIST of these (a point can have several
    foliage layers stacked, e.g. grass over a deco plant), unlike every
    other inspector so far which returns one object per inspection. The
    list itself stays a plain Lua array -- only needs to exist so callers
    can iterate it, nothing about "being a list" needs its own type -- the
    typed/dumpable unit is each hit.
]]

WailaFoliageHit = {}
local WailaFoliageHit_mt = Class(WailaFoliageHit)

function WailaFoliageHit.new(name, density, kind)
    local self = setmetatable({}, WailaFoliageHit_mt)

    self.name = name
    self.density = density
    self.kind = kind

    return self
end

function WailaFoliageHit:toTable()
    return {
        name = self.name,
        density = self.density,
        kind = self.kind,
    }
end

function WailaFoliageHit:dumpHudJson()
    return self:toTable()
end

function WailaFoliageHit:dumpLogJson()
    return self:toTable()
end
