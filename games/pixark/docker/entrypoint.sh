#!/bin/bash
# PixARK dedicated server entrypoint.
# Runs steamcmd on start (or when the install is missing) to keep the server
# binaries current, then translates env vars into the URL-style CLI args
# PixARK (Unreal-based) expects, and exec-wine's the server binary.
#
# Mirrors the logic of upstream silentmecha/pixark-linux's entry.sh but adds
# a steamcmd update step so we don't get stuck on whatever PixARK version
# the upstream image was last built against.

PIXARK_DIR="${PIXARK_DIR:-/home/steam/PixARK-dedicated}"

# First pass: run as root to fix volume ownership, then drop to steam user.
# Docker named volumes mount root:root by default; without this, steamcmd
# fails with a misleading "Missing configuration" error because the steam
# user can't write to /home/steam/PixARK-dedicated.
if [[ "$EUID" -eq 0 ]]; then
    mkdir -p "$PIXARK_DIR" /home/steam/.steam /home/steam/.wine
    chown -R steam:steam "$PIXARK_DIR" /home/steam/.steam /home/steam/.wine 2>/dev/null || true
    exec runuser -u steam -- "$0" "$@"
fi

set -uo pipefail

STEAM_SAVEDIR="${PIXARK_DIR}/ShooterGame/Saved"
APP_ID=824360

serverPID=""

# Graceful shutdown: broadcast → saveworld → doExit via RCON, then SIGINT.
shutdown_handler() {
    if [[ -n "$serverPID" ]] && kill -0 "$serverPID" 2>/dev/null; then
        echo ">>> SIGTERM received — graceful shutdown via RCON"
        "${HOME}/mcrcon/mcrcon" -H 127.0.0.1 -P "${RCONPORT:-27017}" -p "${SERVERADMINPASSWORD:-ChangeMe}" -w 1 \
            'broadcast Warning!!\nServer stopping in 5' \
            'broadcast Warning!!\nServer stopping in 4' \
            'broadcast Warning!!\nServer stopping in 3' \
            'broadcast Warning!!\nServer stopping in 2' \
            'broadcast Warning!!\nServer stopping in 1' \
            'saveworld' \
            'doExit' 2>/dev/null || true
        kill -SIGINT "$serverPID" 2>/dev/null || true
    fi
}
trap shutdown_handler SIGTERM SIGINT

install_or_update_server() {
    # Warm up steamcmd so it absorbs any self-update and restart before we ask
    # it to do real work. Without this, a cold start hits "Missing
    # configuration" because the self-update happens mid-command-stream.
    steamcmd +quit >/dev/null 2>&1 || true

    echo ">>> steamcmd: installing/updating PixARK (app ${APP_ID}) into ${PIXARK_DIR}"
    # PixARK is a Windows-only game; force the Windows platform type before
    # +login so steamcmd pulls the Windows depot on this Linux host.
    local attempt
    for attempt in 1 2 3; do
        if steamcmd +@sSteamCmdForcePlatformType windows \
            +force_install_dir "$PIXARK_DIR" \
            +login anonymous \
            +app_update "$APP_ID" validate \
            +quit; then
            return 0
        fi
        echo ">>> steamcmd attempt ${attempt} failed; retrying in 5s"
        sleep 5
    done
    echo ">>> steamcmd failed after 3 attempts — aborting so we don't run the server with a broken install"
    return 1
}

# Update on start, or run initial install if the binary is missing.
if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    install_or_update_server || exit 1
elif [[ ! -f "${PIXARK_DIR}/ShooterGame/Binaries/Win64/PixARKServer.exe" ]]; then
    echo ">>> PixARKServer.exe missing; running initial install"
    install_or_update_server || exit 1
fi

# Final sanity: if the binary still isn't there, there's no point proceeding.
if [[ ! -f "${PIXARK_DIR}/ShooterGame/Binaries/Win64/PixARKServer.exe" ]]; then
    echo ">>> PixARKServer.exe missing after install attempt — aborting"
    exit 1
fi

# First-run wine configuration.
if [[ ! -d "${HOME}/.wine" ]]; then
    echo ">>> Configuring wine for the first time"
    wine wineboot --init 2>&1 | grep -v "err:winediag:nodrv_CreateWindow\|err:ole:\|err:systray\|err:ntlm" || true
fi

# --- Compose launch args (mirrors upstream entry.sh logic) ---
MAP="${MAP:-CubeWorld_Light}"
SESSIONNAME="${SESSIONNAME:-PixARK Server}"
SERVERPASSWORD="${SERVERPASSWORD:-}"
SERVERADMINPASSWORD="${SERVERADMINPASSWORD:-ChangeMe}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"
QUERYPORT="${QUERYPORT:-27016}"
RCONPORT="${RCONPORT:-27017}"
CUBEPORT="${CUBEPORT:-27018}"
RCONENABLED="${RCONENABLED:-True}"
CULTUREFORCOOKING="${CULTUREFORCOOKING:-en}"
CUBEWORLD="${CUBEWORLD:-cubeworld}"
MAPSEED="${MAPSEED:-}"
CLUSTERID="${CLUSTERID:-}"
ALTSAVEDIRECTORYNAME="${ALTSAVEDIRECTORYNAME:-}"
ADDITIONAL_ARGS="${ADDITIONAL_ARGS:-}"

# Seed GameUserSettings.ini with the session name if this is a fresh volume.
if [[ -n "$ALTSAVEDIRECTORYNAME" ]]; then
    save_dir="${STEAM_SAVEDIR}/${ALTSAVEDIRECTORYNAME}"
else
    save_dir="$STEAM_SAVEDIR"
fi
if [[ ! -f "${save_dir}/Config/WindowsServer/GameUserSettings.ini" ]]; then
    mkdir -p "${save_dir}/Config/WindowsServer"
    printf '[SessionSettings]\r\nSessionName=%s\r\n' "$SESSIONNAME" \
        > "${save_dir}/Config/WindowsServer/GameUserSettings.ini"
fi

# Validate map name; fall back to default for anything unrecognized.
case "$MAP" in
    CubeWorld_Light|SkyPiea_light) ;;
    *) echo ">>> Unknown map '$MAP' — defaulting to CubeWorld_Light"; MAP="CubeWorld_Light" ;;
esac

# Build the ?-separated URL parameters.
url="${MAP}?listen"
if [[ -n "$ALTSAVEDIRECTORYNAME" ]]; then
    url="${url}?AltSaveDirectoryName=${ALTSAVEDIRECTORYNAME}"
fi
if [[ -n "$SERVERPASSWORD" ]]; then
    url="${url}?ServerPassword=${SERVERPASSWORD}"
fi
if [[ -n "$SERVERADMINPASSWORD" ]]; then
    url="${url}?ServerAdminPassword=${SERVERADMINPASSWORD}?RCONEnabled=${RCONENABLED}?RCONPort=${RCONPORT}"
else
    url="${url}?RCONEnabled=False"
fi
url="${url}?MaxPlayers=${MAXPLAYERS}?CULTUREFORCOOKING=${CULTUREFORCOOKING}"

# Build flag arguments (each as its own argv entry).
declare -a FLAGS=(-NoBattlEy -NoHangDetection)
[[ -n "$ALTSAVEDIRECTORYNAME" ]] && FLAGS+=(-ConfigsUseAltDir)
[[ -n "$MAPSEED" ]] && FLAGS+=("-Seed=${MAPSEED}")
[[ -n "$CLUSTERID" ]] && FLAGS+=("-clusterid=${CLUSTERID}")
FLAGS+=(
    "-Port=${PORT}"
    "-QueryPort=${QUERYPORT}"
    "-RCONPort=${RCONPORT}"
    "-CubePort=${CUBEPORT}"
    "-cubeworld=${CUBEWORLD}"
    -server
    -log
)

# ADDITIONAL_ARGS is free-form space-separated; word-split intentionally.
if [[ -n "$ADDITIONAL_ARGS" ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=($ADDITIONAL_ARGS)
    FLAGS+=("${EXTRA_ARGS[@]}")
fi

cd "$PIXARK_DIR"
echo ">>> Starting PixARK server"
echo "    URL:   $url"
echo "    Flags: ${FLAGS[*]}"

# Background + wait so the trap can fire before the process dies.
wine "${PIXARK_DIR}/ShooterGame/Binaries/Win64/PixARKServer.exe" "$url" "${FLAGS[@]}" &
serverPID=$!
wait $serverPID
