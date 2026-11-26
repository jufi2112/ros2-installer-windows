[CmdletBinding(PositionalBinding = $false)]
param(
    [switch] $BuildOffline,
    [switch] $PreviewOnly,
    [switch] $FrameworkDependent,
    [string] $Dotnet
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
if (@($BuildOffline, $PreviewOnly, $FrameworkDependent).Where({ $_ }).Count -gt 1) {
    throw 'Choose only one of -BuildOffline, -PreviewOnly, or -FrameworkDependent.'
}

$env:DOTNET_CLI_HOME = Join-Path $projectRoot 'build/dotnet-home'
$env:NUGET_PACKAGES = Join-Path $projectRoot 'build/nuget'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'

$portableDotnet = Join-Path $projectRoot 'build/sdk/dotnet.exe'
$candidates = if ($Dotnet) { @($Dotnet) } else { @($portableDotnet, 'dotnet.exe') }
$checked = @()
$sdkVersion = $null
foreach ($candidate in $candidates) {
    $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$command) { continue }

    $available = @(& $command.Source --list-sdks)
    $checked += "$($command.Source): $($available -join ', ')"
    if ($LASTEXITCODE -ne 0 -or !($available | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 10 })) {
        continue
    }

    $active = & $command.Source --version | Select-Object -Last 1
    if ($LASTEXITCODE -eq 0 -and $active -match '^(\d+)\.' -and [int]$Matches[1] -ge 10) {
        $Dotnet = $command.Source
        $sdkVersion = $active
        break
    }
    $checked += "$($command.Source) selected SDK $active"
}
if (!$sdkVersion) {
    throw "This project targets .NET 10. Run .\prepare.ps1 for the local SDK, or select a compatible SDK via PATH or -Dotnet. Checked: $($checked -join '; ')"
}
Write-Output "Using .NET SDK $sdkVersion at $Dotnet"

function Invoke-Checked {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File returned exit code $LASTEXITCODE." }
}

function Publish-App {
    param([string] $Project, [string] $Output, [bool] $SelfContained = $true)
    $source = Join-Path $projectRoot "src/$Project/$Project.csproj"
    $arguments = @('publish', $source, '--configuration', 'Release', '--runtime', 'win-x64',
        '--self-contained', $SelfContained.ToString().ToLowerInvariant(), '-p:PublishSingleFile=true',
        '-p:DebugType=none', '--output', $Output)
    if ($SelfContained) { $arguments += '-p:IncludeNativeLibrariesForSelfExtract=true' }
    Invoke-Checked $Dotnet $arguments
}

$dist = Join-Path $projectRoot 'dist'
if ($PreviewOnly) {
    Publish-App 'Preview' (Join-Path $dist 'preview')
    return
}

if ($FrameworkDependent) {
    $output = Join-Path $dist 'online-framework-dependent'
    Publish-App 'Installer' $output -SelfContained $false
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $output
    return
}

$online = Join-Path $dist 'online'
Publish-App 'Installer' $online
Publish-App 'Cli' $online
if (!$BuildOffline) { return }

$osType = & docker info --format '{{.OSType}}'
if ($LASTEXITCODE -ne 0 -or $osType -ne 'windows') {
    throw 'An active Windows container engine is required for the offline payload build.'
}

$buildId = [Guid]::NewGuid().ToString('N')
$work = Join-Path $projectRoot "build/offline-$buildId"
$bundle = Join-Path $work 'bundle'
$context = Join-Path $work 'image'
New-Item -ItemType Directory -Path $bundle, $context | Out-Null
$cli = Join-Path $online 'Ros2HumbleCli.exe'
Copy-Item -LiteralPath $cli -Destination $context
Copy-Item -LiteralPath (Join-Path $online 'Ros2HumbleSetup.exe'), $cli -Destination $bundle
$image = "ros2-humble-offline-builder:$buildId"
@'
FROM mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-ltsc2022
COPY Ros2HumbleCli.exe /builder/
'@ | Set-Content -LiteralPath (Join-Path $context 'Dockerfile') -Encoding Ascii
Invoke-Checked 'docker' @('build', '--isolation=hyperv', '--tag', $image, $context)

$container = & docker create --isolation=hyperv $image 'C:/builder/Ros2HumbleCli.exe' '--prepare-offline' 'C:/offline'
if ($LASTEXITCODE -ne 0 -or !$container) { throw 'Could not create the offline payload build container.' }
try {
    Invoke-Checked 'docker' @('start', '--attach', $container)
    $exitCode = & docker inspect --format '{{.State.ExitCode}}' $container
    if ($LASTEXITCODE -ne 0 -or "$exitCode" -ne '0') { throw "Offline payload preparation failed ($exitCode)." }
    Invoke-Checked 'docker' @('cp', "${container}:C:/offline/payload", $bundle)
    Invoke-Checked 'docker' @('cp', "${container}:C:/offline/offline.json", $bundle)
    $zip = Join-Path $dist 'ros2-humble-offline-win-x64.zip'
    Invoke-Checked 'tar.exe' @('-a', '-cf', $zip, '-C', $bundle, '.')
    Write-Output "Offline installer: $zip"
}
finally {
    & docker rm $container | Out-Null
}
