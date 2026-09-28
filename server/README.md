# Steam Idler on a server (24/7)

The desktop apps need a running Steam client, which a headless server doesn't have. This
folder runs [ArchiSteamFarm](https://github.com/JustArchiNET/ArchiSteamFarm) (ASF) instead.
ASF logs in to Steam's network directly and tells it which games you are playing, in about
55 to 75 MB of memory and next to no CPU.

The Dockerfile wraps the official `justarchi/archisteamfarm:stable` image. `entrypoint.sh`
writes ASF's config from environment variables on every start, then hands over to ASF.

## Deploy on Railway

1. In Railway, create a project, choose **Deploy from GitHub repo** and pick this repository
   (or your fork).
2. In the service's **Settings**, set **Root Directory** to `/server` and the config file path
   to `/server/railway.toml`. Railway resolves the config file from the repository root, so
   it needs the full path.
3. Add a **volume** to the service, mounted at `/app/config`. It keeps the login token ASF
   saves, so you only sign in once.
4. Under **Variables**, add:
   - `STEAM_LOGIN`: your Steam account name
   - `GAMES`: the AppIDs to idle, separated by commas, at most 32 (e.g. `440,570`)
   - `IPC_PASSWORD`: a long random password; it guards the web UI, which controls your account
5. Deploy. The log ends with `Received a request for user input, but process is running in
   headless mode!`. That is expected: ASF is waiting for you to sign in.
6. Under **Settings → Networking**, choose **Generate Domain**. If Railway asks for a port, use
   the one in the log line `steamidler: ... web UI on port N` (1242 unless Railway set `PORT`).
   Open the domain and sign in to the web UI with `IPC_PASSWORD`.
7. In the web UI, open **Commands** and run these one after another. Get the code last, since
   it expires after 30 seconds:
   ```
   input idler Password <your Steam password>
   input idler TwoFactorAuthentication <code from the Steam mobile app>
   start idler
   ```
   For an account that gets Steam Guard codes by email, use
   `input idler SteamGuard <code from the email>` instead of the second line.

   `start idler` is only needed this once, to log in. After that the bot starts by itself on
   every deploy. The web UI's Start, Pause and Resume buttons are about ASF's card farming, so
   you never need them.
8. Check the log for a line starting `Playing selected`, listing your games. That line is the
   proof it works.

   ASF talks about "farming" everywhere, because its main feature is farming trading cards.
   That feature is paused on purpose so that only `GAMES` get playtime, which makes these
   messages normal:
   - `status idler` answers "Bot is paused or running in manual mode."
   - The web UI shows the bot as paused, or as not farming anything.
   - Pressing Resume (or `resume idler`) is harmless. Only games in ASF's priority queue may be
     farmed, and that queue is empty, so ASF finds nothing to farm and goes back to `GAMES`.

   One message means something else is holding the play session: "Account is currently being
   used: ASF will resume farming when it's free...". Steam lets one session play at a time, so
   quit any game or desktop idler on your other devices and ASF carries on by itself.
9. Optional: remove the domain again under **Settings → Networking**. Idling carries on;
   generate a domain again whenever you need the web UI.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `STEAM_LOGIN` | required | Steam account name |
| `GAMES` | required | AppIDs to idle, comma-separated, at most 32 |
| `IPC_PASSWORD` | required | password for the web UI and the API |
| `STEAM_PASSWORD` | unset | lets ASF sign in again by itself if Steam ever drops the saved token; without it, repeat step 7 when that happens |
| `FARM_CARDS` | `false` | `true` lets ASF farm trading cards first, which plays whichever games still have drops (and shows those to friends) and `GAMES` only after that |
| `DISPLAY_GAME` | unset | what friends see you playing: an AppID (moved to the front of `GAMES`, or added to it) or any text, shown as a non-Steam game; see below |
| `ONLINE_STATUS` | `offline`, or `online` with `DISPLAY_GAME` | `offline`, `online`, `busy`, `away` or `invisible`; playtime accrues either way |
| `BOT_NAME` | `idler` | the name used in commands |

The variables are the source of truth. Changing one redeploys the service, and edits made in
the web UI's config editor are overwritten on the next start.

### Choosing the game friends see

When several games play at once, Steam shows one of them as your current game: the first in
the list. `DISPLAY_GAME` picks it.

- **An AppID**, e.g. `2868840`: that game moves to the front of `GAMES`. If it isn't in
  `GAMES` yet it is added, so it gets playtime too and you must own it.
- **Any other text**, e.g. `Touching grass`: shown as "Playing non-Steam game: Touching grass".
  It takes one of Steam's 32 slots, so `GAMES` can then hold at most 31.

Friends only see it while your status is visible, so `ONLINE_STATUS` defaults to `online` when
`DISPLAY_GAME` is set. Steam treats both kinds as a hint and may occasionally show another of
your games.

## Things to know

- **One play session per account.** Launch a game on another device and Steam offers to
  disconnect the other session. Accept it: ASF waits until you stop playing, then resumes
  `GAMES` by itself. Don't run the desktop Steam Idler at the same time, since only one of
  them can hold the session.
- **No Steam group.** By default ASF joins its own Steam group with every account it logs in.
  The generated config turns that off (`RemoteCommunication: 0`).
- **Same limits as the desktop app.** You must own the games, it is hours only, and idled
  hours count toward the refund window.
- **Updates.** The image uses ASF's `stable` tag, which has no built-in auto-update. A rebuild
  picks up the current stable release.
- **Railway volumes** mean a few seconds of downtime on each redeploy, and no replicas.

## Running it anywhere else

Any Docker host works the same way:

```sh
docker build -t steamidler-server server
docker run -d --name steamidler --restart unless-stopped \
  -p 127.0.0.1:1242:1242 -v steamidler-config:/app/config \
  -e STEAM_LOGIN=... -e GAMES=... -e IPC_PASSWORD=... \
  steamidler-server
```

Then do steps 7 and 8 at `http://127.0.0.1:1242`.
