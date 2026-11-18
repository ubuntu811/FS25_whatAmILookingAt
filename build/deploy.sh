#!/usr/bin/env bash

# Exit immediately if any command fails
set -e

MOD_NAME="FS25_whatAmILookingAt"
SOURCE_ZIP="build/${MOD_NAME}.zip"
TARGET_DIR_NAME="$HOME/fs25/mods/${MOD_NAME}"

echo "=== Starting FS25 Hot-Reload Deployment Pipeline ==="

# 0. Nothing that does not parse reaches a running game: every Lua file is syntax checked, modDesc and the xml of the mod must be well formed, the tests (when there are any) must pass.
BAD=0
for f in $(find scripts -name '*.lua' 2>/dev/null); do
    if ! lua -e "assert(loadfile('$f'))" >/tmp/deploy_lua_check.txt 2>&1; then
        echo "!!! $f does not parse:"; head -2 /tmp/deploy_lua_check.txt; BAD=1
    fi
done
for f in modDesc.xml $(ls vehicles/*/*.xml handTools/*/*.xml 2>/dev/null); do
    if ! python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$f" 2>/tmp/deploy_xml_check.txt; then
        echo "!!! $f is not well formed:"; tail -1 /tmp/deploy_xml_check.txt; BAD=1
    fi
done
for f in $(ls tests/*.lua 2>/dev/null); do
    if ! lua "$f" >/tmp/deploy_test_out.txt 2>&1; then
        echo "!!! $f FAILS:"; grep -v "passed$" /tmp/deploy_test_out.txt | head -6; BAD=1
    fi
done
if [ "$BAD" != "0" ]; then
    echo "!!! NOT deployed: fix the file(s) above first."; exit 1
fi

# 1. Always rebuild first (unconditional: a stale zip once deployed old code).
if [ -f "build/build.sh" ]; then
    bash build/build.sh
fi

# 2. Deploy to a LIVE game. The game is always running and reads the mod's xml, models and scripts when it loads or starts: the folder must NEVER be emptied or a file half written (2026-11-17: a deploy that did
# rm -rf + unzip while the game was starting made it fail to open five vehicle xml files, load without the bridge, and the next save dropped the bridge from the savegame). So: unzip into a staging folder, then rsync only
# the files that really changed (checksums; each is written as a temp file and renamed).
STAGE="build/.deploy_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$TARGET_DIR_NAME"
unzip -q "$SOURCE_ZIP" -d "$STAGE"
# rsync --delete removes what is not in the stage: never with an empty or wrong stage, never outside this mod's own folder, never more than a few files at once.
if [ ! -f "$STAGE/modDesc.xml" ]; then
    echo "!!! the staged package has no modDesc.xml: the target is NOT touched"; rm -rf "$STAGE"; exit 1
fi
case "$TARGET_DIR_NAME" in
    */mods/${MOD_NAME}) ;;
    *) echo "!!! the target is not .../mods/${MOD_NAME}: nothing deleted or written"; rm -rf "$STAGE"; exit 1 ;;
esac
CHANGES=$(rsync -rt --checksum --delete --max-delete=30 --itemize-changes "$STAGE"/ "$TARGET_DIR_NAME"/ | grep -v '^\.d' | grep -E '^(>f|\*deleting)' || true)
rm -rf "$STAGE"
if [ -z "$CHANGES" ]; then
    echo "--> Nothing changed in the deployed mod."
else
    echo "--> Changed files:"
    echo "$CHANGES" | sed 's/^[^ ]* /    /'
    echo "--> RESTART the game to see it (scripts, modDesc, vehicles and models are read at start)."
fi

echo "================================================="
echo " SUCCESS: Mod deployed as a loose unzipped folder!"
echo " Path: ${TARGET_DIR_NAME}"
echo "================================================="
