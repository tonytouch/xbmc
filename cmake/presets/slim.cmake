# Slim Kodi build preset.
#
# This file is meant to be passed via `cmake -C` BEFORE the project's
# options() definitions are evaluated, so the initial cache values here
# take effect:
#
#   cmake -S . -B build -C cmake/presets/slim.cmake
#
# What it does:
#   * Disables Optical drive + libdvdcss (no DVD/CD playback).
#   * Keeps AirTunes / AirPlay receiver enabled (DACP).
#   * Keeps Python (required by plugin.video.jellyfin).
#   * Keeps microhttpd (HTTP web interface).
#   * Keeps PVR / Live TV (codepath is already in tree).
#
# Combine with the slim addons/ tree (see docs/LIGHTWEIGHT.md) for the
# "Jellyfin-first" configuration.

# Optical / DVD: dropped. Authored 2026-10-03 by slim-kodi.
set(ENABLE_OPTICAL     OFF CACHE BOOL "Slim: drop optical drive support"    FORCE)
set(ENABLE_DVDCSS      OFF CACHE BOOL "Slim: drop libdvdcss"                FORCE)

# AirPlay: kept. The AirTunes option also gates xbmc/network/dacp via
# cmake/treedata/optional/common/dacp.txt.
set(ENABLE_AIRTUNES    ON  CACHE BOOL "Slim: keep AirTunes/AirPlay"         FORCE)

# Python: required. plugin.video.jellyfin is Python, and the matrix-era
# Python modules it depends on (script.module.requests / dateutil /
# websocket / typing_extensions) ship via repository.xbmc.org.
set(ENABLE_PYTHON      ON  CACHE BOOL "Slim: keep Python (jellyfin-kodi)"   FORCE)

# HTTP web interface: kept. Without it, Chorus and HTTP remote apps stop
# working. Low-cost feature.
set(ENABLE_MICROHTTPD  ON  CACHE BOOL "Slim: keep HTTP web interface"       FORCE)