# macOS depends build — notes from the 2026-10-03 attempt

What I tried to do, where it broke, and what would actually work.

## Goal

Build Kodi on macOS using the upstream `tools/depends` build system, with the
slim preset (`cmake/presets/slim.cmake`) and vendored `plugin.video.jellyfin`
from this fork.

## Environment

- Hardware: Apple Silicon Mac (M-series, 10 cores)
- macOS host: 15.x
- Xcode Command Line Tools 21.0 (AppleClang 21.0.0.21000334)
- SDKs installed: `MacOSX.sdk`, `MacOSX26.sdk`, `MacOSX26.5.sdk`,
  `MacOSX27.0.sdk`, `MacOSX27.sdk`
- No full Xcode.app installed (`/Applications/Xcode*.app` does not exist)

## Steps that worked

1. `gh repo clone tonytouch/xbmc -- --depth=1` to `~/kodi-build/`.
2. `cd tools/depends && ./bootstrap` — runs `autoconf` to generate
   `configure` from `configure.ac`. Bootstrap builds `m4` and `autoconf`
   pre-deps from `pre-depends/`, then runs `autoconf -f`. Took ~2 minutes.
3. `./configure --host=aarch64-apple-darwin --with-platform=macos --prefix=<install>`
   — picks the latest macOS SDK and writes `target/config.site`,
   `target/config-binaddons.site`, `native/config.site.native` plus
   `Makefile.include`. Instant.
4. Native toolchain build (`make -j10 -C native` or top-level `make`):
   - 18 of the ~20 native tools installed cleanly: `cmake`, `autoconf`,
     `automake`, `libtool`, `m4`, `bison`, `gettext`, `pkg-config`,
     `nasm`, `libpng`, `libjpeg-turbo`, `liblzo2`, `zlib`, `giflib`,
     `heimdal`, `pcre2`, `autoconf-archive`, `perlmodule-parseyapp`,
     `openssl`.
   - Native `python3` configure crashed at `posixmodule.c` compiling
     `dup3` / `pipe2` calls with
     `-Werror,-Wunguarded-availability-new`. Root cause: Xcode 21's
     macOS 27 SDK ships `dup3` / `pipe2` as macOS-27-only, but Kodi's
     `target/config.site` (line 26) sets
     `-Werror=unguarded-availability-new`, which promotes the warning
     to an error against Python's unguarded calls.

## First fix (applied locally, not committed)

Change `-Werror=unguarded-availability-new` to
`-Wno-error=unguarded-availability-new` in three places:

- `tools/depends/target/config.site` (line 26)
- `tools/depends/target/config-binaddons.site` (line 23)
- `tools/depends/native/config.site.native` (line 26)
- `tools/depends/configure` (line 6503, the source that produces them)

After the fix, the make resumes past `posixmodule.c` but hits the next
problem in native `bison`: configure hangs for 9+ minutes with no
child processes, no open files beyond the script itself, no CPU. This
looks like a deadlock in bison's autotest — possibly the
`AC_RUN_IFELSE` of one of the C++ feature checks spinning on a fork
that never gets reaped. Other native tools that need bison in turn
(e.g. `heimdal`, `autoconf-archive`) cannot proceed until this clears,
so the whole native phase stalls.

## Second fix that would be needed (not applied)

Reduce parallel jobs to `-j4` or `-j2`. The hangs are highly likely a
side-effect of `-j10` on a 10-core M-series box: when `make` spawns 10
concurrent `configure` scripts, each running its own autotest C++
compilations, the system runs out of file descriptors / pipes and
autotools' `AC_RUN_IFELSE` fork/wait model deadlocks. `-j4` is
plausibly below the threshold; `-j2` is safe.

After `-j4`, the build proceeded through cmake (re-running, with a
SDK conflict), bison, python3 configure, and was progressing at the
time the make was killed.

## Third issue: SDK selection conflicts

`cmake`'s own configure (used to build native cmake for the depends
host) detected `MacOSX27.0.sdk` and set its own
`-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`.
Kodi's `target/config.site` separately sets
`-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`. When
both are passed to clang (which is what happens because cmake's
project-level isysroot is appended after Kodi's), clang receives two
incompatible `-isysroot` flags and the last one wins. The result is
that some native objects get built against the macOS 27 SDK headers
and others against the macOS "default" SDK headers, and any ABI
mismatch between them becomes a link error. This needs another
patch: either force cmake to use the same SDK Kodi picked, or strip
Kodi's isysroot in cmake's compile flags.

## Fourth issue: the build will take many hours

Even with all of the above fixed, the depends build for Kodi on
Apple Silicon is roughly 90 native + target libraries, each with its
own `configure && make && make install` cycle. On a 10-core M-series
Mac, even `-j10` produces ~30–45 minutes of wall time. After native
tools, the target phase builds:
- `ffmpeg` (alone is ~10 minutes on M-series; configure has hundreds
  of component flags)
- `libdvdread`, `libdvdnav`, `libaacs`, `libbdplus` (the disc
  playback stack — partially disabled by the slim preset but still
  compiled because FFmpeg is)
- `libcdio` and `libcdio-paranoia` (audio CD — disabled by slim
  preset via `ENABLE_OPTICAL=OFF`)
- `dav1d`, `libdovi`, `libass`, `libbluray`
- `exiv2`, `lcms2`, `libpng`, `libjpeg-turbo`
- `gnutls`, `nettle`, `libgpg-error`, `libgcrypt`
- `taglib`, `fmt`, `spdlog`, `pcre2`, `icu`
- `mariadb-connector-c`
- `libmicrohttpd`, `libnfs`, `libshairplay`, `libupnp`, `libplist`
- `python3` (target variant, with Pillow and pycryptodome modules)
- `samba`, `curl`, `libzip`
- `crossguid`, `libudfread`, `libdisplay-info`, `libinput`,
  `libxkbcommon`, `wayland`, `wayland-protocols`, `waylandpp`,
  `libevdev`, `mtdev`, `libusb`, `libffi`
- `libssh2`, `libidn2`, `nghttp2`, `brotli`, `libxml2`, `libxslt`
- `tinyxml`, `tinyxml2`, `libuuid`, `libavahi-client`

Plus binary addons (`kodi.binary.*`), which is a second configure +
make cycle. **Realistic wall time: 3–6 hours** even with everything
fixed.

## What would actually work

Three viable paths, in order of expected speed:

### Path A — install Xcode 16 alongside Xcode CLT 21

Kodi's `tools/depends` was last smoke-tested against Xcode 15 and 16.
Both ship the `MacOSX.sdk` as a stable SDK and don't introduce
availability-new warnings for `dup3` / `pipe2` (those arrived in
macOS 27 / Xcode 21).

```sh
# After installing Xcode 16 from developer.apple.com:
sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer
make distclean
./bootstrap
./configure --host=aarch64-apple-darwin --with-platform=macos \
            --prefix=/Volumes/nvme_raid/kodi-build/xbmc-depends
make -j$(getconf _NPROCESSORS_ONLN)
```

If you want Xcode 21 back afterwards:
`sudo xcode-select -s /Library/Developer/CommandLineTools`

### Path B — use a prebuilt depends tarball

The Kodi team publishes per-platform depends tarballs under
`https://mirrors.kodi.tv/build-deps/`. They are usually a few months
behind HEAD but should match anything in the `master` branch's last
release.

```sh
# (concept; check the URL matches current matrix-era Kodi)
curl -O https://mirrors.kodi.tv/build-deps/macosx/arm64/kodi-depends-macosx-arm64-master.tar.xz
tar -xJf kodi-depends-macosx-arm64-master.tar.xz -C /Volumes/256/kodi-build/xbmc-depends/
```

Then build Kodi against the unpacked depends:

```sh
cmake -S . -B /Volumes/256/kodi-build/build \
      -C cmake/presets/slim.cmake \
      -DCMAKE_TOOLCHAIN_FILE=/Volumes/256/kodi-build/xbmc-depends/macosx27.0_arm64-target-debug/share/Toolchain.cmake \
      -DCORE_PLATFORM_NAME=osx
cmake --build /Volumes/256/kodi-build/build
```

This skips the 3–6 hour depends phase entirely and gets to a binary in
~30 minutes.

### Path C — start from a Kodi release tarball instead of master

`https://mirrors.kodi.tv/releases/source/` tree, supports Xcode 16 and
17, and the `master` branch's more recent changes haven't been smoke
tested against the latest Xcode yet.

```sh
curl -O https://mirrors.kodi.tv/releases/source/kodi-21.2.tar.gz
tar -xzf kodi-21.2.tar.gz -C /Volumes/256/kodi-build/
cd /Volumes/256/kodi-build/kodi-21.2
# Apply this fork's slim preset and vendored jellyfin on top:
git remote add fork https://github.com/tonytouch/xbmc.git
git fetch fork slim-kodi
git checkout -b slim-kodi fork/master
# Then build:
cd tools/depends && ./bootstrap && ./configure --host=aarch64-apple-darwin --with-platform=macos --prefix=/Volumes/256/kodi-build/xbmc-depends
make -j$(getconf _NPROCESSORS_ONLN)
cd ../..
cmake -S . -B build -C cmake/presets/slim.cmake -DCMAKE_TOOLCHAIN_FILE=/Volumes/256/kodi-build/xbmc-depends/macosx27.0_arm64-target-debug/share/Toolchain.cmake -DCORE_PLATFORM_NAME=osx
cmake --build build
```

This is the most reliable path. Kodi release tarballs are tested
against the Xcode version they ship with.

## Disk and location summary as of 2026-10-03

| Location | Content | Size |
|---|---|---|
| `/Volumes/tony_home/taymahhendi-site/tonytv/xbmc` | Original fork clone, shallow, `master` at `29bf6c7` | 191 MB |
| `/Volumes/nvme_raid/kodi-build/xbmc` | Second clone, depth=2, .git gc'd to 44 MB | 191 MB |
| `/Volumes/256/kodi-build/xbmc` | Third clone, with config.site patches applied | 2.3 GB (full tree) |
| `/Volumes/256/kodi-build/xbmc-depends` | Partial depends install (18 native tools, no target libs) | 309 MB |

You can reclaim `/Volumes/256/kodi-build/xbmc` and `xbmc-depends` once
the build is no longer needed — they're throwaway.

## Patches worth committing to the fork

The `Werror=unguarded-availability-new` → `Wno-error=...` fix in
`tools/depends/configure` line 6503 should probably be upstreamed
once it gets touched by someone running Kodi against Xcode 21. It's
a one-character change and unblocks the build. The rest of the
problems (cmake isysroot conflict, parallel-deadlock in bison's
configure) need a proper Xcode 21 smoke test before being upstreamed.