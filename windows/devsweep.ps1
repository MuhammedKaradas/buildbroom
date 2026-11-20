<#
.SYNOPSIS
  devsweep - safely reclaim disk space eaten by developer caches and build artifacts.

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
      and delete the real source. devsweep never uses it on artifact folders.)
    * Paths are never followed through reparse points while scanning or measuring.
    * Big items like Docker/WSL virtual disks and Android SDKs are reported, never deleted.

.EXAMPLE
  .\devsweep.ps1                                   # report caches + artifacts (dry run)
  .\devsweep.ps1 -Mode artifacts -Roots F:\code    # report build artifacts under F:\code
  .\devsweep.ps1 -Mode artifacts -Roots F:\code -OlderThanDays 14 -Apply
  .\devsweep.ps1 -Mode caches -Apply
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

    [string]$Config = (Join-Path $env:USERPROFILE '.config\devsweep\config.json')
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
if (-not $Roots) { $Roots = @((Get-Location).Path) }

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

# Size of a directory tree, never following junctions/symlinks.
function Get-DirBytes([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    [double]$sum = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $path -Force))
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $items = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($i in $items) {
            if (Test-Reparse $i) { continue }
            if ($i -is [IO.DirectoryInfo]) { $stack.Push($i) } else { $sum += $i.Length }
        }
    }
    return $sum
}

# Remove a directory without following reparse points.
function Remove-DirSafe([string]$path) {
    if (-not $Apply) { return }
    if (-not (Test-Path -LiteralPath $path)) { return }
    cmd /c "rmdir /s /q `"$path`"" 2>$null
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
    @{ Name = 'npm cache'; Path = "$LA\npm-cache"; Block = @(); Run = {
        if (Test-Cmd npm) { npm cache clean --force 2>$null | Out-Null } }
    }
    @{ Name = 'Yarn cache'; Path = "$LA\Yarn\Cache"; Block = @(); Run = {
        if (Test-Cmd yarn) { yarn cache clean 2>$null | Out-Null } }
    }
    @{ Name = 'pnpm store (unreferenced only)'; Path = "$LA\pnpm"; Block = @(); Run = {
        if (Test-Cmd pnpm) { pnpm store prune 2>$null | Out-Null } }
    }
    @{ Name = 'Go build cache'; Path = "$LA\go-build"; Block = @(); Run = {
        if (Test-Cmd go) { go clean -cache } }
    }
    @{ Name = 'Gradle caches + daemon logs'; Path = "$U\.gradle\caches"; Extra = @("$U\.gradle\daemon");
       Block = @('studio64', 'idea64'); Run = {
        Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'GradleDaemon' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Remove-DirSafe "$U\.gradle\caches"
        Remove-DirSafe "$U\.gradle\daemon" }
    }
    @{ Name = 'NuGet http + plugins cache'; Path = "$LA\NuGet\v3-cache"; Extra = @("$LA\NuGet\plugins-cache");
       Block = @('devenv', 'rider64'); Run = {
        if (Test-Cmd dotnet) {
            dotnet nuget locals http-cache --clear | Out-Null
            dotnet nuget locals plugins-cache --clear | Out-Null
        } }
    }
    @{ Name = "Temp files older than $TempDays days"; Path = $null; Block = @(); Measure = {
            $cut = (Get-Date).AddDays(-$TempDays); [double]$s = 0
            Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cut -and -not (Test-Reparse $_) } |
                ForEach-Object { if ($_ -is [IO.DirectoryInfo]) { $s += Get-DirBytes $_.FullName } else { $s += $_.Length } }
            $s }
       Run = {
            $cut = (Get-Date).AddDays(-$TempDays)
            Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cut } |
                ForEach-Object {
                    if ($_ -is [IO.DirectoryInfo]) { Remove-DirSafe $_.FullName }
                    else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                } }
    }
    @{ Name = 'Crash dumps'; Path = "$LA\CrashDumps"; Block = @(); Run = {
        Get-ChildItem -LiteralPath "$LA\CrashDumps" -File -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue }
    }
    @{ Name = 'Docker build cache (images/containers/volumes untouched)'; Path = $null; Block = @(); Run = {
        if ((Test-Cmd docker) -and (docker info 2>$null)) { docker builder prune -f 2>$null | Out-Null } }
    }
)
if ($Deep) {
    $CacheTargets += @{ Name = '[deep] NuGet global packages'; Path = "$U\.nuget\packages";
        Block = @('devenv', 'rider64'); Run = { if (Test-Cmd dotnet) { dotnet nuget locals global-packages --clear | Out-Null } } }
    $CacheTargets += @{ Name = '[deep] Gradle wrapper distributions'; Path = "$U\.gradle\wrapper\dists";
        Block = @('studio64', 'idea64'); Run = { Remove-DirSafe "$U\.gradle\wrapper\dists" } }
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
        $busy = Test-Running $t.Block
        if ($busy) { Add-Row 'cache' $t.Name $bytes "skipped ($busy running)"; continue }
        if ($Apply) { & $t.Run; Add-Row 'cache' $t.Name $bytes 'cleaned' }
        else        { Add-Row 'cache' $t.Name $bytes 'would clean' }
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
$NeverDescend = @('.git', '.hg', '.svn', '.vs', '.idea')

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
            if ($NeverDescend -contains $s.Name) { continue }
            if ($ArtifactRules.Contains($s.Name) -and (Test-Marker $dir.FullName $ArtifactRules[$s.Name])) {
                [void]$found.Add($s); continue          # never descend into an artifact
            }
            if ($depth + 1 -lt $MaxDepth) { $stack.Push(@($s, ($depth + 1))) }
        }
    }
    return $found
}

function Invoke-Artifacts {
    $cut = (Get-Date).AddDays(-$OlderThanDays)
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { Write-Warning "Root not found: $root"; continue }
        Write-Host "Scanning $root ..." -ForegroundColor DarkGray
        foreach ($a in (Find-Artifacts $root)) {
            $path = $a.FullName
            if ($Exclude | Where-Object { $path -like $_ }) { continue }
            $bytes = Get-DirBytes $path
            if ($a.LastWriteTime -gt $cut) { Add-Row 'artifact' $path $bytes "kept (changed < $OlderThanDays d)"; continue }
            if (-not $NoGitCheck) {
                $g = Get-GitIgnoreState $a.Parent.FullName $a.Name
                if ($g -eq 1)  { Add-Row 'artifact' $path $bytes 'kept (tracked by git)'; continue }
                if ($g -ne 0)  { Add-Row 'artifact' $path $bytes 'kept (not a git repo; -NoGitCheck)'; continue }
            }
            if ($Apply) { Remove-DirSafe $path; Add-Row 'artifact' $path $bytes 'deleted' }
            else        { Add-Row 'artifact' $path $bytes 'would delete' }
        }
    }
}

# ---------------------------------------------------------------- main
$free0 = Get-FreeBytes
$modeText = if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing deleted, add -Apply)' }
Write-Host "devsweep $Version - $modeText" -ForegroundColor Cyan
Write-Host ("Free on {0}: {1}" -f $env:SystemDrive, (Format-Size $free0)) -ForegroundColor Cyan

if ($Mode -in 'all', 'caches')    { Invoke-Caches }
if ($Mode -in 'all', 'artifacts') { Invoke-Artifacts }

$script:Rows |
    Where-Object { $_.Size -gt 0 } |
    Sort-Object Kind, @{ e = 'Size'; Descending = $true } |
    Format-Table Kind, @{ n = 'Size'; e = { Format-Size $_.Size }; a = 'right' }, Status, Item -AutoSize -Wrap

$actionable = $script:Rows | Where-Object { $_.Status -in 'would clean', 'would delete', 'cleaned', 'deleted' }
$sum = ($actionable | Measure-Object Size -Sum).Sum
if ($Apply) {
    $free1 = Get-FreeBytes
    Write-Host ("Done. Free: {0} -> {1}  (+{2})" -f (Format-Size $free0), (Format-Size $free1), (Format-Size ([math]::Max(0, $free1 - $free0)))) -ForegroundColor Green
} else {
    Write-Host ("Reclaimable: ~{0}. Run again with -Apply to clean." -f (Format-Size $sum)) -ForegroundColor Green
}
