# Contributing

Thanks for helping. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md); security problems go
through the [security policy](SECURITY.md), not public issues.

## Getting started

On Windows you need Windows 10 or 11 with Windows PowerShell 5.1 (built in) or PowerShell 7, and git.
On macOS you need the built-in bash and git; install [ShellCheck](https://www.shellcheck.net/) (`brew install shellcheck`) to lint.

```powershell
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom
.\buildbroom.cmd -Mode caches                       # dry run, deletes nothing
powershell -NoProfile -ExecutionPolicy Bypass -File tests\safety.ps1
```

On macOS:

```bash
unix/buildbroom.sh --mode caches                    # dry run, deletes nothing
shellcheck -x unix/buildbroom.sh tests/safety.sh
BB_BASH=/bin/bash bash tests/safety.sh              # bash 3.2, the macOS default
```

`tests\safety.ps1` (and `tests/safety.sh`) builds a throwaway folder tree, runs buildbroom with `-Apply` against it and checks what was
deleted and what survived. It never touches your real projects. Run it before every PR.

**While developing, never run `-Apply` on real folders until the dry run shows exactly what you expect.**

## Adding a cache or a build folder

- **Cache:** add an entry to `$CacheTargets` in `windows/buildbroom.ps1`. Prefer the tool's own clean command
  (`npm cache clean`, `go clean -cache`) over deleting folders, set `Tool` so it is skipped when the tool is missing,
  and set `Block` to the IDEs that would break while it runs.
- **Build folder:** add it to `$ArtifactRules` with the marker files that must sit next to it. A rule without a
  specific marker (for example `build` next to any file) is not accepted.
- If it is big but not safe to delete automatically, add it to `$WatchOnly` so it is only reported.
- **On macOS / unix:** caches and report-only items go in `os_register_caches` in `unix/lib/macos.sh`
  (`add_cache` / `add_watch`, the arguments are explained in `unix/lib/common.sh`). Build folder rules are
  shared by every unix platform: `ARTIFACT_RULES` in `unix/lib/common.sh`. Keep the scripts bash 3.2
  compatible and use only flags that BSD and GNU tools both have.
- Update both READMEs (`README.md`, `README.tr.md`).

Linux support is planned (#2): it goes in `unix/lib/linux.sh`, which fills the same `os_*` hooks as
`unix/lib/macos.sh` and may redefine any function of `unix/lib/common.sh`. Comment on the issue before starting, so
the approach can be agreed.

## Branches

- `main` must always pass CI.
- Every change is made on its own branch, tied to an issue: `feature/<issue>-short-name`, `fix/<issue>-short-name`,
  `docs/…`, `chore/…`.
- Branches are merged into `main` through a PR with **squash merge**. The PR title follows the commit convention.
- There's no separate development branch. Releases are tags cut from `main`.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), in English:
`feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`.

- The description starts with a lowercase letter, uses the imperative mood ("add", "fix"), has no trailing period
  and is at most 72 characters.
- A change that alters behavior or isn't self-explanatory explains the *why* in the body.
- No attribution trailers in commits (`Co-Authored-By`, "Generated with …", etc.).

## Pull requests

- Fill in the PR template.
- CI runs PSScriptAnalyzer and the safety test on Windows PowerShell 5.1 and PowerShell 7, ShellCheck and the
  unix safety test on macOS with bash 3.2 and bash 5, and a secret scan
  (gitleaks) over the PR's commits. A token or key that was committed must be revoked, not just removed in a later
  commit.
- Dependabot opens weekly PRs for outdated GitHub Actions.

## Releasing

1. Update `$Version` in `windows/buildbroom.ps1` and `BB_VERSION` in `unix/lib/common.sh` and merge it into `main`.
2. Tag and push:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The `Release` workflow checks that the tag matches `$Version`, runs the safety test, zips the scripts with a
   SHA256 file and creates a **draft** GitHub Release.
4. Review the notes on the Release page and publish it. Tags containing `-` (`v0.2.0-beta.1`) are marked as
   pre-releases.
