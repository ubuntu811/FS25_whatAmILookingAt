# The map scan: how WAILA draws a map-independent picture of the world

Immersive weathering allows to easily drive paths into the map, while driving
vehicles. In game map editor and other mods can edit the map, sadly none of that
so far was visible on the actual in game map. Until now. Anything after this is 
AI generated documentation. 

WAILA can look at any FS25 map, without knowing anything about it in advance, and
draw what it finds as layers on the in-game map: **water, forest, single trees,
trails, roads and buildings**, plus a list of every **field** with its outline.
The drawing itself is TaskMap's job (it hooks the map); the scanning, the data, the
saving and the settings live here. This page explains how it works now that the bugs
are out.

- [What you get](#what-you-get)
- [In plain words](#in-plain-words)
- [The clue: judging a map without customising for it](#the-clue-judging-a-map-without-customising-for-it)
- [The grid: chunks, cells and seams](#the-grid-chunks-cells-and-seams)
- [One layer at a time](#one-layer-at-a-time)
- [From cells to shapes](#from-cells-to-shapes)
- [Overlays: how it gets onto the map](#overlays-how-it-gets-onto-the-map)
- [Saving and loading](#saving-and-loading)
- [Rescanning part of the map](#rescanning-part-of-the-map)
- [Fields: the second scanner](#fields-the-second-scanner)
- [HUD, hub and settings](#hud-hub-and-settings)
- [For other mods](#for-other-mods)
- [Performance](#performance)
- [Tests](#tests)
- [Lessons and gotchas](#lessons-and-gotchas)
- [Known limits and open ideas](#known-limits-and-open-ideas)

## What you get

| Layer | What it is | Source of truth |
|---|---|---|
| Water | lakes, rivers, sea, ponds you dig | `WATER` collision planes above the terrain |
| Forest | where trees stand, as an area | tree trunks (overlap query) plus learned forest-floor paint |
| Trees | one dot per trunk | the same trunk queries, merged and drawn as small circles |
| Trails | worn dirt and gravel (IW's wear shows up here) | terrain material ids outside roads and forest |
| Roads | asphalt and tracks the map author built | best of: `ROAD` collision raycast, a learned paint layer, the road splines |
| Buildings | roofs and tall static objects | a downward raycast per cell |
| Fields | outline and id of every field | a separate sweep, see [Fields](#fields-the-second-scanner) |

Keys and places: **Shift+G** (TaskMap) starts the whole-map scan, and so does "Scan the
whole map" in the hub's **Terrain** tab, so the key can be freed up if you want it for
something else. The WAILA hub (Shift+L) has a **Map layers** tab (colour, opacity,
show/hide per layer) and, in the **Terrain** tab, also "Rescan around me". Progress shows in a strip under the WAILA mini
panel.

## In plain words

Picture the map as one huge sheet of graph paper, and the scanner as someone who walks
over it with a checklist.

1. **Cut it into squares.** The map is divided into **64 m x 64 m chunks** (4,096 of them
   on a 4 km map). The scanner works through them like reading a page: from the north-west
   corner, left to right, row by row, a few per frame so the game never stutters.
   *Why squares?* Four reasons. The polygons stay small (a handful to a few dozen points
   each; the first attempts outlined whole forests in one go and ended with polygons of
   100,000 points). The work per step has a fixed upper size. Each square can be
   saved, redrawn or rescanned on its own. And a margin around each square (below) takes
   care of the seams.

2. **Lay a fine grid over one square.** Inside a chunk the scanner looks at **2 m cells**
   (not 0.5 m; the 0.5 m steps you see in the HUD are its small 5 m patch around the
   crosshair). 2 m is as fine as this needs to be, since a road is 4 to 8 m wide. With a
   4-cell margin on every side that is 40 x 40 = **1,600 points per chunk**. A quick
   check on a fraction of them first tells it that an empty square (open sea, bare field)
   has nothing to do, and it moves on.

3. **Ask the engine about each point.** For the centre of each cell it asks a few
   questions: what is the ground paint here (one terrain read), is a tree trunk in this
   4 m box, does a ray from above hit water, a roof, or a road. Each answer puts a
   **mark** on that cell: *forest*, *worn ground*, *road*, *water*, *something solid*. The
   result is one grid of yes/no per layer (a "mask"), 40 x 40 each.

4. **Decide with the neighbours.** One marked cell means little. So each mask is cleaned
   up by looking at the cells around it: gaps between trunks are joined, specks dropped,
   small holes filled. This is where "a handful of marked cells" becomes "a forest" (see
   [A flag, or a conclusion?](#a-flag-or-a-conclusion)).

5. **Draw the outline.** The edge of every blob is traced and smoothed into a curve, so a
   forest that was hundreds of cells becomes one polygon of a few dozen points.

6. **Hand it over.** The polygons are kept under that chunk's name (that is what the save
   file holds) and painted into the big picture of the layer that the map shows.

7. **When the last square is done:** dotted trails are joined, the pictures are
   refreshed, and the field outlines are swept.

What it never does is look at a point and decide *alone*, or know anything about the map
beforehand. The next section is about the second half of that sentence.

## The clue: judging a map without customising for it

> "that's the whole clue of the mod, how you manage to look at the map and define
> something as 'looks like forest' without having to customize this for every map"

Every FS25 map paints its ground its own way. The road paint the scanner learned on one
map reads `0.0710 / 0.0630 / 0.0630 / 0.0000`, on another `0.1570 / 0.1410 / 0.1220 /
0.0000`; and a single map can have several forest floors (one 4 km map had two, `0.1550 /
0.0820 / 0.0370 / 0.5910` and `0.2200 / 0.2120 / 0.1960 / 0.0000`). One map's roads are
decals with no collision at all, another's are paint, another's a tagged mesh. The
obvious approach, a table saying "paint X is forest, paint Y is road", would need a new
table for every map and for every map update. This scanner has no such table. It works
because it separates two kinds of evidence:

- **Universal evidence**: things the engine defines the *same way on every map*.
  Collision groups (`TREE`, `WATER`, `ROAD`, `BUILDING`, static objects), whether foliage
  actually grows at a point, the map's road splines, the material buckets (dirt, gravel,
  stone), field ground. A tree is a tree body on any map.
- **Map-specific evidence**: how *this* map looks, which in practice means the paint
  fingerprint of a point. Meaningless without knowing the map.

The rule: **only universal evidence decides. Map-specific evidence is learned from it,
fresh, at the start of every scan, and is only ever used to fill in where the universal
evidence is thin.**

```
 universal evidence                  learned for THIS map, at scan start         then used for
 ------------------                  --------------------------------------      -----------------------------
 road splines, sampled every 6 m --> which paint fingerprints are ROAD paint --> roads on maps whose asphalt has
                                     (common along the splines, rare on the      no collision tag
                                      rest of the map)
 trunks (TREE bodies, via the old    which fingerprints lie mostly under trees -> forest between the trunks,
 statistical classifier as teacher)  = FOREST FLOOR paint                          where foliage confirms it
 ROAD / WATER / BUILDING collision   nothing to learn, used directly            --> roads, water, buildings, trees
```

One honest qualification: the *teacher* for forest-floor paint is not trunk ground truth. At scan start the
learner uses the older statistical classifier (a material-diversity heuristic over a 3 x 3 pattern of samples) to say
which cells are forest, and a paint fingerprint is learned as forest floor when most of its sampled occurrences fall in
such cells (at least 8 samples, at least 60%). Trunks decide the forest in the detailed scan itself; the learned paint
only extends it. So the rule above is "universal evidence decides, learned paint fills in", with a heuristic bootstrap
for the paint.

So "this looks like forest" is never a lookup. It is a chain, strongest evidence first:

1. **Trunks.** Enough `TREE` bodies in the neighbourhood of a cell (universal; works on any
   map that has standing trees).
2. **Closed up.** The gaps between trunks are joined (radius 2 cells), specks dropped,
   enclosed clearings kept, so a wood is an area and not a dotted line.
3. **The learned floor.** Cells whose paint fingerprint the scanner *learned* to be forest
   floor on this map extend the forest where trunks are sparse, but only where foliage is
   actually growing.
4. **Nothing else.** No name, no colour, no per-map number.

What the learning looks like, from one real run on a 4 km map (the log lines
`LayerClasses:` at scan start):

```
ROAD   0.1570/0.1410/0.1220/0.0000  (97% of spline samples, 2.4% of map, main road paint)
FOREST 0.1550/0.0820/0.0370/0.5910  (85% of its 588 cells in forest cells, 15.4% of map)
FOREST 0.2200/0.2120/0.1960/0.0000  (91% of its 239 cells in forest cells, 6.2% of map)
learned 1 road + 2 forest layer(s) from 112 spline(s) / 6658 spline sample(s), 3827 map cell(s), 165 ms
```

Nobody told the scanner those numbers. 97% of the road-spline samples carried the first
one and only 2.4% of the rest of the map did, so it is road paint; 85% and 91% of the
cells carrying the other two have trees standing on them, so they are forest floor. On
the next map the numbers are different and the same code finds different ones. The whole
learning step takes a fraction of a second.

**What this buys.** One code path, no configuration, has handled three very different maps
(CreativeHorizon, Pirambeiras, Estancia Lapacho): roads that are decals with no collision
tag, roads painted on a layer of their own, and a `ROAD`-tagged collision mesh painted
like ordinary ground. The scan picks a different source for the roads on each, and is
otherwise the same.

**Where it stops.** The scheme is only as good as its universal evidence. A map whose trees
have no collision bodies (purely decorative foliage) has no trunks to teach it; a forest
with no foliage planes has nothing to confirm the learned floor; a map that paints roads
like ground *and* has no collision tag falls back to the spline ribbons. Thresholds
(how common a fingerprint must be to count) are fixed numbers that happen to work on the
three maps seen so far; the notes file on per-map tuning lists what to change if a map
needs it.

The learning steps in detail:

1. **The terrain "fingerprint" of a point.** For one world position `(x, z)`,
   `getTerrainAttributesAtWorldPos(terrainNode, x, 0, z, ...)` returns four numbers
   `r, g, b, w` and, as a fifth value, the **material id** (dirt, gravel, stone ...).
   The scanner never interprets `r, g, b, w`. It rounds them to three decimals and uses
   the **combination as a name** for "this kind of ground paint", and later learns which
   names mean road and which mean forest floor. Real examples from the logs of two maps:

   | `r / g / b / w` | what it turned out to be on that map |
   |---|---|
   | `0.0710 / 0.0630 / 0.0630 / 0.0000` | road (95% of the road-spline samples, 1.6% of the map) |
   | `0.2200 / 0.2120 / 0.1960 / 0.0000` | forest floor (91% of its cells under trees) |
   | `0.1550 / 0.0820 / 0.0370 / 0.3000`, `... / 0.5910`, `... / 0.6000`, `... / 0.7000` | the most common ground on that map (76% of it), four different values of `w` on the same `r, g, b` |

   What the numbers *physically* are, we only know partly: the GIANTS editor scripts
   match terrain paint by comparing exactly these four values; the first three look like
   the paint's colour, and the fourth steps through values (0.3, 0.5, 0.6, 0.7) on the
   same colour, which reads like a blend weight, so a spot that is half one paint and
   half another gets its own combination. They are what the engine reports for that
   point, already combining the paint painted there. **Nothing is averaged by the
   scanner**: one position gives one set of numbers.

   **You can see them yourself.** In the full HUD (Shift+M), looking at the ground
   (the values below are illustrative, the layout is the real one):

   ```
   Ground: DIRT [1]  field=... 
   Layer attrs: r=0.157000 g=0.141000 b=0.122000 w=0.000000     <- the crosshair point, one read
     Layer 0.1570/0.1410/0.1220/0.0000   97.0% (97)              <- the same read at 100 points
     Layer 0.1550/0.0820/0.0370/0.6000    3.0% (3)                   (5 x 5 m, every 0.5 m), grouped
   Learned classes: road 97%  forest floor 0%                      <- those groups matched to the classes
   ```

   The histogram under the crosshair line is the *averaging* you may remember: it
   counts the fingerprints of 100 sample points (a 5 x 5 m area, one read every 0.5 m),
   so a spot on a road edge shows, say, 60% road paint and 40% grass. The map scan does
   not do that: it reads one point
   per cell (see [Where the terrain reads come from](#where-the-terrain-reads-come-from)
   below) and lets the later cleaning steps (closing, opening, hole filling, in cell
   space) smooth the result over neighbouring cells.
2. **Learning the road layer** (`learnLayerClasses`, `isRoadLayerStat`). The map's
   road splines (`g_currentMission.aiSystem:getRoadSplines()`) are sampled and the
   fingerprints under them counted. A layer is "road paint" when it is common along
   the splines but rare on the map: spline share >= 25%, or >= 3% with at least 12
   samples and 5x enrichment, with a map share <= 10%. On some maps no layer
   qualifies (Estancia Lapacho: asphalt is painted like ground), and that is fine,
   see roads below.
3. **Learning the forest floor.** The older statistical forest classifier
   (`classifyForestCell`) now only acts as a teacher: layers that lie mostly inside
   cells it calls forest become "forest floor" classes. The scan itself uses trunks
   first.
4. **A probe per map** decides where roads come from (below), so the same code draws
   roads on a map with collision-tagged asphalt, on one with paint-only roads, and on
   one that has nothing but splines.

Nothing is stored per map. The learned classes are **not saved**: they are relearned at
the start of every scan (a fraction of a second) from the terrain and the splines as
they are right now. What is saved is the *result* of a scan, see [Saving and
loading](#saving-and-loading).

## The grid: chunks, cells and seams

The map is cut into **64 m chunks**. Each chunk is scanned on a **2 m cell grid**
(32 x 32 cells), looking at a **window** that is the chunk plus a **halo of 4 cells**
on every side.

Why the halo? Cleaning up a mask (closing small gaps, removing specks, filling holes)
needs context: a structure straddling a chunk border must be judged the same way from
both sides. The rule that makes seams invisible is simple and strict:

> A connected component that **touches the window edge is never judged**. It is kept
> as is. Only components fully inside the window are filtered (too small, too thin,
> enclosed hole). The same decision is reached from the neighbouring chunk, whose
> window sees the whole thing.

The scan is a state machine (`wholeMapScanState`) advanced from the game's update loop
by `tickWholeMapScan` with an **8 ms budget per frame**. One step is one chunk (the
slowest chunk measured is 75-105 ms of work, so a frame can overshoot once in a while,
but the average cost stays small). A 4 km map is 64 x 64 = 4096 chunks; about half of
them are empty (open sea, bare fields). Measured on Estancia: **25-50 s of scan work,
50-95 s wall time** depending on the machine.

### Where the terrain reads come from

All terrain data is read **one position at a time on regular x/z grids** (world
coordinates, origin at the map centre, the map spanning `-size/2 .. +size/2`). There are
three grids, for three jobs:

| Job | Positions | How many (4 km map) |
|---|---|---|
| **Learning: the map's mix of layers** | the centre of every 4th 16 m coarse cell, per axis (one sample per 64 m x 64 m); cells on fields are skipped. Each sample also runs the old forest classifier (3 x 3 reads) as the "teacher". | about 4,000 samples |
| **Learning: roads** | along every road spline from `aiSystem:getRoadSplines()`, every 6 m of spline length | a few thousand, depending on the map |
| **The scan itself** | the centre of **every 2 m cell** in each chunk's window: `(col + 0.5) * 2 m`, 40 x 40 cells per chunk (32 for the chunk plus 4 halo cells on each side) | 1,600 reads per chunk, up to 6.5 million for the whole map if no chunk were skipped; empty chunks stop after the cheap prefilter below |

Every read is a **point sample, not an average**: one position, one set of numbers
(the crosshair line of the HUD above, repeated for every 2 m cell). The scan's read is
`getLayerCellAt(x, z)`: **one terrain read answering two questions**,
the learned class of the fingerprint (road paint, forest floor, or neither) and the
material id (worn ground or not). A cell outside the map is skipped.

**Prefilter.** Most chunks hold nothing (open sea, bare fields). Before a chunk is
scanned in full, the window is probed on every second cell in both axes (400 reads) plus
one tree overlap query, and the probe stops at the first hit: a chunk with no tree, no
learned class and no worn ground is empty and costs almost nothing. That is why about
half of a typical map's chunks are skipped.

Per chunk, in this order (`tickLayerScanStep`):

1. buildings and water (`scanBuildingChunk`), recorded and drawn
2. forest, trail and trees (`scanLayerChunk`), recorded and drawn
3. roads (`scanRoadRayChunk`, or the spline ribbons, or the learned paint layer)

When the last chunk is done: trail fragments are linked, every overlay is regenerated
once ("forced"), the log gets a summary (counts, worst chunk, wall time) and the field
sweep starts.

## One layer at a time

### A flag, or a conclusion?

Not every layer is equally easy to read from one point. Some have a **clear engine flag**
for "this point is X"; others are a **conclusion drawn from the neighbourhood**, and for
those no single point can ever decide:

| Layer | Does one point have a flag? | What the neighbours add |
|---|---|---|
| **Water** | **Yes.** A downward ray hits a `WATER` collision plane that stands at least 0.15 m above the terrain. | Only tidying: the mask grows one cell (the wet lakebed fringe), tiny islands and holes are dropped. |
| **Roads** | **Mostly yes.** A downward ray hits a collider with the `ROAD` bit; or the point's fingerprint is a learned road paint; or it lies under a road spline. | Only tidying (minimum size, holes). |
| **Buildings** | **Half.** A ray hit well above the ground (roof) or on a tall static object says "something solid stands here". | Whether it is a *building* or a fence post is decided by the neighbours: an opening of radius 1 removes anything 4 m wide or less, and the footprint must be at least 12 cells. |
| **Trees** (the dots) | **Yes, per trunk.** An overlap query finds `TREE` bodies. | Nearby trunks closer than 0.5 m count as one. |
| **Trails** | **Half.** The material id says "dirt" or "gravel" at the point. | Whether it is a *trail* depends on context: not on a road, not on water, away from the forest edge unless the connected worn area is at least 40 cells (a path or yard, not a patch of forest-floor dirt), enclosed holes filled. |
| **Forest** | **No.** There is no flag for "forest" anywhere in the engine. | Everything. A single trunk is not a forest; a cell is forest when enough trunks stand in its 4 m box *and its neighbours*, the gaps between trunks are closed (radius 2 cells), specks are dropped, cells whose paint is a learned forest-floor class count too, but only where foliage is actually present there (so bare patches of the same paint do not), and enclosed clearings stay clearings. |

So the scan has two kinds of steps. **Reading** is cheap and local: one query or ray per
cell. **Deciding** always looks at the neighbours, in cell space, and for forest it is
the whole story. That is also why the seam rule ("a component touching the window edge
is never judged") and the 4-cell halo exist at all: the decision about a cell near a
chunk border needs the cells on the other side.

### Forest and trees

"Forest is where trunks are, however the ground under them was painted." Every 4 m
cell gets an `overlapBox` query against the `TREE` collision group; the count of
shapes is the number of trunks. Two facts learned the hard way:

- A big per-chunk window query reports only about **one shape per window** (the engine
  returns far fewer shapes than are there; the cause is unknown). The reliable way is
  many small queries, one per cell. The window query is merged in only as a safety net.
- A standing tree is a *static* body with the `TREE` bit. A felled one is not.

From the trunk counts: a mask, **closing** (radius 2 cells, joins the gaps between
trunks into one area), small specks dropped, enclosed holes up to 100 cells filled
(a real clearing stays a clearing), then traced into polygons. The forest-floor paint
classes and forest-family foliage (`forestPlants` ...) add to the mask where trunks
are sparse.

Tree dots (`TREE_DOT_RADIUS = 2.5` m hexagons) are drawn from the merged trunk
positions, one per trunk (positions closer than 0.5 m are one tree).

### Trails (worn ground)

Dirt and gravel material ids (`WORN_MATERIALS`) on cells that are **not** road and
**not** forest, not on water. A small patch near forest is forest-floor dirt and is
dropped; a connected worn component of >= 40 cells is a path or a yard and is kept
wherever it lies ("a path through the woods is a long strip, a floor patch is a blob").
Enclosed holes up to 400 cells are filled: a placeable on a yard carries its own ground
layer and would otherwise show as a hole. This is the layer IW's wear writes to, so
tractors wearing a track show up here.

**Stone road, gravel shoulders.** Beside a road, shoulders of gravel often sit right next to the road paint. Only the
paint of the road itself is a learned road class; the shoulders usually are not, and a forest-floor paint can sit on them
too. In the pictures (2 m cells, then cleanup) the two can end up as one wide band of "road". Code that must know where the
road itself is (the road follower) asks `WailaTrailTracer.sampleRoadPaint(x, z)`, which reads the paint at that exact
point instead of the picture.

After the scan, `linkTrailFragments` bridges aligned dashes (gap up to 40 m, up to 25
degrees apart, only elongated fragments) with narrow ribbons, so a dotted track reads as
a track.

### Roads

Three sources, best first, chosen **per map at scan start**:

1. **Collision raycast.** If at least half of the spline samples sit on a collider with
   the `ROAD` bit (`probeRoadCollision`), roads are found by a downward ray per cell
   (a coarse 4 m prefilter, then 2 m). This is exact on maps like Estancia where the
   asphalt is a tagged mesh.
2. **Learned paint layer.** The road paint learned above.
3. **Spline ribbons.** The road splines widened to 6 m ribbons. Last resort, but it
   works on maps (CreativeHorizon) whose roads are decals.

The chosen source is shown in the Map layers tab ("collision raycast", "paint layer",
"spline ribbons").

**Splines and chunks.** A road spline is one long curve for the whole map; it is not made
of little pieces. The scanner uses them in three different ways:

1. **Once, at the start, for the whole map**: sample every spline every 6 m, to learn
   which paint fingerprints are road paint and to test whether the roads carry the `ROAD`
   collision bit. Nothing about chunks yet.
2. **Only if the roads have to be drawn *from* the splines** (the last resort, no
   collision tag and no learned paint): the splines are widened to 6 m ribbons and then
   **cut at the 64 m chunk borders**, each chunk getting its own piece (plus one extra
   point reaching into the next chunk, so the pieces overlap and leave no gap). That is
   why they end up as little pieces: it is bookkeeping, so that each chunk's roads can
   be drawn, saved and rescanned like every other layer. The cut is done once, before
   the first chunk; each chunk then just picks up its pieces.
3. **The other two road sources never touch the splines for drawing**: the ray version asks
   each 2 m cell "is there a `ROAD` collider under you", and the paint version asks
   "is your fingerprint a road paint".

For driving, WAILA's path store keeps the splines **uncut**, as whole curves.

### Buildings

A downward ray from 60 m above each 2 m cell with the mask
`BUILDING | STATIC_OBJECT | WATER`. A hit more than 1.5 m above the ground is a roof;
the stepped roof outline is the footprint (placeable boxes are far bigger than the
building, so rays are the right tool). **Map-baked buildings** (silos, warehouses in
the map file) carry `STATIC_OBJECT | PLACEMENT_BLOCKING` and *no* `BUILDING` bit, so
tall static objects count too: >= 2.5 m high, an opening (radius 1) removes anything
4 m wide or less (fences, poles), and the footprint must be >= 12 cells.

### Water

The same ray also accepts the `WATER` bit. A cell is water when the plane is at least
0.15 m above the terrain; the mask is grown one cell so the wet lakebed fringe goes
too (that fringe is what used to be mistaken for a trail: the material under a river
reads as a path). The water mask is handed to the trail pass, which drops trail cells
on water. Islands and holes use the same "enclosed and small" rule.

## From cells to shapes

Cell masks are turned into polygons by a **directed-edge loop tracer**: every border
between a set and a not-set cell is an edge with a direction, edges are chained into
closed loops, outer loops and holes by winding. The loops are then **curve fitted**
(Schneider's Bezier fitting, `fitLoopCurves`) with a tolerance per layer (forest 2.0 m,
trail 1.0 m, road 0.7 m, water 1.0 m), then sampled back into polylines. Result: smooth
outlines from a 2 m grid, with a handful of points instead of one per cell.

Position-independent rules (islands/holes smaller than N cells, minimum area, minimum
thickness) are applied in cell space *before* tracing, with the seam rule above.

## Overlays: how it gets onto the map

Each layer is a **bit-vector map** of 2048 x 2048 (`createBitVectorMap`,
`loadBitVectorMapNew`): 2 m per pixel on a 4096 m map, 1 channel (forest and trail use
2: the second value is a debug mark). Polygons are written into it with a
`DensityMapModifier` (`addPolygonPointWorldCoords`, `executeSet`). A
`DensityMapVisualizationOverlay` turns the map into something drawable with
`setDensityMapVisualizationOverlayStateColor` (value -> colour) and
`generateDensityMapVisualizationOverlay`. Regenerating costs real time, so while a scan
runs each layer regenerates at most every few seconds, and once at the end ("forced").

TaskMap draws the overlays from hooks on `IngameMap:drawFields` (one per layer, order:
water, forest, trees, trails, buildings, roads, debug layers), reading colour,
opacity and visibility from WAILA every frame.

The same maps are what other mods read: `WailaTrailTracer.sampleDrivable(x, z)`
answers 0 / 1 (trail) / 2 (road) straight from the bitmaps.

## Saving and loading

Two stores, written together after every game save and restored together at load.

1. **Polygons** (`<savegame>/wailaTrail.xml`): the per-chunk region store
   (`savedRegions` for forest, water, road, building; `savedRegionsByMaterial` for
   trails). Written and parsed **tick-budgeted** (5 ms per frame, 50 polygons per batch)
   so a big map does not stall a frame. Needed for trail linking and for area rescans,
   and it is the fallback for any layer whose image is missing.
2. **Images** (`<savegame>/wailaLayer_<layer>.grle`): each overlay bit-vector map
   written as a `.grle` image with `saveBitVectorMapToFile`, one layer every 0.25 s.
   Measured: **14-24 ms to save and 32-37 ms to load a 2048 x 2048 layer**, files from
   17 KB (water) to ~580 KB (trees). `.png` writes nothing; the format follows the
   extension and `.grle` is the density-map format. A round trip was checked pixel by
   pixel: 0 mismatches.

Load order (`tickLoadFromXML`): about 3 s after the mission loads, the **images** come
back, one layer per frame, each regenerated once. Then, after a 15 s settling delay (the
game is at its slowest right after loading), the **polygon store** is parsed; layers
that came from an image are **not redrawn** from polygons (the expensive part), only the
data is kept. A layer without a usable image (missing, wrong size) is drawn from its
polygons as before. Result: a reload that used to take minutes on a big map shows its
layers in well under a second.

Things that bit us:

- **The game deletes savegame files it did not write itself** on its own save. WAILA
  files are rewritten in the `SavegameController.onSaveComplete` hook (settings, paths,
  field list, polygons, images) or they vanish.
- **Quitting mid-save** used to leave no polygon file at all (it is written in the last
  tick). `flushPendingIO` finishes a running save and the image queue at teardown.
- A **whole-map scan cancels a restore that is still waiting** (it replaces everything
  anyway) and a refused press shows "Busy: ..." in the HUD strip.

## Rescanning part of the map

`startAreaScan(x, z)` rescans **3 x 3 chunks (192 m)** around a point through exactly the
same pipeline: the chunk's overlay rectangle is wiped (`clearChunkOverlays`), the chunk
is scanned and recorded again (replacing its stored polygons), the same colours and
settings apply, trail links are redone, and the layers are regenerated. It does not
start a field sweep. The hub's "Rescan around me" uses it; it is meant as the building
block for "something changed here" triggers (a placeable built, terrain dug, a vehicle
driven over ground).

## Fields: the second scanner

Fields are not read from the layer scan: `WailaFieldIndex` owns them.

- **Sweep** (`WailaFieldGridScanner`): seeds on a 24 m grid; each seed that stands on
  field ground (`FSDensityMapUtil.getFieldDataAtWorldPosition`) walks +z to the field's
  edge and **traces the boundary** with `WailaFieldBoundaryTracer`, a direct port of
  the base game's own `BoundaryDetectionTask` (the same thing the AI uses to find a
  field's outline). Cells inside a found field are claimed so each field is traced once.
- **Holes.** A void inside a field is a boundary too, and used to be registered as a
  field once per field cell (211 entries, 27 s). A traced outline must **contain its
  seed**; otherwise it is a hole, remembered, and later seeds inside it are skipped. The
  seed cell is always claimed.
- **When it runs.** Not on a timer any more. The full sweep runs after a whole-map scan,
  or once after load when there is no trusted saved list (the list is cached in
  `waila.xml`; a list with every boundary and unique sample points is trusted and the
  startup sweep skipped). A vehicle or the player **leaving a field** queues a budgeted
  rescan of just that field, at most once per minute per field. Every few minutes and at
  each growth period only the per-field crop/growth snapshot is re-read (no tracing).
- **Budgets.** Sweep: 3 ms per frame. Single-field rescans: the same, queued one at a
  time. A fresh load with slow frames can stretch a 2-3 s sweep to 15 s; it never
  stalls.

## HUD, hub and settings

- **Task strip** under the WAILA mini panel: one row per running job (map scan with live
  counts of trees, forest, trails, roads, buildings and water found so far; field sweep;
  field rescan; restore; save; image restore/save), a short "Busy: ..." note when a key
  press is refused, and the restore countdown.
- **Map layers tab**: per layer colour (the base game's colour picker), opacity (mouse
  wheel, or the arrow selector), show/hide, reset; a colour chip and a ten-segment
  opacity meter on every row; what the scan detected for that layer.
  Settings are per savegame (`wailaMapSettings.xml`), rewritten after each game save.
- **Debug log switch** (General tab, `WailaConfig`): chatty lines ("Field found ...",
  self-test events) only log when it is on; other mods read
  `g_currentMission.waila.isDebugLogEnabled()`.

## For other mods

Everything is published through `g_currentMission` (mod globals are invisible to other
mods):

| Name | What |
|---|---|
| `g_currentMission.waila` | the `Waila` table: `get(type, x, z)`, `getAll(type)`, `registerDebugTab`, `isDebugLogEnabled` ... |
| `g_currentMission.wailaTrailTracer` | scan control and data: `startWholeMapScan`, `startAreaScan(x, z, radius)`, `sampleDrivable(x, z)`, `hasDrivableData()`, `getLayerAlpha(layer)`, `isLayerVisible(layer)`, `recolorOverlays()` |
| `g_currentMission.wailaPaths` | the path store (recorded drives, imported roads, the map's splines): `findNear`, `add`, `newRecorder`, ... see `WailaPathStore.lua` |
| `WailaFieldIndex` events | `VEHICLE_LEFT_FIELD`, re-exposed as `Waila.events` |

## Performance

The rule: **every scan has a per-frame budget**. These are cooperative targets: the work is cut into steps (one chunk,
one batch) and the budget is checked *between* steps, so a single chunk or one native call can overshoot it. Learning the
layer classes and choosing the road source run synchronously at scan start, before the chunk loop.

| Job | Budget |
|---|---|
| layer scan | 8 ms per frame |
| field sweep / single-field rescan | 3 ms per frame |
| save, restore (polygons) | 5 ms per frame, 50 polygons per batch |
| layer images | one layer per 0.25 s (save), one per frame (load) |

Measured on Estancia Lapacho (4 km): whole-map scan 25-50 s of work over 50-95 s wall;
field sweep 1.6-3.4 s; restore of ~3,600 polygons 0.8 s; image load 0.2 s for all
layers.

## Tests

`bash tests/run.sh` runs every suite against stubs of the engine (plain Lua 5.1), over
the **real** source files. Relevant here: `layer_scan_test`, `building_scan_test`,
`road_ray_test`, `spline_road_test`, `learn_test` (the scan), `field_scan_test`
(including the hole fix and the single-field rescan queue), `persistence_test` (polygon
store, images, fallback, teardown flush), `area_scan_test`, `map_settings_test`,
`hud_tasks_test`, `drivable_sample_test`, `path_store_test`, `path_import_test`. Look at
`tests/stubs.lua` for what is faked. A crash in a test prints no "FAIL" line: read the
exit status.

## Lessons and gotchas

- **Straight lines in a lake** were never the scanner: they were the 256 m tile of the
  debug overlay.
- **Window queries undercount** (one shape per window); per-cell queries are reliable.
  The cause is unknown.
- **`pairs(_G)` does not list engine functions**; ask by name (`_G["saveBitVectorMapToFile"]`),
  and `rawget(_G, name)` is nil for them. A probe that listed "0 matches" proved nothing.
- **`a and b or c`** turns a `false` into `c`. It hid a failing `fileExists` once.
- **`goto` does not exist** in the game's Lua 5.1.
- **Unbudgeted calls** hide in helpers: a tracer "seek" that looked free walked a whole
  field in one frame. If it loops over map data, it needs the budget.
- **Debug overlays and real overlays share state**: forcing a regenerate at the end is
  what makes the last chunks visible.
- **Settings written only on change disappear**: the game's save sweeps unknown files.

## Known limits and open ideas

- Trees on a map with no standing-tree colliders (some decorative foliage) are not seen.
- Forest *floor* classes are learned heuristically; a map with unusual painting can need
  its thresholds tuned (`project_waila_forest_yard_per_map_tuning` in the notes).
- The ghost-tree square (a dot with no tree under it) was seen once and not chased.
- Event-driven rescans (placeable built, terrain edited, tractor drove over ground) are
  possible with `startAreaScan` but not wired.
- The path store (`WailaPathStore`) is the intended home for centre-lines derived from
  these layers, recorded drives and the map's splines: see the road-follow work in
  `FS25_RoadFollow`.
