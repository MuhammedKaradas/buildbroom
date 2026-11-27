<#
.SYNOPSIS
  buildbroom - safely reclaim disk space eaten by developer caches and build artifacts.

.DESCRIPTION
  Two kinds of cleanup:

    caches     Global, re-downloadable tool caches (npm, Gradle, NuGet, Go, Yarn, pnpm,
               Docker build cache, old Temp files, crash dumps).
    artifacts  Per-project build output (node_modules, bin/obj, target, .next, build, ...)
               found under the roots you give it. Ideal for many repos / git worktrees.

  Safety model:
    * Dry run by default. Nothing is deleted unless -Apply is passed.
    * An artifact folder is only a candidate when:
        - its name is on the known list AND a matching project marker sits next to it
          (node_modules needs package.json, bin/obj need a *.csproj, target needs Cargo.toml/pom.xml ...)
        - git says it is ignored (git check-ignore), so committed folders are never touched
          (use -NoGitCheck for projects that are not git repos)
        - it has not been modified for -OlderThanDays days (active worktrees are kept)
    * Deletion uses `rmdir /s /q`, which removes junctions/symlinks WITHOUT following them.
      (PowerShell 5.1 Remove-Item can follow junctions - e.g. pnpm/monorepo workspace links -
      and delete the real source. buildbroom never uses it on artifact folders.)
    * Paths are never followed through reparse points while scanning or measuring.
    * Big items like Docker/WSL virtual disks and Android SDKs are reported, never deleted.

.EXAMPLE
  .\buildbroom.ps1                                   # report caches + artifacts (dry run)
  .\buildbroom.ps1 -Mode artifacts -Roots F:\code    # report build artifacts under F:\code
  .\buildbroom.ps1 -Mode artifacts -Roots F:\code -OlderThanDays 14 -Apply
  .\buildbroom.ps1 -Mode caches -Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'caches', 'artifacts')]
    [string]$Mode = 'all',

    [string[]]$Roots,

    [int]$OlderThanDays = 7,

    [int]$TempDays = 3,

    [int]$MaxDepth = 8,

    [string[]]$Exclude = @(),

    [switch]$NoGitCheck,

    [switch]$Deep,

    [switch]$Apply,

    [string]$Config = (Join-Path $env:USERPROFILE '.config\buildbroom\config.json')
)

$ErrorActionPreference = 'Continue'
$Version = '0.1.0'
$U  = $env:USERPROFILE
$LA = $env:LOCALAPPDATA

# ---------------------------------------------------------------- config
if (Test-Path -LiteralPath $Config) {
    try {
        $cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        if (-not $PSBoundParameters.ContainsKey('Roots')         -and $cfg.roots)         { $Roots = @($cfg.roots) }
        if (-not $PSBoundParameters.ContainsKey('OlderThanDays') -and $cfg.olderThanDays) { $OlderThanDays = [int]$cfg.olderThanDays }
        if (-not $PSBoundParameters.ContainsKey('Exclude')       -and $cfg.exclude)       { $Exclude = @($cfg.exclude) }
    } catch { Write-Warning "Could not read config $Config : $_" }
}
# No roots given or configured: an explicit `-Mode artifacts` scans the current folder;
# the default `all` mode does not, so running it from your home folder never scans everything.
$RootsNote = $null
if (-not $Roots) {
    if ($Mode -eq 'artifacts') { $Roots = @((Get-Location).Path) }
    else { $RootsNote = 'Artifacts skipped: no -Roots given and none in the config file.' }
}

# ---------------------------------------------------------------- helpers
function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N2} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N0} MB' -f ($bytes / 1MB) }
    return '{0:N0} KB' -f ($bytes / 1KB)
}

function Get-FreeBytes {
    $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($d) { return [double]$d.Free } else { return 0 }
}

function Test-Reparse([IO.FileSystemInfo]$i) {
    return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Size and newest write time of a directory tree, never following junctions/symlinks.
# A folder's own LastWriteTime only changes when its direct children change, so the
# newest time anywhere inside is the only reliable "was this used recently" signal.
function Get-DirStats([string]$path) {
    $r = [pscustomobject]@{ Bytes = [double]0; Newest = [datetime]::MinValue }
    if (-not (Test-Path -LiteralPath $path)) { return $r }
    $root = Get-Item -LiteralPath $path -Force
    $r.Newest = $root.LastWriteTime
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $items = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($i in $items) {
            if ($i.LastWriteTime -gt $r.Newest) { $r.Newest = $i.LastWriteTime }
            if (Test-Reparse $i) { continue }
            if ($i -is [IO.DirectoryInfo]) { $stack.Push($i) } else { $r.Bytes += $i.Length }
        }
    }
    return $r
}
function Get-DirBytes([string]$path) { return (Get-DirStats $path).Bytes }

# Remove a directory without following reparse points (rmdir /s removes a junction or
# symlink itself and never enters it). Returns $true when the folder is fully gone.
function Remove-DirSafe([string]$path) {
    if (-not $Apply) { return $false }
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    if ($path.Contains('%')) { Write-Warning "Skipping path with '%' (cmd would expand it): $path"; return $false }
    cmd /c "rmdir /s /q `"$path`"" 2>$null
    return -not (Test-Path -LiteralPath $path)
}

function Test-Running([string[]]$names) {
    if (-not $names) { return $null }
    $p = Get-Process -Name $names -ErrorAction SilentlyContinue
    if ($p) { return ($p | Select-Object -ExpandProperty ProcessName -Unique) -join ', ' }
    return $null
}

function Test-Cmd([string]$name) { return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

$script:Rows = New-Object System.Collections.ArrayList
function Add-Row($kind, $name, $bytes, $status) {
    [void]$script:Rows.Add([pscustomobject]@{ Kind = $kind; Size = $bytes; Status = $status; Item = $name })
}

# ---------------------------------------------------------------- caches
$CacheTargets = @(
    @{ Name = 'npm cache'; Path = "$LA\npm-cache\_cacache"; Tool = 'npm'; Block = @(); Run = {
        npm cache clean --force 2>$null | Out-Null }
    }
    @{ Name = 'Yarn cache'; Path = "$LA\Yarn\Cache"; Tool = 'yarn'; Block = @(); Run = {
        yarn cache clean 2>$null | Out-Null }
    }
    @{ Name = 'pnpm store (unreferenced only)'; Path = "$LA\pnpm"; Tool = 'pnpm'; Block = @(); Run = {
        pnpm store prune 2>$null | Out-Null }
    }
    @{ Name = 'Go build cache'; Path = "$LA\go-build"; Tool = 'go'; Block = @(); Run = {
        go clean -cache }
    }
    @{ Name = 'Gradle caches + daemon logs'; Path = "$U\.gradle\caches"; Extra = @("$U\.gradle\daemon");
       Block = @('studio64', 'idea64'); Run = {
        Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'GradleDaemon' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        [void](Remove-DirSafe "$U\.gradle\caches")
        [void](Remove-DirSafe "$U\.gradle\daemon") }
    }
    @{ Name = 'NuGet http + plugins cache'; Path = "$LA\NuGet\v3-cache"; Extra = @("$LA\NuGet\plugins-cache");
       Tool = 'dotnet'; Block = @('devenv', 'rider64'); Run = {
        dotnet nuget locals http-cache --clear | Out-Null
        dotnet nuget locals plugins-cache --clear | Out-Null }
    }
    @{ Name = "Temp entries untouched for $TempDays days"; Path = $null; Block = @(); Measure = {
            [double]$s = 0
            foreach ($e in (Get-OldTempEntries)) { $s += $e.Bytes }
            $s }
       Run = {
            foreach ($e in (Get-OldTempEntries)) {
                if ($e.Item -is [IO.DirectoryInfo]) { [void](Remove-DirSafe $e.Item.FullName) }
                else { Remove-Item -LiteralPath $e.Item.FullName -Force -ErrorAction SilentlyContinue }
            } }
    }
    @{ Name = 'Crash dumps'; Path = "$LA\CrashDumps"; Block = @(); Run = {
        Get-ChildItem -LiteralPath "$LA\CrashDumps" -File -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue }
    }
    @{ Name = 'Docker build cache (images/containers/volumes untouched)'; Path = $null; Tool = 'docker'; Block = @();
       Measure = { Get-DockerBuildCacheBytes }
       Run = { if (docker info 2>$null) { docker builder prune -f 2>$null | Out-Null } }
    }
)
if ($Deep) {
    $CacheTargets += @{ Name = '[deep] NuGet global packages'; Path = "$U\.nuget\packages"; Tool = 'dotnet';
        Block = @('devenv', 'rider64'); Run = { dotnet nuget locals global-packages --clear | Out-Null } }
    $CacheTargets += @{ Name = '[deep] Gradle wrapper distributions'; Path = "$U\.gradle\wrapper\dists";
        Block = @('studio64', 'idea64'); Run = { [void](Remove-DirSafe "$U\.gradle\wrapper\dists") } }
}

# Reclaimable Docker build cache in bytes, from `docker system df` (decimal units such as
# "1.5GB"). 0 when Docker is missing, not running or fails (seen with containerd snapshot
# issues). Reclaimable, not total: `docker builder prune` keeps cache that is in use.
function Get-DockerBuildCacheBytes {
    if (-not (Test-Cmd 'docker')) { return [double]0 }
    $lines = docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return [double]0 }
    foreach ($l in @($lines)) {
        $parts = "$l".Split('|')
        if ($parts.Count -lt 2 -or $parts[0] -ne 'Build Cache') { continue }
        $m = [regex]::Match($parts[1], '^\s*([0-9.]+)\s*([kKMGT]?B)\b')
        if (-not $m.Success) { return [double]0 }
        $mult = @{ 'B' = 1; 'KB' = 1e3; 'MB' = 1e6; 'GB' = 1e9; 'TB' = 1e12 }[$m.Groups[2].Value]
        return [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $mult
    }
    return [double]0
}

# Top-level Temp entries with nothing inside written for -TempDays days.
function Get-OldTempEntries {
    $cut = (Get-Date).AddDays(-$TempDays)
    foreach ($i in (Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue)) {
        if ($i -is [IO.DirectoryInfo] -and -not (Test-Reparse $i)) {
            $st = Get-DirStats $i.FullName
            if ($st.Newest -lt $cut) { [pscustomobject]@{ Item = $i; Bytes = $st.Bytes } }
        } elseif ($i.LastWriteTime -lt $cut) {
            [pscustomobject]@{ Item = $i; Bytes = $(if ($i -is [IO.FileInfo]) { $i.Length } else { 0 }) }
        }
    }
}

$WatchOnly = [ordered]@{
    'Docker Desktop data disk'  = "$LA\Docker\wsl"
    'WSL distro disks'          = "$LA\wsl"
    'Android SDK'               = "$LA\Android\Sdk"
    'Android emulators (AVD)'   = "$U\.android\avd"
    'Downloads'                 = "$U\Downloads"
}

function Invoke-Caches {
    foreach ($t in $CacheTargets) {
        if ($t.Measure) { $bytes = & $t.Measure }
        else {
            $bytes = 0
            foreach ($p in @($t.Path) + @($t.Extra)) { if ($p) { $bytes += Get-DirBytes $p } }
        }
        if ($t.Tool -and -not (Test-Cmd $t.Tool)) { Add-Row 'cache' $t.Name $bytes "skipped ($($t.Tool) not on PATH)"; continue }
        $busy = Test-Running $t.Block
        if ($busy) { Add-Row 'cache' $t.Name $bytes "skipped ($busy running)"; continue }
        if (-not $Apply) { Add-Row 'cache' $t.Name $bytes 'would clean'; continue }
        & $t.Run
        # Report what was really freed, not what we hoped to free.
        if ($t.Measure) { $after = & $t.Measure }
        else { $after = 0; foreach ($p in @($t.Path) + @($t.Extra)) { if ($p) { $after += Get-DirBytes $p } } }
        $freed = [math]::Max(0, $bytes - $after)
        $status = if ($after -gt 0 -and $freed -lt $bytes) { "cleaned ($(Format-Size $after) left, in use or kept by the tool)" } else { 'cleaned' }
        Add-Row 'cache' $t.Name $freed $status
    }
    foreach ($k in $WatchOnly.Keys) {
        $b = Get-DirBytes $WatchOnly[$k]
        if ($b -gt 0) { Add-Row 'watch' "$k  ($($WatchOnly[$k]))" $b 'report only' }
    }
}

# ---------------------------------------------------------------- artifacts
# folder name -> markers that must exist in the parent folder
$ArtifactRules = [ordered]@{
    'node_modules'  = @('package.json')
    '.next'         = @('package.json')
    '.nuxt'         = @('package.json')
    '.svelte-kit'   = @('package.json')
    '.turbo'        = @('package.json', 'turbo.json')
    '.angular'      = @('angular.json')
    '.parcel-cache' = @('package.json')
    'dist'          = @('package.json')
    'bin'           = @('*.csproj', '*.fsproj', '*.vbproj')
    'obj'           = @('*.csproj', '*.fsproj', '*.vbproj')
    'target'        = @('Cargo.toml', 'pom.xml')
    'build'         = @('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts', 'pubspec.yaml', 'CMakeLists.txt')
    '.gradle'       = @('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts')
    '.dart_tool'    = @('pubspec.yaml')
    '__pycache__'   = @('*.py')
    '.pytest_cache' = @('*.py', 'pytest.ini', 'pyproject.toml')
    '.mypy_cache'   = @('*.py', 'pyproject.toml')
}
# Folder names never scanned into. node_modules is here too: when it is not itself a
# candidate, its packages (each with a package.json) must never be mistaken for projects.
$NeverDescend = @('.git', '.hg', '.svn', '.vs', '.idea', 'node_modules')

# Tool and OS locations never scanned, even if a root contains them. A node_modules or
# bin folder in there belongs to an installed program (global npm, VS Code extensions,
# nvm Node versions ...) and deleting it breaks that program.
$NeverScan = @(
    $env:APPDATA, $LA, "$U\AppData", $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:windir,
    "$U\.vscode", "$U\.vscode-insiders", "$U\.cursor", "$U\.nuget", "$U\.gradle", "$U\.android",
    "$U\.cargo", "$U\.rustup", "$U\.npm", "$U\.nvm", "$U\scoop", "$U\go\pkg"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

function Test-NeverScan([string]$path) {
    foreach ($n in $NeverScan) {
        if ($path -eq $n -or $path.StartsWith("$n\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-Marker([string]$parent, [string[]]$markers) {
    foreach ($m in $markers) {
        if ($m.Contains('*')) { if (Get-ChildItem -LiteralPath $parent -Filter $m -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true } }
        elseif (Test-Path -LiteralPath (Join-Path $parent $m)) { return $true }
    }
    return $false
}

# 0 = ignored, 1 = tracked/not ignored, 128 = not a git repo
function Get-GitIgnoreState([string]$parent, [string]$name) {
    git -C $parent check-ignore -q -- $name 2>$null | Out-Null
    return $LASTEXITCODE
}

function Find-Artifacts([string]$root) {
    $found = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@((Get-Item -LiteralPath $root -Force), 0))
    while ($stack.Count) {
        $entry = $stack.Pop(); $dir = $entry[0]; $depth = $entry[1]
        try { $subs = $dir.GetDirectories() } catch { continue }
        foreach ($s in $subs) {
            if (Test-Reparse $s) { continue }
            if (Test-NeverScan $s.FullName) { continue }
            if ($ArtifactRules.Contains($s.Name) -and (Test-Marker $dir.FullName $ArtifactRules[$s.Name])) {
                [void]$found.Add($s); continue          # never descend into an artifact
            }
            if ($NeverDescend -contains $s.Name) { continue }
            if ($depth + 1 -lt $MaxDepth) { $stack.Push(@($s, ($depth + 1))) }
        }
    }
    return $found
}

function Invoke-Artifacts {
    $cut = (Get-Date).AddDays(-$OlderThanDays)
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { Write-Warning "Root not found: $root"; continue }
        $root = (Resolve-Path -LiteralPath $root).ProviderPath.TrimEnd('\')
        if (Test-NeverScan $root) { Write-Warning "Root is a tool/system folder, skipped: $root"; continue }
        Write-Host "Scanning $root ..." -ForegroundColor DarkGray
        foreach ($a in (Find-Artifacts $root)) {
            $path = $a.FullName
            if ($Exclude | Where-Object { $path -like $_ }) { continue }
            $st = Get-DirStats $path
            $bytes = $st.Bytes
            if ($st.Newest -gt $cut) { Add-Row 'artifact' $path $bytes "kept (used < $OlderThanDays d ago)"; continue }
            if (-not $NoGitCheck) {
                $g = Get-GitIgnoreState $a.Parent.FullName $a.Name
                if ($g -eq 1)  { Add-Row 'artifact' $path $bytes 'kept (tracked by git)'; continue }
                if ($g -ne 0)  { Add-Row 'artifact' $path $bytes 'kept (not a git repo; -NoGitCheck)'; continue }
            }
            if (-not $Apply) { Add-Row 'artifact' $path $bytes 'would delete'; continue }
            if (Remove-DirSafe $path) { Add-Row 'artifact' $path $bytes 'deleted' }
            else {
                $left = Get-DirBytes $path
                Add-Row 'artifact' $path ([math]::Max(0, $bytes - $left)) "partly deleted ($(Format-Size $left) in use)"
            }
        }
    }
}

# ---------------------------------------------------------------- main
$free0 = Get-FreeBytes
$modeText = if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing deleted, add -Apply)' }
Write-Host "buildbroom $Version - $modeText" -ForegroundColor Cyan
Write-Host ("Free on {0}: {1}" -f $env:SystemDrive, (Format-Size $free0)) -ForegroundColor Cyan

if ($Mode -in 'all', 'caches')    { Invoke-Caches }
if ($Mode -in 'all', 'artifacts') {
    if ($RootsNote) { Write-Host $RootsNote -ForegroundColor Yellow } else { Invoke-Artifacts }
}

$script:Rows |
    Where-Object { $_.Size -gt 0 } |
    Sort-Object Kind, @{ e = 'Size'; Descending = $true } |
    Format-Table Kind, @{ n = 'Size'; e = { Format-Size $_.Size }; a = 'right' }, Status, Item -AutoSize -Wrap

$actionable = $script:Rows | Where-Object { $_.Status -match '^(would clean|would delete|cleaned|deleted|partly deleted)' }
$sum = ($actionable | Measure-Object Size -Sum).Sum
if ($Apply) {
    $free1 = Get-FreeBytes
    Write-Host ("Done. Free: {0} -> {1}  (+{2})" -f (Format-Size $free0), (Format-Size $free1), (Format-Size ([math]::Max(0, $free1 - $free0)))) -ForegroundColor Green
} else {
    Write-Host ("Reclaimable: ~{0}. Run again with -Apply to clean." -f (Format-Size $sum)) -ForegroundColor Green
}

exit 0
