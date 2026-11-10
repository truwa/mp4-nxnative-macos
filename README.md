# MP4 nxnative

A Mac app that builds Metroid Prime 4: Beyond (Switch, version 1.1.0) from your own copy of the game and plays it natively on Apple silicon.
It runs on [nxnative](https://github.com/seedds/nxnative) by seedds, with our changes for this game.
Nothing from the game is in this repository or in the app. Not affiliated with or endorsed by Nintendo.

## Before you start: this is a beta

Please read this part. MP4 nxnative works, and on a Mac mini M4 the game runs smoothly at 60 fps, but it is still early days.

**Not the whole game has been played.** We have played through the opening hours and checked the parts we changed, but nobody has
finished the game with it yet. You may run into graphical glitches, a crash in an area we haven't reached, or something that looks
slightly off. If you do, the log in the app's Play window helps us a lot.

**Only one version is supported.** The app is made and tested for Metroid Prime 4: Beyond on Switch, version 1.1.0, title ID
`010019A01E2F2000`. You need the base game plus the 1.1.0 update. Other versions won't work.

**The first build takes a long time.** This game has around 260,000 shaders, the small programs that draw everything you see, and each one
has to be compiled for your Mac before it can be used. That happens once, on your own Mac, and takes roughly three hours on a Mac mini M4
(longer on slower Macs). The finished build needs about 65 GB of disk space, and the build cleans up as it goes, so it never needs much more than that while it runs (plan for about 70 GB free).

**You can play long before it's done.** With Quick start (on by default), the app first compiles the shaders we recorded while playing the
opening of the game, and the game is ready after about ten minutes. The rest keeps compiling quietly in the background while you play.
You can also stop the build and pick it up later; nothing is lost.

## What we added on top of nxnative

nxnative does the heavy lifting of running Switch games natively on a Mac. For this game we added, among other things:

- **Higher resolutions** without any mods: 1080p, 1440p, 4K, 5K and 8K, plus two ultrawide sizes, made from the game's own code.
- **A scan visor that works at higher resolutions.** At higher sizes the game's scanner used to find nothing; it works again (it may still show a few extra targets).
- **Quick start** and a faster, multi-process shader build, with a time estimate made on your own Mac.
- **Saves that work on any drive**, including external drives formatted Mac OS Extended or exFAT.
- **A Mac app around it all**: it finds your game files (also from a Ryujinx or Astris setup), checks Xcode, builds, plays and updates itself,
  with controller options, a picture Fill mode and an on-screen overlay showing the resolution and frame rate.

## For players

Download the disk image from the Releases page, open it and drag MP4 nxnative onto Applications. The `README.txt` inside the disk image
lists what you need: an Apple silicon Mac with macOS 26 or later, Xcode with its Metal Toolchain, your own game dump with the
1.1.0 update and your prod.keys, and about 70 GB of free space (the finished build takes about 65 GB).

## For developers

| Folder | What it holds |
|---|---|
| `launcher/` | The SwiftUI app: Build, Play, Settings and Speed test windows, Check for Updates |
| `runtime/` | The scripts the app runs: `nx_build.py` (building), `nx_play.py` (starting the game), `nx_speedtest.py` |
| `scripts/` | Making the app's private Python and runtime bundle, and `release.sh` (sign, notarize, disk image, update zip) |
| `nxnative/` | The engine, a separate repository cloned here (not part of this one) |

```bash
git clone <this repository> mp4-nxnative && cd mp4-nxnative
git clone <the engine repository> nxnative
make app NX_REF=WORKTREE     # launcher/dist/MP4 nxnative.app, with developer options
make release                 # the signed, notarized release in release.noindex/<version>/
```

Building needs Xcode 27.2 with the Metal Toolchain and the .NET SDK 10.

## Licence

MIT License, see `LICENSE`. nxnative is under its own MIT License (in its repository and inside the app).
