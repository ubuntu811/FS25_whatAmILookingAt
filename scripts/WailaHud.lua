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
    self.maxStatsRows = 6
    self.maxFoliageStatsRows = 10
    return self
end

function WailaHud:addLine(lines, text, bold)
    table.insert(lines, {text = text, bold = bold == true})
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

function WailaHud:drawLines(lines)
    local x = self.right - self.width + self.paddingX
    local panelHeight = #lines * self.lineHeight + self.paddingY * 2
    local panelBottom = self.top - panelHeight + self.paddingY

    if drawFilledRect ~= nil then
        drawFilledRect(
            self.right - self.width,
            panelBottom,
            self.width,
            panelHeight,
            0.02, 0.02, 0.02, 0.92
        )
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)

    for index, entry in ipairs(lines) do
        setTextBold(entry.bold)
        renderText(x, self.top - index * self.lineHeight, self.textSize, entry.text)
    end

    setTextBold(false)
end

function WailaHud:draw(inspection, areaSize, areaStep)
    local lines = {}
    self:addLine(lines, "WHAT AM I LOOKING AT?", true)

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
        targetKind = string.format("foliage (%s)", foliagePoint[1].name)
    end

    self:addLine(lines, string.format("Target: %s", targetKind), true)
    self:addLine(lines, string.format("Hit position: %.2f / %.2f / %.2f", hit.x, hit.y, hit.z))
    self:addLine(lines, string.format("Node: %s  name=%s", tostring(hit.nodeId), WailaUtil.value(object and object.nodeName)))

    if object ~= nil and object.nodePosition ~= nil then
        self:addLine(lines, "Node position: " .. self:formatPosition(object.nodePosition))
    end

    self:addLine(lines, string.format("Physics: %s  sleeping=%s", WailaUtil.value(object and object.rigidBodyTypeName), WailaUtil.bool(object and object.isSleeping)))

    if object ~= nil and object.objectClass ~= nil then
        self:addLine(lines, string.format("Object: %s  farm=%s", object.objectClass, WailaUtil.value(object.ownerFarmId)))
    end

    if vehicle ~= nil then
        self:addLine(lines, string.format("Vehicle: %s", WailaUtil.value(vehicle.vehicleName)), true)
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
    end

    if object ~= nil and object.isSplitShape then
        self:addLine(lines, string.format("Split shape: type=%s split=%s volume=%s", WailaUtil.value(object.splitType), WailaUtil.bool(object.isSplit), WailaUtil.value(object.volume)))
    end

    if vehicle == nil then
        local terrain = inspection.terrain
        if terrain ~= nil then
            self:addLine(lines, string.format("Ground: %s [%s]  field=%s", terrain.materialName, tostring(terrain.materialId), WailaUtil.bool(terrain.isOnField)), true)
            self:addLine(lines, string.format("Ground type=%s densityBits=%s depth=%s", WailaUtil.value(terrain.groundType), WailaUtil.value(terrain.densityBits), WailaUtil.value(terrain.depth)))
        end

        local foliagePoint = inspection.foliagePoint or {}
        local names = {}
        for _, entry in ipairs(foliagePoint) do
            table.insert(names, string.format("%s(%s)", entry.name, tostring(entry.density)))
        end
        self:addLine(lines, "Foliage here: " .. (#names > 0 and table.concat(names, ", ") or "<empty>"))

        self:addLine(lines, string.format("AREA %.0fx%.0fm / step %.2fm", areaSize, areaSize, areaStep), true)

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

    self:addLine(lines, "Shift+J: dump current target")
    self:drawLines(lines)
end
