# buildbroom

Safely reclaim disk space eaten by developer caches and build artifacts.

If you work on many repos, or on one repo with several **git worktrees**, build output piles up
fast: every worktree gets its own `node_modules`, `bin/obj`, `target`, `.next`, `build` and so on.
Add global caches (npm, Gradle, NuGet, Go, Docker build cache, Temp) on top of that and your system
drive fills up again every few weeks. Each time you end up looking up which folders are safe to delete.

buildbroom keeps that knowledge in one script, and **does nothing destructive unless you ask it to**.

> Status: **Windows (PowerShell 5.1+)** works today. macOS and Linux are planned. See [ROADMAP](docs/ROADMAP.md).

## Quick start (Windows)

```powershell
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom

.\buildbroom.cmd                              # dry run: report caches + artifacts under the current folder
.\buildbroom.cmd -Mode artifacts -Roots D:\code,E:\work
.\buildbroom.cmd -Mode artifacts -Roots D:\code -OlderThanDays 14 -Apply
.\buildbroom.cmd -Mode caches -Apply
```

`buildbroom.cmd` just runs `windows\buildbroom.ps1` with `-ExecutionPolicy Bypass`, so you don't have to
change your execution policy. You can also call the `.ps1` directly.

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
| Temp | only entries older than `-TempDays` (default 3) |
| Crash dumps | `%LOCALAPPDATA%\CrashDumps` |
| Docker build cache | `docker builder prune -f`. Images, containers and volumes are **not** touched |

With `-Deep`: NuGet global packages and Gradle wrapper distributions as well. The next build
downloads them again.

**Report only, never deleted:** Docker Desktop / WSL virtual disks, Android SDK, Android emulators,
Downloads. They show up in the report so you know where your space went.

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

## Safety model

1. **Dry run by default.** Without `-Apply`, buildbroom only prints a report.
2. **Marker files.** A folder named `build` is only a candidate if a real project file sits next to it.
3. **Git check.** A candidate is deleted only if `git check-ignore` says it is ignored, so a
   committed `dist/` or `bin/` is never touched. Folders outside a git repo are kept unless you
   pass `-NoGitCheck`.
4. **Age check.** Anything modified within `-OlderThanDays` (default 7) is kept, so the worktree
   you are working in right now stays as it is.
5. **No junction following.** Folders are deleted with `rmdir /s /q`, which removes
   junctions/symlinks without going into them. In PowerShell 5.1, `Remove-Item -Recurse` can follow a
   junction (for example a pnpm or monorepo workspace link inside `node_modules`) and delete the real
   source it points to. Scanning and size measuring skip reparse points too.
6. **Busy tools.** Cache cleanups that could break a running IDE are skipped while that IDE is open.

## Options

| Option | Default | Meaning |
|---|---|---|
| `-Mode` | `all` | `all`, `caches` or `artifacts` |
| `-Roots` | current folder | one or more folders to scan for artifacts |
| `-OlderThanDays` | `7` | keep artifacts changed more recently than this |
| `-TempDays` | `3` | keep Temp entries newer than this |
| `-MaxDepth` | `8` | how deep to scan under each root |
| `-Exclude` | | wildcard paths to skip, e.g. `*\keep-me\*` |
| `-NoGitCheck` | off | also clean artifacts in folders that are not git repos |
| `-Deep` | off | also clear NuGet global packages and Gradle wrapper distributions |
| `-Apply` | off | actually delete |

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

Command-line options override the config.

## Running it regularly

Run it every week or two, read the dry-run report, then repeat with `-Apply`. If you prefer
to schedule it, use Task Scheduler. Schedule `-Mode caches -Apply` first. Turn on artifact cleanup
only after a few dry runs show it picks the right folders.

## License

[MIT](LICENSE)
