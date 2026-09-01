# PixARK

PixARK has no native Linux dedicated server — Snail Games only ever shipped Windows
binaries — so the server runs under Wine. Everything below follows from that.

## Image

`games/pixark/docker/Dockerfile` builds `pixark-server:latest` from `ubuntu:24.04`
plus Wine from WineHQ's own apt repo, pinned to an exact version.

We deliberately do **not** inherit from an upstream PixARK image. Every community
option is the same wine+steamcmd trick and all of them are abandoned:

| Option | State |
| --- | --- |
| `silentmecha/pixark-linux` | last commit 2023-01-10; game files baked in at that date |
| `silentmecha/steamcmd-wine` | still rebuilt (2026-03-03) but ships Ubuntu's archive Wine 9.0 |
| `rainbowdashobard/docker-steamcmd-pixark` | self-described "(not working)" |

Two consequences shape the Dockerfile:

- **PixARK is installed at runtime via steamcmd** into the `pixark-install-<env>`
  volume, never baked into an image layer. We track upstream releases instead of
  freezing at an image build date. Same pattern as the ARK plugin's use of
  `acekorneya/asa_server`.
- **Wine comes from WineHQ, not Ubuntu.** Ubuntu 24.04 ships Wine 9.0. Wine 11.0
  brings NTSYNC (in-kernel Windows sync primitives rather than futex emulation)
  and a stable WoW64, both of which matter for a heavily threaded UE4 server.
  Bump `WINE_VERSION` in the Dockerfile to move it; `WINE_BRANCH=staging` carries
  more game-oriented patches but is a moving target.

The image also installs `mcrcon` at `/home/steam/mcrcon/mcrcon`. The entrypoint's
graceful-shutdown handler (broadcast → `saveworld` → `doExit`) has always called
it, but the old base image never actually shipped it, so every stop silently fell
through to `SIGINT` without saving. It is a real binary now.

`steam` is **UID 1001**, not 1000. That is not a preference — it is what the
existing `pixark-vol-*` volumes are owned by and what the `atmoz/sftp` sidecar
chowns its mount to.

## Host networking — why the terrain used to be missing

**Symptom:** the world loads and players connect, but there is no terrain. You
spawn floating above nothing.

**Cause:** PixARK serves voxel terrain over a channel separate from the UE4 actor
replication on the game port. Under a Docker bridge network the server logs

```
LogInit: WinSock: I am c169d1e48adb (172.19.0.3:0)
```

and hands clients *that* address for the terrain data session. `172.19.0.3` is
unroutable from outside the host, so the client connects, spawns, and replicates
entities fine over the NAT'd UDP game port — while the terrain session never
establishes and no chunks ever arrive.

The old logs show this precisely: the cube server starts cleanly, loads a 333MB
`terrain.db` and thousands of chunks (`DB_LoadAllChunkUids ... succeed`,
`load 1141 chunks use 0.052631 seconds`), and saves on schedule — yet not one
`UBrickWorldDataSenssionComponent` client-session line is ever written. The
terrain was always there. It just never reached anyone.

**Fix:** `network_mode: host` for the game server. The server then sees the host's
real address and every port binds directly, with no NAT in the path. This also
satisfies upstream's warning that *"PixARK does not like port remapping"*.

This is safe here because the per-instance port offset model already puts every
instance on distinct ports — there is no longer a network namespace separating
them, so those offsets are load-bearing rather than cosmetic. Current allocation:

| Env | Ports | Nearest neighbour |
| --- | --- | --- |
| production | 27015–27018 (`main`) | palworld query at 27019 |
| staging | 47015–47018 (`test`) | nothing else in 47xxx |

Adding pixark instances is fine (offset 10 each), but production has only ~4
slots before it runs into ARK's query port at 27030. Check
`games/*/environments/*.json` before adding one.

The SFTP sidecar stays on the default bridge network with a normal port mapping —
it is plain TCP with no address-advertisement problem.

## Memory

PixARK wants 16GB minimum and has long-standing memory-leak reports. The old
caps — 8g production, 4g staging — meant a slow leak ended in an OOM kill rather
than a visible crash, which reads to players as an unexplained restart.

| Env | `memory_limit` | Was |
| --- | --- | --- |
| production | 16g | 8g |
| staging | 8g | 4g |

Staging is deliberately *not* 16g. These are caps, not reservations, but the box
has 32GB and staging is a 4-player test instance — giving both environments 16g
would let a leaking staging server starve production. Raise it only if staging
starts getting OOM-killed.

## Presets and config swap

**Swaps are always cold, and cannot be otherwise.** PixARK has none of ARK's
dynamic-config machinery — `dynamicconfig`, `CustomDynamicConfigUrl`,
`ForceUpdateDynamicConfig` and `UseDynamicConfig` return zero matches in
`PixARKServer.exe` — and RCON offers no reload verb, only `Broadcast`,
`SaveWorld`, `DoExit`, `ListPlayers`, `KickPlayer`, `BanPlayer`, `ServerChat`
and `cheat *`. The only settings changeable at runtime are `SetTimeOfDay` and
`cheat SetMessageOfTheDay`. `[ServerSettings]` is read once, at process start.

A preset's `game_settings` is a map of real `GameUserSettings.ini`
`[ServerSettings]` key names:

```json
"game_settings": {
  "HarvestAmountMultiplier": 2.0,
  "XPMultiplier": 2.0,
  "TamingSpeedMultiplier": 3.0
}
```

`additional_args` is the one special key: it is argv (URL-style `?Arg=Value`
flags), not config, so it stays on the command line. Presets inherit via
`metadata.inherits`, naming the parent *file* (`"default.json"`), and should
inherit only from `default`.

The flow is: `pixark_start_server` resolves the preset, splits `additional_args`
off, base64-encodes the remaining `Key=Value` lines into
`PIXARK_SERVER_SETTINGS_B64` (base64 because the values would otherwise have to
survive envsubst and the compose environment intact), and the entrypoint merges
them into `[ServerSettings]` on **every** start. Re-applying every start is
deliberate: `GameUserSettings.ini` is widely reported to reset itself across
restarts, and this makes the preset authoritative regardless.

**The entrypoint tracks what it applied**, in `.pixark-applied-settings` beside
the save data. Without that, swaps could only ever add keys — going from
`boosted` back to `default` would leave the boosted multipliers in place while
`.state` cheerfully reported `default`. Keys a previous preset set that the
current one does not mention are deleted from the ini so the game falls back to
its own built-in defaults. Booleans are written `True`/`False`; PixARK will not
parse JSON's lowercase form.

Only keys the preset names are touched. The game's own `[ServerSettings]`
entries, the other sections, and the file's CRLF line endings are all preserved.

`pixark_validate_preset` warns — never errors — about keys absent from
`PIXARK_KNOWN_SETTINGS`, a snapshot of PixARK's shipped
`DefaultGameUserSettings.ini` (build 25052834). It catches `XPMultipler` without
rejecting a key a newer build has added. Regenerate it with:

```bash
docker run --rm -v pixark-install-<env>:/v alpine sh -c \
  'grep -oE "^[A-Za-z_]+=" /v/ShooterGame/Config/DefaultGameUserSettings.ini | tr -d = | sort -u'
```

### The multiplier cache

PixARK caches server multipliers in three shipped blueprints (note the upstream
typo — `Sever`, not `Server`):

```
ShooterGame/Content/Mods/CubeWorld/Blueprints/CW_SeverMultiplier_PVE.uasset
                                              CW_SeverMultiplier_PVP.uasset
                                              CW_SeverMultiplier_PVPforever.uasset
```

Deleting them is the widely cited fix for "my `GameUserSettings.ini` changes are
ignored". The entrypoint **reports** them when the applied settings change but
deliberately does not delete them, because deleting them turned out to be much
harder to undo than expected:

- They are shipped content in the install volume, which every instance in an
  environment shares.
- With the files gone, the server stops loading the `CW_SeverMultiplier_*`
  classes altogether — measured, not assumed.
- **A plain `steamcmd app_update ... validate` does not put them back.** It
  reports `Success! App '824360' fully installed` and leaves them missing. The
  Steam depot manifests in the install root do not index CubeWorld content at
  all, so validate has nothing to compare against.

Recovering them needs a forced re-resolve — delete the appmanifest first, then
validate, with every instance in the environment stopped:

```bash
docker run --rm -v pixark-install-<env>:/v alpine \
  rm -f /v/steamapps/appmanifest_824360.acf
# then start one instance; the entrypoint's retry loop handles the
# "Missing configuration" that the first attempt after this reliably hits
```

So clear the cache by hand only if a swap genuinely appears to be ignored, and
expect a full 3GB re-verify to undo it. Players may need to clear the same files
in their own client install.

## Wine noise in the logs

A healthy headless start still prints these. They are cosmetic — there is no
display server or GPU in the container, and the dedicated server does not need one:

```
err:winediag:nodrv_CreateWindow Application tried to create a window...
err:vulkan:vulkan_init_once Failed to load libvulkan.so.1
err:systray:initialize_systray Could not create tray window
fixme:actctx:parse_depend_manifests Could not find dependent assembly ...
error: XDG_RUNTIME_DIR is invalid or not set in the environment.
```

Judge a start by the game's own log instead — `Saved/Logs/ShooterGame.log` should
reach `Game Engine Initialized`, `GameNetDriver ... listening on port <game port>`
and `RCON Server Sockets is ready`.

## ntsync

Wine 11 uses `/dev/ntsync` when the host kernel provides it (6.14+), which is a
significant win for a threaded UE4 server. `pixark_start_server` maps the device
**only when it exists** — naming a missing device is a hard container-start
failure, and the server runs fine on the futex fallback. Check with
`ls -l /dev/ntsync` on the server; the start log says which path it took.

## Deployment

Per the root CLAUDE.md, deployment is manual. `pixark_start_server` calls
`pixark_build_image` — an unconditional `docker build` — on every start, so a
changed Dockerfile is picked up automatically via the layer cache. No separate
build step is needed:

```bash
git pull
./scripts/core/server-manager.sh stop  --game pixark --instance main --env production
./scripts/core/server-manager.sh start --game pixark --instance main --env production
```

The first start after a Wine bump takes a few extra minutes while the new layers
build. Note that `start` must follow a `stop` — switching to host networking
changes the container's network config, which a restart alone will not apply.
World data lives in the volumes and is unaffected.

The Wine pin makes builds reproducible, but it also means Wine only moves when
someone edits `WINE_VERSION`. That is the intent: a game server should not
silently change Wine version on an unrelated redeploy.
