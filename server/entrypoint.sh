#!/bin/sh
# Writes ArchiSteamFarm's config from environment variables (Railway service
# variables), then hands over to ASF's own launcher, which fixes ownership of
# the config volume and drops to the unprivileged asf user.
#
# The variables are the source of truth: the JSON files are rewritten on every
# start. The login token ASF saves (<bot>.db) is kept, so the Steam password and
# a Steam Guard code are only needed for the first login.
set -eu

fail() {
    echo "steamidler: $1" >&2
    exit 1
}

[ -n "${STEAM_LOGIN:-}" ] || fail "set STEAM_LOGIN to your Steam account name"
[ -n "${GAMES:-}" ] || fail "set GAMES to the AppIDs to idle, separated by commas (e.g. 440,570)"
[ -n "${IPC_PASSWORD:-}" ] || fail "set IPC_PASSWORD: it protects the web UI, which is reachable from outside the container"

bot="${BOT_NAME:-idler}"
config=/app/config
port="${PORT:-1242}"

case "$bot" in
    *[!A-Za-z0-9_-]* | ASF) fail "BOT_NAME may only contain letters, digits, - and _ (and cannot be ASF)" ;;
esac

games="$(printf '%s' "$GAMES" | tr -d ' ' | sed 's/,,*/,/g; s/^,//; s/,$//')"
case "$games" in
    '' | *[!0-9,]*) fail "GAMES must be AppIDs separated by commas, got: $GAMES" ;;
esac
count="$(printf '%s' "$games" | tr ',' '\n' | grep -c .)"
[ "$count" -le 32 ] || fail "Steam plays at most 32 games at once, GAMES has $count"

# Card farming would play other games (the ones with drops left) before these.
# Paused by default, so only GAMES get playtime; ASF then plays GAMES as soon as it logs in.
case "${FARM_CARDS:-false}" in
    true | 1 | yes) farming=0 ;;
    false | 0 | no) farming=1 ;;
    *) fail "FARM_CARDS must be true or false" ;;
esac

# Offline still accrues playtime; it just doesn't show you as online around the clock.
case "${ONLINE_STATUS:-offline}" in
    offline) status=0 ;;
    online) status=1 ;;
    busy) status=2 ;;
    away) status=3 ;;
    invisible) status=7 ;;
    *) fail "ONLINE_STATUS must be offline, online, busy, away or invisible" ;;
esac

json_string() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

mkdir -p "$config"

# One account, one bot: drop configs of bots renamed away from, or ASF would log in twice.
find "$config" -maxdepth 1 -name '*.json' ! -name ASF.json ! -name "$bot.json" -delete

cat > "$config/ASF.json" <<EOF
{
  "Headless": true,
  "IPCPassword": $(json_string "$IPC_PASSWORD")
}
EOF

cat > "$config/IPC.config" <<EOF
{
  "Kestrel": {
    "Endpoints": {
      "HTTP": { "Url": "http://*:$port" }
    }
  }
}
EOF

password=""
if [ -n "${STEAM_PASSWORD:-}" ]; then
    password="
  \"SteamPassword\": $(json_string "$STEAM_PASSWORD"),"
fi

# RemoteCommunication 0: by default ASF joins its own Steam group with every
# account it logs in, which nobody wants on a main account.
cat > "$config/$bot.json" <<EOF
{
  "Enabled": true,
  "SteamLogin": $(json_string "$STEAM_LOGIN"),$password
  "GamesPlayedWhileIdle": [$games],
  "FarmingPreferences": $farming,
  "OnlineStatus": $status,
  "RemoteCommunication": 0
}
EOF

echo "steamidler: bot '$bot' idles $count game(s): $games (card farming $([ "$farming" = 0 ] && echo on || echo off)), web UI on port $port"

exec ArchiSteamFarm --no-restart "$@"
