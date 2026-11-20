<#
  Safety test for buildbroom's artifact cleanup.

  Builds a throwaway fixture tree, runs buildbroom with -Apply and checks that exactly the
  right folders are gone and everything else survives. Exits 1 on the first failure.

  Run locally:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\safety.ps1
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\windows\buildbroom.ps1'
# Temp lives under AppData, which buildbroom refuses to scan, so the fixture goes elsewhere.
$F = Join-Path $env:SystemDrive ("bb-fixture-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
if ($env:BB_FIXTURE_DIR) { $F = $env:BB_FIXTURE_DIR }

$old = (Get-Date).AddDays(-30)
$failed = 0
function Set-Old([string]$p) {
    Get-ChildItem -LiteralPath $p -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $_.LastWriteTime = $old }
    (Get-Item -LiteralPath $p).LastWriteTime = $old
}
function Assert([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else     { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failed++ }
}
function Invoke-BB([string[]]$extra) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Mode artifacts -Roots $F -Config "$F\none.json" @extra | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "buildbroom exited with $LASTEXITCODE" }
}

try {
    New-Item -ItemType Directory -Force -Path `
        "$F\repo\node_modules\lodash", "$F\repo\bin\Debug\net8", "$F\repo\obj", "$F\repo\dist", "$F\repo\build",
        "$F\shared\pkg", "$F\nogit\node_modules\x", "$F\repo\node_modules\pkg-a" | Out-Null

    Set-Content "$F\shared\pkg\index.js" 'SOURCE'
    Set-Content "$F\repo\package.json" '{}'
    Set-Content "$F\repo\app.csproj" '<Project/>'
    Set-Content "$F\repo\node_modules\lodash\a.js" ('x' * 10000)
    Set-Content "$F\repo\node_modules\pkg-a\package.json" '{}'     # a package, not a project
    Set-Content "$F\repo\obj\o.txt" 'o'
    Set-Content "$F\repo\dist\out.js" 'committed'
    Set-Content "$F\repo\bin\Debug\net8\app.dll" 'dll'
    Set-Content "$F\repo\build\script.sh" 'no marker next to this build folder'
    Set-Content "$F\repo\.gitignore" "node_modules/`nbin/`nobj/"
    Set-Content "$F\nogit\package.json" '{}'
    Set-Content "$F\nogit\node_modules\x\i.js" 'y'
    cmd /c mklink /J "$F\repo\node_modules\shared-pkg" "$F\shared\pkg" | Out-Null

    git -C "$F\repo" init -q
    git -C "$F\repo" add -A
    git -C "$F\repo" -c user.name=test -c user.email=test@example.com commit -qm init

    foreach ($p in "$F\repo\node_modules", "$F\repo\obj", "$F\repo\dist", "$F\repo\bin", "$F\nogit\node_modules") { Set-Old $p }
    (Get-Item "$F\repo\bin\Debug\net8\app.dll").LastWriteTime = Get-Date   # recent file deep inside bin

    Write-Host "`n== dry run deletes nothing"
    Invoke-BB @()
    Assert 'dry run: obj still there'          (Test-Path "$F\repo\obj")
    Assert 'dry run: node_modules still there' (Test-Path "$F\repo\node_modules")

    Write-Host "`n== -Apply (node_modules has a fresh junction, so it is kept at 7 days)"
    Invoke-BB @('-Apply')
    Assert 'old ignored obj deleted'                 (-not (Test-Path "$F\repo\obj"))
    Assert 'bin kept: recent file deep inside'       (Test-Path "$F\repo\bin\Debug\net8\app.dll")
    Assert 'tracked dist kept'                       (Test-Path "$F\repo\dist\out.js")
    Assert 'build without a marker kept'             (Test-Path "$F\repo\build\script.sh")
    Assert 'non-git node_modules kept'               (Test-Path "$F\nogit\node_modules")
    Assert 'node_modules kept (fresh junction)'      (Test-Path "$F\repo\node_modules")

    Write-Host "`n== -Apply -OlderThanDays 0, bin excluded"
    Invoke-BB @('-Apply', '-OlderThanDays', '0', '-Exclude', '*\bin')
    Assert 'node_modules deleted'                    (-not (Test-Path "$F\repo\node_modules"))
    Assert 'junction target (real source) survives'  (Test-Path "$F\shared\pkg\index.js")
    Assert 'excluded bin kept'                       (Test-Path "$F\repo\bin")
    Assert 'tracked dist still kept'                 (Test-Path "$F\repo\dist\out.js")
    Assert 'non-git node_modules still kept'         (Test-Path "$F\nogit\node_modules")

    Write-Host "`n== a root under AppData is refused"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Mode artifacts -Roots $env:LOCALAPPDATA -Config "$F\none.json" 2>&1 | Out-String
    Assert 'AppData root skipped' ($out -match 'tool/system folder, skipped')

    Write-Host "`n== default mode without roots does not scan the current folder"
    Push-Location "$F\repo"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Config "$F\none.json" 2>&1 | Out-String
    Pop-Location
    Assert 'artifacts skipped without roots' ($out -match 'Artifacts skipped')
}
finally {
    if (Test-Path $F) { cmd /c "rmdir /s /q `"$F`"" }
}

if ($failed) { Write-Host "`n$failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed" -ForegroundColor Green
exit 0
