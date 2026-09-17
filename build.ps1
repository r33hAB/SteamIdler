# Builds SteamIdler.exe and SteamIdlerWorker.exe using the in-box .NET Framework
# compiler. No SDK, no downloads, no admin rights needed.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'src'
$out  = Join-Path $root 'bin'

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found at $csc" }

New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Host 'Compiling SteamIdlerWorker.exe (x64 console)...'
& $csc /nologo /target:exe /platform:x64 /optimize+ `
    /out:"$out\SteamIdlerWorker.exe" `
    "$src\Worker.cs"
if ($LASTEXITCODE -ne 0) { throw 'Worker build failed' }

Write-Host 'Compiling SteamIdler.exe (x64 WinForms)...'
& $csc /nologo /target:winexe /platform:x64 /optimize+ `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    /out:"$out\SteamIdler.exe" `
    "$src\MainForm.cs" "$src\AddAppForm.cs" "$src\SteamLibrary.cs" "$src\Config.cs"
if ($LASTEXITCODE -ne 0) { throw 'GUI build failed' }

# Pull a steam_api64.dll out of any installed game so the worker can load it.
$dest = Join-Path $out 'steam_api64.dll'
if (-not (Test-Path $dest)) {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    $steam = $steam -replace '/', '\'

    $libs = @((Join-Path $steam 'steamapps'))
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libs += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps')
        }
    }

    foreach ($lib in $libs) {
        $common = Join-Path $lib 'common'
        if (-not (Test-Path $common)) { continue }
        $found = Get-ChildItem $common -Recurse -Filter 'steam_api64.dll' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName $dest
            Write-Host "Copied steam_api64.dll from $($found.Directory.Name)"
            break
        }
    }
}

if (Test-Path $dest) {
    Write-Host ''
    Write-Host "Build complete -> $out\SteamIdler.exe" -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Build complete, but steam_api64.dll was not found.' -ForegroundColor Yellow
    Write-Host "Copy one from any installed game folder into $out before running." -ForegroundColor Yellow
}
