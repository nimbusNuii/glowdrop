# Changelog

All notable changes to Glowdrop are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-11-20

### Added

- Right-click a Glowdrop tile in System Settings → Wallpaper (macOS 26 or later) for "Add Video…" or
  "Open Glowdrop Library…"; both open the Glowdrop gallery.
- Settings → "Show a still image when Reduce Motion is on" (on by default): while macOS's Reduce Motion is on,
  both engines hold a still image instead of playing.

### Fixed

- A library video re-rendered under the same name now refreshes its tile image in System Settings and the
  wallpaper that shows it, instead of keeping the old picture.

### Security

- The new `glowdrop://` links accept only `glowdrop://add-video` and `glowdrop://library`; anything else in the
  link (a path, query, user name or port) makes Glowdrop ignore it, and no link can name a file.

## [0.3.0] - 2026-11-20

### Added

- macOS wallpaper engine (experimental, macOS 26 or later): Settings → Wallpaper engine → "macOS wallpaper" lets
  macOS play Glowdrop videos on the desktop and the Lock Screen, like Aerials. Playback continues after you quit
  Glowdrop. System Settings → Wallpaper shows a "Glowdrop" tile that follows the app plus one tile per library
  video, so each display or Space can show a different video. The default stays "Glowdrop window".
- Menu bar → "Restart Wallpaper Agent" (macOS 26 or later) for a stuck or grey wallpaper.
- When a Glowdrop wallpaper is selected and macOS stopped its extension while Glowdrop launched, Glowdrop restarts
  the Wallpaper Agent once, so the wallpaper keeps playing.
- The wallpaper extension honours Pause, Low Power Mode, the battery rule and high thermal pressure, and keeps a
  surface for 15 seconds after macOS releases it, so Space switches and wake do not flash dark.

### Changed

- The Lock Screen option is now part of the "Glowdrop window" engine; the macOS wallpaper engine always covers
  the Lock Screen.
- Pausing Glowdrop also pauses the Lock Screen video.

### Security

- The extension still has no network access and can read only
  `~/Library/Application Support/Glowdrop/LockScreen/`. The new `catalog.json` there is read like `state.json`:
  a regular, non-symlink file of at most 256 KB; entries must name a video file the app wrote, titles are cut to
  80 characters without control characters, and at most 200 entries are used.
- Videos on another drive get no tile of their own, so Glowdrop never copies a whole library across drives.
- Glowdrop never copies videos out of protected folders on its own: library videos that are links to files outside
  the library folder, and "My Videos" files in Desktop, Documents, Downloads or iCloud Drive get no tile.
- The shared folder must be a real folder (not a symbolic link) before Glowdrop writes or deletes anything in it;
  the extension ignores symbolic links inside it; tile titles drop invisible formatting characters.
- Movies are opened with external references forbidden, so a video file can never make Glowdrop or the extension
  load media from anywhere else.

## [0.2.0] - 2026-11-20

### Added

- Lock Screen (experimental, macOS 26 or later): Settings → "Show on Lock Screen" puts the playing wallpaper on
  the Lock Screen after you choose Glowdrop once in System Settings → Wallpaper. A bundled wallpaper extension plays
  the video only while the screen is locked or the screen saver is on, and shows a still frame otherwise. It uses
  undocumented system interfaces and may break after a macOS update. The extension plumbing is derived from
  Phosphene (MIT).
- `build.sh --release` also builds a drag-to-install `Glowdrop-<version>.dmg`.

### Security

- The wallpaper extension runs in the App Sandbox and can read only
  `~/Library/Application Support/Glowdrop/LockScreen/`; it rejects callers that are verifiably not Apple-signed
  and reads only a regular, non-symlink `state.json` of at most 4 KB that names an mp4, mov or m4v file the app wrote there.
- Its writes into private system objects are made only after the expected memory layout is verified at startup;
  on a mismatch it replies with an error instead. Errors and paths are logged as private.

## [0.1.0] - 2026-11-19

First public release.

### Added

- Plays a looping video as the desktop wallpaper on every display, behind the desktop icons.
- Fully offline: no network code, no account, no analytics.
- Library folder where each subfolder is a category, with optional `-4k` / `-2k` variants, thumbnails
  and a `wallpapers.json` sidecar for titles, order and the default wallpaper.
- Gallery window with a sidebar, search, drag and drop, "Add Video…" and Open With from Finder.
- Settings window (⌘,): open at login, language (Thai / English / system), quality (Auto / 2K / 4K),
  library folder, and pause rules (covered by windows, screen locked, Low Power Mode, on battery).
- Auto quality: 4K only on a wide (3200 px+) display while on power, otherwise 2K.
- Files macOS cannot play are rejected with a banner; the current wallpaper keeps playing.
- Three bundled glitch wallpapers (Neon Green, Neon Purple, RGB Glitch) rendered by `tools/glitch-render`.
- Universal build (Apple Silicon and Intel), macOS 13 or later.
- App icon, generated by `tools/app-icon`.

### Security

- Signed with the hardened runtime, so other processes cannot inject code into the app.
- `wallpapers.json` files larger than 64 KB are ignored and titles are limited to 80 characters, so a hostile
  library folder cannot stall the app.
- "Open Library Folder" only reveals the folder in Finder; it never launches a file.
