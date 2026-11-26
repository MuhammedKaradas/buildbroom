# shellcheck shell=bash
# buildbroom shared logic for every unix platform (bash 3.2+, BSD and GNU tools).
#
# unix/buildbroom.sh sources this file first, then one OS file (lib/macos.sh, later
# lib/linux.sh). The OS file fills in the os_* hooks below and may redefine any other
# function here when that platform needs different behavior. The safety rules (dry run,
# marker files, git check-ignore, newest-write age check, never following symlinks)
# live only in this file, so every platform gets the same ones.

BB_VERSION='0.1.0'
TAB=$(printf '\t')

# ---------------------------------------------------------------- options (defaults)
MODE=all
ROOTS=()
OLDER_THAN_DAYS=7
MAX_DEPTH=8
EXCLUDE=()
NO_GIT_CHECK=0
DEEP=0
APPLY=0
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/buildbroom/config.json"
SET_ROOTS=0
SET_OLDER=0
SET_EXCLUDE=0

# ---------------------------------------------------------------- OS hooks (defaults)
OS_NAME=unix
FIND_PATH_TEST=-path            # -ipath on case-insensitive file systems
path_key() { printf '%s' "$1"; }  # comparison key for paths (lowercase on macOS)
os_never_scan() { :; }          # print one path per line: never scanned, even under a root
os_register_caches() { :; }     # call add_cache / add_watch
os_config_scalar() { return 1; }  # FILE KEY -> print value
os_config_list() { return 1; }    # FILE KEY -> print one element per line
os_config_valid() { return 1; }   # FILE -> 0 when the file can be read

# ---------------------------------------------------------------- output helpers
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_INFO=$(printf '\033[36m'); C_DIM=$(printf '\033[90m'); C_OK=$(printf '\033[32m')
    C_WARN=$(printf '\033[33m'); C_OFF=$(printf '\033[0m')
else
    C_INFO=; C_DIM=; C_OK=; C_WARN=; C_OFF=
fi
info() { printf '%s%s%s\n' "$C_INFO" "$*" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
note() { printf '%s%s%s\n' "$C_WARN" "$*" "$C_OFF"; }
warn() { printf '%sWARNING: %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()  { printf 'buildbroom: %s\n' "$*" >&2; exit 2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

fmt_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB", b / 1073741824
        else if (b >= 1048576) printf "%.0f MB", b / 1048576
        else printf "%.0f KB", b / 1024 }'
}

free_bytes() { df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }'; }

# ---------------------------------------------------------------- file system helpers
# Disk usage of a tree. du -P never follows symlinks; a link counts as the link only.
dir_bytes() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then echo 0; return; fi
    du -P -sk -- "$1" 2>/dev/null | awk '{ s = $1 } END { print (s + 0) * 1024 }'
}

# Sum of dir_bytes over several paths.
paths_bytes() {
    local total=0 p
    for p in "$@"; do
        [ -n "$p" ] || continue
        total=$(( total + $(dir_bytes "$p") ))
    done
    echo "$total"
}

# True when anything in the tree, the folder itself included, was written within $2 days.
# A folder's own mtime only changes when its direct children change, so the newest write
# anywhere inside is the only reliable "was this used recently" signal. find -P never
# follows symlinks; a symlink's own mtime counts, so a freshly made workspace link keeps
# its node_modules.
written_within_days() {
    [ "$2" -gt 0 ] || return 1
    [ -n "$(find -P "$1" -mmin "-$(( $2 * 1440 ))" -print -quit 2>/dev/null)" ]
}

# Delete a folder without following symlinks: rm -rf removes a link inside the tree as a
# link and never enters it; a link given as the path itself is removed as a link too.
# Returns 0 when the path is fully gone.
remove_dir_safe() {
    local p=$1
    [ "$APPLY" = 1 ] || return 1
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 0; fi
    case $p in
        /*) ;;
        *) warn "Refusing to delete a relative path: $p"; return 1 ;;
    esac
    case $p in
        /|"$HOME"|"$HOME"/) warn "Refusing to delete $p"; return 1 ;;
    esac
    rm -rf -- "$p" 2>/dev/null
    [ ! -e "$p" ] && [ ! -L "$p" ]
}

# Print the names (from $@) that have a running process with exactly that name.
running_of() {
    local n out=
    for n in "$@"; do
        if pgrep -x "$n" >/dev/null 2>&1; then out="${out:+$out, }$n"; fi
    done
    printf '%s' "$out"
}

# Physical path of an existing folder, or the input unchanged.
real_dir() {
    if [ -d "$1" ]; then (cd -P -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
    else printf '%s\n' "$1"; fi
}

expand_tilde() {
    case $1 in
        \~) printf '%s\n' "$HOME" ;;
        \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# ---------------------------------------------------------------- report rows
ROWS_FILE=
add_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ROWS_FILE"; }

# ---------------------------------------------------------------- caches
# add_cache NAME TOOL BLOCK RUN MEASURE GUARD PATH...
#   TOOL     command that must be on PATH, or '' (skipped and reported when missing)
#   BLOCK    space-separated process names; skipped while one of them runs (IDEs ...)
#   RUN      function that cleans it (prefer the tool's own clean command)
#   MEASURE  function printing its size in bytes, or '' to measure PATH...
#   GUARD    function printing a reason to skip it right now, or ''
CT_N=0
add_cache() {
    CT_NAME[CT_N]=$1; CT_TOOL[CT_N]=$2; CT_BLOCK[CT_N]=$3
    CT_RUN[CT_N]=$4; CT_MEASURE[CT_N]=$5; CT_GUARD[CT_N]=$6
    shift 6
    local IFS
    IFS=$(printf '\n_'); IFS=${IFS%_}
    CT_PATHS[CT_N]="$*"
    CT_N=$(( CT_N + 1 ))
}

# Report-only items: big, but not safe to delete automatically.
WT_N=0
add_watch() { WT_LABEL[WT_N]=$1; WT_PATH[WT_N]=$2; WT_N=$(( WT_N + 1 )); }

cache_bytes() {
    local i=$1 old_ifs=$IFS
    if [ -n "${CT_MEASURE[i]}" ]; then "${CT_MEASURE[i]}"; return; fi
    set -f
    IFS=$(printf '\n_'); IFS=${IFS%_}
    # shellcheck disable=SC2086  # split on newlines on purpose, globbing is off
    paths_bytes ${CT_PATHS[i]}
    IFS=$old_ifs
    set +f
}

invoke_caches() {
    local i=0 name bytes busy reason after freed status
    while [ "$i" -lt "$CT_N" ]; do
        name=${CT_NAME[i]}
        bytes=$(cache_bytes "$i")
        # shellcheck disable=SC2086  # BLOCK is a word list
        busy=$(running_of ${CT_BLOCK[i]})
        reason=
        if [ -n "${CT_GUARD[i]}" ]; then reason=$("${CT_GUARD[i]}"); fi

        if [ -n "${CT_TOOL[i]}" ] && ! have_cmd "${CT_TOOL[i]}"; then
            add_row cache "$bytes" "skipped (${CT_TOOL[i]} not on PATH)" "$name"
        elif [ -n "$busy" ]; then
            add_row cache "$bytes" "skipped ($busy running)" "$name"
        elif [ -n "$reason" ]; then
            add_row cache "$bytes" "skipped ($reason)" "$name"
        elif [ "$APPLY" != 1 ]; then
            add_row cache "$bytes" 'would clean' "$name"
        else
            "${CT_RUN[i]}" >/dev/null 2>&1
            # Report what was really freed, not what we hoped to free.
            after=$(cache_bytes "$i")
            freed=$(( bytes - after )); [ "$freed" -ge 0 ] || freed=0
            if [ "$after" -gt 0 ] && [ "$freed" -lt "$bytes" ]; then
                status="cleaned ($(fmt_size "$after") left, in use or kept by the tool)"
            else
                status=cleaned
            fi
            add_row cache "$freed" "$status" "$name"
        fi
        i=$(( i + 1 ))
    done

    i=0
    while [ "$i" -lt "$WT_N" ]; do
        bytes=$(dir_bytes "${WT_PATH[i]}")
        [ "$bytes" -gt 0 ] && add_row watch "$bytes" 'report only' "${WT_LABEL[i]}  (${WT_PATH[i]})"
        i=$(( i + 1 ))
    done
}

# ---------------------------------------------------------------- artifacts
# folder name : markers that must exist in the parent folder (a * marker must be a file)
ARTIFACT_RULES=(
    'node_modules:package.json'
    '.next:package.json'
    '.nuxt:package.json'
    '.svelte-kit:package.json'
    '.turbo:package.json turbo.json'
    '.angular:angular.json'
    '.parcel-cache:package.json'
    'dist:package.json'
    'bin:*.csproj *.fsproj *.vbproj'
    'obj:*.csproj *.fsproj *.vbproj'
    'target:Cargo.toml pom.xml'
    'build:build.gradle build.gradle.kts settings.gradle settings.gradle.kts pubspec.yaml CMakeLists.txt'
    '.gradle:build.gradle build.gradle.kts settings.gradle settings.gradle.kts'
    '.dart_tool:pubspec.yaml'
    '__pycache__:*.py'
    '.pytest_cache:*.py pytest.ini pyproject.toml'
    '.mypy_cache:*.py pyproject.toml'
)
# Folder names never scanned into. node_modules is here too: when it is not itself a
# candidate, its packages (each with a package.json) must never be mistaken for projects.
NEVER_DESCEND=(.git .hg .svn .vs .idea node_modules)

# SDKs installed as git checkouts (Flutter) are full of folders that look like projects
# (pubspec.yaml next to .dart_tool and build). They belong to the tool: never scan them.
sdk_never_scan() {
    local f d
    if [ -n "${FLUTTER_ROOT:-}" ]; then printf '%s\n' "$FLUTTER_ROOT"; fi
    f=$(command -v flutter 2>/dev/null) || return 0
    case $f in /*) ;; *) return 0 ;; esac
    while [ -L "$f" ]; do
        d=$(cd -P -- "$(dirname -- "$f")" && pwd -P) || return 0
        f=$(readlink -- "$f")
        case $f in /*) ;; *) f="$d/$f" ;; esac
    done
    d=$(cd -P -- "$(dirname -- "$f")/.." 2>/dev/null && pwd -P) || return 0
    if [ -d "$d/packages/flutter_tools" ]; then printf '%s\n' "$d"; fi
}

NEVER_SCAN=()      # physical paths, filled by prepare_never_scan
prepare_never_scan() {
    local p
    NEVER_SCAN=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        p=$(real_dir "$p"); p=${p%/}
        [ -n "$p" ] && NEVER_SCAN+=("$p")
    done <<EOF
$(os_never_scan)
$(sdk_never_scan)
EOF
}

is_never_scan() {
    local k n
    k=$(path_key "$1")
    for n in ${NEVER_SCAN[@]+"${NEVER_SCAN[@]}"}; do
        n=$(path_key "$n")
        case $k in "$n"|"$n"/*) return 0 ;; esac
    done
    return 1
}

glob_escape() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# Shell snippet run by find for each folder whose name is on the rule list:
# exits 0 when a matching marker sits next to it.
marker_script() {
    local s rule
    # shellcheck disable=SC2016  # this is code for the child shell, not expanded here
    s='p=$1; parent=${p%/*}; set -f; case ${p##*/} in'
    for rule in "${ARTIFACT_RULES[@]}"; do
        s="$s '${rule%%:*}') m='${rule#*:}' ;;"
    done
    # shellcheck disable=SC2016
    s="$s"' *) exit 1 ;; esac
for x in $m; do
    set +f
    for f in "$parent"/$x; do
        case $x in *"*"*) [ -f "$f" ] && exit 0 ;; *) [ -e "$f" ] && exit 0 ;; esac
    done
    set -f
done
exit 1'
    printf '%s' "$s"
}

# Print (NUL-separated) every artifact folder under $1. A single find walk:
# never-scan paths are pruned, candidates are printed and not entered, NEVER_DESCEND
# names are pruned, symlinks are never followed (-P) and never match -type d.
find_artifacts() {
    local root=$1 args=() n rule first
    if [ "${#NEVER_SCAN[@]}" -gt 0 ]; then
        args+=('(')
        first=1
        for n in "${NEVER_SCAN[@]}"; do
            [ "$first" = 1 ] || args+=(-o)
            args+=("$FIND_PATH_TEST" "$(glob_escape "$n")")
            first=0
        done
        args+=(')' -prune -o)
    fi
    args+=(-type d '(')
    first=1
    for rule in "${ARTIFACT_RULES[@]}"; do
        [ "$first" = 1 ] || args+=(-o)
        args+=(-name "${rule%%:*}")
        first=0
    done
    args+=(')' -exec sh -c "$(marker_script)" sh '{}' ';' -print0 -prune -o)
    args+=(-type d '(')
    first=1
    for n in "${NEVER_DESCEND[@]}"; do
        [ "$first" = 1 ] || args+=(-o)
        args+=(-name "$n")
        first=0
    done
    args+=(')' -prune)
    find -P "$root" -mindepth 1 -maxdepth "$MAX_DEPTH" "${args[@]}" 2>/dev/null
}

is_excluded() {
    local pat
    for pat in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
        # shellcheck disable=SC2254  # the pattern is a glob on purpose
        case $1 in $pat) return 0 ;; esac
    done
    return 1
}

invoke_artifacts() {
    local root path bytes g left
    for root in "${ROOTS[@]}"; do
        root=$(expand_tilde "$root")
        if [ ! -d "$root" ]; then warn "Root not found: $root"; continue; fi
        root=$(real_dir "$root"); [ "$root" = / ] || root=${root%/}
        if is_never_scan "$root"; then warn "Root is a tool/system folder, skipped: $root"; continue; fi
        dim "Scanning $root ..."
        while IFS= read -r -d '' path <&3; do
            is_excluded "$path" && continue
            bytes=$(dir_bytes "$path")
            if written_within_days "$path" "$OLDER_THAN_DAYS"; then
                add_row artifact "$bytes" "kept (used < $OLDER_THAN_DAYS d ago)" "$path"; continue
            fi
            if [ "$NO_GIT_CHECK" != 1 ]; then
                # 0 = ignored, 1 = tracked / not ignored, 128 = not a git repo
                git -C "${path%/*}" check-ignore -q -- "${path##*/}" >/dev/null 2>&1 </dev/null
                g=$?
                if [ "$g" = 1 ]; then add_row artifact "$bytes" 'kept (tracked by git)' "$path"; continue; fi
                if [ "$g" != 0 ]; then add_row artifact "$bytes" 'kept (not a git repo; --no-git-check)' "$path"; continue; fi
            fi
            if [ "$APPLY" != 1 ]; then add_row artifact "$bytes" 'would delete' "$path"; continue; fi
            if remove_dir_safe "$path"; then
                add_row artifact "$bytes" deleted "$path"
            else
                left=$(dir_bytes "$path")
                g=$(( bytes - left )); [ "$g" -ge 0 ] || g=0
                add_row artifact "$g" "partly deleted ($(fmt_size "$left") in use)" "$path"
            fi
        done 3< <(find_artifacts "$root")
    done
}

# ---------------------------------------------------------------- report
print_report() {
    [ -s "$ROWS_FILE" ] || return 0
    echo
    awk -F "$TAB" '$2 > 0' "$ROWS_FILE" | sort -t "$TAB" -k1,1 -k2,2nr | awk -F "$TAB" '
        function size(b) {
            if (b >= 1073741824) return sprintf("%.2f GB", b / 1073741824)
            if (b >= 1048576) return sprintf("%.0f MB", b / 1048576)
            return sprintf("%.0f KB", b / 1024)
        }
        { kind[NR] = $1; sz[NR] = size($2); st[NR] = $3; item[NR] = $4
          if (length($3) > w) w = length($3) }
        END {
            if (NR == 0) exit
            if (w < 6) w = 6
            printf "%-9s %10s  %-" w "s  %s\n", "Kind", "Size", "Status", "Item"
            printf "%-9s %10s  %-" w "s  %s\n", "----", "----", "------", "----"
            for (i = 1; i <= NR; i++) printf "%-9s %10s  %-" w "s  %s\n", kind[i], sz[i], st[i], item[i]
        }'
    echo
}

actionable_bytes() {
    awk -F "$TAB" '$3 ~ /^(would clean|would delete|cleaned|deleted|partly deleted)/ { s += $2 } END { print s + 0 }' "$ROWS_FILE"
}

# ---------------------------------------------------------------- arguments and config
usage() {
    cat <<EOF
buildbroom $BB_VERSION - safely reclaim disk space eaten by developer caches and build artifacts.

Usage: buildbroom.sh [options]

  --mode all|caches|artifacts   what to clean (default: all)
  --roots DIR[,DIR...]          folders to scan for artifacts (repeatable; default: config file)
  --older-than-days N           keep artifacts changed within N days (default: 7)
  --max-depth N                 how deep to scan under each root (default: 8)
  --exclude PATTERN             wildcard path to skip, e.g. '*/keep-me/*' (repeatable)
  --no-git-check                also clean artifacts in folders that are not git repos
  --deep                        also clear big caches that take long to download again
  --apply                       actually delete (default: dry run, nothing is deleted)
  --config FILE                 config file (default: ~/.config/buildbroom/config.json)
  -h, --help                    show this help
  --version                     show the version

Examples:
  buildbroom.sh                                        # dry run: caches (+ artifacts under configured roots)
  buildbroom.sh --mode artifacts --roots ~/code,~/work
  buildbroom.sh --mode artifacts --roots ~/code --older-than-days 14 --apply
  buildbroom.sh --mode caches --apply
EOF
}

need_uint() { case $2 in ''|*[!0-9]*) die "$1 needs a whole number, got '$2'" ;; esac; }

add_roots() {
    local parts p
    IFS=, read -r -a parts <<EOF
$1
EOF
    for p in ${parts[@]+"${parts[@]}"}; do [ -n "$p" ] && ROOTS+=("$p"); done
}

parse_args() {
    local opt val has_val
    while [ $# -gt 0 ]; do
        case $1 in
            --*=*) opt=${1%%=*}; val=${1#*=}; has_val=1 ;;
            *) opt=$1; val=; has_val=0 ;;
        esac
        case $opt in
            --mode|--roots|--root|--older-than-days|--max-depth|--exclude|--config)
                if [ "$has_val" = 0 ]; then
                    [ $# -ge 2 ] || die "$opt needs a value"
                    val=$2; shift
                fi ;;
            *) [ "$has_val" = 0 ] || die "$opt does not take a value" ;;
        esac
        case $opt in
            --mode)
                case $val in all|caches|artifacts) MODE=$val ;; *) die "--mode must be all, caches or artifacts" ;; esac ;;
            --roots|--root) add_roots "$val"; SET_ROOTS=1 ;;
            --older-than-days) need_uint "$opt" "$val"; OLDER_THAN_DAYS=$val; SET_OLDER=1 ;;
            --max-depth) need_uint "$opt" "$val"; MAX_DEPTH=$val ;;
            --exclude) EXCLUDE+=("$val"); SET_EXCLUDE=1 ;;
            --config) CONFIG=$val ;;
            --no-git-check) NO_GIT_CHECK=1 ;;
            --deep) DEEP=1 ;;
            --apply) APPLY=1 ;;
            -h|--help) usage; exit 0 ;;
            --version) echo "buildbroom $BB_VERSION"; exit 0 ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

load_config() {
    local v
    [ -f "$CONFIG" ] || return 0
    if ! os_config_valid "$CONFIG"; then warn "Could not read config $CONFIG"; return 0; fi
    if [ "$SET_ROOTS" = 0 ]; then
        while IFS= read -r v; do [ -n "$v" ] && ROOTS+=("$v"); done <<EOF
$(os_config_list "$CONFIG" roots)
EOF
    fi
    if [ "$SET_OLDER" = 0 ] && v=$(os_config_scalar "$CONFIG" olderThanDays); then
        case $v in ''|*[!0-9]*) warn "Ignoring olderThanDays '$v' in $CONFIG" ;; *) OLDER_THAN_DAYS=$v ;; esac
    fi
    if [ "$SET_EXCLUDE" = 0 ]; then
        while IFS= read -r v; do [ -n "$v" ] && EXCLUDE+=("$v"); done <<EOF
$(os_config_list "$CONFIG" exclude)
EOF
    fi
}

# ---------------------------------------------------------------- main
bb_main() {
    local roots_note='' free0 free1 gained
    parse_args "$@"
    [ "$(id -u)" -ne 0 ] || die "refusing to run as root; run it as the user whose caches you want to clean"
    load_config

    # No roots given or configured: an explicit --mode artifacts scans the current folder;
    # the default all mode does not, so running it from your home folder never scans everything.
    if [ "${#ROOTS[@]}" -eq 0 ]; then
        if [ "$MODE" = artifacts ]; then ROOTS=("$(pwd -P)")
        else roots_note='Artifacts skipped: no --roots given and none in the config file.'; fi
    fi

    ROWS_FILE=$(mktemp "${TMPDIR:-/tmp}/buildbroom.XXXXXX") || die "cannot create a temp file"
    trap 'rm -f "$ROWS_FILE"' EXIT
    prepare_never_scan

    free0=$(free_bytes)
    if [ "$APPLY" = 1 ]; then info "buildbroom $BB_VERSION ($OS_NAME) - APPLY"
    else info "buildbroom $BB_VERSION ($OS_NAME) - DRY RUN (nothing deleted, add --apply)"; fi
    info "Free: $(fmt_size "${free0:-0}")"

    if [ "$MODE" = all ] || [ "$MODE" = caches ]; then
        os_register_caches
        invoke_caches
    fi
    if [ "$MODE" = all ] || [ "$MODE" = artifacts ]; then
        if [ -n "$roots_note" ]; then note "$roots_note"; else invoke_artifacts; fi
    fi

    print_report
    if [ "$APPLY" = 1 ]; then
        free1=$(free_bytes)
        gained=$(( ${free1:-0} - ${free0:-0} )); [ "$gained" -ge 0 ] || gained=0
        printf '%sDone. Free: %s -> %s  (+%s)%s\n' "$C_OK" "$(fmt_size "${free0:-0}")" "$(fmt_size "${free1:-0}")" "$(fmt_size "$gained")" "$C_OFF"
    else
        printf '%sReclaimable: ~%s. Run again with --apply to clean.%s\n' "$C_OK" "$(fmt_size "$(actionable_bytes)")" "$C_OFF"
    fi
    return 0
}
