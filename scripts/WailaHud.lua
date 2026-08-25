WailaHud = {}
local WailaHud_mt = Class(WailaHud)

function WailaHud.new()
    local self = setmetatable({}, WailaHud_mt)
    self.right = 0.985
    self.top = 0.88
    self.width = 0.36
    self.paddingX = 0.010
    self.paddingY = 0.010
    self.lineHeight = 0.018
    self.textSize = 0.014
    -- Extra vertical space inserted before a section's first line (see
    -- addLine's gapBefore param) -- was one flat, ungapped block before,
    -- with no visual separation between e.g. WEATHER, Target/Vehicle, and
    -- the AREA stats block.
    self.sectionGap = 0.008
    self.maxStatsRows = 6
    self.maxFoliageStatsRows = 10

    -- Mini summary panel - always visible, sits in the leftmost slot of
    -- the same top-left row ImmersiveWeathering's panels use, whether or
    -- not the full inspector is toggled on. Matches IW's own panel row
    -- height (0.098) for visual alignment; kept narrow (0.085) since the
    -- available band between the quickbar and the date/money bar is
    -- shared with two IW panels and doesn't have room to spare.
    self.miniLeft = 0.20
    self.miniTop = 0.98
    self.miniWidth = 0.085
    self.miniHeight = 0.098
    self.miniTitleSize = 0.015
    self.miniValueSize = 0.015
    self.miniKeybindSize = 0.0135

    return self
end

function WailaHud:addLine(lines, text, bold, gapBefore)
    table.insert(lines, {text = text, bold = bold == true, gapBefore = gapBefore == true})
end

-- Reads the REAL current binding for an action instead of a hardcoded
-- guess - a player's manual rebind via the settings screen silently
-- overrides modDesc.xml's shipped default from then on, confirmed the
-- hard way while chasing ImmersiveWeathering's own keybind display. Same
-- native the base game's own InputGlyphElement uses for on-screen key
-- prompts (g_inputDisplayManager), not in scriptBinding.xml, so wrapped
-- in pcall with a fallback.
function WailaHud:getActionKeyLabel(actionName, fallback)
    if g_inputDisplayManager == nil then
        return fallback
    end

    local success, helpElement = pcall(
        g_inputDisplayManager.getControllerSymbolOverlays,
        g_inputDisplayManager, actionName, nil, "", true
    )

    if not success or helpElement == nil or helpElement.keys == nil or #helpElement.keys == 0 then
        return fallback
    end

    return "[" .. table.concat(helpElement.keys, "+") .. "]"
end

-- Long vehicle names ("CLAAS XERION 12.650 SE") were overflowing straight
-- past the mini panel's right edge into IW's panel next to it - the mini
-- panel is only 0.085 wide by design (see miniWidth comment above), and
-- renderText doesn't clip or wrap on its own. getTextWidth is the real
-- base-game global (used internally for text alignment) that reports
-- normalized width for a given size/string, so we can trim character by
-- character until it actually fits instead of guessing a fixed cutoff
-- length that would be wrong at every other font size or string.
function WailaHud:truncateToWidth(text, size, maxWidth)
    if text == nil or getTextWidth == nil or getTextWidth(size, text) <= maxWidth then
        return text
    end

    local ellipsis = "..."
    for length = #text - 1, 0, -1 do
        local candidate = string.sub(text, 1, length) .. ellipsis
        if getTextWidth(size, candidate) <= maxWidth then
            return candidate
        end
    end

    return ellipsis
end

function WailaHud:formatPosition(position)
    if position == nil then
        return "-"
    end

    if position.x == nil or position.y == nil or position.z == nil then
        return "-"
    end

    return string.format("%.2f / %.2f / %.2f", position.x, position.y, position.z)
end

local WAILA_HUD_IW_GAP = 0.01

-- Short label for the always-on mini panel - vehicle name if looking at
-- one, otherwise whatever foliage is actually at the point (a raycast
-- only ever hits the terrain collision mesh, so "terrain" alone would be
-- true but useless while standing in grass), otherwise the terrain
-- material, otherwise nothing found.
function WailaHud:getMiniSummary(inspection)
    if inspection == nil or inspection.hit == nil then
        return "No target"
    end

    if inspection.vehicle ~= nil then
        return WailaUtil.value(inspection.vehicle.vehicleName)
    end

    local foliagePoint = inspection.foliagePoint or {}
    if #foliagePoint > 0 then
        return foliagePoint[1].name
    end

    if inspection.terrain ~= nil then
        return inspection.terrain.materialName
    end

    return "Unknown"
end

function WailaHud:drawMini(inspection, perf)
    if drawFilledRect == nil then
        return
    end

    local left = self.miniLeft
    local top = self.miniTop
    local panelBottom = top - self.miniHeight

    -- Published via g_currentMission, not a bare WailaHud global - proved
    -- the hard way that separately-loaded mods don't actually see a new
    -- global table one of them declares (confirmed nil from IW's side via
    -- direct logging), even though both can freely read/write fields on
    -- g_currentMission, which genuinely is shared engine-side state that
    -- exists before any mod runs. Full detailed panel below docks off
    -- these too, not off IW - mini panel is the real anchor for this row.
    if g_currentMission ~= nil then
        g_currentMission.wailaHudMiniLeft = left
        g_currentMission.wailaHudMiniRight = left + self.miniWidth
        g_currentMission.wailaHudMiniBottom = panelBottom
    end

    drawFilledRect(left, panelBottom, self.miniWidth, self.miniHeight, 0, 0, 0, 0.65)

    setTextAlignment(RenderText.ALIGN_LEFT)
    local textLeft = left + 0.008

    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(textLeft, top - 0.017, self.miniTitleSize, "WAILA")
    setTextBold(false)

    setTextColor(0.65, 0.65, 0.65, 1)
    renderText(textLeft, top - 0.029, self.miniKeybindSize, self:getActionKeyLabel("WAILA_TOGGLE_HUD", "[Shift+M]"))

    -- Header divider, matching IW's panels - everything was crammed into
    -- one ungapped block before, no visual separation between the header
    -- (title/keybind) and the body content below it.
    local headerHeight = 0.036
    drawFilledRect(left, top - headerHeight, self.miniWidth, 0.001, 0, 0, 0, 0.7)
    local bodyTop = top - headerHeight

    -- Scan time is the point raycast's own cost (updatePointInspection,
    -- which now always runs regardless of whether the full inspector is
    -- toggled on) - the actual number to watch if wondering whether this
    -- background scanning tanks performance, not overall FPS, which every
    -- other mod and the base game itself also feed into.
    if perf ~= nil then
        setTextColor(0.55, 0.75, 0.55, 1)
        renderText(
            textLeft, bodyTop - 0.016, self.miniKeybindSize,
            string.format("%.0ffps  %.2fms", perf.fps or 0, perf.scanMs or 0)
        )
    end

    setTextColor(1, 1, 1, 1)
    local summary = self:truncateToWidth(
        self:getMiniSummary(inspection),
        self.miniValueSize,
        self.miniWidth - 0.016
    )
    -- panelBottom + 0.018, not + 0.014 - matches ImmersiveWeathering's
    -- drawHudPanel content row (its swatch+value text sits at
    -- swatchBottom + 0.004 = panelBottom + 0.018) exactly, so this summary
    -- line and IW's Texture/Chance/Samples/Run Now/Weather Target content
    -- all land on the same Y instead of a few pixels off from each other.
    renderText(textLeft, panelBottom + 0.018, self.miniValueSize, summary)

    setTextAlignment(RenderText.ALIGN_LEFT)
end

function WailaHud:drawLines(lines)
    -- Dock directly under our own mini panel, which is always drawn
    -- first and is the real anchor for this whole row now - falls back
    -- to the fixed top-right corner only if the mini panel somehow never
    -- ran (shouldn't happen in practice, both are the same mod).
    local boxLeft = self.right - self.width
    local boxWidth = self.width
    local top = self.top

    if g_currentMission ~= nil and g_currentMission.wailaHudMiniBottom ~= nil then
        boxLeft = g_currentMission.wailaHudMiniLeft
        boxWidth = self.width
        top = g_currentMission.wailaHudMiniBottom - WAILA_HUD_IW_GAP
    end

    local x = boxLeft + self.paddingX

    -- Cumulative, not #lines * lineHeight -- a gapBefore line costs extra
    -- height that a flat multiply can't account for.
    local contentHeight = 0
    for _, entry in ipairs(lines) do
        contentHeight = contentHeight + self.lineHeight + (entry.gapBefore and self.sectionGap or 0)
    end
    local panelHeight = contentHeight + self.paddingY * 2
    local panelBottom = top - panelHeight + self.paddingY

    if drawFilledRect ~= nil then
        drawFilledRect(
            boxLeft,
            panelBottom,
            boxWidth,
            panelHeight,
            0, 0, 0, 0.65
        )
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)

    local y = top
    for _, entry in ipairs(lines) do
        y = y - self.lineHeight - (entry.gapBefore and self.sectionGap or 0)
        setTextBold(entry.bold)
        renderText(x, y, self.textSize, entry.text)
    end

    setTextBold(false)
end

function WailaHud:draw(inspection, areaSize, areaStep)
    local lines = {}
    self:addLine(lines, "WHAT AM I LOOKING AT?", true)

    -- Global state, not tied to whatever's under the crosshair - the base
    -- game's own weather icon (top-right, next to the date) already tells
    -- you at a glance whether it's raining; the actual point of exposing
    -- this here is the raw fields underneath that icon, which nothing else
    -- shows numerically. See docs/engine-api/Weather.md - isRaining is a
    -- derived three-part formula, not something the engine hands you
    -- directly, so it's worth showing the inputs, not just the verdict.
    if inspection ~= nil and inspection.weather ~= nil then
        local weather = inspection.weather
        self:addLine(lines, "Weather", true, true)
        self:addLine(lines, string.format(
            "rainScale=%.2f  timeSinceLastRain=%.1fs  temp=%.1f\194\176C",
            weather.rainScale, weather.timeSinceLastRain, weather.temperature
        ))
        self:addLine(lines, string.format("isRaining=%s (rainScale>0.1 and timeSinceLastRain<30 and temp>0)", WailaUtil.bool(weather.isRaining)))
    end

    -- Global state, same reasoning as Weather above -- only shown while a
    -- sweep is actually running (isSweeping), not a permanent fixture.
    -- Reads Waila.indices.field directly (same-mod access, no
    -- g_currentMission indirection needed -- that's only required for
    -- OTHER mods reading this) rather than threading sweep state through
    -- draw()'s own parameters.
    do
        local fieldIndex = Waila.indices.field
        if fieldIndex ~= nil and fieldIndex.isSweeping and fieldIndex.scanner ~= nil then
            self:addLine(lines, string.format("Field sweep: row %d/%d", (fieldIndex.scanner.lastLoggedRow or 0) + 1, fieldIndex.scanner.rows), true, true)
        end
    end

    if inspection == nil or inspection.hit == nil then
        self:addLine(lines, "No target")
        self:drawLines(lines)
        return
    end

    local hit = inspection.hit
    local object = inspection.object
    local vehicle = inspection.vehicle

    -- A raycast can only ever hit the terrain collision mesh - foliage has
    -- no collision at all - so "terrain" is technically correct even when
    -- you're standing in dense grass. Prefer announcing the foliage that's
    -- actually there over the bare fact that terrain is under everything.
    local targetKind = object and object.kind or "unknown"
    local foliagePoint = inspection.foliagePoint or {}

    if targetKind == "terrain" and #foliagePoint > 0 then
        -- .density (the growth-state/level number) was already sitting
        -- right there on the same table the "Foliage here:" line below
        -- already uses it from - this line just never read it, showing
        -- "decoFoliage" with no level while the summary below correctly
        -- shows "decoFoliage L9" for the exact same point.
        targetKind = string.format("foliage (%s(%s)[%s])", foliagePoint[1].name, tostring(foliagePoint[1].density), foliagePoint[1].kind or "unknown")
    end

    self:addLine(lines, string.format("Target: %s", targetKind), true, true)
    self:addLine(lines, string.format("Hit position: %.2f / %.2f / %.2f", hit.x, hit.y, hit.z))
    self:addLine(lines, string.format("Node: %s  name=%s", tostring(hit.nodeId), WailaUtil.value(object and object.nodeName)))

    -- Any mod-declared area covering this exact hit point (see
    -- Waila.registerArea/WailaDeclaredArea) -- "field" excluded, that
    -- already gets its own dedicated section below. Waila.getTypes loops
    -- every registered index generically, so a third-party mod's area
    -- shows up here with zero WailaHud changes on its end.
    do
        local declaredTypes = {}
        for _, typeName in ipairs(Waila.getTypes(hit.x, hit.z)) do
            if typeName ~= "field" then
                table.insert(declaredTypes, typeName)
            end
        end
        if #declaredTypes > 0 then
            self:addLine(lines, "Declared areas: " .. table.concat(declaredTypes, ", "), true, true)
        end
    end

    if object ~= nil and object.nodePosition ~= nil then
        self:addLine(lines, "Node position: " .. self:formatPosition(object.nodePosition))
    end

    self:addLine(lines, string.format("Physics: %s  sleeping=%s", WailaUtil.value(object and object.rigidBodyTypeName), WailaUtil.bool(object and object.isSleeping)))

    if object ~= nil and object.objectClass ~= nil then
        self:addLine(lines, string.format("Object: %s  farm=%s", object.objectClass, WailaUtil.value(object.ownerFarmId)))
    end

    if vehicle ~= nil then
        self:addLine(lines, string.format("Vehicle: %s", WailaUtil.value(vehicle.vehicleName)), true, true)
        self:addLine(lines, string.format("Root: %s  name=%s  class=%s", WailaUtil.value(vehicle.rootNodeId), WailaUtil.value(vehicle.rootNodeName), WailaUtil.value(vehicle.vehicleClass)))

        if vehicle.componentIndex ~= nil then
            self:addLine(lines, string.format("Component: %d/%d  node=%s  name=%s",
                vehicle.componentIndex, vehicle.componentCount,
                WailaUtil.value(vehicle.componentNodeId), WailaUtil.value(vehicle.componentNodeName)))
        else
            self:addLine(lines, string.format("Components: %d", vehicle.componentCount or 0))
        end

        if vehicle.wheelIndex ~= nil then
            self:addLine(lines, string.format("Wheel: %d/%d  %s=%s  name=%s",
                vehicle.wheelIndex, vehicle.wheelCount,
                WailaUtil.value(vehicle.wheelNodeField), WailaUtil.value(vehicle.wheelNodeId),
                WailaUtil.value(vehicle.wheelNodeName)), true)

            -- mass = this wheel's own physics mass (WheelPhysics.lua).
            -- tireLoad = real ground contact force + gravity-weighted mass
            -- combined (WheelPhysics:getTireLoad, confirmed via WheelAxle's
            -- real axle-load-balancing use of it) - NOT what drives the
            -- built-in tire-track visual rut depth, that's a separate
            -- static terrain attribute. Still a real, useful reading.
            if vehicle.wheelMass ~= nil or vehicle.wheelTireLoad ~= nil then
                self:addLine(lines, string.format("  mass=%s  tireLoad=%s",
                    WailaUtil.value(vehicle.wheelMass), WailaUtil.value(vehicle.wheelTireLoad)))
            end
        else
            self:addLine(lines, string.format("Wheels: %d", vehicle.wheelCount or 0))
        end

        if vehicle.attacherJointIndex ~= nil then
            self:addLine(lines, string.format("Attacher joint: %d/%d  node=%s  name=%s  type=%s",
                vehicle.attacherJointIndex, vehicle.attacherJointCount,
                WailaUtil.value(vehicle.attacherJointNodeId), WailaUtil.value(vehicle.attacherJointNodeName),
                WailaUtil.value(vehicle.attacherJointTypeName or vehicle.attacherJointType)), true)
        else
            self:addLine(lines, string.format("Attacher joints: %d", vehicle.attacherJointCount or 0))
        end

        -- "-" means the spec itself isn't present (e.g. no engine to turn
        -- on, no lowering mechanism at all) - distinct from a real
        -- false/no, which WailaUtil.bool also renders but means something
        -- different. Added specifically to stop guessing what
        -- getIsTurnedOn()/getIsLowered() actually report on a given
        -- vehicle instead of round-tripping through a live test each time.
        self:addLine(lines, string.format("Motorized: %s  turnedOn=%s   Attachable: %s  lowered=%s",
            WailaUtil.bool(vehicle.hasMotor), WailaUtil.bool(vehicle.turnedOn),
            WailaUtil.bool(vehicle.hasAttachable), WailaUtil.bool(vehicle.lowered)))

        self:addLine(lines, string.format("Foldable: %s  unfolded=%s",
            WailaUtil.bool(vehicle.hasFoldable), WailaUtil.bool(vehicle.unfolded)))

        if vehicle.hasSowingMachine then
            -- isWorking is the one field that actually correlated with
            -- real sowing activity across everything else tried tonight -
            -- on the HUD live now instead of needing a Shift+J dump to
            -- the log every time.
            self:addLine(lines, string.format("SowingMachine: yes  isWorking=%s  workAreaTypes=%s",
                WailaUtil.bool(vehicle.isWorking),
                vehicle.workAreaTypes ~= nil and table.concat(vehicle.workAreaTypes, ",") or "-"))
        end

        if vehicle.hasPushHandTool then
            self:addLine(lines, "PushHandTool: yes")
        end
    end

    if object ~= nil and object.isSplitShape then
        self:addLine(lines, string.format("Split shape: type=%s split=%s volume=%s", WailaUtil.value(object.splitType), WailaUtil.bool(object.isSplit), WailaUtil.value(object.volume)))
    end

    if vehicle == nil then
        local terrain = inspection.terrain
        if terrain ~= nil then
            self:addLine(lines, string.format("Ground: %s [%s]  field=%s", terrain.materialName, tostring(terrain.materialId), WailaUtil.bool(terrain.isOnField)), true, true)
            self:addLine(lines, string.format("Ground type=%s densityBits=%s depth=%s", WailaUtil.value(terrain.groundType), WailaUtil.value(terrain.densityBits), WailaUtil.value(terrain.depth)))
        end

        local foliagePoint = inspection.foliagePoint or {}
        local names = {}
        for _, entry in ipairs(foliagePoint) do
            table.insert(names, string.format("%s(%s)[%s]", entry.name, tostring(entry.density), entry.kind or "unknown"))
        end
        self:addLine(lines, "Foliage here: " .. (#names > 0 and table.concat(names, ", ") or "<empty>"))

        -- Raw field state, not derived "needs X" verdicts - same philosophy
        -- as the Ground/Foliage lines above, real confirmed numbers, human
        -- reads them. field is nil off any registered field (most terrain).
        local field = inspection.field
        if field ~= nil then
            -- fieldId nil means real, tilled field ground with no registered
            -- Field object behind it (tillage creates/expands field ground
            -- independent of the map's fixed field polygons) -- say so
            -- rather than showing area=0.00ha, which would read as "zero
            -- area" instead of "not tracked as a Field at all".
            if field.fieldId ~= nil then
                self:addLine(lines, string.format("Field %s  area=%.2fha  owner=%s", WailaUtil.value(field.fieldId), field.areaHa or 0, WailaUtil.value(field.ownerFarmId)), true, true)
            else
                self:addLine(lines, "Field (unregistered -- tilled ground, no map-defined Field object)", true, true)
            end
            -- Shown separately from fieldId -- a farmland's own land
            -- parcel is typically much larger than any Field registered
            -- within it (can include forest/wilderness), so this can be
            -- non-nil even standing well outside any actual crop area.
            self:addLine(lines, string.format("Farmland: %s", WailaUtil.value(field.farmlandId)))

            -- Which WailaFieldIndex blob/wailaFieldId this exact position
            -- falls in, distinct from the live field data printed above --
            -- a tillage-extended field's blob can have its own sample
            -- point land on unregistered ground (fieldId nil above) while
            -- still legitimately being the SAME blob that also covers real
            -- registered Field ground elsewhere. Comparing this number
            -- while walking across what looks like one field is how you'd
            -- notice it actually split into several registry entries.
            if Waila.indices.field ~= nil then
                local entry = Waila.indices.field:getEntry(hit.x, hit.z)
                if entry ~= nil then
                    self:addLine(lines, string.format("WAILA field id: %d", entry.wailaFieldId))
                else
                    self:addLine(lines, "WAILA field id: none (nothing registered nearby)")
                end
            end

            self:addLine(lines, string.format("Crop: %s  growth=%s(%s)", WailaUtil.value(field.fruitTypeName), WailaUtil.value(field.growthStateName), WailaUtil.value(field.growthState)))
            -- useRolling appended here as a live, one-glance check --
            -- no Lua assignment anywhere in the decompiled scripts (native
            -- platform-capability flag, not a game setting), so this is
            -- the only way to actually see its real value instead of
            -- guessing why R never shows up on any field's job letters.
            self:addLine(lines, string.format("Ground: %s  plow=%s/%s  roller=%s  stubble=%s  useRolling=%s", WailaUtil.value(field.groundTypeName), WailaUtil.value(field.plowLevel), WailaUtil.value(field.maxPlowLevel), WailaUtil.value(field.rollerLevel), WailaUtil.value(field.stubbleShredLevel), WailaUtil.bool(Platform.gameplay.useRolling)))
            self:addLine(lines, string.format("Weed: state=%s weededState=%s  stone=%s  grassOnly=%s", WailaUtil.value(field.weedState), WailaUtil.value(field.weededState), WailaUtil.value(field.stoneLevel), WailaUtil.bool(field.grassMissionOnly)))
            self:addLine(lines, string.format("Spray: %s  level=%s/%s  lime=%s/%s", WailaUtil.value(field.sprayTypeName), WailaUtil.value(field.sprayLevel), WailaUtil.value(field.maxSprayLevel), WailaUtil.value(field.limeLevel), WailaUtil.value(field.maxLimeLevel)))
        end

        self:addLine(lines, string.format("Area %.0fx%.0fm / step %.2fm", areaSize, areaSize, areaStep), true, true)

        if inspection.terrainArea ~= nil then
            self:addLine(lines, string.format("Field coverage: %.1f%%", inspection.terrainArea.fieldPercent))
            for index, row in ipairs(inspection.terrainArea.materials) do
                if index > self.maxStatsRows then break end
                self:addLine(lines, string.format("  Ground %-18s %5.1f%% (%d)", row.name, row.percent, row.count))
            end
        end

        if inspection.foliageArea ~= nil then
            for index, row in ipairs(inspection.foliageArea.foliage) do
                if index > self.maxFoliageStatsRows then break end
                self:addLine(lines, string.format("  Foliage %-17s %5.1f%% (%d)", row.name, row.percent, row.count))
            end
        end
    end

    self:addLine(lines, self:getActionKeyLabel("WAILA_DUMP_TARGET", "[Shift+J]") .. ": dump current target", false, true)
    self:addLine(lines, self:getActionKeyLabel("WAILA_DEBUG_MENU", "[Shift+L]") .. ": debug tools menu")
    self:drawLines(lines)
end
