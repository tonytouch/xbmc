# Lightweight / Jellyfin-first fork — status & roadmap

This fork of Kodi started from the desire to ship a slim media player whose
primary job is **playing your Jellyfin library** (movies + TV + add-ons). The
fork exists at <https://github.com/tonytouch/xbmc>; this doc tracks what's
actually in the tree today, what was tried and reverted, and what would
genuinely be required to make the binary "lightweight".

## What's in this fork right now

| Change | File(s) | Effect |
|---|---|---|
| Slim CMake preset | `cmake/presets/slim.cmake` (new) | Disables Optical drive + libdvdcss when passed via `cmake -C`. Keeps AirPlay, Python, and HTTP web interface. Builds the same source tree, just without the libcdio / libdvdcss transitive deps. |
| Vendored Jellyfin add-on | `addons/plugin.video.jellyfin/` (new) | Ships `jellyfin-kodi 2.2.0` directly in the tree so it installs on first run with no network round-trip to the Kodi add-on repository. |

That is it. Nothing else in the source tree has been modified.

## What was tried and reverted (and why)

The first pass tried to remove the music / games / cdrip / pictures /
programs / speech / weather subsystems outright:

* `git rm cmake/treedata/common/{music,games}.txt` — drops the
  `add_subdirectory()` entries for `xbmc/music/*` and `xbmc/games/*`.
* `git rm -r xbmc/{music,games,cdrip,pictures,programs,speech,weather}` —
  deletes the source directories.
* Edit `cmake/treedata/common/subdirs.txt` to drop the unconditional
  `xbmc/pictures / programs / speech / weather` lines.
* `git rm -r addons/{audioencoder.*, game.controller.*, kodi.binary.instance.game,
  kodi.binary.instance.screensaver, kodi.binary.instance.visualization,
  metadata.album.universal, metadata.artists.universal,
  metadata.common.{allmusic.com, musicbrainz.org, theaudiodb.com},
  metadata.demo.{movies,tv}, metadata.generic.{albums,artists},
  resource.images.weathericons.default, screensaver.xbmc.builtin.{black,dim},
  service.xbmc.versioncheck}`.

That diff looked clean until I greped the rest of the source tree for
dangling `#include` lines:

```
$ grep -rln '#include.*\(music/\|games/\|cdrip/\|pictures/\|programs/\|speech/\|weather/\)' \
    --include='*.cpp' --include='*.h' xbmc | wc -l
198
```

The 198 files include the Kodi **core**: `xbmc/FileItem.cpp`,
`xbmc/DatabaseManager.cpp`, `xbmc/GUIInfoManager.cpp`,
`xbmc/ServiceManager.cpp`, `xbmc/application/Application.cpp`,
`xbmc/addons/AddonBuilder.cpp`, and the entire `xbmc/addons/Scraper.cpp`
family. Music tags are embedded in `FileItem`, game tags too, music
database in `DatabaseManager`, the audio CD auto-rip in `Autorun.cpp`,
PartyMode in `xbmc/PartyModeManager.cpp`, the disc-insert auto-play in
`xbmc/CueDocument.cpp`, the entire `MusicInfoTag`/`ReplayGain` plumbing
in `FileItem.cpp`, and so on.

That is not "delete a directory". It is a real refactor of the core
type system, the database layer, the info-manager, and the add-on
loader. Per `AGENTS.md`:

> When a substantial refactor or feature is required, establish the
> architecture and intended scope before generating a large
> implementation.
>
> If implementation reveals that a substantially larger change is
> necessary, report that before continuing to expand the diff.

So the source-tree edits were reverted in their entirety. The slim
preset + the vendored Jellyfin add-on remain.

## Realistic scope of "lightweight Kodi"

If the goal is a binary that genuinely does not contain the music,
games, weather, pictures, screensaver, and visualization code, the
actual work breaks into these milestones. Each is independently
reviewable but they add up to several weeks, not days.

1. **Refactor `FileItem` / `DatabaseManager` / `GUIInfoManager`** to
   make music + game tags optional feature flags (compile-time, not
   runtime). Today they are unconditional `CMusicInfoTag` /
   `CGameInfoTag` members.
2. **Split `xbmc/addons/Scraper.cpp`** so album / artist scrapers do not
   require the music database to exist.
3. **Move weather + pictures content type registration** out of the
   info-manager and into a separate `xbmc/weather/` / `xbmc/pictures/`
   optional subsystem loaded by `add_subdirectory()` only when the
   corresponding compile-time flag is enabled.
4. **Move `CueDocument`, `PartyModeManager`, `Autorun.cpp` (CD auto-rip
   branch), `MusicInfoTag`, `ReplayGain`, `MusicFileItemClassify`** out
   of the always-compiled core and into the optional music subsystem.
5. **Decide whether to keep music and skin in core** or move them out.
   The "Estuary" skin in `addons/skin.estuary/xml/Home.xml` references
   `music`, `pictures`, `weather`, and `livetv` content blocks by id;
   those entries must be made conditional (Estuary uses an
   `Include` / `Defs` mechanism for conditional skins — see
   `addons/skin.estuary/xml/Includes_Defs.xml`).
6. **Drop `xbmc/games/` entirely**: the games subsystem is mostly
   self-contained (its own controllers, ports, database, dialogs) and
   already isolated behind `kodi.binary.instance.game` addons. Once the
   music/game tag coupling in core is removed, deleting `xbmc/games/`
   plus the `cmake/treedata/common/games.txt` filelist becomes
   straightforward.
7. **Then** drop `xbmc/music/`, `xbmc/cdrip/`, `xbmc/pictures/`,
   `xbmc/programs/`, `xbmc/speech/`, `xbmc/weather/`, plus the
   corresponding in-tree add-ons, and edit
   `cmake/treedata/common/subdirs.txt` accordingly.

Until steps 1–4 are done, deleting the dirs does not compile.

## What the slim preset already gives you

Even without touching the source tree, `cmake/presets/slim.cmake` cuts a
real chunk out of the dependency graph on macOS / Linux / Windows
desktop targets:

| Disabled | Transitive deps dropped from the build |
|---|---|
| `ENABLE_OPTICAL=OFF` | `libcdio`, `libcdio-paranoia` (the audio CD reader), and any autoplay/autorip code paths |
| `ENABLE_DVDCSS=OFF` | `libdvdcss` (CSS-protected DVD playback) |

Combined with the vendored `plugin.video.jellyfin` add-on, a build with
this preset produces a Kodi binary that already does what the user
asked for:

* Boots straight into Jellyfin-mode (no first-run wizard, no network
  repo required for the add-on itself).
* Plays the full Jellyfin library including transcoded streams via the
  `kodi.binary.instance.inputstream` add-on (already in tree).
* Still supports AirPlay receiver and the HTTP web interface.

Use it like this (after running Kodi's standard `tools/depends` build
for your platform):

```sh
cmake -S . -B build \
      -C cmake/presets/slim.cmake \
      -DCORE_PLATFORM_NAME=<osx|linux:GBM|X11|…>
cmake --build build
```

## Why Jellyfin's Python deps are not vendored

`plugin.video.jellyfin` 2.2.0 declares these `requires` in
`addons/plugin.video.jellyfin/addon.xml`:

```
xbmc.python 3.0.0
script.module.requests 2.22.0+matrix.1
script.module.dateutil 2.8.1+matrix.1
script.module.websocket 1.6.4
script.module.typing_extensions 4.7.1
```

`xbmc.python` ships in-tree. The other four are Kodi matrix-era
Python modules that are maintained by Team Kodi in the official add-on
repository (`addons/repository.xbmc.org` is already in this tree). On
first launch, Kodi will install them automatically from that repo. If
you want them vendored too, copy them from
<https://mirrors.kodi.tv/addons/matrix/script.module.requests/> (and
the others) into `addons/` and adjust `addons/repository.xbmc.org`'s
`addon.xml` accordingly. They are not vendored by default to keep the
diff focused.

## Updating the vendored Jellyfin add-on

When upstream `jellyfin/jellyfin-kodi` ships a new release:

```sh
cd /path/to/jellyfin-kodi        # your local clone
git pull --depth=1               # if also shallow
cd addons/plugin.video.jellyfin
rsync -a --delete \
  --exclude='addon.xml' --exclude='changelog.txt' \
  /path/to/jellyfin-kodi/ .
# Then re-run build.py from upstream to regenerate addon.xml,
# or hand-edit addon.xml with the new version + matrix.py3 dependencies.
```

The `changelog.txt` and `addon.xml` in the vendored copy should track
upstream release notes; everything else is a straight copy.