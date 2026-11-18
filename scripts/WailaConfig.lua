--[[
    WailaConfig.lua

    WAILA's own user-level config (the same for every savegame), kept in
    <profile>/modSettings/FS25_whatAmILookingAt/config.xml, the same place and
    pattern IWConfig uses. Today it holds one switch: debug logging. Chatty
    diagnostics (a line per field found, per self-test event, ...) go through
    WailaConfig.debug and stay silent unless the switch is on; the debug hub's
    General tab flips it. Other mods read it through
    g_currentMission.waila.isDebugLogEnabled() (see Waila.lua) so one switch
    quiets every related mod. Off by default.
]]

WailaConfig = {}

WailaConfig.FILENAME = "config.xml"

local debugLog = false
local loaded = false

local function baseDir()
    if getUserProfileAppPath == nil then
        return nil
    end
    return getUserProfileAppPath() .. "modSettings/FS25_whatAmILookingAt/"
end

local function load()
    loaded = true
    local dir = baseDir()
    if dir == nil then
        return
    end
    local xmlFile = XMLFile.loadIfExists("wailaConfig", dir .. WailaConfig.FILENAME)
    if xmlFile == nil then
        return
    end
    local value = xmlFile:getBool("wailaConfig#debugLog")
    if value ~= nil then
        debugLog = value
    end
    xmlFile:delete()
end

local function save()
    local dir = baseDir()
    if dir == nil then
        return false
    end
    createFolder(dir)
    local xmlFile = XMLFile.create("wailaConfig", dir .. WailaConfig.FILENAME, "wailaConfig")
    if xmlFile == nil then
        return false
    end
    xmlFile:setBool("wailaConfig#debugLog", debugLog)
    xmlFile:save()
    xmlFile:delete()
    return true
end

function WailaConfig.isDebugLog()
    if not loaded then
        load()
    end
    return debugLog
end

function WailaConfig.setDebugLog(enabled)
    if not loaded then
        load()
    end
    debugLog = enabled == true
    save()
    Logging.info("[WhatAmILookingAt] debug logging %s (all WAILA-aware mods follow this switch)", debugLog and "ON" or "OFF")
end

function WailaConfig.toggleDebugLog()
    WailaConfig.setDebugLog(not WailaConfig.isDebugLog())
end

-- Logs like Logging.info, but only while debug logging is on. The tag is
-- added here so call sites keep the bare message.
function WailaConfig.debug(formatString, ...)
    if WailaConfig.isDebugLog() then
        Logging.info("[WhatAmILookingAt] " .. formatString, ...)
    end
end
