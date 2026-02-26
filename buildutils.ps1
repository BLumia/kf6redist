# BuildUtils.ps1
# Reusable utilities for CMake-based build workflows

function Test-ExecutableExists {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [string]$ExecutableName
    )

    # Use Get-Command to check for the executable
    # -Type Application ensures only external programs are considered
    # -ErrorAction SilentlyContinue suppresses error messages if the command is not found
    $command = Get-Command -Name $ExecutableName -CommandType Application -ErrorAction SilentlyContinue

    # Return $true if $command is not $null (i.e., the executable was found), otherwise $false
    return [bool]$command
}

function Check-ExecutableExists {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [string]$ExecutableName
    )

    if (-not (Test-ExecutableExists $ExecutableName)) {
        Write-Error "Required executable '$ExecutableName' not found in PATH"
        exit 1
    } else {
        Write-Host "Found executable '$ExecutableName'" -ForegroundColor Green
    }
}

<#
.SYNOPSIS
    Initialize build environment by loading environment configuration scripts.
.DESCRIPTION
    Loads environment configuration scripts with priority:
    1. <Name>.local.ps1 (local override, not committed to VCS)
    2. <Name>.ps1       (shared defaults)

    Sets $env:ENV_SCRIPT_LOADED to prevent duplicate loading in the same session.
    Must be dot-sourced to properly set variables in caller's scope.

.PARAMETER EnvironmentName
    The base name of the environment script to load.
    Default is 'env', which looks for 'env.local.ps1' or 'env.ps1'.
    Example: 'env-msys2' will look for 'env-msys2.local.ps1' or 'env-msys2.ps1'.
    Do not include the .ps1 extension.

.EXAMPLE
    . Initialize-BuildEnvironment
    # Loads env.local.ps1 or env.ps1

.EXAMPLE
    . Initialize-BuildEnvironment -EnvironmentName "env-msys2"
    # Loads env-msys2.local.ps1 or env-msys2.ps1
#>
function Initialize-BuildEnvironment {
    param(
        [string]$EnvironmentName = 'env'
    )

    # Skip if already loaded in current session (Prevent variable pollution)
    if ($env:ENV_SCRIPT_LOADED) {
        Write-Host "Environment script already loaded from: $env:ENV_SCRIPT_LOADED" -ForegroundColor Yellow
        Write-Host "Skipping initialization to prevent conflicts." -ForegroundColor Gray
        return
    }

    # Determine script directory (works for both direct execution and dot-sourcing)
    $private:scriptDir = if ($PSScriptRoot) {
        $PSScriptRoot
    } else {
        # Fallback for interactive console execution
        $private:callingScript = $MyInvocation.PSCommandPath
        if (-not $private:callingScript) {
            $private:callingScript = $MyInvocation.MyCommand.Definition
        }
        if ($private:callingScript) {
            Split-Path -Parent -Path $private:callingScript
        } else {
            $PWD.Path  # Fallback to current directory
        }
    }

    # Construct environment script paths based on the provided name
    # Pattern: <Name>.local.ps1 > <Name>.ps1
    $private:localEnvPath = Join-Path -Path $private:scriptDir -ChildPath "${EnvironmentName}.local.ps1"
    $private:globalEnvPath = Join-Path -Path $private:scriptDir -ChildPath "${EnvironmentName}.ps1"

    # Execute environment script based on priority rules
    if (Test-Path -Path $private:localEnvPath -PathType Leaf) {
        Write-Host "Loading local environment override: $private:localEnvPath" -ForegroundColor Cyan
        . $private:localEnvPath
        $env:ENV_SCRIPT_LOADED = $private:localEnvPath
    }
    elseif (Test-Path -Path $private:globalEnvPath -PathType Leaf) {
        Write-Host "Loading shared environment: $private:globalEnvPath" -ForegroundColor Cyan
        . $private:globalEnvPath
        $env:ENV_SCRIPT_LOADED = $private:globalEnvPath
    }
    else {
        Write-Error "Environment script not found in $private:scriptDir`nExpected: ${EnvironmentName}.local.ps1 or ${EnvironmentName}.ps1"
        return
    }

    Write-Host "Environment initialized from: $env:ENV_SCRIPT_LOADED" -ForegroundColor Green
}

<#
.SYNOPSIS
    Safely execute external commands and check exit codes
.DESCRIPTION
    Wraps external command execution with automatic $LASTEXITCODE validation.
    Required because $ErrorActionPreference="Stop" does NOT affect native commands.
.PARAMETER ScriptBlock
    Script block containing the external command to execute
.PARAMETER Description
    Human-readable description for error messages
#>
function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [string]$Description = "External command"
    )
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "[FAILED] $Description exited with code $LASTEXITCODE"
    }
}

<#
.SYNOPSIS
    Build generic CMake project from Git repository or local source path
.DESCRIPTION
    Supports two modes:
      1. Remote mode: Clones Git repository (with optional patches), builds, and installs
      2. Local mode: Builds directly from existing local source directory

    Skips completed builds via marker file in build directory.
    Supports tags, branches, and commit hashes in remote mode.
.PARAMETER RepoUrl
    Full Git repository URL (e.g., https://github.com/user/repo.git)
    Required in RemoteSource mode.
.PARAMETER Version
    Version identifier: tag, branch name, or commit hash
    Required in RemoteSource mode.
.PARAMETER SourcePath
    Local path to existing source directory (absolute or relative)
    Required in LocalSource mode. Skips cloning and patching.
.PARAMETER RepoName
    Project identifier for directory naming and logging (e.g., "extra-cmake-modules")
.PARAMETER SourceSubdir
    Optional subdirectory within repo/source containing CMakeLists.txt
.PARAMETER PatchFiles
    Optional list of patch files to apply after cloning (RemoteSource mode only).
    Patches are applied in order using 'git apply --ignore-whitespace'.
.PARAMETER SkipCloneIfExist
    (RemoteSource mode only) Skip cloning if source directory already exists.
    When skipped, patching is also skipped (assumes patches were applied previously).
.PARAMETER CMakeArgs
    Additional CMake arguments (e.g., @("-DBUILD_TESTING=OFF"))
.PARAMETER InstallPrefix
    Installation root directory (default: kf6redist-install)
.PARAMETER BuildBaseDir
    Root directory for build outputs (default: build)
.PARAMETER BuildType
    CMake build type (default: Release)
.PARAMETER ForceRebuild
    Ignore completion marker and rebuild from scratch
.PARAMETER SkipInstall
    Avoid/skip install
.PARAMETER NoSourceIdentifierFolder
    Avoid creating a subfolder as the source identifier (e.g., simply ""build/" instead of "build/v1.2.3-reponame/")
#>
function Build-CMakeProject {
    [CmdletBinding(DefaultParameterSetName = "RemoteSource")]
    param(
        [Parameter(Mandatory, ParameterSetName = "RemoteSource")]
        [string]$RepoUrl,

        [Parameter(Mandatory, ParameterSetName = "RemoteSource")]
        [string]$Version,

        [Parameter(Mandatory, ParameterSetName = "LocalSource")]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$RepoName,

        [Parameter(ParameterSetName = "RemoteSource")]
        [string[]]$PatchFiles = @(),

        [Parameter(ParameterSetName = "RemoteSource")]
        [switch]$SkipCloneIfExist,

        [string]$SourceSubdir = "",
        [string[]]$CMakeArgs = @(),
        [string]$InstallPrefix = "kf6redist-install",
        [string]$BuildBaseDir = "build",
        [string]$BuildType = "Release",
        [switch]$ForceRebuild,
        [switch]$SkipInstall,
        [switch]$NoSourceIdentifierFolder
    )

    if ($env:GITHUB_ACTIONS -eq "true") {
        Write-Host "::group::Building: $RepoName"
    }

    # Determine mode and set up paths
    $isRemoteMode = ($PSCmdlet.ParameterSetName -eq "RemoteSource")
    if ($isRemoteMode) {
        $sourceDir = "${Version}-${RepoName}"
        $buildDir  = $NoSourceIdentifierFolder ? $BuildBaseDir : (Join-Path $BuildBaseDir "${Version}-${RepoName}")
        $sourceType = "remote"
        $sourceIdentifier = "${Version}-${RepoName}"
    } else {
        # LocalSource mode: normalize path immediately
        try {
            $sourceDir = Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop
        } catch {
            throw "Source path not found: '$SourcePath' (current dir: $($PWD.Path))"
        }
        $buildDir  = $NoSourceIdentifierFolder ? $BuildBaseDir : (Join-Path $BuildBaseDir "local-${RepoName}")
        $sourceType = "local"
        $sourceIdentifier = "local-${RepoName}"
    }

    $doneFile = Join-Path $buildDir ".ci-build-done"

    # Skip if already successfully built (unless forced)
    if (-not $ForceRebuild -and (Test-Path -LiteralPath $doneFile)) {
        Write-Host "[SKIP] ${RepoName}@${sourceIdentifier} already built" -ForegroundColor Green
        if ($env:GITHUB_ACTIONS -eq "true") {
            Write-Host "::endgroup::"
        }
        return
    }

    Write-Host "`n[BUILD] ${RepoName}@${sourceIdentifier}" -ForegroundColor Cyan
    if ($isRemoteMode) {
        Write-Host "        Repo: $RepoUrl" -ForegroundColor DarkGray
        if ($PatchFiles) {
            Write-Host "        Patches: $($PatchFiles -join ', ')" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "        Local source: $sourceDir" -ForegroundColor DarkGray
    }
    if ($SourceSubdir) {
        Write-Host "        Subdir: $SourceSubdir" -ForegroundColor DarkGray
    }

    try {
        # ========== REMOTE MODE: Clone + Patching ==========
        if ($isRemoteMode) {
            $shouldClone = $true

            # Check if we can skip cloning
            if ($SkipCloneIfExist -and (Test-Path -LiteralPath $sourceDir -PathType Container)) {
                Write-Host "  → Source directory exists, skipping clone/patching (SkipCloneIfExist)" -ForegroundColor Yellow
                $shouldClone = $false
            }
            # Always clean if we need to clone (or if directory exists but shouldn't)
            elseif (Test-Path -LiteralPath $sourceDir) {
                Write-Host "  → Cleaning source directory: $sourceDir" -ForegroundColor Yellow
                Remove-Item -Recurse -Force $sourceDir -ErrorAction Stop
            }

            # Perform clone + checkout if needed
            if ($shouldClone) {
                Write-Host "  → Cloning repository (version: $Version) ..." -ForegroundColor Yellow
                if ($Version -match '^[0-9a-f]{7,40}$') {
                    # Commit hash: clone then checkout
                    Invoke-ExternalCommand -ScriptBlock {
                        git clone --depth 1 $RepoUrl $sourceDir --quiet
                    } -Description "Git clone"
                    Push-Location $sourceDir
                    try {
                        Invoke-ExternalCommand -ScriptBlock {
                            git checkout $Version --quiet
                        } -Description "Git checkout commit"
                    } finally {
                        Pop-Location
                    }
                } else {
                    # Tag or branch: direct clone with --branch
                    Invoke-ExternalCommand -ScriptBlock {
                        git clone --depth 1 --branch $Version $RepoUrl $sourceDir --quiet
                    } -Description "Git clone (branch/tag)"
                }

                # Resolve patch paths BEFORE directory changes (critical!)
                $absolutePatchFiles = @()
                foreach ($patch in $PatchFiles) {
                    try {
                        $absPath = Resolve-Path -LiteralPath $patch -ErrorAction Stop
                        $absolutePatchFiles += $absPath.ProviderPath
                    } catch {
                        $currentDir = $PWD.Path
                        $suggestedPath = Join-Path $PSScriptRoot $patch
                        throw "Patch file not found: '$patch'`n" +
                              "  Current directory: $currentDir`n" +
                              "  Suggested path: $suggestedPath"
                    }
                }

                # Apply patches if needed
                if ($absolutePatchFiles.Count -gt 0) {
                    Write-Host "  → Applying patches ..." -ForegroundColor Yellow
                    Push-Location $sourceDir
                    try {
                        foreach ($patchAbsPath in $absolutePatchFiles) {
                            $patchName = Split-Path -Leaf $patchAbsPath
                            Write-Host "    → Applying: $patchName" -ForegroundColor DarkYellow
                            Invoke-ExternalCommand -ScriptBlock {
                                git apply --ignore-whitespace "$patchAbsPath" 2>&1
                            } -Description "Apply patch: $patchName"
                        }
                    } finally {
                        Pop-Location
                    }
                }
            }
        }
        # ========== LOCAL MODE: Validate source path ==========
        else {
            if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
                throw "Local source directory not found: $sourceDir"
            }
            Write-Host "  → Using existing source directory" -ForegroundColor Yellow
        }

        # ========== COMMON BUILD STEPS ==========
        # Prepare build directory
        $null = New-Item -ItemType Directory -Path $buildDir -Force -ErrorAction Stop

        # Configure with CMake
        Write-Host "  → Configuring with CMake ..." -ForegroundColor Yellow
        Invoke-ExternalCommand -ScriptBlock {
            $sourcePath = if ($SourceSubdir) { Join-Path $sourceDir $SourceSubdir } else { $sourceDir }
            cmake -S $sourcePath -B $buildDir -DCMAKE_INSTALL_PREFIX="$InstallPrefix" -DCMAKE_BUILD_TYPE="$BuildType" @CMakeArgs
        } -Description "CMake configure"

        # Build
        Write-Host "  → Building ..." -ForegroundColor Yellow
        Invoke-ExternalCommand -ScriptBlock {
            cmake --build "$buildDir" --config "$BuildType"
        } -Description "Build"

        # Install
        if (-not $SkipInstall) {
            Write-Host "  → Installing to: $InstallPrefix" -ForegroundColor Yellow
            Invoke-ExternalCommand -ScriptBlock {
                cmake --install "$buildDir" --prefix "$InstallPrefix" --config "$BuildType"
            } -Description "Install"
        } else {
            Write-Host "  → Install step skipped." -ForegroundColor Yellow
        }

        # Create completion marker with build metadata
        $markerContent = if ($isRemoteMode) {
            $patchList = if ($PatchFiles) { $PatchFiles -join ';' } else { 'none' }
            @"
Built at: $(Get-Date -Format 'u')
Source: remote
Repo: $RepoUrl
Version: $Version
Patches: $patchList
SkipCloneIfExist: $($SkipCloneIfExist.IsPresent)
Type: $($BuildType)
"@
        } else {
            @"
Built at: $(Get-Date -Format 'u')
Source: local
Path: $sourceDir
Type: $($BuildType)
"@
        }
        Set-Content -Path $doneFile -Value $markerContent -Force
        Write-Host "[✓] ${RepoName}@${sourceIdentifier} build succeeded" -ForegroundColor Green

        if ($env:GITHUB_ACTIONS -eq "true") {
            Write-Host "::endgroup::"
        }
    } catch {
        Write-Error "[✗] ${RepoName}@${sourceIdentifier} build failed: $_"
        if ($env:GITHUB_ACTIONS -eq "true") {
            Write-Host "::endgroup::"
        }
        # Clean up failed build artifacts
        if (Test-Path $buildDir) {
            Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
        }
        throw
    }
}

<#
.SYNOPSIS
    Build KDE Frameworks 6 module
.DESCRIPTION
    Wrapper for Build-CMakeProject specialized for KDE Frameworks repositories.
    Automatically constructs repository URL from module name.
.PARAMETER RepoName
    KDE Frameworks module name (e.g., "extra-cmake-modules", "kcoreaddons")
.PARAMETER KfVer
    KDE Frameworks version tag (e.g., "v6.22.0")
.PARAMETER CMakeArgs
    Additional CMake arguments
.PARAMETER InstallPrefix
    Installation root directory
.PARAMETER ForceRebuild
    Force rebuild even if marker file exists
#>
function Build-KF6Module {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoName,
        [Parameter(Mandatory)]
        [string]$KfVer,
        [string[]]$PatchFiles = @(),
        [string[]]$CMakeArgs = @(),
        [string]$InstallPrefix = "kf6redist-install",
        [switch]$ForceRebuild
    )

    $repoUrl = "https://invent.kde.org/frameworks/${RepoName}.git"
    Build-CMakeProject `
        -RepoUrl $repoUrl `
        -Version $KfVer `
        -RepoName $RepoName `
        -PatchFiles $PatchFiles `
        -CMakeArgs $CMakeArgs `
        -InstallPrefix $InstallPrefix `
        -ForceRebuild:$ForceRebuild
}

<#
.SYNOPSIS
    Initialize Visual Studio Developer Shell environment
.DESCRIPTION
    Locates Visual Studio installation using vswhere.exe, imports DevShell module,
    and configures build environment variables (PATH, LIB, INCLUDE, etc.).

    Sets $env:VS_DEV_SHELL_INITIALIZED to prevent duplicate initialization.
    Idempotent - safe to call multiple times in the same session.
.PARAMETER DevCmdArguments
    Optional arguments to pass to underlying vsdevcmd.bat (e.g., "-arch=x64")
.PARAMETER Force
    Force re-initialization even if environment is already configured
.EXAMPLE
    Initialize-VSDevShell
.EXAMPLE
    Initialize-VSDevShell -DevCmdArguments "-arch=x64 -host_arch=x64"
#>
function Initialize-VSDevShell {
    [CmdletBinding()]
    param(
        [string]$DevCmdArguments,
        [switch]$Force
    )

    # Skip if already initialized and not forced
    if (-not $Force -and $env:VS_DEV_SHELL_INITIALIZED) {
        Write-Host "Visual Studio Developer Shell already initialized at: $env:VS_DEV_SHELL_INITIALIZED" -ForegroundColor Green
        return
    }

    # Locate vswhere.exe
    $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
        throw "vswhere.exe not found at: $vswherePath"
    }

    # Query latest VS installation with VC++ tools
    $vsPath = & $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if (-not $vsPath) {
        throw "Could not find Visual Studio installation with VC++ tools"
    }

    Write-Host "Using Visual Studio installation at: $vsPath" -ForegroundColor Cyan

    # Import DevShell module if not already loaded
    $devShellModuleName = "Microsoft.VisualStudio.DevShell"
    if (-not (Get-Module -Name $devShellModuleName -ErrorAction SilentlyContinue)) {
        $devShellModulePath = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
        if (-not (Test-Path -LiteralPath $devShellModulePath -PathType Leaf)) {
            throw "DevShell module not found at: $devShellModulePath"
        }
        Import-Module $devShellModulePath -Force -ErrorAction Stop
    }

    # Enter VS Developer Shell environment
    $enterParams = @{
        VsInstallPath = $vsPath
        SkipAutomaticLocation = $true
        SetDefaultWindowTitle = $true
    }
    if ($DevCmdArguments) { $enterParams.DevCmdArguments = $DevCmdArguments }

    Enter-VsDevShell @enterParams -ErrorAction Stop

    # Mark as initialized
    $env:VS_DEV_SHELL_INITIALIZED = $vsPath
    Write-Host "Visual Studio Developer Shell initialized successfully" -ForegroundColor Green
}
