dofile("tests/stubs.lua")

-- fake XMLFile: per path a flat key -> value table
local files = {}
local function api(store)
    local f = {}
    function f:setString(k, v) store[k] = tostring(v) end
    function f:setFloat(k, v) store[k] = v end
    function f:setBool(k, v) store[k] = v end
    function f:getString(k) return store[k] end
    function f:getFloat(k) return store[k] end
    function f:getBool(k) return store[k] end
    function f:save() end
    function f:delete() end
    function f:iterator(prefix)
        local i, keys = -1, {}
        while store[prefix:gsub("%.[^.]*$", "") == "" and "" or (prefix .. "(" .. (i + 1) .. ")#name")] ~= nil do
            i = i + 1
            table.insert(keys, prefix .. "(" .. i .. ")")
        end
        local n = 0
        return function()
            n = n + 1
            if keys[n] then return n, keys[n] end
        end
    end
    return f
end
XMLFile = {
    create = function(_, path) files[path] = {}; return api(files[path]) end,
    loadIfExists = function(_, path) if files[path] then return api(files[path]) end end,
}
g_currentMission = { missionInfo = { savegameDirectory = "/save" } }

dofile("scripts/WailaMapSettings.lua")
local S = WailaMapSettings

check("tree defaults: green dots at 90%", S.get("tree").alpha == 0.9 and S.get("tree").color[2] > S.get("tree").color[1])
check("water defaults: blue at 70%", S.get("water").alpha == 0.7 and S.get("water").color[3] > S.get("water").color[1])
check("defaults: trail is dark gray at 50%", S.get("trail").alpha == 0.5 and S.get("trail").color[1] == 0.15)
check("defaults: nothing changed", S.isDefault("forest") and S.isDefault("road"))

for _ = 1, 10 do S.stepAlpha("building", -S.ALPHA_STEP) end
check("opacity steps down to the floor, never below", S.get("building").alpha == S.MIN_ALPHA)
S.setAlpha("building", 0.5)
S.stepAlpha("building", 0.1)
check("ten-percent steps land on exact tenths (0.5 + 0.1 = 0.6)", S.get("building").alpha == 0.6)
S.stepAlpha("building", 5)
check("opacity caps at 1", S.get("building").alpha == 1)

S.setColor("road", 2, -1, 0.5)
check("colours clamp to 0..1", S.get("road").color[1] == 1 and S.get("road").color[2] == 0 and S.get("road").color[3] == 0.5)
S.setVisible("forest", false)
check("hide is stored", S.get("forest").visible == false)
check("a changed layer is not default", not S.isDefault("forest"))
check("hex of linear white is #FFFFFF", S.colorToHex({ 1, 1, 1 }) == "#FFFFFF")
check("hex of linear black is #000000", S.colorToHex({ 0, 0, 0 }) == "#000000")

-- round trip through the fake file
S.setColor("trail", 0.25, 0.5, 0.75)
S.setAlpha("trail", 0.3)
check("settings file written to the savegame", files["/save/wailaMapSettings.xml"] ~= nil)
S.reset("trail")
S.reset("forest")
S.reset("road")
S.reset("building")
-- reset saved defaults; now write a changed state and load it back over defaults
S.setColor("trail", 0.25, 0.5, 0.75)
S.setAlpha("trail", 0.3)
S.setVisible("road", false)
local saved = {}
for k, v in pairs(files["/save/wailaMapSettings.xml"]) do saved[k] = v end
S.reset("trail"); S.reset("road")
files["/save/wailaMapSettings.xml"] = saved
check("load finds the file", S.load() == true)
check("trail colour restored", math.abs(S.get("trail").color[1] - 0.25) < 1e-3 and math.abs(S.get("trail").color[3] - 0.75) < 1e-3)
check("trail opacity restored", math.abs(S.get("trail").alpha - 0.3) < 1e-6)
check("road hidden flag restored", S.get("road").visible == false)
files["/save/wailaMapSettings.xml"] = nil
check("no file: load reports false and everything is default", S.load() == false and S.isDefault("trail") and S.isDefault("road"))

-- tab: picked colour from the list page and from the custom page
Waila = { registerDebugTab = function() end }
Utils = { getFilename = function(f) return f end }
FS25WhatAmILookingAt = { MOD_DIRECTORY = "" }
local recolored = 0
g_currentMission.wailaTrailTracer = { recolorOverlays = function() recolored = recolored + 1 end }
dofile("scripts/WailaMapLayersTab.lua")
local Tab = WailaMapLayersTab
local items = Tab.getItems()
check("six layer rows, water first (bottom of the draw order), trees after forest", #items == 6 and items[1].layer == "water" and items[3].layer == "tree" and items[6].layer == "building")
Tab.onColorPicked(Tab, 1, { layer = "road", index = 3 }, nil)
local first = Tab.swatches()[1]
check("list swatch 1 becomes the road colour", math.abs(S.get("road").color[1] - first[1]) < 1e-6)
check("a pick re-colours the overlays", recolored == 1)
Tab.onColorPicked(Tab, nil, { layer = "forest", index = 1 }, { customColor = { 0.1, 0.2, 0.3 } })
check("custom RGB becomes the forest colour", math.abs(S.get("forest").color[2] - 0.2) < 1e-6)
local before = S.get("forest").color[2]
Tab.onColorPicked(Tab, nil, { layer = "forest", index = 1 }, nil)
check("backing out changes nothing", S.get("forest").color[2] == before and recolored == 2)
local primary, secondary = Tab.describeItem(items[4])
check("row text: layer name plus what was detected, state on the second line", primary:find("^Trails") ~= nil and secondary:find("opacity") ~= nil)
g_currentMission.wailaTrailTracer.roadSource = "collision raycast"
local roadText = Tab.describeItem(items[5])
check("road row shows the detected source", roadText:find("collision raycast") ~= nil)
-- mouse wheel on a row
S.setAlpha("trail", 0.5)
Tab.onScroll(items[4], 1)
check("wheel up = more opaque (50% -> 60%)", math.abs(S.get("trail").alpha - 0.6) < 1e-9)
Tab.onScroll(items[4], -1)
Tab.onScroll(items[4], -1)
check("wheel down twice = 40%", math.abs(S.get("trail").alpha - 0.4) < 1e-9)
for _ = 1, 20 do Tab.onScroll(items[4], 1) end
check("wheel up past the top stays at 100%", S.get("trail").alpha == 1)
local _, scrollText = Tab.describeItem(items[4])
check("the row says so: opacity ... (scroll)", scrollText:find("%(scroll%)") ~= nil)
-- opacity meter (ten segments, one per 10 percent) and colour chip
S.setAlpha("water", 0.7)
local fraction, dim = Tab.getItemMeter({ layer = "water" })
check("meter: 70 percent opacity is 0.7, not dimmed", fraction == 0.7 and dim == false)
S.setVisible("water", false)
fraction, dim = Tab.getItemMeter({ layer = "water" })
check("meter: a hidden layer is dimmed", dim == true)
S.setVisible("water", true)
S.setAlpha("water", S.MIN_ALPHA)
check("meter: the lowest opacity still lights one segment", math.floor(Tab.getItemMeter({ layer = "water" }) * 10 + 0.5) == 1)
local r, g, b, a = Tab.getItemColor({ layer = "forest" })
check("chip: the layer colour, opaque", r == S.get("forest").color[1] and b == S.get("forest").color[3] and a == 1)
-- the tab as the hub sees it: arrow selector hooks, instant buttons (no "Done" flash)
local registered
Waila = { registerDebugTab = function(descriptor) registered = descriptor end }
FS25WhatAmILookingAt = { MOD_DIRECTORY = "mod/" }
Utils = { getFilename = function(name) return name end }
Tab.register()
check("tab: opacity selector reads the layer's opacity", registered.getOpacity({ layer = "water" }) == S.get("water").alpha)
registered.setOpacity({ layer = "water" }, 0.4)
check("tab: opacity selector sets it", S.get("water").alpha == 0.4)
registered.setOpacity({ layer = "water" }, 0)
check("tab: ...never below the floor", S.get("water").alpha == S.MIN_ALPHA)
local labels, allInstant = {}, true
for _, button in ipairs(registered.buttons) do
    labels[#labels + 1] = button.label
    allInstant = allInstant and button.instant == true
end
check("tab: buttons are colour, show/hide, reset (opacity moved to the selector)", table.concat(labels, "|") == "Pick colour|Show / hide|Reset")
check("tab: all of them are instant, so no Done flash", allInstant)
finish("map_settings_test")
