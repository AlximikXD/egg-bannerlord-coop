# Bannerlord Coop: Pelican egg and server image

Pelican egg and Docker image for a **Mount & Blade II: Bannerlord** co-op
campaign server, running the Windows dedicated build under Wine.

No game files are baked in. steamcmd downloads workshop item `3770450698` into
the server volume on boot, so every operator fetches their own entitled copy.

## What is in here

| File | What it is |
| --- | --- |
| [`egg-bannerlord-coop.json`](egg-bannerlord-coop.json) | The egg. Import this in the panel. |
| [`Dockerfile`](Dockerfile) | The yolk, built on the official Pelican wine yolk. |
| [`start.sh`](start.sh) | Boot script: steamcmd, Wine prefix, server config, launch. |
| [`player_count_api.py`](player_count_api.py) | Read-only HTTP API for the current player count. |
| [`compose.yaml`](compose.yaml) | Runs the same image with no panel. |

Published image `ghcr.io/geofmigliacci/bannerlord-coop:latest`, also tagged per
commit sha. amd64 only.

## Requirements

- A Steam account that owns Bannerlord (app `261550`). Paid apps refuse
  anonymous workshop downloads, so there is no credential-free path.
- Two consecutive UDP allocations. Clients join on the first, the mod also uses
  the second.
- One TCP allocation for the player-count API (default port `4202`).
- About 9 GB of disk: ~6 GB of game files plus a 1.6 GB Wine prefix, both built
  on first boot.

## Install on Pelican

1. Admin, Eggs, Import Egg: upload `egg-bannerlord-coop.json`.
2. Create a server with two consecutive UDP allocations and a TCP allocation on
   port `4202` (or the configured `PLAYER_COUNT_PORT`).
3. Set **Steam username**. Leave **Steam password** empty.
4. Start it and watch the console. steamcmd asks for the password, then Steam
   Guard. A mobile authenticator is a push to approve, email codes are typed in.
5. The first start downloads about 6 GB. steamcmd then caches a token for
   months, so later starts are unattended.

## Run without a panel

```sh
cp .env.example .env   # fill in STEAM_USERNAME
docker compose up      # approve the Steam Guard push on your phone
```

`.env` is all you need, compose loads it and wires every variable. With an empty
`STEAM_PASSWORD` the first run needs `docker compose run --rm coop`, so the
prompt reaches your terminal.

`compose.yaml` also sets `STARTUP`, which a panel would send itself. To change
the game UDP host ports, edit the left side of those port mappings. Set
`PLAYER_COUNT_PORT` to change the HTTP API port.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `STEAM_USERNAME` | | Account that owns Bannerlord. Required. |
| `STEAM_PASSWORD` | | Optional. Prompted in the console if empty, which keeps it out of the panel database. |
| `AUTO_UPDATE` | `1` | Check Steam for a newer mod build on every start. `0` boots what is already there. |
| `WORKSHOP_MODS` | | Extra workshop item ids to load, `X,Y,Z`. See [Mods](#mods). |
| `SAVE_NAME` | `saveauto1` | World to host. A missing save is created from `default_new_game.sav`. |
| `SERVER_PASSWORD` | | Password players are prompted for. Empty means open. |
| `AUTOSAVE_MINUTES` | `5` | Minutes between autosaves. `0` disables them. |
| `PLAYER_COUNT_HOST` | `0.0.0.0` | Interface for the read-only player-count API. |
| `PLAYER_COUNT_PORT` | `4202` | TCP port for the read-only player-count API. |
| `PLAYER_COUNT_TOKEN` | | Optional bearer token for the player-count API. |

`DATA_DIR`, `STEAM_DIR` and `WINEPREFIX` are internal and stay hidden in the
panel. `ENGINE_PORT` (`7210`) and `REGION` (`EU`) set the engine's internal
custom-server arguments and are not the port players join on.

## Player-count API

The container serves `GET /player-count` over HTTP, default TCP port `4202`.
The launcher keeps the game connected to a pseudo-terminal so Pelican's console
continues to work, while also capturing output in
`data/logs/player-count-console.log`. The API reads its latest structured
`@DS@` players snapshot and returns only the count:

```json
{"numPlayers":2,"maxPlayers":null}
```

If the current server session has not emitted its startup/player snapshot yet,
the endpoint returns HTTP `503` instead of reporting a false zero. The endpoint
listens on `PLAYER_COUNT_HOST` (`0.0.0.0` by default). In Pelican, allocate the
configured `PLAYER_COUNT_PORT` as a **TCP** port. With Compose, the port is
published by default; change `PLAYER_COUNT_PORT` in `.env` to choose another.

The Discord bot can query `http://<server-host>:4202/player-count`. Set
`PLAYER_COUNT_TOKEN` to require a bearer token; requests without it receive
HTTP `401`. The token is sent over plain HTTP, so keep this port on a trusted
network or put it behind a TLS proxy.

## Mods

`WORKSHOP_MODS=3010984416,3794802607` downloads those workshop items alongside
the Coop mod and loads them. steamcmd fetches each one, `start.sh` links it into
the server's `engine/Modules` under the id its `SubModule.xml` declares, and the
module list handed to the engine becomes:

```
_MODULES_*Native*SandBoxCore*Sandbox*CoopNightly*<your mods>*DedicatedServer.Windows*_MODULES_
```

Mods load after the Coop module, in the order listed, which is what the
coop-aware ones expect: they name `CoopNightly` as a dependency. Dropping an id
unlinks that module on the next start.

Three rules decide whether a mod works here:

- **It must ship `bin/Win64_Shipping_Server`.** The dedicated server loads module
  code from there, never from `Win64_Shipping_Client`. A client-only mod is
  listed and its XML applies, but none of its code runs.
- **Mods needing `Bannerlord.Harmony` do not work yet.** Coop bundles its own
  MonoMod; giving Harmony a server build makes Coop's `GameInterface.dll` fail to
  load, in either load order. [ModderLords](https://github.com/PlueRyvius/ModderLords)
  solves this with an assembly-resolution hook, which this egg does not carry.
- **Every player needs the identical set, at identical versions.** The server
  compares module lists on join and refuses a client that has one the server
  lacks, or the other way round.

## Ports

Clients join on `port` in `server-config.json`, set from the primary allocation
on every start. The mod uses that port and the one above it.

`ENGINE_PORT` is not the join port. It is the engine's internal custom-server
port, default 7210, so pointing it at your allocation gives a server that boots
and never connects.

## Console and stopping

Commands are read from stdin, so they work in the panel console: `status`,
`players`, `save`, `say`, `kick`, `stop`, `help`, plus the game's `campaign.*`
and `coop.*` commands. The server prints its own list as an
`@DS@{"ev":"commands"}` line on boot.

`start.sh` still has the tty translate carriage returns, so the console also
works from a real terminal, which submits a line on CR.

`stop` writes a shutdown save and exits cleanly, and is what the egg sends. After
a kill instead, the last autosave is the recovery point and two dated backups
are kept.

Everything persistent lives in the server volume:

| Path | Contents |
| --- | --- |
| `data/Game Saves` | Worlds and dated backups. |
| `data/logs` | `Coop_server.log`, written by the mod. Console output also goes to the panel. |
| `data/server-config.json` | Port, save name, password, autosave. Re-applied from the panel on every start. |
| `data/mod-config.json` | Mod settings, written by the mod on first boot. |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `SERVER_PORT=0 is not in 1-65534` | The server has no primary allocation. Give it two consecutive free UDP ports. |
| `server-config.json port=0 is not a port in 1-65534` | The stored config holds `"port": 0`. Assign a primary allocation, the next start rewrites it. |
| `workshop item N has no SubModule.xml` | The id is not a Bannerlord module, or steamcmd could not fetch it. Check the id and the console for steamcmd errors. |
| A mod is listed on boot but does nothing | It ships no `bin/Win64_Shipping_Server`, so none of its code loads. See [Mods](#mods). |
| `Cannot load: GameInterface.dll` | A mod is supplying its own Harmony or MonoMod. Remove it from `WORKSHOP_MODS`. |
| Players are refused with `Server does not support module 'X'` | Their module list differs from the server's. Line up `WORKSHOP_MODS` with what they have. |
| Typed commands do nothing | The container has no tty. wings always allocates one, compose needs `tty: true`. |
| Steam Guard on every start | The cached token is not persisting. `STEAM_DIR` must be on the server volume, and the volume must survive a restart. |
| `no game files found and Steam could not be used` | Steam is unreachable and the volume is empty. Set `STEAM_USERNAME`, or point `GAME_DIR` at an existing copy with `AUTO_UPDATE=0`. |

## How it boots

```
tini -g --                          from the yolk: reaps orphans, signals the group
/entrypoint.sh                      from the yolk: Xvfb on :0, stty 250, evals $STARTUP
/usr/local/bin/start.sh             steamcmd, modules, Wine prefix, server-config.json
exec wine engine/dotnet/dotnet.exe TaleWorlds.Starter.DotNetCore.dll \
          "_MODULES_*...*_MODULES_" /dedicatedcustomserver 7210 EU 0
```

The image adds no `ENTRYPOINT` and no `CMD`, it keeps the yolk's. wings passes
the panel's Startup Command as `$STARTUP` and the yolk entrypoint is what
evaluates it, so that panel field stays live. `exec` keeps the game one hop from
wings' stdin, which is how console commands reach it.

`BannerlordCoopServer.exe` is shipped with the workshop item but not used: it
hardcodes its module list to the five it ships with, so extra mods can only be
loaded by starting the engine the same way it does. What it also did, `start.sh`
now does: seeding `server-config.json`, checking the port, and creating the
first world from `default_new_game.sav`. The mod still verifies its own
assemblies against the release pins at boot, and `data/Game Saves` keeps the same
backup generations.

## Development

```sh
docker build -t bannerlord-coop:latest .
sh start.sh --self-test
```

The egg's `~bannerlord-coop:latest` image entry tells wings to use a local build
without pulling. CI runs `shellcheck start.sh` and the self-test on every push,
then builds and pushes `:latest` plus the sha tag.
