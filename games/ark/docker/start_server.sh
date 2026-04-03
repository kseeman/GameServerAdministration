#!/bin/bash

# ARK Survival Ascended Dedicated Server Startup Script
# Runs the Windows server binary through GE-Proton with Xvfb virtual display

set -e

ARK_DIR="/home/ark/arkserver"
STEAMCMD_DIR="/home/ark/steamcmd"
PROTON_DIR="/home/ark/proton"
SERVER_BINARY="$ARK_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe"

# Default environment variables
MAP="${MAP:-TheIsland_WP}"
SESSION_NAME="${SESSION_NAME:-ARK Server}"
MAX_PLAYERS="${MAX_PLAYERS:-70}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
RCON_PORT="${RCON_PORT:-27020}"
RCON_ENABLED="${RCON_ENABLED:-true}"
UPDATE_ON_BOOT="${UPDATE_ON_BOOT:-false}"

echo "=== ARK Survival Ascended Dedicated Server ==="
echo "  Map: $MAP"
echo "  Session: $SESSION_NAME"
echo "  Max Players: $MAX_PLAYERS"
echo "  RCON Port: $RCON_PORT"
echo "  RCON Enabled: $RCON_ENABLED"
echo "  Update on Boot: $UPDATE_ON_BOOT"

# --- Optional: Update server on boot ---
if [[ "$UPDATE_ON_BOOT" == "true" ]]; then
    echo "Checking for ARK server updates..."
    "$STEAMCMD_DIR/steamcmd.sh" \
        +force_install_dir "$ARK_DIR" \
        +login anonymous \
        +app_info_update 1 \
        +app_update 2430930 \
        +quit || echo "WARNING: Update check failed, continuing with installed version."
fi

# Verify server binary exists
if [[ ! -f "$SERVER_BINARY" ]]; then
    echo "ERROR: Server binary not found at $SERVER_BINARY"
    echo "The image may not have been built correctly."
    exit 1
fi

# --- Ensure config directories exist in the mounted volume ---
# The volume may be freshly created with root ownership; config injection
# already creates Config/WindowsServer, but we need Logs too.
# These may fail if the volume has wrong permissions — not fatal.
mkdir -p "$ARK_DIR/ShooterGame/Saved/Config/WindowsServer" 2>/dev/null || true
mkdir -p "$ARK_DIR/ShooterGame/Saved/Logs" 2>/dev/null || true

# --- Start Xvfb virtual display ---
# Proton/Wine requires a display even in headless mode
echo "Starting Xvfb virtual display..."
Xvfb :0 -screen 0 1024x768x16 &
XVFB_PID=$!
sleep 1

if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "WARNING: Xvfb on :0 failed, trying :1..."
    Xvfb :1 -screen 0 1024x768x16 &
    XVFB_PID=$!
    export DISPLAY=:1.0
    sleep 1
fi

echo "Xvfb running on $DISPLAY (PID: $XVFB_PID)"

# --- Find Proton executable ---
PROTON_EXEC=""
if [[ -x "$PROTON_DIR/proton" ]]; then
    PROTON_EXEC="$PROTON_DIR/proton"
elif [[ -x "/home/ark/GE-Proton-Current/proton" ]]; then
    PROTON_EXEC="/home/ark/GE-Proton-Current/proton"
else
    echo "ERROR: GE-Proton not found. Cannot run ARK SA without Proton."
    exit 1
fi
echo "Using Proton: $PROTON_EXEC"

# --- Build server launch parameters ---
# ARK SA uses URL-style params for map/session and dash flags for ports/engine options
# Port flags use -port= syntax per ARK SA documentation
MAP_PARAMS="${MAP}?listen"
MAP_PARAMS="${MAP_PARAMS}?SessionName=${SESSION_NAME}"

if [[ -n "$ADMIN_PASSWORD" ]]; then
    MAP_PARAMS="${MAP_PARAMS}?ServerAdminPassword=${ADMIN_PASSWORD}"
fi

if [[ -n "$SERVER_PASSWORD" ]]; then
    MAP_PARAMS="${MAP_PARAMS}?ServerPassword=${SERVER_PASSWORD}"
fi

if [[ "$RCON_ENABLED" == "true" ]]; then
    MAP_PARAMS="${MAP_PARAMS}?RCONEnabled=True?RCONPort=${RCON_PORT}"
fi

SERVER_FLAGS="-server -log -NoBattlEye -servergamelog"
SERVER_FLAGS="${SERVER_FLAGS} -port=7777 -QueryPort=27015"
SERVER_FLAGS="${SERVER_FLAGS} -WinLiveMaxPlayers=${MAX_PLAYERS}"

STARTUP_PARAMS="${MAP_PARAMS}"

echo "Launching ARK SA through Proton..."
echo "  Binary: $SERVER_BINARY"
echo "  Params: $STARTUP_PARAMS $SERVER_FLAGS"

# --- Cleanup on exit ---
cleanup() {
    echo "Shutting down..."
    kill $XVFB_PID 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

# --- Launch ARK through Proton ---
exec "$PROTON_EXEC" run "$SERVER_BINARY" "$STARTUP_PARAMS" $SERVER_FLAGS
