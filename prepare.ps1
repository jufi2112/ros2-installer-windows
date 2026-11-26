$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = '10.0.404'
$archiveName = "dotnet-sdk-$version-win-x64.zip"
$sdkUrl = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$archiveName"
$sdkSha512 = '330ddd2665b43cd2e428216a0d8ea1ac7bb19b5434fdc530e62010dc3b52823a620bf95489d628e1ed6f5122401793ee4887cca4a019122361a1231497f632ee'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build'))
$sdk = Join-Path $build 'sdk'
$dotnet = Join-Path $sdk 'dotnet.exe'

function Assert-SdkArchive([string] $Path) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash -ne $sdkSha512) {
        throw "The .NET SDK archive at $Path failed SHA-512 verification."
    }
}

if (Test-Path -LiteralPath $build) {
    $directory = Get-Item -LiteralPath $build
    if (!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Use a regular build directory inside the repository ($build)."
    }
}
else {
    [IO.Directory]::CreateDirectory($build) | Out-Null
}

if (Test-Path -LiteralPath $sdk) {
    if (!(Test-Path -LiteralPath $dotnet -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $sdk "sdk/$version/dotnet.dll") -PathType Leaf)) {
        throw "The directory $sdk already exists without SDK $version. Move it aside before running prepare.ps1."
    }
    Write-Output "Using the repository's .NET SDK $version."
}
else {
    $archive = Join-Path $build $archiveName
    if (Test-Path -LiteralPath $archive) {
        Assert-SdkArchive $archive
    }
    else {
        $download = Join-Path $build "$archiveName.$([Guid]::NewGuid().ToString('N')).download"
        try {
            Write-Output "Downloading .NET SDK $version for Windows x64."
            Invoke-WebRequest -UseBasicParsing -Uri $sdkUrl -OutFile $download
            Assert-SdkArchive $download
            [IO.File]::Move($download, $archive)
        }
        finally { [IO.File]::Delete($download) }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $staging = [IO.Path]::GetFullPath((Join-Path $build "sdk-$([Guid]::NewGuid().ToString('N'))"))
    if ([IO.Path]::GetDirectoryName($staging) -ne $build -or [IO.Path]::GetDirectoryName($sdk) -ne $build) {
        throw 'The SDK paths must be inside the build directory.'
    }
    try {
        Write-Output "Extracting the verified SDK into $sdk."
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)
        [IO.Directory]::Move($staging, $sdk)
    }
    finally {
        if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
    }
}

$settings = @{
    DOTNET_CLI_HOME = Join-Path $build 'dotnet-home'
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
    NUGET_PACKAGES = Join-Path $build 'nuget'
    NUGET_HTTP_CACHE_PATH = Join-Path $build 'nuget-http-cache'
}
$previous = @{}
Push-Location -LiteralPath $PSScriptRoot
try {
    foreach ($key in $settings.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $settings[$key])
    }
    foreach ($project in 'Installer', 'Cli', 'Preview') {
        & $dotnet restore "src/$project/$project.csproj" --runtime win-x64 --source 'https://api.nuget.org/v3/index.json' `
            -p:Configuration=Release -p:SelfContained=true -p:PublishSingleFile=true
        if ($LASTEXITCODE -ne 0) { throw "NuGet restore for $project returned exit code $LASTEXITCODE." }
    }
}
finally {
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    Pop-Location
}

Write-Output 'The build dependencies are ready. Run .\build.ps1 to publish the installer.'
