[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if ($Check) {
        dotnet run --project windows/Smoke/Smoke.csproj -c Release
        if ($LASTEXITCODE -ne 0) { throw 'Windows smoke tests failed.' }
    }

    $product = 'HoldToDictate-windows-x64'
    $output = Join-Path $root 'build/windows-x64'
    $dist = Join-Path $root 'dist/windows'
    if (Test-Path $output) { Remove-Item $output -Recurse -Force }
    New-Item -Path $dist -ItemType Directory -Force | Out-Null
    dotnet publish windows/HoldToDictate.Windows/HoldToDictate.Windows.csproj -c Release `
        -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    $exe = Join-Path $output 'HoldToDictate.exe'
    if (-not (Test-Path $exe)) { throw 'Windows executable was not produced.' }

    if ($Check) {
        $process = Start-Process -FilePath $exe -ArgumentList '--self-test' -NoNewWindow -PassThru
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Packaged self-test timed out.' }
        if ($process.ExitCode -ne 0) { throw "Packaged self-test failed: $($process.ExitCode)." }
    }

    Copy-Item (Join-Path $root 'LICENSE') $output
    Copy-Item (Join-Path $root 'windows/NAudio-LICENSE.txt') $output
    $runtimeNotices = Join-Path (Split-Path -Parent (Get-Command dotnet).Source) 'ThirdPartyNotices.txt'
    if (Test-Path $runtimeNotices) { Copy-Item $runtimeNotices (Join-Path $output 'DOTNET-ThirdPartyNotices.txt') }
    $zipName = "$product.zip"
    $zip = Join-Path $dist $zipName
    Compress-Archive -Path "$output/*" -DestinationPath $zip -Force
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $zipName" | Set-Content -Encoding ascii (Join-Path $dist "$zipName.sha256")
    Write-Host "Created $zip"
} finally {
    Pop-Location
}
