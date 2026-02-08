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
    Initialize build environment by loading env.local.ps1 or env.ps1
.DESCRIPTION
    Loads environment configuration scripts with priority:
    1. env.local.ps1 (local override, not committed to VCS)
    2. env.ps1       (shared defaults)
    
    Sets $env:ENV_SCRIPT_LOADED to prevent duplicate loading.
    Must be dot-sourced to properly set variables in caller's scope.
    
.EXAMPLE
    . Initialize-BuildEnvironment
#>
function Initialize-BuildEnvironment {
    # Skip if already loaded in current session
    if ($env:ENV_SCRIPT_LOADED) {
        Write-Host "Environment script already loaded from: $env:ENV_SCRIPT_LOADED" -ForegroundColor Green
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

    # Define environment script paths with priority order
    $private:localEnvPath = Join-Path -Path $private:scriptDir -ChildPath "env.local.ps1"
    $private:globalEnvPath = Join-Path -Path $private:scriptDir -ChildPath "env.ps1"

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
        Write-Error "Environment script not found in $private:scriptDir (expected env.local.ps1 or env.ps1)"
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
    Build generic CMake project from Git repository
.DESCRIPTION
    Clones repository, configures with CMake, builds, and installs.
    Supports tags, branches, and commit hashes. Skips completed builds via marker file.
    Optionally applies patches after cloning and before configuration.
.PARAMETER RepoUrl
    Full Git repository URL (e.g., https://github.com/user/repo.git)
.PARAMETER Version
    Version identifier: tag, branch name, or commit hash
.PARAMETER ProjectName
    Project identifier for directory naming (e.g., "extra-cmake-modules")
.PARAMETER SourceSubdir
    Optional subdirectory within repo containing CMakeLists.txt
.PARAMETER PatchFiles
    Optional list of patch files to apply after cloning (relative to current directory).
    Patches are applied in the order specified using 'git apply --ignore-whitespace'.
.PARAMETER CMakeArgs
    Additional CMake arguments (e.g., @("-DBUILD_TESTING=OFF"))
.PARAMETER InstallPrefix
    Installation root directory (default: kf6redist-install)
.PARAMETER BuildBaseDir
    Root directory for build outputs (default: build)
.PARAMETER ForceRebuild
    Ignore completion marker and rebuild from scratch
#>
function Build-CMakeProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [string]$ProjectName,
        [string]$SourceSubdir = "",
        [string[]]$PatchFiles = @(),
        [string[]]$CMakeArgs = @(),
        [string]$InstallPrefix = "kf6redist-install",
        [string]$BuildBaseDir = "build",
        [switch]$ForceRebuild
    )

    if ($env:GITHUB_ACTIONS -eq "true") {
        Write-Host "::group::Building: $ProjectName"
    }

    # Resolve patch paths to absolute paths IMMEDIATELY (before any directory changes)
    # This prevents failures when $PWD changes later (e.g., during git checkout)
    $absolutePatchFiles = @()
    if ($PatchFiles.Count -gt 0) {
        foreach ($patch in $PatchFiles) {
            try {
                # Resolve relative to caller's current directory at function invocation time
                $absPath = Resolve-Path -LiteralPath $patch -ErrorAction Stop
                $absolutePatchFiles += $absPath.ProviderPath
                Write-Debug "Resolved patch path: '$patch' -> '$($absPath.ProviderPath)'"
            } catch {
                # Provide helpful error message with context
                $currentDir = $PWD.Path
                $suggestedPath = Join-Path $PSScriptRoot $patch
                throw "Patch file not found: '$patch'`n" +
                      "  Current directory: $currentDir`n" +
                      "  Tried resolving from current directory.`n" +
                      "  Hint: Use absolute path or ensure patch exists relative to script directory.`n" +
                      "  Suggested absolute path: $suggestedPath"
            }
        }
    }

    $sourceDir = "${Version}-${ProjectName}"
    $buildDir  = Join-Path $BuildBaseDir "${Version}-${ProjectName}"
    $doneFile  = Join-Path $buildDir ".ci-build-done"

    # Skip if already successfully built
    if (-not $ForceRebuild -and (Test-Path -LiteralPath $doneFile)) {
        Write-Host "[SKIP] ${ProjectName}@${Version} already built" -ForegroundColor Green
        return
    }

    Write-Host "`n[BUILD] ${ProjectName}@${Version}" -ForegroundColor Cyan
    Write-Host "        Repo: $RepoUrl" -ForegroundColor DarkGray
    if ($SourceSubdir) { Write-Host "        Subdir: $SourceSubdir" -ForegroundColor DarkGray }
    if ($PatchFiles) {
        Write-Host "        Patches: $($PatchFiles -join ', ')" -ForegroundColor DarkGray
    }

    try {
        # Clean previous source checkout if exists
        if (Test-Path -LiteralPath $sourceDir) {
            Write-Host "  → Cleaning source directory: $sourceDir" -ForegroundColor Yellow
            Remove-Item -Recurse -Force $sourceDir -ErrorAction Stop
        }

        # Clone repository
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

        # Apply patches if specified
        if ($absolutePatchFiles.Count -gt 0) {
            Write-Host "  → Applying patches ..." -ForegroundColor Yellow
            Push-Location $sourceDir
            try {
                foreach ($patchAbsPath in $absolutePatchFiles) {
                    Write-Host "    → Applying: $(Split-Path -Leaf $patch)" -ForegroundColor DarkYellow
                    Invoke-ExternalCommand -ScriptBlock {
                        git apply --ignore-whitespace "$patchAbsPath" 2>&1
                    } -Description "Apply patch: $patch"
                }
            } finally {
                Pop-Location
            }
        }

        # Prepare build directory
        $null = New-Item -ItemType Directory -Path $buildDir -Force -ErrorAction Stop

        # Configure with CMake
        Write-Host "  → Configuring with CMake ..." -ForegroundColor Yellow
        Invoke-ExternalCommand -ScriptBlock {
            $sourcePath = if ($SourceSubdir) { Join-Path $sourceDir $SourceSubdir } else { $sourceDir }
            cmake -S $sourcePath -B $buildDir -DCMAKE_INSTALL_PREFIX="$InstallPrefix" @CMakeArgs
        } -Description "CMake configure"

        # Build
        Write-Host "  → Building ..." -ForegroundColor Yellow
        Invoke-ExternalCommand -ScriptBlock {
            cmake --build "$buildDir" --config Release
        } -Description "Build"

        # Install
        Write-Host "  → Installing to: $InstallPrefix" -ForegroundColor Yellow
        Invoke-ExternalCommand -ScriptBlock {
            cmake --install "$buildDir" --prefix "$InstallPrefix" --config Release
        } -Description "Install"

        # Create completion marker
        $markerContent = @"
Built at: $(Get-Date -Format 'u')
Repo: $RepoUrl
Version: $Version
Patches: $($PatchFiles -join '; ' -replace '^$','none')
"@
        Set-Content -Path $doneFile -Value $markerContent -Force
        Write-Host "[✓] ${ProjectName}@${Version} build succeeded" -ForegroundColor Green

        if ($env:GITHUB_ACTIONS -eq "true") {
            Write-Host "::endgroup::"
        }
    } catch {
        Write-Error "[✗] ${ProjectName}@${Version} build failed: $_"
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
        -ProjectName $RepoName `
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
