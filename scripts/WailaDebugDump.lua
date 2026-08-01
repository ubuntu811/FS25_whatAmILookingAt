WailaDebugDump = {}

local function log(formatString, ...)
    Logging.info("[WhatAmILookingAt] " .. formatString, ...)
end

local function dumpTable(value, prefix, depth, seen)
    if type(value) ~= "table" or depth <= 0 or seen[value] then
        return
    end

    seen[value] = true
    for key, nested in pairs(value) do
        log("%s%s = %s (%s)", prefix, tostring(key), tostring(nested), type(nested))
        if type(nested) == "table" then
            dumpTable(nested, prefix .. "  ", depth - 1, seen)
        end
    end
end

function WailaDebugDump.dump(inspection)
    if inspection == nil or inspection.hit == nil then
        log("No current target")
        return
    end

    log("------------------------------------------------------------")
    log("TARGET node=%s pos=(%.3f, %.3f, %.3f) distance=%.3f",
        tostring(inspection.hit.nodeId), inspection.hit.x, inspection.hit.y, inspection.hit.z, inspection.hit.distance or -1)

    if inspection.object ~= nil then
        for key, value in pairs(inspection.object) do
            log("object.%s = %s (%s)", tostring(key), tostring(value), type(value))
        end
        if inspection.object.object ~= nil then
            dumpTable(inspection.object.object, "object.object.", 2, {})
        end
    end

    if inspection.vehicle ~= nil then
        for key, value in pairs(inspection.vehicle) do
            log("vehicle.%s = %s (%s)", tostring(key), tostring(value), type(value))
        end

        -- Checking the tractor's engine turned out to be nearly useless
        -- as an "is this seeder actually working" gate - the engine's on
        -- the whole time you're driving, seeding or not. The real
        -- per-implement activation state (referenced in real seeder XML
        -- as <needsActivation>) should live on spec_sowingMachine itself,
        -- not the generic vehicle-level getIsTurnedOn we already found
        -- unreliable. Dumping its real top-level fields directly instead
        -- of guessing another name blind.
        local rawVehicle = inspection.vehicle.vehicle
        if rawVehicle ~= nil and rawVehicle.spec_sowingMachine ~= nil then
            log("-- spec_sowingMachine --")
            dumpTable(rawVehicle.spec_sowingMachine, "spec_sowingMachine.", 1, {})
        end

        -- Aiming the crosshair precisely at a towed implement while
        -- actually driving the tractor is fiddly - walk the driven
        -- vehicle's own attachments instead, so one dump from the
        -- driver's seat covers the seeder too, not just whatever's
        -- directly under the crosshair (the tractor's own cab/hood in
        -- practice). getAttachedImplements() is the real, well-established
        -- GIANTS API for this - each entry has an .object field pointing
        -- at the attached vehicle.
        if rawVehicle ~= nil and rawVehicle.getAttachedImplements ~= nil then
            local implements = WailaUtil.safeCall(nil, rawVehicle.getAttachedImplements, rawVehicle)
            if implements ~= nil then
                for i, entry in ipairs(implements) do
                    local implementVehicle = entry.object
                    if implementVehicle ~= nil then
                        log("-- attached implement [%d]: configFileName=%s --", i, tostring(implementVehicle.configFileName))
                        log("implement[%d].spec_sowingMachine present = %s", i, tostring(implementVehicle.spec_sowingMachine ~= nil))
                        if implementVehicle.spec_sowingMachine ~= nil then
                            dumpTable(implementVehicle.spec_sowingMachine, string.format("implement[%d].spec_sowingMachine.", i), 1, {})
                        end
                    end
                end
            end
        end
    end

    if inspection.terrain ~= nil then
        for key, value in pairs(inspection.terrain) do
            log("terrain.%s = %s", tostring(key), tostring(value))
        end
    end

    log("------------------------------------------------------------")
end

function WailaDebugDump.dumpFoliageCatalog(layers, writableLayers, systemFields)
    if layers == nil then
        log("Foliage catalog unavailable (map I3D not loaded yet)")
        return
    end

    log("------------------------------------------------------------")
    log("FOLIAGE CATALOG (%d multilayers)", #layers)

    for _, layer in ipairs(layers) do
        log("Layer %d  densityMapId=%s plane=%s typeChannels=%s",
            layer.layerIndex, tostring(layer.densityMapId), tostring(layer.terrainDataPlaneId), tostring(layer.numTypeIndexChannels))

        for _, foliageType in ipairs(layer.types) do
            log("  [%d] %-20s (%s)", foliageType.typeIndex, foliageType.name, foliageType.kind)
        end
    end

    log("------------------------------------------------------------")
    log("WRITABLE DECO LAYERS (what applyDecoFoliage actually accepts - independent of the map I3D types above)")

    if writableLayers == nil then
        log("  unavailable (foliageSystem not loaded yet)")
    else
        log("  decoFoliages:")
        for _, name in ipairs(writableLayers.decoFoliages) do
            log("    %s", name)
        end
        log("  paintableFoliages:")
        for _, name in ipairs(writableLayers.paintableFoliages) do
            log("    %s", name)
        end
    end

    log("------------------------------------------------------------")
    log("RAW foliageSystem FIELDS (grassShort passes getIsDecoLayerDefined but isn't in either list above - looking for where)")

    if systemFields == nil then
        log("  unavailable (foliageSystem not loaded yet)")
    else
        for _, field in ipairs(systemFields) do
            if field.length ~= nil then
                log("  %-24s %-10s length=%d", field.name, field.valueType, field.length)
            else
                log("  %-24s %s", field.name, field.valueType)
            end
        end
    end

    log("------------------------------------------------------------")
end
