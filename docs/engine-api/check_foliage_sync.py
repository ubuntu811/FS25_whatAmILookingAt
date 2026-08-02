#!/usr/bin/env python3
"""
Cross-checks a map's map.xml <decoFoliages>/<paintableFoliages> declarations
against what the map's own I3D actually backs, and against each declared
layer's real per-type numDensityMapChannels. Catches the three bug
categories found the hard way in FS25_Estancia_Lapacho_orange (see
FoliageDensityMap.md in this folder):

  1. <decoFoliage layerName="X"> with no matching FoliageType in the I3D -
     getIsDecoLayerDefined resolves "defined" but nothing ever renders.
     (5 of 9 declared layers on that map: decoFoliageEU, forestPlants,
     decoBushUS, groundFoliage, forestBush.)
  2. <mapping layerName="X"> with no sibling <decoFoliage layerName="X"> -
     write silently fails regardless of real I3D backing. (This is what
     blocked "meadow" - real I3D backing, <paintableFoliage> declared, but
     no <decoFoliage> sibling.)
  3. Declared numChannels lower than the real descriptor's
     numDensityMapChannels - writes to higher states silently clamp
     instead of erroring or honoring the value. (This is what "the
     annoying bush" turned out to be - forestGrass, numChannels="1"
     declared vs. numDensityMapChannels="4" real.)

Usage:
    python3 check_foliage_sync.py /path/to/MapMod/maps/map.xml
    python3 check_foliage_sync.py /path/to/MapMod/maps/map.xml --game-install "/path/to/Farming Simulator 25"

--game-install is only needed to verify layers backed by base-game shared
assets ($data/... paths, e.g. decoFoliage/decoBush/meadow/most fruit
types) - without it those are reported OK-but-unverified. Layers backed by
map-relative paths (e.g. this map's own forestGrass.xml) are always
checked regardless.

Exit code 0 = no problems found, 1 = at least one problem found.
No third-party dependencies - stdlib only.
"""
import sys
import argparse
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_map_xml(map_xml_path):
    tree = ET.parse(map_xml_path)
    root = tree.getroot()

    i3d_filename = root.findtext("filename")

    deco_layers = {}  # layerName -> declared numChannels
    for el in root.iter("decoFoliage"):
        name = el.get("layerName")
        if name:
            deco_layers[name] = int(el.get("numChannels", "0"))

    mappings = []  # (name, layerName, state)
    for el in root.iter("mapping"):
        mappings.append((el.get("name"), el.get("layerName"), el.get("state")))

    paintable_layers = set()
    for el in root.iter("paintableFoliage"):
        name = el.get("layerName")
        if name:
            paintable_layers.add(name)

    return i3d_filename, deco_layers, mappings, paintable_layers


def parse_i3d(i3d_path):
    tree = ET.parse(i3d_path)
    root = tree.getroot()

    foliage_types = {}  # name -> foliageXmlId
    for multilayer in root.iter("FoliageMultiLayer"):
        for ftype in multilayer.findall("FoliageType"):
            name = ftype.get("name")
            xml_id = ftype.get("foliageXmlId")
            if name:
                foliage_types[name] = xml_id

    files = {}  # fileId -> filename
    for f in root.iter("File"):
        file_id = f.get("fileId")
        filename = f.get("filename")
        if file_id and filename:
            files[file_id] = filename

    return foliage_types, files


def resolve_descriptor_path(filename, map_dir, game_install):
    if filename.startswith("$data/"):
        if game_install is None:
            return None
        return Path(game_install) / "data" / filename[len("$data/"):]
    return map_dir / filename


def get_real_num_channels(descriptor_path):
    if descriptor_path is None or not descriptor_path.exists():
        return None
    tree = ET.parse(descriptor_path)
    layer = tree.getroot().find("foliageLayer")
    if layer is None:
        return None
    return int(layer.get("numDensityMapChannels", "0"))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("map_xml", help="Path to the map's map.xml")
    parser.add_argument(
        "--game-install", default=None,
        help="Path to the FS25 Steam install (needed to verify $data/-backed layers)"
    )
    args = parser.parse_args()

    map_xml_path = Path(args.map_xml).resolve()
    map_dir = map_xml_path.parent
    # <filename> in map.xml (e.g. "maps/mapEU.i3d") is relative to the mod
    # root (parent of the maps/ folder map.xml itself lives in), not
    # relative to map.xml's own location.
    mod_root = map_dir.parent

    i3d_filename, deco_layers, mappings, paintable_layers = parse_map_xml(map_xml_path)
    i3d_path = mod_root / i3d_filename
    if not i3d_path.exists():
        print(f"ERROR: I3D not found at {i3d_path}")
        sys.exit(1)

    foliage_types, files = parse_i3d(i3d_path)

    problems = 0

    print(f"=== decoFoliage layers declared in map.xml: {len(deco_layers)} ===")
    for layer_name, declared_channels in sorted(deco_layers.items()):
        if layer_name not in foliage_types:
            print(f"  [MISSING BACKING] '{layer_name}' has no matching FoliageType in the I3D "
                  f"- getIsDecoLayerDefined will resolve but nothing renders")
            problems += 1
            continue

        xml_id = foliage_types[layer_name]
        filename = files.get(xml_id)
        if filename is None:
            print(f"  [WARN] '{layer_name}' -> foliageXmlId={xml_id} but no matching <File> entry")
            continue

        descriptor_path = resolve_descriptor_path(filename, map_dir, args.game_install)
        real_channels = get_real_num_channels(descriptor_path)

        if real_channels is None:
            note = (" (pass --game-install to check $data/ paths)"
                    if filename.startswith("$data/") and args.game_install is None else "")
            print(f"  [OK, unverified] '{layer_name}' -> {filename}{note}")
        elif declared_channels < real_channels:
            print(f"  [NUMCHANNELS MISMATCH] '{layer_name}': map.xml declares numChannels={declared_channels}, "
                  f"real descriptor declares numDensityMapChannels={real_channels} "
                  f"- states {declared_channels} to {real_channels - 1} will silently clamp on write")
            problems += 1
        else:
            print(f"  [OK] '{layer_name}': numChannels={declared_channels} matches real descriptor ({real_channels})")

    print(f"\n=== <mapping> entries: {len(mappings)} ===")
    mapping_layer_names = sorted(set(m[1] for m in mappings if m[1]))
    for layer_name in mapping_layer_names:
        if layer_name not in deco_layers:
            in_paintable = (" (declared as <paintableFoliage> only)" if layer_name in paintable_layers
                             else " (not declared anywhere else either)")
            print(f"  [NO DECOFOLIAGE SIBLING] mappings targeting '{layer_name}' will all fail"
                  f"{in_paintable} - add <decoFoliage layerName=\"{layer_name}\" .../>")
            problems += 1

    print(f"\n{'FOUND ' + str(problems) + ' PROBLEM(S)' if problems else 'No problems found'}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
