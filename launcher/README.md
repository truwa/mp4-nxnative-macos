# MP4 nxnative: the launcher app

A macOS app that takes the user's own Metroid Prime 4: Beyond dump (XCI or NSP, the 1.1.0 update NSP and `prod.keys`),
builds the native runtime's data on the user's Mac, and launches the game as a native Apple-silicon app.
Nothing from the game is in this repository. The runtime bundle (the build and play scripts, the nxnative engine, .NET, a private Python) is made by the top-level `make app`.

## Building (0.1)

Requires macOS 26 or later on Apple silicon, Xcode 27 command-line tools and Python 3.

```bash
make app        # swift build + assemble dist/MP4 nxnative.app
make run        # build and open it
make release    # optimised build
```

From the repository root, `make app` builds the runtime and this app with the runtime inside it (`launcher/dist/MP4 nxnative.app`).
For development the launcher also takes a runtime bundle at `dist/Runtime` next to the app, or one picked on the Locations screen.
`docs/CONTRACT.md` records what the launcher expects from the runtime. `Testing/FakeRuntime/` is a stand-in runtime for testing the launcher without the game.

Two windows: **Build** (a checklist of the base game, the 1.1.0 update, prod.keys, the build folder and this Mac; then the
build with steps, progress and time left) and **Play** (Play, resolution, Game Mode, Metal HUD, shader progress, status,
log), plus Settings behind the gear. Design: `../docs/LAUNCHER_UI.md`.

Everything the app writes is in the build folder, `~/Library/Application Support/mp4launcher` by default (a different
one can be chosen; then only `location.json` stays there): `settings.json`, the game folder with game data, shaders,
saves, logs, the copied prod.keys (mode 600) and resolution packs (`mods/`). Nothing is kept in macOS defaults. The
first start renames a 0.1 `MP4 Launcher` folder and reads its settings once. The icon is `Resources/AppIcon.svg`.
