#!/bin/sh
# Bannerlord Coop dedicated server launcher. steamcmd fetches the game at boot, none is baked in.
set -u

APP_ID=261550
ITEM_ID=3770450698

STEAM_DIR=${STEAM_DIR:-/home/container/.steamcmd}
# Run straight out of the steamcmd download; left empty, the path is discovered below.
GAME_DIR=${GAME_DIR:-}
DATA_DIR=${DATA_DIR:-/home/container/data}
WINEPREFIX=${WINEPREFIX:-/home/container/.wine}
AUTO_UPDATE=${AUTO_UPDATE:-1}
# Extra workshop item ids to load beside Coop, "X,Y,Z" or space separated.
WORKSHOP_MODS=${WORKSHOP_MODS:-}
# The engine's own custom-server port and region. Not the port players join on.
ENGINE_PORT=${ENGINE_PORT:-7210}
REGION=${REGION:-EU}
export WINEPREFIX

log()  { echo "[coop] $*"; }
warn() { echo "[coop] WARNING: $*" >&2; }
die()  { echo "[coop] ERROR: $*" >&2; exit 1; }

# Docker Desktop's 9p mount can return EEXIST for a missing dir, so test the result.
ensure_dir() { mkdir -p "$1" 2>/dev/null; [ -d "$1" ] || die "cannot create $1"; }

# server-config.json is JSONC, so sed, not a parser. esc() prefixes & \ | for sed.
esc() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }
set_cfg() {
  grep -qE "\"$1\"[[:space:]]*:" "$cfg" 2>/dev/null || return 0
  sed -i -E "s|(\"$1\"[[:space:]]*:[[:space:]]*)[^,}]*|\1$(esc "$2")|" "$cfg"
}

# wings sends its primary allocation here, and 0 when the server has none. A bad
# port strands the server with no way in, so check before downloading 6 GB.
check_port() {
  # 1-65534, since the mod also uses port+1. awk compares without overflowing on a
  # long digit string, and [1-9] first means no leading zero and no need for a
  # lower-bound test.
  awk -v p="${1:-}" 'BEGIN{exit !(p ~ /^[1-9][0-9]*$/ && p+0<=65534)}' ||
    die "${2:-SERVER_PORT}=${1:-} is not a port in 1-65534. Pelican sends 0 when the
server has no primary allocation: give it two consecutive free UDP ports."
}

# --- extra modules ----------------------------------------------------------
# The engine activates only what its _MODULES_ argument names, so a mod has to be
# downloaded, linked into Modules, and added to the list built in section 5. It
# also needs bin/Win64_Shipping_Server; a client-only build loads no code.

mod_ids() { printf '%s' "$WORKSHOP_MODS" | tr ',' ' '; }

# The ids end up on a command line, so nothing but digits gets through.
check_mod_ids() {
  for id in $(mod_ids); do
    awk -v i="$id" 'BEGIN{exit !(i ~ /^[0-9]+$/)}' ||
      die "WORKSHOP_MODS contains \"$id\", which is not a workshop item id (digits only)."
  done
}

# The declared id, not the folder name: Coop's folder declares "Coop" or "CoopNightly".
module_id() { sed -n 's/.*<Id[[:space:]]*value="\([^"]*\)".*/\1/p' "$1" | head -1; }

# stage_mods <workshop root> <modules dir> - prints the ids it staged, in order.
stage_mods() {
  ws=$1; dir=$2; staged=
  for id in $(mod_ids); do
    sub=$ws/$id/SubModule.xml
    # Some uploads nest the module one level down.
    [ -f "$sub" ] || sub=$(find "$ws/$id" -maxdepth 2 -name SubModule.xml 2>/dev/null | head -1)
    if [ -z "$sub" ] || [ ! -f "$sub" ]; then
      warn "workshop item $id has no SubModule.xml - not loaded"
      continue
    fi
    mid=$(module_id "$sub")
    if [ -z "$mid" ]; then
      warn "workshop item $id declares no module Id - not loaded"
      continue
    fi
    link=$dir/$mid
    # Only ever replace a link of our own, never one of the shipped modules.
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "$mid is a real folder under Modules, leaving it as it is"
    elif ! ln -sfn "$(dirname "$sub")" "$link"; then
      warn "could not link $mid into Modules"
      continue
    fi
    staged="$staged $mid"
  done
  printf '%s' "${staged# }"
}

# prune_mods <modules dir> <ids to keep> - drops what WORKSHOP_MODS no longer names,
# by removing only our own links.
prune_mods() {
  for link in "$1"/*; do
    [ -L "$link" ] || continue
    case " $2 " in
      *" $(basename "$link") "*) continue ;;
    esac
    rm -f "$link"
  done
}

# `sh start.sh --self-test` checks both round trips. CI runs it.
if [ "${1:-}" = "--self-test" ]; then
  cfg=$(mktemp) || exit 1
  printf '{\n  "port": 4200, // trailing comment\n  "password": "old",\n}\n' > "$cfg"
  set_cfg password '"a|b&c\d"'
  want='  "password": "a|b&c\d",'
  got=$(grep password "$cfg"); rm -f "$cfg"
  [ "$got" = "$want" ] || die "self-test: got [$got] want [$want]"
  for bad in "" 0 abc 04200 65535 99999999999999999999; do
    ( check_port "$bad" ) 2>/dev/null && die "self-test: check_port took [$bad]"
  done
  check_port 4200 || die "self-test: check_port rejected 4200"

  for bad in abc 1x -1 12a; do
    WORKSHOP_MODS=$bad
    ( check_mod_ids ) 2>/dev/null && die "self-test: check_mod_ids took [$bad]"
  done

  # A nested module stages under its declared id, and unstages when dropped.
  ws=$(mktemp -d) || exit 1
  md=$(mktemp -d) || exit 1
  mkdir -p "$ws/123/Inner"
  printf '<Module>\n  <Id value="TestMod" />\n</Module>\n' > "$ws/123/Inner/SubModule.xml"
  : > "$md/RealModule"
  WORKSHOP_MODS=123
  got=$(stage_mods "$ws" "$md")
  [ "$got" = TestMod ] || die "self-test: stage_mods got [$got] want [TestMod]"
  [ -f "$md/TestMod/SubModule.xml" ] || die "self-test: TestMod did not stage"
  # MSYS ln -s copies, so assert prune_mods only where symlinks are real. CI is.
  if ln -s . "$md/.probe" 2>/dev/null && [ -L "$md/.probe" ]; then
    rm -f "$md/.probe"
    WORKSHOP_MODS=
    prune_mods "$md" "$(stage_mods "$ws" "$md")"
    [ -L "$md/TestMod" ] && die "self-test: prune_mods kept a dropped mod"
    [ -e "$md/RealModule" ] || die "self-test: prune_mods removed a real module"
  else
    log "self-test: no symlink support here, skipped the prune_mods check"
  fi
  rm -rf "$ws" "$md"

  echo "self-test ok"; exit 0
fi

[ -z "${SERVER_PORT:-}" ] || check_port "$SERVER_PORT"
check_mod_ids

# --- 1. game files ----------------------------------------------------------
# steamcmd puts content under $HOME/Steam, so HOME points at STEAM_DIR; roots vary, hence the list.
WORKSHOP=steamapps/workshop/content/$APP_ID/$ITEM_ID/DedicatedServer
GAME_ROOTS="$STEAM_DIR/Steam $STEAM_DIR ${HOME:-/root}/Steam"
resolve_game_dir() {
  [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/BannerlordCoopServer.exe" ] && return 0
  for root in $GAME_ROOTS; do
    if [ -f "$root/$WORKSHOP/BannerlordCoopServer.exe" ]; then
      GAME_DIR=$root/$WORKSHOP
      return 0
    fi
  done
  return 1
}

mod_download_args() {
  for id in $(mod_ids); do
    printf ' +workshop_download_item %s %s' "$APP_ID" "$id"
  done
}

run_steamcmd() {
  # shellcheck disable=SC2046  # the ids are digits, checked by check_mod_ids
  HOME=$STEAM_DIR "$STEAM_DIR/steamcmd.sh" "$@" \
      +workshop_download_item "$APP_ID" "$ITEM_ID" $(mod_download_args) +quit
}

update_game() {
  if [ "$AUTO_UPDATE" != 1 ]; then
    log "AUTO_UPDATE=0 - not contacting Steam"
    return 1
  fi
  if [ -z "${STEAM_USERNAME:-}" ]; then
    log "STEAM_USERNAME unset - not contacting Steam"
    return 1
  fi

  ensure_dir "$STEAM_DIR"
  if [ ! -x "$STEAM_DIR/steamcmd.sh" ]; then
    log "installing steamcmd into $STEAM_DIR"
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz |
      tar zx -C "$STEAM_DIR" || { warn "could not install steamcmd"; return 1; }
  fi

  log "steamcmd: checking workshop item $ITEM_ID for updates"
  [ -z "$WORKSHOP_MODS" ] || log "steamcmd: also fetching mods $WORKSHOP_MODS"
  # Cached token first: passing the password re-authenticates and pushes Guard every boot.
  # NoPromptForPassword makes that attempt fail fast instead of waiting at a password prompt.
  if [ -f "$STEAM_DIR/Steam/config/config.vdf" ]; then
    log "steamcmd: trying cached token"
    run_steamcmd +@NoPromptForPassword 1 +login "$STEAM_USERNAME" && return 0
    log "steamcmd: cached token rejected, using password"
  fi
  # An empty password means steamcmd prompts for it, and for the Guard code, on the console.
  # shellcheck disable=SC2086
  run_steamcmd +login "$STEAM_USERNAME" ${STEAM_PASSWORD:+"$STEAM_PASSWORD"} ||
    { warn "steamcmd failed"; return 1; }
}

if ! update_game; then
  # A Steam outage or an expired credential must never brick a server that already works.
  if ! resolve_game_dir; then
    # Steam rate-limits repeated failed logins, so slow the wings restart loop to one a minute.
    sleep 60
    die "no game files found and Steam could not be used. Looked in:$(for r in $GAME_ROOTS; do printf '\n  %s' "$r/$WORKSHOP"; done)
Set STEAM_USERNAME (and STEAM_PASSWORD), or point GAME_DIR at an existing copy with AUTO_UPDATE=0."
  fi
  warn "continuing with the game files already present"
fi
resolve_game_dir || die "BannerlordCoopServer.exe is missing after the update step. Looked in:$(for r in $GAME_ROOTS; do printf '\n  %s' "$r/$WORKSHOP"; done)"
log "game files: $GAME_DIR"

ensure_dir "$DATA_DIR"

# --- 1b. link the extra modules in ------------------------------------------
MODULES_DIR=$GAME_DIR/engine/Modules
[ -d "$MODULES_DIR" ] || die "no engine module folder at $MODULES_DIR"
# .../workshop/content/$APP_ID, two levels above the DedicatedServer folder.
WS_ROOT=$(dirname "$(dirname "$GAME_DIR")")

MODS=$(stage_mods "$WS_ROOT" "$MODULES_DIR")
prune_mods "$MODULES_DIR" "$MODS"
[ -z "$MODS" ] || log "extra modules: $MODS"

# --- 2. wine prefix ---------------------------------------------------------
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "creating wine prefix at $WINEPREFIX (~2 min)"
  ensure_dir "$WINEPREFIX"
  xvfb-run -a wineboot -i >/dev/null 2>&1
  wineserver -k 2>/dev/null
  [ -f "$WINEPREFIX/system.reg" ] || die "could not create a wine prefix at $WINEPREFIX"
fi

# --- 3. mod-config.json must land in the data dir ---------------------------
# COOP_DATA_DIR below already points the mod here; this covers anything the engine
# still resolves through Wine's Documents. The uid has no passwd entry, so glob.
for docs in "$WINEPREFIX"/drive_c/users/*/Documents; do
  [ -d "$docs" ] || continue
  ensure_dir "$docs/Mount and Blade II Bannerlord"
  link="$docs/Mount and Blade II Bannerlord/CoopData"
  [ -L "$link" ] && rm -f "$link"
  [ -e "$link" ] || ln -s "$DATA_DIR" "$link"
done

# --- 4. server-config.json --------------------------------------------------
# Seeded before launch, or the mod writes its own with port 4200.
cfg=$DATA_DIR/server-config.json

if [ ! -f "$cfg" ]; then
  log "seeding $cfg"
  cat > "$cfg" <<CFG
{
  "port": ${SERVER_PORT:-4200},
  "saveName": "${SAVE_NAME:-saveauto1}",
  "password": "${SERVER_PASSWORD:-}",
  "autosaveMinutes": ${AUTOSAVE_MINUTES:-5},
  "logFile": true,
  "steam": false
}
CFG
else
  [ -n "${SERVER_PORT:-}" ]       && set_cfg port "$SERVER_PORT"
  [ -n "${SAVE_NAME:-}" ]         && set_cfg saveName "\"$SAVE_NAME\""
  [ -n "${SERVER_PASSWORD+x}" ]   && set_cfg password "\"$SERVER_PASSWORD\""
  [ -n "${AUTOSAVE_MINUTES:-}" ]  && set_cfg autosaveMinutes "$AUTOSAVE_MINUTES"
fi

# Nothing downstream rejects a stored 0, so the file gets the panel's check too.
check_port "$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$cfg" | head -1)" \
           "server-config.json port"

# --- 4b. first-boot world ---------------------------------------------------
# The engine loads the configured save and will not create one, so seed it here the
# way BannerlordCoopServer.exe did.
save_name=$(sed -n 's/.*"saveName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)
[ -n "$save_name" ] || save_name=${SAVE_NAME:-saveauto1}
ensure_dir "$DATA_DIR/Game Saves"
if [ ! -f "$DATA_DIR/Game Saves/$save_name.sav" ]; then
  seed="$GAME_DIR/server-data/Game Saves/default_new_game.sav"
  [ -f "$seed" ] ||
    die "save '$save_name' does not exist and there is no default_new_game.sav at $seed"
  log "new world '$save_name' from default_new_game.sav"
  cp "$seed" "$DATA_DIR/Game Saves/$save_name.sav" || die "could not seed $save_name.sav"
fi

# --- 5. go -------------------------------------------------------------------
win_data=$(winepath -w "$DATA_DIR" 2>/dev/null)
[ -n "$win_data" ] || die "winepath could not map $DATA_DIR to a Windows path"

# This list, in this order, and nothing else. Mods go after Coop, which they depend on.
coop_id=$(module_id "$MODULES_DIR/Coop/SubModule.xml")
[ -n "$coop_id" ] || die "cannot read the Coop module id from $MODULES_DIR/Coop/SubModule.xml"
token=_MODULES_
for m in Native SandBoxCore Sandbox "$coop_id" $MODS DedicatedServer.Windows; do
  token="$token*$m"
done
token="$token*_MODULES_"

log "starting: $token"
cd "$GAME_DIR/engine/bin/Win64_Shipping_Server" ||
  die "cannot enter $GAME_DIR/engine/bin/Win64_Shipping_Server"

dotnet_root=$(winepath -w "$GAME_DIR/engine/dotnet" 2>/dev/null)
[ -n "$dotnet_root" ] || die "winepath could not map $GAME_DIR/engine/dotnet"
# BANNERLORD_USER_DIR: server-config.json, Game Saves, logs. COOP_DATA_DIR:
# mod-config.json. This egg keeps both in the data dir.
export DOTNET_ROOT="$dotnet_root" DOTNET_MULTILEVEL_LOOKUP=0
export BANNERLORD_USER_DIR="$win_data" COOP_DATA_DIR="$win_data"

# The structured @DS@ events appear on the server console, but not necessarily
# in Coop_server.log. Capture stdout/stderr separately for the API reader.
PLAYER_COUNT_LOG="$DATA_DIR/logs/player-count-console.log"
ensure_dir "$DATA_DIR/logs"

# Serve the latest captured player snapshot. Start before the game so the API
# is ready as soon as the server boots.
python3 /usr/local/bin/player_count_api.py &
player_count_pid=$!
player_count_ready=
for _ in 1 2 3 4 5; do
  if python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1).close()' \
      "${PLAYER_COUNT_PORT:-4202}" >/dev/null 2>&1; then
    player_count_ready=1
    break
  fi
  if ! kill -0 "$player_count_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ -z "$player_count_ready" ]; then
  kill "$player_count_pid" 2>/dev/null || true
  wait "$player_count_pid" 2>/dev/null || true
  die "player-count endpoint failed to start"
fi

# A no-op for wings, which sends LF; keeps the console usable from a real terminal.
stty inlcr 2>/dev/null || true

# The game expects a terminal on stdout. `script` gives it a PTY, forwards
# console input/output to Wings, and records the same output for the API reader.
quote_arg() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

server_command=wine
for arg in "$GAME_DIR/engine/dotnet/dotnet.exe" TaleWorlds.Starter.DotNetCore.dll \
           "$token" /dedicatedcustomserver "$ENGINE_PORT" "$REGION" 0 "$@"; do
  server_command="$server_command $(quote_arg "$arg")"
done

# The API is a background process; stop and reap it when the server exits so it
# cannot keep Wings from marking the container offline after a normal stop.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'kill "$player_count_pid" 2>/dev/null || true; wait "$player_count_pid" 2>/dev/null || true' EXIT

script --quiet --flush --return --command "$server_command" "$PLAYER_COUNT_LOG" <&0
server_status=$?
exit "$server_status"
