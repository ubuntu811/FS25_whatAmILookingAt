WailaObjectInspector = {}
local WailaObjectInspector_mt = Class(WailaObjectInspector)

function WailaObjectInspector.new()
    return setmetatable({}, WailaObjectInspector_mt)
end

function WailaObjectInspector:inspect(hit)
    return WailaObject.new(hit)
end
