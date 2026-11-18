#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Define configuration variables
MOD_NAME="FS25_whatAmILookingAt"
TARGET_ZIP="build/${MOD_NAME}.zip"
BUILD_DIR="build/.build_staging"


echo "=== Starting FS25 Mod Packaging Loop ==="

# 1. Clean up any previous old build artifacts
if [ -f "$TARGET_ZIP" ]; then
    echo "--> Removing old target zip archive..."
    rm "$TARGET_ZIP"
fi

if [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
fi

mkdir -p $BUILD_DIR

echo "=== sanity check lua scripts ==="
find . -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p

echo "=== sanity check xml files ==="
find . -name '*.xml' -print0 | xargs -0 -n1 python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])'

echo "--> Copying production files to staging area..."
# Copy the core runtime logic and metadata. Existence-checked, not assumed -
# l10n/ is empty (all <l10n> text lives inline in modDesc.xml) and git does
# not track empty directories, so a fresh clone never has it at all. An
# unconditional `cp -r l10n/` only ever worked locally, where the empty dir
# still physically exists on disk from before this was noticed - it fails
# on any real fresh checkout, which is exactly what caught it (first CI run).
for i in icon.dds scripts/ gui/ l10n/ i3d/ xml/ modDesc.xml; do
  if [ -e "$i" ]; then
    cp -r "$i" "$BUILD_DIR/$i"
  else
    echo "    (Skipping missing/empty: $i)"
  fi
done

# 3. Compile the production archive
echo "--> Compiling optimized production zip archive..."
cd "$BUILD_DIR"
# Zip everything inside the folder (-r for recursive, -q for quiet execution)
zip -rq "../${MOD_NAME}.zip" ./*
cd ..

# 4. Post-build cleanup
echo "--> Tearing down temporary staging directory..."
rm -rf "$BUILD_DIR"

echo "========================================="
echo " SUCCESS: Built production package!"
echo " File: ./${TARGET_ZIP}"
echo "========================================="

