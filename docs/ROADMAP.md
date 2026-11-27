# Roadmap

## v0.1: Windows script (done)
- PowerShell 5.1+ script, dry run by default
- Global caches + per-project artifacts with marker / git-ignore / age checks
- Junction-safe deletion

## v0.2: macOS + Linux
- macOS (done, #1): `unix/buildbroom.sh` (bash 3.2+) with the same options as `--flags` and the same
  safety rules; shared logic in `unix/lib/common.sh`, platform locations in `unix/lib/macos.sh`
- Linux (#2): `unix/lib/linux.sh` on top of the same core
- Cache locations: `~/.npm`, `~/.cache/*`, `~/Library/Caches/*`, `~/.gradle`, `~/go/pkg/mod`
  (with `-Deep` only), Xcode `DerivedData`, iOS simulators (report only), Homebrew `brew cleanup`
- Never follow symlinks (`find -P`, `rm -rf` on the link itself only)

## v0.3: shared rule set
- Move the cache and artifact rules into one `rules.json`, read by both scripts,
  so adding a new tool is a one-line change
- `--json` output for scripting / CI (macOS done, #3; Windows still to do)

## v0.4: single cross-platform command
Options, to be decided:
- **npm package** (`npx buildbroom`): easiest for JS developers, Node is already installed
- **Go or Rust binary**: no runtime needed, one file per OS, could ship via winget / scoop / Homebrew
- Keep the shell scripts as zero-dependency fallbacks

## Ideas
- Interactive mode: pick which items to delete from the report
- Detect stale git worktrees (`git worktree list` + prunable) and suggest `git worktree remove`
  (macOS done, #5; Windows still to do)
- Docker: report reclaimable space per image/volume and compact the WSL vhdx (needs admin)
- "Watch" report: show what grew since the last run
