#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# buildbroom - safely reclaim disk space eaten by developer caches and build artifacts.
#
#   caches     Global, re-downloadable tool caches (npm, Yarn, pnpm, Go, Gradle, NuGet,
#              Xcode DerivedData, CocoaPods, SwiftPM, Homebrew, Docker build cache).
#   artifacts  Per-project build output (node_modules, target, .next, build, ...) under
#              the roots you give it. Ideal for many repos / git worktrees.
#
# Dry run by default: nothing is deleted unless --apply is passed. See --help and README.md.
# Works with bash 3.2 (the macOS default). Platform files live in lib/: common.sh holds the
# safety rules, macos.sh (and later linux.sh) the platform's locations.

# Resolve the real folder of this script, so a symlink in ~/bin or /usr/local/bin works.
src=$0
while [ -L "$src" ]; do
    dir=$(cd -P -- "$(dirname -- "$src")" && pwd -P) || exit 2
    src=$(readlink -- "$src")
    case $src in /*) ;; *) src="$dir/$src" ;; esac
done
BB_DIR=$(cd -P -- "$(dirname -- "$src")" && pwd -P) || exit 2
unset src dir

# shellcheck source=lib/common.sh
. "$BB_DIR/lib/common.sh"

case $(uname -s) in
    Darwin)
        # shellcheck source=lib/macos.sh
        . "$BB_DIR/lib/macos.sh" ;;
    *)
        echo "buildbroom: $(uname -s) is not supported yet (Linux: issue #2)" >&2
        exit 2 ;;
esac

bb_main "$@"
