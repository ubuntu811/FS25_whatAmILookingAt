#!/usr/bin/env bash

# Exit immediately if any command fails
set -e

# Define source archive and destination folder name
MOD_NAME="FS25_whatAmILookingAt"
SOURCE_ZIP="build/${MOD_NAME}.zip"
TARGET_DIR_NAME="$HOME/fs25/mods/${MOD_NAME}"

echo "=== Starting FS25 Hot-Reload Deployment Pipeline ==="

# 1. Verify that a fresh production zip exists
if [ ! -f "$SOURCE_ZIP" ]; then
    if [ -f "./build.sh" ]; then
        ./build.sh
    fi
fi

rm -rf ${TARGET_DIR_NAME}

echo "--> Constructing staging directory at: ${TARGET_DIR_NAME}"
mkdir -p "$TARGET_DIR_NAME"

# 3. Deploy cleanly unzipped development package
echo "--> Unzipping production package directly into development target..."
unzip -q "$SOURCE_ZIP" -d "$TARGET_DIR_NAME"

echo "================================================="
echo " SUCCESS: Mod deployed as a loose unzipped folder!"
echo " Path: ${TARGET_DIR_NAME}"
echo "================================================="

