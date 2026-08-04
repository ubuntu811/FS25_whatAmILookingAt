#!/usr/bin/env bash

# Exit immediately if any command fails
set -e

# Define source archive and destination folder name
MOD_NAME="FS25_whatAmILookingAt"
SOURCE_ZIP="build/${MOD_NAME}.zip"
TARGET_DIR_NAME="$HOME/fs25/mods/${MOD_NAME}"

echo "=== Starting FS25 Hot-Reload Deployment Pipeline ==="

# 1. Always rebuild from current source - a "build if missing" check here
# caused IW's deploy.sh to silently redeploy a stale pre-session zip for an
# entire session once, since the zip already existed on disk and this
# never re-ran build.sh. Same copy-pasted script here, same fix.
# build/build.sh, not ./build.sh - this script, like build.sh itself
# (references top-level scripts/, modDesc.xml directly), assumes it's run
# from the repo root, e.g. `bash build/deploy.sh`.
build/build.sh

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

