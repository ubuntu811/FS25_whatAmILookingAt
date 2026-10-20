dofile("tests/stubs.lua")

local files, folders = {}, {}
local function api(store)
    local f = {}
    function f:setBool(k, v) store[k] = v end
    function f:getBool(k) return store[k] end
    function f:save() end
    function f:delete() end
    return f
end
XMLFile = {
    create = function(_, path) files[path] = {}; return api(files[path]) end,
    loadIfExists = function(_, path) if files[path] then return api(files[path]) end end,
}
createFolder = function(path) folders[path] = true end
getUserProfileAppPath = function() return "/profile/" end

local lines = {}
Logging = { info = function(fmt, ...) table.insert(lines, string.format(fmt, ...)) end }

dofile("scripts/WailaConfig.lua")

check("debug logging is off by default", WailaConfig.isDebugLog() == false)
WailaConfig.debug("chatty %d", 1)
check("debug lines are silent while off", #lines == 0)

WailaConfig.setDebugLog(true)
check("switch on", WailaConfig.isDebugLog() == true)
check("config folder created under modSettings", folders["/profile/modSettings/FS25_whatAmILookingAt/"] == true)
check("config file written", files["/profile/modSettings/FS25_whatAmILookingAt/config.xml"] ~= nil)
lines = {}
WailaConfig.debug("chatty %d", 2)
check("debug lines appear with the tag while on", #lines == 1 and lines[1] == "[WhatAmILookingAt] chatty 2")

WailaConfig.toggleDebugLog()
check("toggle switches it off again", WailaConfig.isDebugLog() == false)

-- a fresh start reads the saved value back
WailaConfig.setDebugLog(true)
dofile("scripts/WailaConfig.lua")
check("saved value survives a restart (fresh load)", WailaConfig.isDebugLog() == true)
finish("config_test")
