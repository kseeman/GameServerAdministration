#!/bin/bash
# Smalland dedicated server entrypoint.
# Installs/updates the server via steamcmd on first run (or when UPDATE_ON_START=true),
# translates env vars into Smalland's URL-style CLI args, and exec's the server binary.
set -euo pipefail

SMALLAND_DIR="${SMALLAND_DIR:-/home/steam/smalland}"

install_or_update_server() {
    echo ">>> steamcmd: installing/updating Smalland (app 808040) into ${SMALLAND_DIR}"
    steamcmd.sh \
        +force_install_dir "$SMALLAND_DIR" \
        +login anonymous \
        +app_update 808040 validate \
        +quit
}

if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    install_or_update_server
elif [[ ! -f "${SMALLAND_DIR}/SMALLANDServer.sh" ]]; then
    echo ">>> SMALLANDServer.sh missing; running initial install"
    install_or_update_server
fi

# Defaults (mirror /opt/games/smalland/start-server.sh)
SERVER_NAME="${SERVER_NAME:-Smalland Server}"
WORLD_NAME="${WORLD_NAME:-World}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
FRIENDLY_FIRE="${FRIENDLY_FIRE:-0}"
PEACEFUL_MODE="${PEACEFUL_MODE:-0}"
KEEP_INVENTORY="${KEEP_INVENTORY:-0}"
NO_DETERIORATION="${NO_DETERIORATION:-0}"
TAMED_CREATURES_IMMORTAL="${TAMED_CREATURES_IMMORTAL:-0}"
PRIVATE="${PRIVATE:-0}"
CROSSPLAY="${CROSSPLAY:-1}"
LENGTH_OF_DAY_SECONDS="${LENGTH_OF_DAY_SECONDS:-1800}"
LENGTH_OF_SEASON_SECONDS="${LENGTH_OF_SEASON_SECONDS:-10800}"
CREATURE_HEALTH_MODIFIER="${CREATURE_HEALTH_MODIFIER:-100}"
CREATURE_DAMAGE_MODIFIER="${CREATURE_DAMAGE_MODIFIER:-100}"
CREATURE_RESPAWN_RATE_MODIFIER="${CREATURE_RESPAWN_RATE_MODIFIER:-100}"
RESOURCE_RESPAWN_RATE_MODIFIER="${RESOURCE_RESPAWN_RATE_MODIFIER:-100}"
CREATURE_SPAWN_CHANCE_MODIFIER="${CREATURE_SPAWN_CHANCE_MODIFIER:-100}"
CRAFTING_TIME_MODIFIER="${CRAFTING_TIME_MODIFIER:-100}"
CRAFTING_FUEL_MODIFIER="${CRAFTING_FUEL_MODIFIER:-100}"
STORM_FREQUENCY_MODIFIER="${STORM_FREQUENCY_MODIFIER:-100}"
NOURISHMENT_LOSS_MODIFIER="${NOURISHMENT_LOSS_MODIFIER:-100}"
FALL_DAMAGE_MODIFIER="${FALL_DAMAGE_MODIFIER:-100}"
SERVER_PORT="${SERVER_PORT:-7777}"
EOS_DEPLOYMENT_ID="${EOS_DEPLOYMENT_ID:-}"
EOS_CLIENT_ID="${EOS_CLIENT_ID:-}"
EOS_CLIENT_SECRET="${EOS_CLIENT_SECRET:-}"
EOS_PRIVATE_KEY="${EOS_PRIVATE_KEY:-}"

# Unreal URL — passed as a single argv entry so embedded quotes/spaces survive.
URL="/Game/Maps/WorldGame/WorldGame_Smalland"
URL+="?SERVERNAME=\"${SERVER_NAME}\""
URL+="?WORLDNAME=\"${WORLD_NAME}\""
[[ -n "$SERVER_PASSWORD" ]] && URL+="?PASSWORD=\"${SERVER_PASSWORD}\""
[[ "$FRIENDLY_FIRE" = 1 ]] && URL+="?FRIENDLYFIRE"
[[ "$PEACEFUL_MODE" = 1 ]] && URL+="?PEACEFULMODE"
[[ "$KEEP_INVENTORY" = 1 ]] && URL+="?KEEPINVENTORY"
[[ "$NO_DETERIORATION" = 1 ]] && URL+="?NODETERIORATION"
[[ "$TAMED_CREATURES_IMMORTAL" = 1 ]] && URL+="?TAMEDCREATURESIMMORTAL"
[[ "$PRIVATE" = 1 ]] && URL+="?PRIVATE"
[[ "$CROSSPLAY" = 1 ]] && URL+="?CROSSPLAY"
URL+="?lengthofdayseconds=${LENGTH_OF_DAY_SECONDS}"
URL+="?lengthofseasonseconds=${LENGTH_OF_SEASON_SECONDS}"
URL+="?creaturehealthmodifier=${CREATURE_HEALTH_MODIFIER}"
URL+="?creaturedamagemodifier=${CREATURE_DAMAGE_MODIFIER}"
URL+="?creaturerespawnratemodifier=${CREATURE_RESPAWN_RATE_MODIFIER}"
URL+="?resourcerespawnratemodifier=${RESOURCE_RESPAWN_RATE_MODIFIER}"
URL+="?creaturespawnchancemodifier=${CREATURE_SPAWN_CHANCE_MODIFIER}"
URL+="?craftingtimemodifier=${CRAFTING_TIME_MODIFIER}"
URL+="?craftingfuelmodifier=${CRAFTING_FUEL_MODIFIER}"
URL+="?stormfrequencymodifier=${STORM_FREQUENCY_MODIFIER}"
URL+="?nourishmentlossmodifier=${NOURISHMENT_LOSS_MODIFIER}"
URL+="?falldamagemodifier=${FALL_DAMAGE_MODIFIER}"

declare -a FLAGS=(
    "-ini:Engine:[EpicOnlineServices]:DeploymentId=${EOS_DEPLOYMENT_ID}"
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientId=${EOS_CLIENT_ID}"
    "-ini:Engine:[EpicOnlineServices]:DedicatedServerClientSecret=${EOS_CLIENT_SECRET}"
)
[[ -n "$EOS_PRIVATE_KEY" ]] && FLAGS+=("-ini:Engine:[EpicOnlineServices]:DedicatedServerPrivateKey=${EOS_PRIVATE_KEY}")
FLAGS+=(
    "-port=${SERVER_PORT}"
    "-NOSTEAM"
    "-log"
)

cd "$SMALLAND_DIR"
echo ">>> Starting Smalland server"
echo "    URL:   $URL"
echo "    Flags: ${FLAGS[*]}"
exec ./SMALLANDServer.sh "$URL" "${FLAGS[@]}"
