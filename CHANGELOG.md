# Changelog

Notable changes, newest first. The format follows [Keep a Changelog](https://keepachangelog.com).

## [1.1.0] - 2026-09-28
### Added
- macOS port: native Swift app (`macos/`, `build.sh`) with the same one-worker-per-game design, Dock badge instead of a tray icon, universal arm64 + x86_64 build.
- The macOS workers load the Steam client's own `libsteam_api.dylib` in place, so nothing is copied and no game has to be installed.
- `build.sh` builds with the Command Line Tools alone and installs straight into `/Applications`, quitting and reopening the copy it replaces (a copy running from elsewhere keeps idling).
- Release download for macOS: `SteamIdler-v1.1.0-macos-universal.zip`, ad-hoc signed, not notarized (clear the quarantine flag once).

## [1.0.0] - 2026-09-17
### Added
- Steam Idler for Windows: idle several owned games at once, one supervised `SteamIdlerWorker.exe` per game.
- Library detection across all Steam library folders, manual AppIDs, per-game session timer and persistent tracked total.
- Auto-stop after N hours, minimize/close to tray, single instance, stops everything when Steam exits.
- `build.ps1` compiles with the in-box .NET Framework compiler and copies `steam_api64.dll` from an installed game.
