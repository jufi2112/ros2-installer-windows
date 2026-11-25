param(
    [switch] $Offline,
    [string] $Artifacts
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$osType = & docker info --format '{{.OSType}}'
if ($LASTEXITCODE -ne 0 -or $osType -ne 'windows') {
    throw 'The smoke test requires a running Windows container engine.'
}
if (!$Artifacts) { $Artifacts = Join-Path $root 'dist/online' }
if ($Offline -and !(Test-Path -LiteralPath (Join-Path $Artifacts 'offline.json') -PathType Leaf)) {
    throw 'Supply the extracted offline ZIP directory with -Artifacts.'
}

$tag = [Guid]::NewGuid().ToString('N')
$context = Join-Path $root "build/smoke-$tag"
$testImage = "ros2-humble-smoke:$tag"
New-Item -ItemType Directory -Path (Join-Path $context 'artifacts') | Out-Null
Copy-Item -Path (Join-Path $Artifacts '*') -Destination (Join-Path $context 'artifacts') -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'smoke.ps1') -Destination $context
$baseImage = if ($Offline) { 'mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2022' }
    else { 'mcr.microsoft.com/windows/servercore:ltsc2022' }
@"
FROM $baseImage
COPY artifacts/ /setup/
COPY smoke.ps1 /smoke.ps1
"@ | Set-Content -LiteralPath (Join-Path $context 'Dockerfile') -Encoding Ascii
& docker build --isolation=hyperv --tag $testImage $context
if ($LASTEXITCODE -ne 0) { throw 'Building the Windows smoke test image failed.' }

$dockerArgs = @('run', '--rm', '--isolation=hyperv', '--user', 'ContainerAdministrator')
if ($Offline) { $dockerArgs += @('--network', 'none') }
$dockerArgs += @($testImage, 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:/smoke.ps1')
if ($Offline) { $dockerArgs += '-Offline' }
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "Container smoke test failed with exit code $LASTEXITCODE." }
