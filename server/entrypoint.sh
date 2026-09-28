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

# What friends see you playing. Steam shows the first game in the list, so an
# AppID moves (or adds) that game to the front; any other text is shown as a
# non-Steam game, which takes one of the 32 slots. Steam treats both as a hint.
display="${DISPLAY_GAME:-}"
custom=""
limit=32
case "$display" in
    '') ;;
    *[!0-9]*) custom="$display"; limit=31 ;;
    *)
        rest="$(printf '%s' "$games" | tr ',' '\n' | grep -vx "$display" | paste -sd, -)"
        games="$display${rest:+,$rest}"
        ;;
esac

count="$(printf '%s' "$games" | tr ',' '\n' | grep -c .)"
[ "$count" -le "$limit" ] || fail "Steam plays at most $limit games at once here, GAMES has $count"

# Card farming would play other games (the ones with drops left) before these.
# Off: 9 = FarmingPausedByDefault (ASF plays GAMES as soon as it logs in) plus
# FarmPriorityQueueOnly with an empty queue, so pressing Resume in the web UI
# finds nothing to farm and falls straight back to GAMES.
case "${FARM_CARDS:-false}" in
    true | 1 | yes) farming=0 ;;
    false | 0 | no) farming=9 ;;
    *) fail "FARM_CARDS must be true or false" ;;
esac

# Offline still accrues playtime; it just doesn't show you as online around the clock.
# With DISPLAY_GAME set the default is online, since offline shows nobody anything.
default_status=offline
[ -z "$display" ] || default_status=online
online_status="${ONLINE_STATUS:-$default_status}"
case "$display:$online_status" in
    ?*:offline | ?*:invisible) echo "steamidler: DISPLAY_GAME is set, but nobody sees it while ONLINE_STATUS is $online_status" >&2 ;;
esac
case "$online_status" in
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

shown=""
if [ -n "$custom" ]; then
    shown="
  \"CustomGamePlayedWhileIdle\": $(json_string "$custom"),"
fi

# RemoteCommunication 0: by default ASF joins its own Steam group with every
# account it logs in, which nobody wants on a main account.
cat > "$config/$bot.json" <<EOF
{
  "Enabled": true,
  "SteamLogin": $(json_string "$STEAM_LOGIN"),$password
  "GamesPlayedWhileIdle": [$games],$shown
  "FarmingPreferences": $farming,
  "OnlineStatus": $status,
  "RemoteCommunication": 0
}
EOF

if [ "$farming" = 0 ]; then
    mode="ASF farms trading cards first, then idles these"
else
    mode="ASF's card farming is paused on purpose, so only these get playtime"
fi
echo "steamidler: bot '$bot' idles $count game(s): $games ($mode), web UI on port $port"
[ -z "$display" ] || echo "steamidler: showing friends '$display' as the game being played (status $online_status)"

exec ArchiSteamFarm --no-restart "$@"
