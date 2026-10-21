# ArmaMac Launcher

A native SwiftUI launcher for **Arma 3 on macOS** — server browser, Steam Workshop mod
manager, load-order editor and one-click launch, in a single Mac app.

Bohemia's official launcher is Windows-only, and
[arma3-unix-launcher](https://github.com/muttleyxd/arma3-unix-launcher) is a Qt app aimed at
Linux. This is a Mac-first alternative: `NavigationSplitView`, native `Table`s with sortable
columns, inspectors, `.searchable`, Settings tabs and the system appearance throughout.

> Unofficial community project. Not affiliated with Bohemia Interactive or Valve.

---

## Interface

A permanent **launch bar** runs along the bottom of the window, so the big Play button is one
click away from every tab — server browser included. It is a split control: the main half
launches, the chevron opens vanilla/modded, rejoin-last-server, BattlEye, windowed and
"copy command line".

Two launch modes are first-class rather than a hidden toggle:

| Mode | Loads | Use it for |
|---|---|---|
| **Vanilla** | Base game and official DLC — no `-mod=` at all | Fast starts, vanilla servers |
| **With Mods** | Your enabled load order | Modded servers, unit nights |

Joining a server always uses the server's own mod set, whichever mode is parked.

The **Home** dashboard puts the choice up front with two large cards, plus live counters
(mods installed, load order size, servers and players online), a "Jump back in" list of recent
servers, and your presets. Every counter is clickable and jumps to the matching tab.

## Features

### Server browser
- **Full community server list with no API key** — read straight from your running Steam
  client, the same source Steam's own server browser uses (~4,000 Arma 3 servers).
- Live **A2S** queries on top for accurate ping, version and status.
- Full **Arma 3 Server Browser Protocol v3** decoding, so every server's exact **mod list**,
  DLC and Creator DLC requirements are visible before you join.
- Multi-packet reassembly and the Steam challenge handshake, both required by real servers.
- Filters: search, favourites, recents, ready-to-join, hide empty/full/passworded, BattlEye,
  vanilla vs modded, max ping, minimum players, map, and **"only servers whose mods I have"**.
- Click any column header to sort. Favourites and join history persist.
- Direct connect by `host:port`; player lists with score and time on server.

### Mod manager
- Scans Steam Workshop content, `@folders` in the game directory, official DLC and any extra
  folders you add.
- Reads `mod.cpp` / `meta.cpp` for names, authors, versions and Workshop ids.
- Pulls titles, preview images, sizes, update times and subscriber counts from the Steam
  Workshop API, and flags mods with a **newer version on the Workshop**.
- Drag-to-reorder load order, presets, and import/export of **Arma 3 Launcher `.html` presets**
  so modsets can be shared with Windows players.
- Import a **Workshop collection** by URL — installed mods get enabled, missing ones queued.

### Automatic mod downloading
Join a server that needs mods you do not have and the launcher installs them itself, then
starts the game — no prompt, no second tool, no credentials.

It works through the **Steam client you are already signed in to**: the launcher subscribes
to each missing item exactly as pressing Subscribe on a Workshop page would, Steam downloads
it into your normal workshop folder, and the launcher watches the progress and joins once
everything has landed. If Steam is not running it is started first and the launcher waits
for it to sign in.

Nothing is stored, nothing is duplicated, and mods installed this way show up in the Steam
client like any other subscription. Turn the automatic join off in **Settings ▸ Steam** if
you would rather press the button yourself.

### Launching
Finds Arma 3 across:

| Where | How it runs |
|---|---|
| Native Steam library | `ArmA3 AS Native.app` (Apple Silicon) or `ArmA3.app` (Intel) |
| CrossOver bottle | CrossOver's `wine --bottle <name> --cx-app` |
| Whisky / Wine prefix | `WINEPREFIX=… wine arma3_x64.exe` |
| Any of the above | `steam://run/107410//…` when "Launch through Steam" is on |

**BattlEye and the Apple Silicon build.** Bohemia's Mac port ships two binaries, and they are
not interchangeable:

| Bundle | Architecture | BattlEye |
|---|---|---|
| `ArmA3.app` | x86-64 (non-native) | ✅ supported |
| `ArmA3 AS Native.app` | arm64 (experimental) | ❌ **not supported** |

Almost every public Arma 3 server enforces BattlEye, so the launcher picks the Intel build
whenever BattlEye is on, and only prefers the faster arm64 build when you turn BattlEye off.
If the arm64 build is the only one installed, the game still starts, but the Play screen and
the join sheet warn that BattlEye-protected servers will refuse the connection.

Workshop mods are symlinked into `<Arma 3>/!Workshop` before launch — the same approach
arma3-unix-launcher uses. It keeps `-mod=` short and, under Wine, keeps every mod on one drive
letter. Windows paths are translated through the prefix's `dosdevices` table; the native build
gets POSIX paths.

**Link names never contain a space.** Arma re-reads `-mod=` from the raw command line rather
than from `argv`, so one space anywhere in the list truncates it and the game starts with *no*
mods at all — not just without the mod whose name had the space. `@Advanced Combat Environment`
is therefore linked as `@Advanced_Combat_Environment`; the game still shows each mod's real
name, which it reads from `mod.cpp`. Any mod whose own path contains a space is routed through
a link for the same reason.

All the usual parameters are exposed: `-skipIntro`, `-noSplash`, `-window`, `-maxMem`,
`-cpuCount`, `-exThreads`, `-name`, `-filePatching`, `-checkSignatures`, BattlEye on/off, plus
a free-form field. The exact command line is shown before you launch and can be copied.

---

## Requirements

- macOS 14 or later
- Xcode 16+ to build (developed against Xcode 26 / Swift 6)
- Arma 3 installed via Steam — natively, or in a CrossOver/Whisky bottle
- The Steam client, signed in to an account that owns Arma 3, for the server list and for
  installing mods

### How the server list works (no API key)

Valve's public UDP master server (`hl2master.steampowered.com`) **no longer resolves** — it has
no A record on any public resolver, so the classic keyless enumeration is gone.

Instead ArmaMac asks the **Steam client you already have running**, exactly as the official
Arma 3 Launcher does. It `dlopen`s the `libsteam_api.dylib` that ships inside Arma's app
bundle and calls `ISteamMatchmakingServers::RequestInternetServerList` through Steam's flat C
API — no Steamworks SDK dependency, no API key. All it needs is Steam running and signed in to
an account that owns Arma 3.

Steam's rows already carry the name, map, player counts and Arma's keyword string (BattlEye,
signature checking, server state), so the list is fully populated the moment it lands; ArmaMac
then A2S-queries each server for an accurate ping and fetches mod lists on demand.

The Steam API session is open only for the few seconds a refresh takes and is shut down
immediately afterwards, so Steam does not keep showing you as in-game.

A Steam Web API key remains available in **Settings ▸ Network** as an optional fallback — for
example if Arma lives in a Wine bottle and there is no native Steam library on this Mac to
borrow the dylib from. Favourites, recents and direct connect always work regardless.

---

## Building

```sh
brew install xcodegen      # once
xcodegen generate
open ArmaMac.xcodeproj      # or:
xcodebuild -project ArmaMac.xcodeproj -scheme ArmaMac -configuration Release build
```

Run the tests:

```sh
xcodebuild -project ArmaMac.xcodeproj -scheme ArmaMac \
  -destination 'platform=macOS,arch=arm64' test
```

---

## Layout

```
Sources/ArmaMac/
├── App/            AppModel, ModLibraryModel, ServerBrowserModel, RootView
├── Core/
│   ├── Game/       Arma install + executable discovery
│   ├── Launch/     argument building, mod symlinking, native/CrossOver/Wine/Steam runners
│   ├── Mods/       mod scanner, mod.cpp/meta.cpp parser, Arma 3 preset HTML
│   ├── Models/     Mod, Preset, GameServer, ServerAddress
│   ├── Network/    UDP transport, A2S, Arma browser protocol v3, keywords, master server
│   ├── Settings/   persisted preferences
│   ├── Steam/      Valve KeyValues parser, library discovery, Wine path mapping
│   ├── SteamClient/ C bridge to a running Steam client: server list and Workshop installs
│   └── Workshop/   Steam Workshop API and the download queue
└── Features/       SwiftUI views: Play, Servers, Mods, Load Order, Downloads, Settings
```

## Protocol notes

Arma 3 tunnels its server-browser data through `A2S_RULES`. The rules "keys" are really
`[pageIndex, pageCount]` markers and the values are 124-byte fragments of one binary message.
Three byte values are escaped before transmission because Steam's relay cannot carry them:

```
0x01 0x01 → 0x01      0x01 0x02 → 0x00      0x01 0x03 → 0xFF
```

Reassembled, the message is: version, flags, DLC bitmask, difficulty, DLC hashes, mods
(hash, id-length, id, name), signatures. Creator DLC arrive inside the mod block with an
id-length marker of `19`.

See [`ArmaServerBrowserProtocol.swift`](Sources/ArmaMac/Core/Network/ArmaServerBrowserProtocol.swift)
and Bohemia's [ServerBrowserProtocol3](https://community.bistudio.com/wiki/Arma_3:_ServerBrowserProtocol3).

## Credits

- [arma3-unix-launcher](https://github.com/muttleyxd/arma3-unix-launcher) — prior art for the
  Unix launcher approach and the `!Workshop` symlink strategy
- [WoozyMasta/a2s](https://github.com/WoozyMasta/a2s) — clear documentation of the Arma 3 and
  DayZ server-browser sub-protocols
