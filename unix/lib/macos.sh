# shellcheck shell=bash
# macOS: cache locations, report-only items, folders never scanned and config reading.
# Sourced after lib/common.sh; only fills in the os_* hooks.

OS_NAME=macOS
LIB="$HOME/Library"

# APFS is case-insensitive by default: compare paths and prune with -ipath accordingly.
FIND_PATH_TEST=-ipath
path_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# BSD stat: mtime (epoch) of the link itself, never its target. BSD date formats an epoch with -r.
MTIME_CMD=(stat -f %m)
os_iso_time() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# Xcode re-creates device support files when a device with that OS version is connected again.
DEVICE_SUPPORT_DAYS=90

# ---------------------------------------------------------------- never scanned
# A node_modules or build folder in here belongs to an installed program or a tool home
# (global npm, nvm Node versions, VS Code extensions, Homebrew ...) and deleting it breaks it.
os_never_scan() {
    printf '%s\n' /System /Library /Applications /usr /bin /sbin /opt /private/var /private/etc /cores \
        "$LIB" "$HOME/Applications" "$HOME/.Trash" "$HOME/.cache" "$HOME/.local" "$HOME/.config" \
        "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/.npm" "$HOME/.nvm" \
        "$HOME/.volta" "$HOME/.bun" "$HOME/.deno" "$HOME/.yarn" "$HOME/.pnpm-store" \
        "$HOME/.cargo" "$HOME/.rustup" "$HOME/.gradle" "$HOME/.m2" "$HOME/.android" \
        "$HOME/.nuget" "$HOME/.dotnet" "$HOME/go/pkg" "$HOME/.pub-cache" "$HOME/.cocoapods" \
        "$HOME/.rbenv" "$HOME/.pyenv" "$HOME/.asdf" "$HOME/.docker" "$HOME/.swiftpm"
    if have_cmd brew; then brew --prefix 2>/dev/null; fi
}

# ---------------------------------------------------------------- config (plutil reads JSON)
os_config_valid()  { plutil -convert json -o /dev/null "$1" >/dev/null 2>&1; }
os_config_scalar() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
os_config_list() {
    local i=0 v
    while v=$(plutil -extract "$2.$i" raw -o - "$1" 2>/dev/null); do
        printf '%s\n' "$v"
        i=$(( i + 1 ))
    done
}

# ---------------------------------------------------------------- cache actions
mac_npm()    { npm cache clean --force; }
mac_yarn()   { yarn cache clean; }
mac_pnpm()   { pnpm store prune; }
mac_go()     { go clean -cache; }
mac_gomod()  { go clean -modcache; }
mac_pods()   { pod cache clean --all; }
mac_brew()   { brew cleanup; }
mac_docker() { docker builder prune -f; }
mac_nuget()  { dotnet nuget locals http-cache --clear; dotnet nuget locals plugins-cache --clear; }
mac_nuget_global() { dotnet nuget locals global-packages --clear; }
mac_derived_data() { remove_dir_safe "$LIB/Developer/Xcode/DerivedData"; }
mac_swiftpm() { remove_dir_safe "$LIB/Caches/org.swift.swiftpm"; }
mac_gradle() { remove_dir_safe "$HOME/.gradle/caches"; remove_dir_safe "$HOME/.gradle/daemon"; }
mac_gradle_wrapper() { remove_dir_safe "$HOME/.gradle/wrapper/dists"; }

# A Gradle daemon may be in the middle of a build started from a terminal (./gradlew),
# so it is never killed: the cache is skipped until it stops.
gradle_guard() {
    if pgrep -f GradleDaemon >/dev/null 2>&1; then
        printf 'Gradle daemon running; stop it with ./gradlew --stop'
    fi
}
docker_guard() {
    have_cmd docker || return 0
    docker info >/dev/null 2>&1 || printf 'Docker is not running'
}

# Device support folders (iOS, watchOS, ...) with nothing written for DEVICE_SUPPORT_DAYS.
old_device_support() {
    local d
    for d in "$LIB"/Developer/Xcode/*" DeviceSupport"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        written_within_days "$d" "$DEVICE_SUPPORT_DAYS" || printf '%s\n' "$d"
    done
}
measure_device_support() {
    local total=0 d
    while IFS= read -r d; do
        [ -n "$d" ] && total=$(( total + $(dir_bytes "$d") ))
    done <<EOF
$(old_device_support)
EOF
    echo "$total"
}
mac_device_support() {
    local d
    while IFS= read -r d; do
        [ -n "$d" ] && remove_dir_safe "$d"
    done <<EOF
$(old_device_support)
EOF
}

# ---------------------------------------------------------------- registration
os_register_caches() {
    local gocache="$LIB/Caches/go-build" gomod="$HOME/go/pkg/mod" brewcache="$LIB/Caches/Homebrew"
    if have_cmd go; then
        gocache=$(go env GOCACHE 2>/dev/null || echo "$gocache")
        gomod=$(go env GOMODCACHE 2>/dev/null || echo "$gomod")
    fi
    if have_cmd brew; then brewcache=$(brew --cache 2>/dev/null || echo "$brewcache"); fi
    local nuget="$HOME/.local/share/NuGet"
    local xcode_block='Xcode xcodebuild'

    #         name                                       tool   block           run                measure                 guard         paths...
    add_cache 'npm cache'                                npm    ''              mac_npm            ''                      ''            "$HOME/.npm/_cacache"
    add_cache 'Yarn cache'                               yarn   ''              mac_yarn           ''                      ''            "$LIB/Caches/Yarn" "$HOME/.yarn/berry/cache"
    add_cache 'pnpm store (unreferenced only)'           pnpm   ''              mac_pnpm           ''                      ''            "$LIB/pnpm/store"
    add_cache 'Go build cache'                           go     ''              mac_go             ''                      ''            "$gocache"
    add_cache 'Gradle caches + daemon logs'              ''     'studio idea'   mac_gradle         ''                      gradle_guard  "$HOME/.gradle/caches" "$HOME/.gradle/daemon"
    add_cache 'NuGet http + plugins cache'               dotnet 'rider'         mac_nuget          ''                      ''            "$nuget/http-cache" "$nuget/v3-cache" "$nuget/plugins-cache"
    add_cache 'Xcode DerivedData'                        ''     "$xcode_block"  mac_derived_data   ''                      ''            "$LIB/Developer/Xcode/DerivedData"
    add_cache "Xcode device support unused for $DEVICE_SUPPORT_DAYS days" \
                                                         ''     "$xcode_block"  mac_device_support measure_device_support  ''
    add_cache 'CocoaPods cache'                          pod    ''              mac_pods           ''                      ''            "$LIB/Caches/CocoaPods"
    add_cache 'SwiftPM cache'                            ''     "$xcode_block"  mac_swiftpm        ''                      ''            "$LIB/Caches/org.swift.swiftpm"
    add_cache 'Homebrew downloads + old versions'        brew   ''              mac_brew           ''                      ''            "$brewcache"
    add_cache 'Docker build cache (images/containers/volumes untouched)' \
                                                         docker ''              mac_docker         docker_build_cache_bytes docker_guard
    if [ "$DEEP" = 1 ]; then
        add_cache '[deep] Go module cache'               go     ''              mac_gomod          ''                      ''            "$gomod"
        add_cache '[deep] Gradle wrapper distributions'  ''     'studio idea'   mac_gradle_wrapper ''                      gradle_guard  "$HOME/.gradle/wrapper/dists"
        add_cache '[deep] NuGet global packages'         dotnet 'rider'         mac_nuget_global   ''                      ''            "$HOME/.nuget/packages"
    fi

    add_watch 'Xcode archives'                                 "$LIB/Developer/Xcode/Archives"
    add_watch 'iOS simulators (xcrun simctl delete unavailable)' "$LIB/Developer/CoreSimulator/Devices"
    add_watch 'Android SDK'                                    "$LIB/Android/sdk"
    add_watch 'Android emulators (AVD)'                        "$HOME/.android/avd"
}

# ---------------------------------------------------------------- scheduled runs (launchd)
# A per-user launch agent, weekly on Monday 10:00. launchd runs a missed slot when the Mac
# wakes up, so a sleeping laptop is fine. Output is appended to ~/Library/Logs/buildbroom.log.
SCHED_LABEL=local.buildbroom

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Folders macOS protects (TCC): a background job reading them needs Full Disk Access for bash.
under_protected() {
    case $(path_key "$1") in
        "$(path_key "$HOME/Desktop")"|"$(path_key "$HOME/Desktop")"/*) return 0 ;;
        "$(path_key "$HOME/Documents")"|"$(path_key "$HOME/Documents")"/*) return 0 ;;
        "$(path_key "$HOME/Downloads")"|"$(path_key "$HOME/Downloads")"/*) return 0 ;;
        "$(path_key "$LIB/Mobile Documents")"|"$(path_key "$LIB/Mobile Documents")"/*) return 0 ;;
    esac
    return 1
}

os_schedule_install() {
    local dir="$LIB/LaunchAgents" logs="$LIB/Logs" plist a prev=''
    plist="$dir/$SCHED_LABEL.plist"
    mkdir -p "$dir" "$logs" || die "cannot create $dir"
    {
        cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SCHED_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$BB_DIR/buildbroom.sh")</string>
PLIST
        for a in "$@"; do printf '    <string>%s</string>\n' "$(xml_escape "$a")"; done
        cat <<PLIST
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$PATH")</string>
    <key>NO_COLOR</key>
    <string>1</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>1</integer>
    <key>Hour</key>
    <integer>10</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$logs/buildbroom.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$logs/buildbroom.log")</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
</dict>
</plist>
PLIST
    } > "$plist.tmp" || die "cannot write $plist"
    if ! plutil -lint -s "$plist.tmp"; then rm -f "$plist.tmp"; die "generated an invalid $plist"; fi
    mv -f "$plist.tmp" "$plist"

    launchctl bootout "gui/$(id -u)/$SCHED_LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$plist" || die "launchctl could not load $plist"

    info "Scheduled weekly (Monday 10:00, or at the next wake-up):"
    printf '  /bin/bash'; printf ' %q' "$BB_DIR/buildbroom.sh" "$@"; echo
    echo "  log:    $logs/buildbroom.log"
    echo "  agent:  $plist"
    echo "  remove: $BB_DIR/buildbroom.sh --unschedule"
    if under_protected "$BB_DIR"; then
        note "buildbroom lives in a folder macOS protects ($BB_DIR): the scheduled run cannot read it. Move the repo or give /bin/bash Full Disk Access."
    fi
    for a in "$@"; do
        if [ "$prev" = --roots ] && under_protected "$a"; then
            note "Root $a is in a folder macOS protects: the scheduled run needs Full Disk Access for /bin/bash to scan it."
        fi
        prev=$a
    done
    echo "The script path is stored in the agent: run --schedule again if you move the repo."
}

os_schedule_remove() {
    local plist="$LIB/LaunchAgents/$SCHED_LABEL.plist"
    launchctl bootout "gui/$(id -u)/$SCHED_LABEL" >/dev/null 2>&1
    if [ -e "$plist" ]; then
        rm -f "$plist" && info "Removed the scheduled run ($plist)."
    else
        info "No scheduled run found."
    fi
}
