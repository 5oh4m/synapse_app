# Toolchain — pin this, it explains contradictory bug reports

## Two Flutter SDKs are installed on this machine

| Location | Version | On PATH? |
|---|---|---|
| `/opt/homebrew/share/flutter` | **3.47.3** | yes — this is what `flutter` resolves to in a normal shell |
| `~/flutter` | **3.41.2** | no | 

Everything in this project up to the v2 rewrite was built and verified against
**3.41.2** (`~/flutter/bin`). A normal `flutter run` in this repo therefore uses a
**six-version-newer SDK than anything was tested on**.

## This resolves two "contradictory" findings

Both of these were reported as defects and both are version-dependent, which is why
they reproduced for one of us and not the other:

- **`ReorderableListView.onReorder` deprecated.** Verified: `onReorderItem` exists in
  3.47.3 and does **not** exist in 3.41.2. So the deprecation warning is real and
  actionable on 3.47.3, and unfixable on 3.41.2 — the suggested replacement simply
  isn't in that SDK. Migrate only once the project is pinned to 3.47.3.
- **`InkSparkle` shader crash in `flutter test`.** The shader exists in both SDKs, so
  this is a runtime/headless difference rather than a missing asset. It did not
  reproduce on 3.41.2 (full suite passed repeatedly). Expect it on 3.47.3, where the
  fix is to set `splashFactory: NoSplash.splashFactory` in the test theme (or globally
  in the app theme, which is also defensible for a flat Bauhaus design that shouldn't
  have a sparkle splash anyway).

## Decision

Pin the project to a single SDK and state it in the repo, so this ambiguity cannot
recur. Target **3.47.3**, because that is what is on PATH and what the developer
actually runs.

Action at integration (deliberately deferred — switching SDKs rewrites
`.dart_tool/package_config.json` and `pubspec.lock`, which would corrupt a concurrently
running agent's environment):

1. Wait until all rewrite agents have finished.
2. `export PATH=/opt/homebrew/share/flutter/bin:$PATH && flutter pub get`
3. Run `dart analyze lib test` and `flutter test`.
4. If green: bump the `environment.flutter` constraint in `pubspec.yaml`, migrate
   `onReorder` → `onReorderItem`, add `NoSplash.splashFactory`, commit the new
   `pubspec.lock`, and record the version here.
5. If it breaks: stay on 3.41.2, but add an `fvm`/`.flutter-version` pin plus a README
   note so `flutter` on PATH is never silently used.

Note: `flutter analyze` crashes on this machine on **both** SDKs (broken
`analysis_server.dart.snapshot` in the cache). Use `dart analyze lib test`.

## Done (15 Sep 2026)

Pinned to **3.47.3**: `environment.flutter: ">=3.47.0"` in `pubspec.yaml`, and
`onReorder` → `onReorderItem` in the question review screen (the new callback already
adjusts `newIndex` for the removed item, so the manual `-1` is gone). `dart analyze lib test`
reports no issues and `flutter test` passes on 3.47.3. The answer tiles use
`NoSplash.splashFactory`; the global theme still uses `InkRipple`.

## If `flutter` fails with "You have not agreed to the Xcode license"

The `flutter` launcher calls `git`, and the native-asset hook of `objective_c` calls
`xcrun`; both go through Xcode and stop until its license is accepted. The permanent fix is
`sudo xcodebuild -license accept`. Without admin rights, point both at the Command Line Tools
for one command:

```sh
mkdir -p /tmp/clt-bin
printf '#!/bin/sh\nexport DEVELOPER_DIR=/Library/Developer/CommandLineTools\nexec /usr/bin/xcrun "$@"\n' > /tmp/clt-bin/xcrun
printf '#!/bin/sh\nexport DEVELOPER_DIR=/Library/Developer/CommandLineTools\nexec /usr/bin/git "$@"\n' > /tmp/clt-bin/git
chmod +x /tmp/clt-bin/*
PATH=/tmp/clt-bin:$PATH flutter test
```

The wrapper is needed for `xcrun` because build hooks run with a filtered environment that
drops `DEVELOPER_DIR`.
