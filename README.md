# buildbroom

**English** · [Türkçe](README.tr.md)

Safely reclaim disk space eaten by developer caches and build artifacts.

If you work on many repos, or on one repo with several **git worktrees**, build output piles up
fast: every worktree gets its own `node_modules`, `bin/obj`, `target`, `.next`, `build` and so on.
Add global caches (npm, Gradle, NuGet, Go, Docker build cache, Temp) on top of that and your system
drive fills up again every few weeks. Each time you end up looking up which folders are safe to delete.

buildbroom keeps that knowledge in one script, and **does nothing destructive unless you ask it to**.

> Status: **Windows (PowerShell 5.1+)** and **macOS (bash 3.2+)** work today. Linux is planned. See [ROADMAP](docs/ROADMAP.md).

## Quick start (Windows)

```powershell
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom

.\buildbroom.cmd                              # dry run: report caches (+ artifacts under your configured roots)
.\buildbroom.cmd -Mode artifacts -Roots D:\code,E:\work
.\buildbroom.cmd -Mode artifacts -Roots D:\code -OlderThanDays 14 -Apply
.\buildbroom.cmd -Mode caches -Apply
```

`buildbroom.cmd` just runs `windows\buildbroom.ps1` with `-ExecutionPolicy Bypass`, so you don't have to
change your execution policy. You can also call the `.ps1` directly.

## Quick start (macOS)

```bash
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom

unix/buildbroom.sh                                  # dry run: report caches (+ artifacts under your configured roots)
unix/buildbroom.sh --mode artifacts --roots ~/code,~/work
unix/buildbroom.sh --mode artifacts --roots ~/code --older-than-days 14 --apply
unix/buildbroom.sh --mode caches --apply
```

It runs on the bash 3.2 that ships with macOS and needs nothing else. To call it as `buildbroom`, link it
somewhere on your `PATH`: `ln -s "$PWD/unix/buildbroom.sh" /usr/local/bin/buildbroom`.

## What it cleans

### `caches` (global, re-downloadable)

| Target | How |
|---|---|
| npm cache | `npm cache clean --force` |
| Yarn cache | `yarn cache clean` |
| pnpm store | `pnpm store prune` (unreferenced packages only) |
| Go build cache | `go clean -cache` |
| Gradle `caches/` + `daemon/` logs | stops Gradle daemons first; skipped while Android Studio / IntelliJ is open |
| NuGet http + plugins cache | `dotnet nuget locals ... --clear`; skipped while Visual Studio / Rider is open |
| Temp | only top-level entries with nothing inside written for `-TempDays` days (default 3) |
| Crash dumps | `%LOCALAPPDATA%\CrashDumps` |
| Docker build cache | `docker builder prune -f`. Images, containers and volumes are **not** touched. The size is the reclaimable build cache from `docker system df` |

With `-Deep`: NuGet global packages and Gradle wrapper distributions as well. The next build
downloads them again.

**Report only, never deleted:** Docker Desktop / WSL virtual disks, Android SDK, Android emulators,
Downloads. They show up in the report so you know where your space went.

#### On macOS

| Target | How |
|---|---|
| npm, Yarn, pnpm, Go build cache | same commands as above (`~/.npm`, `~/Library/Caches/Yarn`, `~/Library/pnpm/store`, `go env GOCACHE`) |
| Gradle `caches/` + `daemon/` logs | skipped while Android Studio / IntelliJ is open **or a Gradle daemon is running** (it is never killed; run `./gradlew --stop` first) |
| NuGet http + plugins cache | `dotnet nuget locals ... --clear`; skipped while Rider is open |
| Xcode `DerivedData` | skipped while Xcode or `xcodebuild` is running |
| Xcode device support | only `iOS/watchOS/... DeviceSupport` folders unused for 90 days. Xcode copies them again when that device connects |
| CocoaPods cache | `pod cache clean --all` |
| SwiftPM cache | `~/Library/Caches/org.swift.swiftpm`; skipped while Xcode is running |
| Homebrew | `brew cleanup` (old downloads and old versions) |
| Docker build cache | `docker builder prune -f`, only when Docker is running |

With `--deep`: Go module cache (`go clean -modcache`), Gradle wrapper distributions and NuGet global packages.

**Report only:** Xcode archives, iOS simulators (`xcrun simctl delete unavailable` frees the stale ones),
Android SDK, Android emulators. Docker's disk image and `~/Downloads` are not measured, because reading them
makes macOS ask for folder access.

### `artifacts` (per project, under `-Roots`)

| Folder | Only when the parent has |
|---|---|
| `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.parcel-cache`, `dist` | `package.json` |
| `.turbo` | `package.json` / `turbo.json` |
| `.angular` | `angular.json` |
| `bin`, `obj` | `*.csproj` / `*.fsproj` / `*.vbproj` |
| `target` | `Cargo.toml` / `pom.xml` |
| `build`, `.gradle` | Gradle / Flutter / CMake project files |
| `.dart_tool` | `pubspec.yaml` |
| `__pycache__`, `.pytest_cache`, `.mypy_cache` | Python files |

### Stale git worktrees (report only, macOS for now)

With `--mode artifacts`, `all` (when roots are set) or `worktrees`, buildbroom also lists linked git worktrees
under your roots that look abandoned:

- **folder is gone**: the worktree was deleted by hand; `git worktree prune` cleans up git's record of it
- **merged into main** (or `origin/HEAD`): its branch has nothing that is not already in the default branch
- **last commit N d ago**: older than `--stale-days` (default 30)

Each row shows how much space the worktree takes and warns when it **has uncommitted changes**. Worktrees are
never removed: remove one yourself with `git worktree remove <path>`, which refuses when there is uncommitted work.
Active worktrees are not listed.

## Safety model

1. **Dry run by default.** Without `-Apply`, buildbroom only prints a report.
2. **Marker files.** A folder named `build` is only a candidate if a real project file sits next to it.
3. **Git check.** A candidate is deleted only if `git check-ignore` says it is ignored, so a
   committed `dist/` or `bin/` is never touched. Folders outside a git repo are kept unless you
   pass `-NoGitCheck`.
4. **Age check.** If anything *inside* the folder was written within `-OlderThanDays` (default 7),
   it is kept, so the worktree you are working in right now stays as it is. (A folder's own
   timestamp is not enough: Windows does not update it when files deeper inside change.)
5. **No junction following.** Folders are deleted with `rmdir /s /q`, which removes
   junctions/symlinks without going into them, so a pnpm or monorepo workspace link inside
   `node_modules` never takes the real source with it. (Some older PowerShell builds had bugs
   where `Remove-Item -Recurse` followed links. buildbroom does not rely on it.) Scanning and
   size measuring skip reparse points too. On macOS, `rm -rf` removes a symlink as a link and never enters
   it, and scanning and measuring use `find -P` / `du -P`, which never follow links.
6. **Tool and system folders are never scanned:** `AppData`, `Program Files`, `ProgramData`,
   `Windows`, and tool homes like `~\.vscode`, `~\.cursor`, `~\.nuget`, `~\.gradle`, `~\.cargo`.
   A `node_modules` in there belongs to an installed program (global npm, VS Code extensions, nvm).
   Packages inside a `node_modules` are never mistaken for projects either.
   On macOS: `/System`, `/Library`, `/Applications`, `/usr`, `/opt` (Homebrew), `~/Library` and tool homes
   such as `~/.nvm`, `~/.cargo`, `~/.gradle`, plus the Flutter SDK found on your `PATH`. Paths are compared case-insensitively, like APFS does.
7. **No surprise scans.** The default `all` mode only scans for artifacts under roots you passed
   or configured. `-Mode artifacts` without roots scans the current folder.
8. **Busy or missing tools.** Cache cleanups that could break a running IDE are skipped while that
   IDE is open. Caches whose tool is not on `PATH` are skipped and reported as such.
9. **Honest report.** After `-Apply`, sizes are measured again, so the report shows what was
   really freed, and folders that could not be fully deleted (files in use) are marked.

## Options

| Windows | macOS | Default | Meaning |
|---|---|---|---|
| `-Mode` | `--mode` | `all` | `all`, `caches` or `artifacts`; macOS also has `worktrees` (report only) |
| `-Roots` | `--roots` | from config, else none | one or more folders to scan for artifacts (comma-separated or repeated) |
| `-OlderThanDays` | `--older-than-days` | `7` | keep artifacts changed more recently than this |
| `-TempDays` | | `3` | keep Temp entries newer than this (macOS cleans its temp folder itself) |
| `-MaxDepth` | `--max-depth` | `8` | how deep to scan under each root |
| | `--stale-days` | `30` | report worktrees whose last commit is older than this (`staleDays` in the config) |
| `-Exclude` | `--exclude` | | wildcard paths to skip, e.g. `*\keep-me\*` / `*/keep-me/*` |
| `-NoGitCheck` | `--no-git-check` | off | also clean artifacts in folders that are not git repos |
| `-Deep` | `--deep` | off | also clear big caches that take long to download again (see above) |
| `-Apply` | `--apply` | off | actually delete |
| | `--json` | off | print the report as JSON (see below) |
| `-Config` | `--config` | see below | config file to read |

## JSON output (macOS)

`--json` prints the whole report as one JSON object on stdout, for scripts, CI or a scheduled run. Progress
lines go to stderr, so `unix/buildbroom.sh --json --roots ~/code > report.json` gives a clean file. Every row is
included, also skipped and kept ones. `name` is set for caches and report-only items, `path` for folders,
`newestWrite` (the newest write inside, UTC) for artifacts. `freeBytesAfter` is only set with `--apply`.

```json
{
  "version": "0.1.0", "os": "macOS", "mode": "artifacts", "apply": false,
  "freeBytes": 201265348608, "freeBytesAfter": null, "reclaimableBytes": 1880000000,
  "items": [
    {"kind": "artifact", "name": null, "path": "/Users/me/code/app/node_modules", "bytes": 1880000000,
     "status": "would delete", "newestWrite": "2026-10-02T08:14:00Z"}
  ]
}
```

## Config file

So you don't have to type your roots every time, put them in
`%USERPROFILE%\.config\buildbroom\config.json` (see [`config.example.json`](config.example.json)):

```json
{
  "roots": ["D:\\code", "E:\\work"],
  "olderThanDays": 7,
  "exclude": ["*\\vendor-snapshots\\*"]
}
```

On macOS the file is `~/.config/buildbroom/config.json` (or under `$XDG_CONFIG_HOME`), with paths like
`"~/code"`. It is read with the built-in `plutil` (macOS 12 or later).

Command-line options override the config.

## Running it regularly

Run it every week or two, read the dry-run report, then repeat with `-Apply`. If you prefer
to schedule it, use Task Scheduler on Windows, or `cron` / a launchd agent on macOS. Schedule `-Mode caches -Apply` first. Turn on artifact cleanup
only after a few dry runs show it picks the right folders.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the [code of conduct](CODE_OF_CONDUCT.md), and report
security problems privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
