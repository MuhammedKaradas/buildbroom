# shellcheck shell=bash
# macOS: cache locations, report-only items, folders never scanned and config reading.
# Sourced after lib/common.sh; only fills in the os_* hooks.

OS_NAME=macOS
LIB="$HOME/Library"

# APFS is case-insensitive by default: compare paths and prune with -ipath accordingly.
FIND_PATH_TEST=-ipath
path_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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
                                                         docker ''              mac_docker         ''                      docker_guard
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
