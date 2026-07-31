# Vehicle-scoped action events

**Status:** confirmed via source (TerraFarm's real, working `Machine.lua` /
`VehicleExtension.lua`) AND confirmed via our own implementation
(ImmersiveWeathering's tyre-control keys)

The correct way to bind a key that should only work while driving - not the
`PlayerInputComponent.registerGlobalPlayerActionEvents` global player-input
hook used elsewhere in this doc set for on-foot debug keys, which is a
different, unrelated system that happens to also technically fire while in
a vehicle but behaves inconsistently in third-party keybind-overlay UIs.

## The real mechanism

`onRegisterActionEvents` is a **universal base-`Vehicle`-class event** -
confirmed in base-game `Vehicle.lua`:

```lua
SpecializationUtil.registerEvent(vehicleType, "onRegisterActionEvents")   -- registered on every vehicle type
SpecializationUtil.raiseEvent(self, "onRegisterActionEvents", isActiveForInput, isActiveForInputIgnoreSelection)  -- fired on every control-state change
```

It fires fresh every time a vehicle's control state changes (entering/
exiting, switching between attached implements), passing `isActiveForInput`
- true only for the vehicle currently being driven. `self:addActionEvent`
and `self:clearActionEventsTable` are likewise base `Vehicle` methods
(`addActionEvent` confirmed via `SpecializationUtil.registerFunction` in
`Vehicle.lua`; `clearActionEventsTable` not found in any Lua source we have,
so likely a native/engine method, but confirmed callable via TerraFarm's
real working usage) - available on every vehicle instance, no
specialization required.

## The pattern (from TerraFarm's `Machine.lua`)

```lua
function Machine:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    local spec = self.spec_machine
    self:clearActionEventsTable(spec.actionEvents)   -- always wipe first

    if not isActiveForInput then
        return   -- not the vehicle currently being driven - no events, full stop
    end

    local action = InputAction[Machine.ACTION_TOGGLE_ACTIVE]
    local _, eventId = self:addActionEvent(spec.actionEvents, action, self, Machine.actionEventToggleActive, false, true, false, true)
    g_inputBinding:setActionEventText(eventId, Machine.L10N_ACTION_ACTIVATE)
    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
end
```

Note `self` inside this handler is the **vehicle**, not the mod/spec table -
`Machine:onRegisterActionEvents` is dispatch-called as
`Machine.onRegisterActionEvents(vehicleInstance, ...)`, standard
`SpecializationUtil` event convention (unbound function on the listener
table, invoked with the vehicle as the explicit first argument, not via `:`
sugar on the listener).

## Splicing in without a real specialization

TerraFarm attaches the whole `Machine` specialization to a vehicle instance
retroactively, but you don't need that just to get `onRegisterActionEvents`
- it's already a valid event slot on every vehicle. Just insert a listener
table into it directly:

```lua
Vehicle.load = Utils.appendedFunction(
    Vehicle.load,
    function(vehicle)
        if vehicle.eventListeners ~= nil and vehicle.eventListeners.onRegisterActionEvents ~= nil then
            table.insert(vehicle.eventListeners.onRegisterActionEvents, YourListenerTable)
        end
    end
)
```

`YourListenerTable` just needs an `onRegisterActionEvents(self, isActiveForInput, ...)`
function (`self` = the vehicle at call time, per the dispatch convention
above). TerraFarm gates this behind `MachineUtils.getVehicleConfiguration(vehicle)`
- a bundled per-vehicle-type config system (work-area coordinates, dig
shapes, far more than most mods need). Skip that entirely and splice
unconditionally if you want it on every vehicle, no per-type config needed.

## Target vs. self - don't let the vehicle leak into your own state

`addActionEvent`'s target argument (who the callback fires *on*) is
independent of which vehicle instance's `eventListeners`/`actionEvents`
you're using to register it. If your actual handler logic lives on a
mod-level singleton (not per-vehicle state), pass that singleton as the
target explicitly instead of `self` (the vehicle):

```lua
self:addActionEvent(self.myModActionEvents, InputAction.MY_ACTION, MyMod, MyMod.onMyActionPressed, false, true, false, true)
```

`MyMod.onMyActionPressed`'s own `self` will correctly be `MyMod`, not the
vehicle, even though the vehicle owns the `actionEvents` table and fires the
`onRegisterActionEvents` event that triggered the registration.

## `category` in `modDesc.xml` is irrelevant here

Actions registered this way don't need `category="ONFOOT"`/`"VEHICLE"` at
all - confirmed against TerraFarm's own `MACHINE_TOGGLE_ACTIVE`, declared
with no `category` attribute. `category` only matters for actions going
through the global `g_inputBinding:registerActionEvent` path; it doesn't
gate this one, since the vehicle-context restriction comes from
`isActiveForInput` itself, not any XML metadata.

## References

- `TerraFarm/scripts/specializations/Machine.lua` (`onRegisterActionEvents`, `ACTION_TOGGLE_ACTIVE`)
- `TerraFarm/scripts/extensions/VehicleExtension.lua` (`registerEventListener`, `inj_Vehicle_load`)
- base-game `dataS/scripts/vehicles/Vehicle.lua` (`registerEvent`/`raiseEvent` for `onRegisterActionEvents`, `addActionEvent`/`removeActionEvents` registration)
- `ImmersiveWeathering.lua` (`VehicleTyreControls`, our own implementation)
