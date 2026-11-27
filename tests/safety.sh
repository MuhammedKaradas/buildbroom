#!/usr/bin/env bash
# Safety test for buildbroom's artifact cleanup on unix (macOS today).
#
# Builds a throwaway fixture tree, runs buildbroom with --apply and checks that exactly the
# right folders are gone and everything else survives. Exits 1 if any check fails.
#
# Run locally:  bash tests/safety.sh
# BB_BASH picks the shell that runs buildbroom (CI uses /bin/bash to test bash 3.2).

here=$(cd -P -- "$(dirname -- "$0")" && pwd -P) || exit 2
script="$here/../unix/buildbroom.sh"
bb_bash=${BB_BASH:-bash}
# $TMPDIR lives under /private/var, which buildbroom refuses to scan, so use /tmp.
F=${BB_FIXTURE_DIR:-$(mktemp -d /tmp/bb-fixture.XXXXXX)} || exit 2
mkdir -p "$F" && F=$(cd -P -- "$F" && pwd -P) || exit 2
trap 'rm -rf "$F"' EXIT

failed=0
check() {
    # check NAME COMMAND...
    local name=$1; shift
    if "$@"; then printf '  PASS  %s\n' "$name"
    else printf '  FAIL  %s\n' "$name"; failed=$(( failed + 1 )); fi
}
# Helpers called through check(), which shellcheck cannot see.
# shellcheck disable=SC2329
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
# shellcheck disable=SC2329
there() { [ -e "$1" ] || [ -L "$1" ]; }
# shellcheck disable=SC2329
not_in() { ! grep -qF -- "$1" <<<"$2"; }
# Set everything under a path (symlinks excluded, so they stay fresh) to an old date.
set_old() { find -P "$1" ! -type l -exec touch -t 202001010000 {} +; }
bb() {
    "$bb_bash" "$script" --mode artifacts --roots "$F" --config "$F/none.json" "$@" || {
        echo "buildbroom exited with $?"; exit 1; }
}

mkdir -p "$F/repo/node_modules/lodash" "$F/repo/node_modules/pkg-a" "$F/repo/bin/Debug/net8" \
    "$F/repo/obj" "$F/repo/dist" "$F/repo/build" "$F/shared/pkg" "$F/nogit/node_modules/x"

echo SOURCE > "$F/shared/pkg/index.js"
echo '{}' > "$F/repo/package.json"
echo '<Project/>' > "$F/repo/app.csproj"
echo '[package]' > "$F/repo/Cargo.toml"
head -c 10000 /dev/zero > "$F/repo/node_modules/lodash/a.js"
echo '{}' > "$F/repo/node_modules/pkg-a/package.json"     # a package, not a project
echo o > "$F/repo/obj/o.txt"
echo committed > "$F/repo/dist/out.js"
echo dll > "$F/repo/bin/Debug/net8/app.dll"
echo 'no marker next to this build folder' > "$F/repo/build/script.sh"
printf 'node_modules/\nbin/\nobj/\ntarget\n' > "$F/repo/.gitignore"
echo '{}' > "$F/nogit/package.json"
echo y > "$F/nogit/node_modules/x/i.js"
ln -s "$F/shared/pkg" "$F/repo/node_modules/shared-pkg"   # pnpm / workspace style link
ln -s "$F/shared" "$F/repo/target"                         # artifact name, but a symlink

git -C "$F/repo" init -q
git -C "$F/repo" add -A
git -C "$F/repo" -c user.name=test -c user.email=test@example.com commit -qm init

for p in "$F/repo/node_modules" "$F/repo/obj" "$F/repo/dist" "$F/repo/bin" "$F/nogit/node_modules" "$F/shared"; do
    set_old "$p"
done
touch "$F/repo/bin/Debug/net8/app.dll"                      # recent file deep inside bin

printf '\n== dry run deletes nothing\n'
bb
check 'dry run: obj still there'           there "$F/repo/obj"
check 'dry run: node_modules still there'  there "$F/repo/node_modules"

printf '\n== --apply (node_modules has a fresh symlink, so it is kept at 7 days)\n'
bb --apply
check 'old ignored obj deleted'            gone  "$F/repo/obj"
check 'bin kept: recent file deep inside'  there "$F/repo/bin/Debug/net8/app.dll"
check 'tracked dist kept'                  there "$F/repo/dist/out.js"
check 'build without a marker kept'        there "$F/repo/build/script.sh"
check 'non-git node_modules kept'          there "$F/nogit/node_modules"
check 'node_modules kept (fresh symlink)'  there "$F/repo/node_modules"

printf '\n== --apply --older-than-days 0, bin excluded\n'
bb --apply --older-than-days 0 --exclude '*/bin'
check 'node_modules deleted'               gone  "$F/repo/node_modules"
check 'symlink target (real source) survives' there "$F/shared/pkg/index.js"
check 'excluded bin kept'                  there "$F/repo/bin"
check 'tracked dist still kept'            there "$F/repo/dist/out.js"
check 'non-git node_modules still kept'    there "$F/nogit/node_modules"
check 'symlinked target is not a candidate' there "$F/repo/target"

printf '\n== tool folders under a root are never scanned (--no-git-check)\n'
mkdir -p "$F/home/Library/app/node_modules/m" "$F/home/.nvm/v20/lib/node_modules/n" "$F/home/code/node_modules/c"
for d in "$F/home/Library/app" "$F/home/.nvm/v20/lib" "$F/home/code"; do echo '{}' > "$d/package.json"; done
set_old "$F/home"
HOME="$F/home" "$bb_bash" "$script" --mode artifacts --roots "$F/home" --config "$F/none.json" \
    --apply --older-than-days 0 --no-git-check >/dev/null
check 'node_modules under ~/Library kept'  there "$F/home/Library/app/node_modules"
check 'node_modules under ~/.nvm kept'     there "$F/home/.nvm/v20/lib/node_modules"
check 'node_modules in a project deleted'  gone  "$F/home/code/node_modules"

printf '\n== a Flutter SDK checkout on PATH is never scanned\n'
sdk="$F/home/sdk/flutter"
mkdir -p "$sdk/bin" "$sdk/packages/flutter_tools/.dart_tool" "$F/home/app/.dart_tool"
printf '#!/bin/sh\n' > "$sdk/bin/flutter"; chmod +x "$sdk/bin/flutter"
echo 'name: flutter_tools' > "$sdk/packages/flutter_tools/pubspec.yaml"
echo 'name: app' > "$F/home/app/pubspec.yaml"
set_old "$F/home"
PATH="$sdk/bin:$PATH" "$bb_bash" "$script" --mode artifacts --roots "$F/home" --config "$F/none.json" \
    --apply --older-than-days 0 --no-git-check >/dev/null
check '.dart_tool inside the SDK kept'     there "$sdk/packages/flutter_tools/.dart_tool"
check '.dart_tool in an app deleted'       gone  "$F/home/app/.dart_tool"

printf '\n== a root under ~/Library is refused (any letter case)\n'
out=$("$bb_bash" "$script" --mode artifacts --roots "$HOME/Library" --config "$F/none.json" 2>&1)
check 'Library root skipped'               grep -q 'tool/system folder, skipped' <<<"$out"
out=$("$bb_bash" "$script" --mode artifacts --roots "$HOME/library" --config "$F/none.json" 2>&1)
check 'library root skipped'               grep -q 'tool/system folder, skipped' <<<"$out"

printf '\n== default mode without roots does not scan the current folder\n'
out=$(cd "$F/repo" && "$bb_bash" "$script" --config "$F/none.json" 2>&1)
check 'artifacts skipped without roots'    grep -q 'Artifacts skipped' <<<"$out"

printf '\n== roots come from the config file\n'
mkdir -p "$F/cfgroot"
printf '{ "roots": ["%s"], "olderThanDays": 3 }\n' "$F/cfgroot" > "$F/config.json"
out=$(cd / && "$bb_bash" "$script" --mode artifacts --config "$F/config.json" 2>&1)
check 'config root scanned'                grep -qF "Scanning $F/cfgroot" <<<"$out"

printf '\n== Docker build cache is measured from docker system df (fake docker, isolated HOME and PATH)\n'
# Only the fake docker and the base system tools are on PATH, and HOME is a fixture, so
# --apply in caches mode cannot touch any real cache on this machine.
fake="$F/fakebin"; state="$F/docker-state"
mkdir -p "$fake" "$state" "$F/dhome"
cat > "$fake/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "info "*) exit 0 ;;
    "system df")
        [ -f "$BB_DOCKER_STATE/fail" ] && { echo 'Error: failed to get snapshot usage' >&2; exit 1; }
        r=1.5GB; [ -f "$BB_DOCKER_STATE/pruned" ] && r=0B
        printf 'Images|1.2GB (50%%)\nContainers|0B (0%%)\nLocal Volumes|3GB (100%%)\nBuild Cache|%s\n' "$r" ;;
    "builder prune") touch "$BB_DOCKER_STATE/pruned" ;;
esac
EOF
chmod +x "$fake/docker"
dbb() {
    HOME="$F/dhome" PATH="$fake:/usr/bin:/bin:/usr/sbin:/sbin" BB_DOCKER_STATE="$state" \
        "$bb_bash" "$script" --mode caches --config "$F/none.json" "$@" 2>&1
}
out=$(dbb)
check 'dry run reports 1.5 GB build cache' grep -qE '1\.40 GB +would clean +Docker build cache' <<<"$out"
check 'dry run does not prune'             gone "$state/pruned"
out=$(dbb --apply)
check 'apply prunes the build cache'       there "$state/pruned"
check 'apply reports what was freed'       grep -qE '1\.40 GB +cleaned +Docker build cache' <<<"$out"
rm -f "$state/pruned"; touch "$state/fail"
out=$(dbb); rc=$?
check 'a failing docker system df is not fatal' [ "$rc" = 0 ]
check 'no Docker row when df fails'        not_in 'Docker build cache' "$out"

printf '\n== unknown options are rejected\n'
# shellcheck disable=SC2329
rejects() { ! "$bb_bash" "$script" "$@" >/dev/null 2>&1; }
check 'unknown option rejected'            rejects --bogus
check 'bad --mode rejected'                rejects --mode everything

if [ "$failed" -gt 0 ]; then printf '\n%s check(s) failed\n' "$failed"; exit 1; fi
printf '\nAll checks passed\n'
exit 0
