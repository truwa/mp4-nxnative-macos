MP4 nxnative 0.3 beta
=====================

MP4 nxnative builds Metroid Prime 4: Beyond from your own copy of the game and plays it natively on an
Apple silicon Mac. Nothing from the game is included: you bring your own game files and keys.
Not affiliated with or endorsed by Nintendo. This is a beta: on a Mac mini M4 the game runs at 60 fps,
with some stutters, especially when entering a new room or area. The whole game hasn't been tested yet:
it has been played up to the beginning of Sol Valley without major issues.

Install
-------
Drag "MP4 nxnative" onto Applications, then open it from there. The app is signed and notarized.

What you need
-------------
- A Mac with Apple silicon and macOS 26 or later (tested on macOS 27.2, Mac mini M4 with 16 GB).
- Xcode with its Metal Toolchain. The shaders are compiled on your Mac by Apple's Metal compiler.
  Xcode 27.2 is the tested version (it needs macOS 26.6 or later); on an earlier macOS 26, use the newest
  Xcode that runs on it (untested). The app checks this and can download the Metal Toolchain for you.
- Your own dump of Metroid Prime 4: Beyond (the base game) and its 1.1.0 update, and your prod.keys.
  Only version 1.1.0 is supported. The app can find these in an existing Ryujinx or Astris setup.
- Free space on a fast drive formatted APFS or Mac OS Extended (HFS+): about 70 GB. The finished
  build takes about 65 GB, and the build never needs much more than that while it runs.
  exFAT drives work but are not recommended.

Building
--------
The first build compiles about 260,000 shaders for your Mac: about 2.5 hours on a Mac mini M4.
With Quick start (on by default) you can play after about 10 minutes while the rest compiles in the
background; you can stop the build and continue later. Quick start covers the shaders we recorded
up to the Carvex boss fight: playing past it before the full build has finished is not recommended.
Your saves stay in the build folder.

Don't move or delete the build folder in Finder; use the app's own Remove and Change buttons, so the
app always knows where your build is.

Settings
--------
Resolution: 900p is the game's own size; 1080p up to 8K and two ultrawide sizes are made from the
game's own code. Picture Fill covers the whole window and crops the picture's edges. Controllers:
buttons follow a Switch's layout by position by default; Settings > Controls changes that.

Updates
-------
MP4 nxnative > Check for Updates looks for a newer release, downloads it and replaces the app
(not while the game or a build runs). After an update the app may offer to refresh the build's tools.

Known limits
------------
- At higher resolutions the scan visor works, but it may show a few extra scan targets.
- Stutters, especially when entering a new room or area.
- Mods (frame rate, level of detail) are held back for a later release.

Credits
-------
Built on nxnative (github.com/seedds/nxnative), used under the MIT License.
MP4 nxnative by MacGameTest, open source under the MIT License. The full notices are in the app's About window.
