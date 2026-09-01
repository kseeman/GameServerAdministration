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
    # setpriv, not runuser/su. runuser opens a PAM session and owns PID 1, and
    # on SIGTERM it tears that session down ("Session terminated, killing
    # shell...") while our shutdown_handler is still mid-sequence — the
    # broadcasts go out but saveworld never runs, so every stop silently
    # discarded world state since the last autosave. setpriv just drops
    # privileges and exec's, leaving this script as PID 1 to handle SIGTERM.
    #
    # The tradeoff: setpriv builds no login environment, so HOME/USER must be
    # set by hand or wine reaches for /root/.wine and mcrcon is looked up under
    # the wrong home.
    export HOME=/home/steam USER=steam LOGNAME=steam
    exec setpriv --reuid=steam --regid=steam --init-groups -- "$0" "$@"
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
    local manifest="${PIXARK_DIR}/steamapps/appmanifest_${APP_ID}.acf"
    local attempt
    for attempt in 1 2 3; do
        # +app_info_update 1 is required, not optional. Without it steamcmd can
        # reach "Waiting for user info...OK" and then fail with
        #   ERROR! Failed to install app '824360' (Missing configuration)
        # because it has no cached app info to resolve the forced Windows
        # platform against — reliably so when the appmanifest is absent, which
        # is exactly the state the wedge recovery below leaves behind.
        if steamcmd +@sSteamCmdForcePlatformType windows \
            +force_install_dir "$PIXARK_DIR" \
            +login anonymous \
            +app_info_update 1 \
            +app_update "$APP_ID" validate \
            +quit; then
            return 0
        fi

        # Every time Snail publishes a new build, the appmanifest tends to wedge:
        # it records StateFlags 6 (Fully Installed | Update Required) with
        # UpdateResult 6 and BytesToDownload 0, and steamcmd then fails every
        # retry with "state is 0x6 after update job" while the newer build sits
        # there as TargetBuildID. Clearing the manifest makes steamcmd resolve
        # the depot from scratch; the installed files are kept and `validate`
        # only pulls the delta. Do this once, on the second attempt, so a plain
        # transient network failure still just retries.
        if [[ "$attempt" -eq 1 && -f "$manifest" ]] \
            && grep -q '"StateFlags"[[:space:]]*"6"' "$manifest" 2>/dev/null; then
            echo ">>> appmanifest is wedged (StateFlags 6); clearing it and retrying"
            mv -f "$manifest" "${manifest}.wedged" 2>/dev/null || rm -f "$manifest"
        fi

        echo ">>> steamcmd attempt ${attempt} failed; retrying in 5s"
        sleep 5
    done
    echo ">>> steamcmd failed after 3 attempts"
    return 1
}

SERVER_EXE="${PIXARK_DIR}/ShooterGame/Binaries/Win64/PixARKServer.exe"

# A failed *install* is fatal — there is nothing to run. A failed *update* is
# not: an existing install still boots, and taking the server down over a
# transient Steam problem turns a Valve-side hiccup into an outage. This is not
# hypothetical — a wedged appmanifest (StateFlags 6 / UpdateResult 6) put this
# container into a 12-deep restart loop with a perfectly good install on disk.
if [[ ! -f "$SERVER_EXE" ]]; then
    echo ">>> PixARKServer.exe missing; running initial install"
    install_or_update_server || exit 1
elif [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    if ! install_or_update_server; then
        echo ">>> WARNING: steamcmd update failed, but an existing install is present."
        echo ">>> WARNING: starting the server on the installed build anyway."
        echo ">>> WARNING: if Steam has published a newer build, clients on the new"
        echo ">>> WARNING: version may be unable to connect until this is resolved."
    fi
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
gus_ini="${save_dir}/Config/WindowsServer/GameUserSettings.ini"
if [[ ! -f "$gus_ini" ]]; then
    mkdir -p "${save_dir}/Config/WindowsServer"
    printf '[SessionSettings]\r\nSessionName=%s\r\n' "$SESSIONNAME" > "$gus_ini"
elif grep -q '^SessionName=' "$gus_ini" 2>/dev/null; then
    # Rewrite the name on every start rather than only seeding a fresh volume.
    # The server persists SessionName here on first boot, so seed-only meant the
    # environment JSON could never rename an existing instance — editing
    # base_server_name or an instance description simply had no effect. The JSON
    # is the source of truth; everything else in this file is the game's and is
    # left untouched. Written with awk because the name contains characters sed
    # would treat as special, and the file uses CRLF line endings.
    awk -v name="$SESSIONNAME" '
        /^SessionName=/ { printf "SessionName=%s\r\n", name; next }
        { print }
    ' "$gus_ini" > "${gus_ini}.tmp" && mv -f "${gus_ini}.tmp" "$gus_ini"
fi

# --- Preset [ServerSettings] ---
#
# PIXARK_SERVER_SETTINGS_B64 is base64 of newline-separated Key=Value pairs
# built from the active preset's game_settings. They are merged into
# GameUserSettings.ini here, on every start, for two reasons:
#
#   1. PixARK has no live config reload. The binary has no dynamicconfig /
#      ForceUpdateDynamicConfig machinery (unlike ARK) and RCON exposes no
#      reload command, so [ServerSettings] is only read at process start.
#      Config swaps are necessarily cold.
#   2. GameUserSettings.ini is widely reported to reset itself across restarts.
#      Re-applying every start makes the preset authoritative regardless.
#
# Only keys named by the preset are touched; the rest of the game's file is
# preserved, including its CRLF line endings.
apply_server_settings() {
    local ini="$1" want_file="$2" remove_file="$3"
    awk -v sf="$want_file" -v rf="$remove_file" '
        BEGIN {
            while ((getline line < sf) > 0) {
                if (line == "") continue
                eq = index(line, "=")
                if (eq == 0) continue
                k = substr(line, 1, eq - 1)
                want[k] = substr(line, eq + 1)
                order[++n] = k
            }
            close(sf)
            while ((getline line < rf) > 0) {
                if (line != "") drop[line] = 1
            }
            close(rf)
        }
        function flush_remaining(   i, k) {
            for (i = 1; i <= n; i++) {
                k = order[i]
                if (!(k in applied)) { printf "%s=%s\r\n", k, want[k]; applied[k] = 1 }
            }
        }
        /^\[/ {
            if (in_ss) { flush_remaining(); in_ss = 0 }
            if ($0 ~ /^\[ServerSettings\]/) { in_ss = 1; seen_ss = 1 }
            print; next
        }
        {
            if (in_ss) {
                eq = index($0, "=")
                if (eq > 0) {
                    k = substr($0, 1, eq - 1)
                    if (k in want) { printf "%s=%s\r\n", k, want[k]; applied[k] = 1; next }
                    # Previously set by a preset, not set by this one: drop the
                    # line so the game falls back to its own built-in default.
                    if (k in drop) next
                }
            }
            print
        }
        END {
            if (in_ss) flush_remaining()
            else if (!seen_ss && n > 0) { printf "[ServerSettings]\r\n"; flush_remaining() }
        }
    ' "$ini"
}

# The state file records exactly which Key=Value pairs the previous start
# applied. Without it a swap could only ever add keys: going from a preset with
# overrides back to one without would leave the old multipliers in place, so the
# server kept running boosted rates while .state reported "default".
settings_state="${save_dir}/.pixark-applied-settings"
want_file=$(mktemp); prev_file=$(mktemp); remove_file=$(mktemp)

: > "$want_file"
if [[ -n "${PIXARK_SERVER_SETTINGS_B64:-}" ]]; then
    printf '%s' "$PIXARK_SERVER_SETTINGS_B64" | base64 -d > "$want_file" 2>/dev/null || : > "$want_file"
fi
if [[ -f "$settings_state" ]]; then cp "$settings_state" "$prev_file"; else : > "$prev_file"; fi

# Keys a previous preset set that this one does not mention. Only lines that
# actually contain '=' count, so a truncated or legacy state file is ignored
# rather than being mistaken for a setting name to revert.
comm -23 <(grep '=' "$prev_file" | cut -d= -f1 | sort -u) \
         <(grep '=' "$want_file" | cut -d= -f1 | sort -u) > "$remove_file"

if [[ -s "$want_file" || -s "$remove_file" ]]; then
    if [[ -s "$want_file" ]]; then
        echo ">>> Applying $(grep -c '=' "$want_file") preset setting(s) to [ServerSettings]"
        # awk, not sed: the decoded payload has no trailing newline, and awk's
        # print always terminates the record so the next log line starts cleanly.
        awk '{ print "        " $0 }' "$want_file"
    fi
    if [[ -s "$remove_file" ]]; then
        echo ">>> Reverting $(grep -c . "$remove_file") setting(s) to PixARK defaults"
        awk '{ print "        " $0 }' "$remove_file"
    fi

    if apply_server_settings "$gus_ini" "$want_file" "$remove_file" > "${gus_ini}.tmp"; then
        mv -f "${gus_ini}.tmp" "$gus_ini"

        # PixARK caches server multipliers in three shipped blueprint assets
        # (note the upstream typo: Sever, not Server). Deleting them is the
        # widely cited fix for "my GameUserSettings.ini changes are ignored".
        #
        # This deliberately only *reports* them rather than deleting them. They
        # are shipped game content in the install volume, which every instance in
        # an environment shares, and the only thing that puts them back is
        # `steamcmd validate` — which pixark_start_server refuses to run while
        # another instance is live. Automatic deletion would therefore strip
        # content from a shared install with no reliable restore path, to work
        # around a problem we have not actually confirmed. Clear them by hand if
        # a swap really does appear to be ignored.
        if ! cmp -s "$want_file" "$prev_file"; then
            echo ">>> Settings changed. If they appear to be ignored in game, the"
            echo ">>> client and server multiplier caches may be stale. Clear with:"
            echo ">>>   rm -f ${PIXARK_DIR}/ShooterGame/Content/Mods/CubeWorld/Blueprints/CW_SeverMultiplier_*.uasset"
            echo ">>> then stop every pixark instance in this environment and start"
            echo ">>> one, so steamcmd validate restores them. Players may need to"
            echo ">>> clear the same files in their own client install."
        fi
        cp "$want_file" "$settings_state"
    else
        echo ">>> WARNING: failed to merge preset settings; leaving the ini untouched"
        rm -f "${gus_ini}.tmp"
    fi
fi
rm -f "$want_file" "$prev_file" "$remove_file"

# Validate map name; fall back to default for anything unrecognized. Keep this
# in step with the .umap files actually shipped in
# ShooterGame/Content/**/Maps — a name that is not on this list is silently
# swapped for CubeWorld_Light, which looks like "my map setting is ignored".
#   CubeWorld_Light    base cube world
#   SkyPiea_light      Skyward
#   Underground_Light  Terracrypt (paid DLC, Steam app 3747200) — players must
#                      own the DLC to join, though the server content ships in
#                      the dedicated-server package (824360).
case "$MAP" in
    CubeWorld_Light|SkyPiea_light|Underground_Light) ;;
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
# -NoBattlEye, with the trailing 'e'. UE4 silently ignores unrecognised flags,
# so the long-standing typo "-NoBattlEy" left BattlEye ENABLED — the server
# still starts and still lists in the Steam browser, but every client connect
# fails because BattlEye cannot initialise under Wine. Compare a working April
# run (-NoBattlEye) against the broken ones (-NoBattlEy) in Saved/Logs.
declare -a FLAGS=(-NoBattlEye -NoHangDetection)
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
