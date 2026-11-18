# Weather / rain state

**Status:** confirmed via source (real base game `dataS/scripts/`, not a mod) -
`Washable.lua`'s own vehicle-wetness logic, never actually run by us

No `Weather`/`Rain`/`Environment` category exists in `scriptBinding.xml` at all
- there's a `Precipitation` category, but every function in it is a
`setRain*` particle-simulation tuning knob (spawn box, bounce physics, drop
count), not a state read. `g_currentMission.environment.weather` is a
Lua-side object, not a native, so it was never going to show up there.
Searching real mod source (TerraFarm) for a rain check also came up
completely empty - landscaping tools have no reason to care about weather.
The real answer was in base-game **vehicle** code, `dataS/scripts/vehicles/
specializations/Washable.lua`, which needs rain state to decide when a
vehicle gets washed by weather instead of a pressure washer.

## The pattern (from `Washable:onUpdateTick`/`Washable:updateDebugValues`)

```lua
local weather = g_currentMission.environment.weather
local rainScale = weather:getRainFallScale()
local timeSinceLastRain = weather:getTimeSinceLastRain()
local temperature = weather:getCurrentTemperature()

local isRaining = rainScale > 0.1 and timeSinceLastRain < 30 and temperature > 0
```

Worth noting exactly what this says: the base game does **not** expose a
simple `isRaining()` boolean anywhere. "Is it raining" is a derived,
three-part condition - meaningful rainfall (`rainScale > 0.1`), recent
(`timeSinceLastRain < 30` - seconds, presumably, not confirmed), and above
freezing (`temperature > 0`, i.e. not snow). Copy the whole formula, not
just `rainScale > 0.1` alone, or you'll also count fresh snow as rain.

## Where this was found gated behind `isServer`

`Washable:onUpdateTick` reads weather state inside `if self.isServer then`.
Not confirmed whether `g_currentMission.environment.weather` itself is
`nil`/stale on a client, or whether that guard is specific to Washable's own
sync design - worth checking before relying on this in client-side code, if
that ever comes up. Everything using this so far (IW's ground-mapping
`condition="isRaining"`) runs from the same place `paintWitherMaterial`
already does, which is already effectively server-side (terrain painting is
server-authoritative).

## Resources

- `dataS/scripts/vehicles/specializations/Washable.lua` (`onUpdateTick`,
  `updateDebugValues`) - the real, confirmed usage this page is based on.
- `sdk/debugger/scriptBinding.xml`, category `Precipitation` - exists, but
  is entirely `setRain*` rendering/particle-simulation setters, no read
  side at all.
