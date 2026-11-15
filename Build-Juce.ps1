#Requires -Version 5.1
<#
.SYNOPSIS
    Rock-solid universal JUCE CMake build helper (Windows).

.DESCRIPTION
    Validates environment, CMakeLists, JUCE integration, source files,
    configures, builds, locates artefacts, and optionally installs.
    Designed for Debug / Release of .cpp / .h based JUCE plugins & apps.

.PARAMETER Config
    Build configuration. Default: Release

.PARAMETER Clean
    Remove the build directory before configuring.

.PARAMETER Install
    Copy the built VST3 (and optionally Standalone) to the system VST3 folder.
    Requires Administrator.

.PARAMETER VerboseBuild
    Pass --verbose to cmake --build (shows full compiler command lines).

.PARAMETER Jobs
    Number of parallel jobs. 0 = auto (default).

.PARAMETER Generator
    Force a generator (e.g. "Visual Studio 17 2022", "Ninja"). Empty = auto.

.PARAMETER Target
    Specific CMake target to build (e.g. YourPlugin_VST3). Empty = all.

.PARAMETER CheckOnly
    Run all validation helpers and exit (no configure/build).

.EXAMPLE
    .\Build-Juce.ps1 -Config Debug -VerboseBuild
    .\Build-Juce.ps1 -Clean -Install
    .\Build-Juce.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug", "RelWithDebInfo", "MinSizeRel")]
    [string]$Config = "Debug",

    [switch]$Clean,
    [switch]$Install,
    [switch]$VerboseBuild,
    [switch]$CheckOnly,

    [int]$Jobs = 0,
    [string]$Generator = "",
    [string]$Target = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Warn  { param([string]$Message) Write-Host "  [!]  $Message" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Message) Write-Host "  [X]  $Message" -ForegroundColor Red }
function Write-Info  { param([string]$Message) Write-Host "       $Message" -ForegroundColor DarkGray }

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-VisualStudioPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }

    $path = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null

    if ($path) { return @($path)[0] }
    return $null
}

function Test-CMakeLists {
    param([string]$Root)

    $cmakeLists = Join-Path $Root "CMakeLists.txt"
    if (-not (Test-Path $cmakeLists)) {
        Write-Fail "No CMakeLists.txt found in project root: $Root"
        return $false
    }

    $content = Get-Content $cmakeLists -Raw -ErrorAction SilentlyContinue
    if (-not $content) {
        Write-Fail "CMakeLists.txt is empty or unreadable."
        return $false
    }

    $checks = @(
        @{ Pattern = 'cmake_minimum_required'; Msg = "cmake_minimum_required(...) is present" },
        @{ Pattern = 'project\s*\(';            Msg = "project(...) is present" },
        @{ Pattern = 'juce_add_plugin|juce_add_gui_app|juce_add_console_app|add_executable|add_library'; Msg = "JUCE / target declaration found" }
    )

    $ok = $true
    foreach ($c in $checks) {
        if ($content -match $c.Pattern) {
            Write-Ok $c.Msg
        } else {
            Write-Warn "Missing or unusual: $($c.Msg)"
            # Not fatal for every project type
        }
    }

    # JUCE integration style
    if ($content -match 'add_subdirectory\s*\(\s*JUCE|add_subdirectory\s*\(\s*.*JUCE') {
        Write-Ok "JUCE appears to be included via add_subdirectory"
    } elseif ($content -match 'find_package\s*\(\s*JUCE') {
        Write-Ok "JUCE appears to be included via find_package"
    } else {
        Write-Warn "Could not detect typical JUCE inclusion (add_subdirectory(JUCE) or find_package(JUCE))."
        Write-Info "Make sure JUCE is available before juce_add_plugin / juce_add_* calls."
    }

    return $true
}

function Test-JuceSources {
    param([string]$Root)

    Write-Step "Scanning for source files (.cpp / .h / .hpp)"

    $sources = Get-ChildItem -Path $Root -Recurse -Include *.cpp,*.h,*.hpp,*.c,*.cc,*.cxx `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '\\build\\' -and
            $_.FullName -notmatch '\\JUCE\\' -and
            $_.FullName -notmatch '\\\.git\\' -and
            $_.FullName -notmatch '\\JuceLibraryCode\\'
        }

    if (-not $sources -or $sources.Count -eq 0) {
        Write-Warn "No project .cpp/.h files found outside build/JUCE folders."
        Write-Info "This is only a warning – your CMakeLists may pull sources differently."
        return $true
    }

    Write-Ok "Found $($sources.Count) source/header files in project tree"

    # Basic empty-file check
    $empty = $sources | Where-Object { $_.Length -eq 0 }
    if ($empty) {
        Write-Warn "Empty source files detected:"
        $empty | ForEach-Object { Write-Info $_.FullName }
    }

    # Very light check for common JUCE entry points
    $hasProcessor = $sources | Where-Object { $_.Name -match 'Processor|PluginProcessor' }
    $hasEditor    = $sources | Where-Object { $_.Name -match 'Editor|PluginEditor' }

    if ($hasProcessor) { Write-Ok "PluginProcessor-style file(s) present" }
    if ($hasEditor)    { Write-Ok "PluginEditor-style file(s) present" }

    return $true
}

function Test-JuceFolder {
    param([string]$Root)

    $candidates = @(
        (Join-Path $Root "JUCE"),
        (Join-Path $Root "libs\JUCE"),
        (Join-Path $Root "external\JUCE"),
        (Join-Path $Root "third_party\JUCE"),
        (Join-Path $Root "vendor\JUCE")
    )

    foreach ($c in $candidates) {
        if 
         (Test-Path (Join-Path $c "CMakeLists.txt")) {
            Write-Ok "JUCE tree found at: $c"
            return $true
        }
    }

    # Maybe using find_package / installed JUCE
    Write-Info "No local JUCE folder detected (ok if you use find_package or CPM)."
    return $true
}

function Get-BuildArtefacts {
    param(
        [string]$BuildDir,
        [string]$Config
    )

    $results = [PSCustomObject]@{
        VST3       = $null
        Standalone = $null
        AllVST3    = @()
    }

    # Common JUCE artefact layouts
    $searchRoots = @(
        $BuildDir,
        (Join-Path $BuildDir $Config),
        (Join-Path $BuildDir "*_artefacts"),
        (Join-Path $BuildDir "*_artefacts\$Config")
    )

    $vst3Dirs = Get-ChildItem -Path $BuildDir -Recurse -Directory -Filter "*.vst3" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match [regex]::Escape($Config) -or $Config -eq "Release" }

    if ($vst3Dirs) {
        $results.AllVST3 = $vst3Dirs
        $results.VST3    = $vst3Dirs | Select-Object -First 1
    }

    $exe = Get-ChildItem -Path $BuildDir -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DirectoryName -match "Standalone" -and
            ($_.DirectoryName -match [regex]::Escape($Config) -or $Config -eq "Release")
        } | Select-Object -First 1

    if ($exe) { $results.Standalone = $exe }

    return $results
}

function Show-CMakeCacheHints {
    param([string]$BuildDir)

    $cache = Join-Path $BuildDir "CMakeCache.txt"
    if (-not (Test-Path $cache)) { return }

    Write-Step "CMake cache highlights"
    $lines = Get-Content $cache

    $interesting = @(
        "CMAKE_BUILD_TYPE",
        "CMAKE_GENERATOR",
        "CMAKE_CXX_COMPILER",
        "JUCE_",
        "CMAKE_PROJECT_NAME"
    )

    foreach ($key in $interesting) {
        $lines | Where-Object { $_ -match "^$key" -and $_ -notmatch "^#" } |
            ForEach-Object { Write-Info $_ }
    }
}

# ---------------------------------------------------------------------------
# 1. Tooling checks
# ---------------------------------------------------------------------------

Write-Step "Checking required tools"

$missing = $false

if (-not (Test-CommandExists "cmake")) {
    Write-Fail "CMake not found on PATH"
    Write-Info "Install: winget install Kitware.CMake"
    $missing = $true
} else {
    $cmakeVer = (cmake --version | Select-Object -First 1)
    Write-Ok "CMake: $cmakeVer"
}

if (-not (Test-CommandExists "git")) {
    Write-Fail "Git not found on PATH"
    Write-Info "Install: winget install Git.Git"
    $missing = $true
} else {
    Write-Ok "Git is available"
}

$vsPath = Get-VisualStudioPath
if (-not $vsPath) {
    Write-Fail "Visual Studio with C++ tools not found"
    Write-Info 'Install: winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'
    $missing = $true
} else {
    Write-Ok "Visual Studio C++ tools: $vsPath"
}

if ($missing) {
    Write-Host "`nFix the missing tools, open a NEW PowerShell window, and re-run." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Project structure & CMake / JUCE validation
# ---------------------------------------------------------------------------

Write-Step "Validating project structure"

if (-not (Test-CMakeLists -Root $PSScriptRoot)) {
    exit 1
}

Test-JuceFolder -Root $PSScriptRoot | Out-Null
Test-JuceSources -Root $PSScriptRoot | Out-Null

if ($CheckOnly) {
    Write-Host "`nCheck-only mode finished." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Clean
# ---------------------------------------------------------------------------

$buildDir = Join-Path $PSScriptRoot "build"

if ($Clean -and (Test-Path $buildDir)) {
    Write-Step "Cleaning build directory"
    Remove-Item -Recurse -Force $buildDir
    Write-Ok "Removed $buildDir"
}

# ---------------------------------------------------------------------------
# 4. Configure
# ---------------------------------------------------------------------------

Write-Step "Configuring CMake"

$configureArgs = @("-B", "build", "-S", ".")

if ($Generator) {
    $configureArgs += @("-G", $Generator)
    Write-Info "Using generator: $Generator"
}

# Help multi-config generators (Visual Studio) and single-config (Ninja)
# For VS we still pass --config at build time.
if ($Generator -match "Ninja" -or $Generator -eq "") {
    # When using default (often VS) we let it be multi-config.
    # Users can force -DCMAKE_BUILD_TYPE if they use Ninja.
}

& cmake @configureArgs
if ($LASTEXITCODE -ne 0) {
    Write-Fail "CMake configure failed (exit $LASTEXITCODE)"
    Write-Info "Common causes: missing JUCE, wrong path in add_subdirectory, C++ standard, or missing SDK."
    exit $LASTEXITCODE
}
Write-Ok "Configure succeeded"

Show-CMakeCacheHints -BuildDir $buildDir

# ---------------------------------------------------------------------------
# 5. Build
# ---------------------------------------------------------------------------

Write-Step "Building ($Config)"

$buildArgs = @("--build", "build", "--config", $Config)

if ($Jobs -gt 0) {
    $buildArgs += @("--parallel", $Jobs)
} else {
    $buildArgs += "--parallel"
}

if ($VerboseBuild) {
    $buildArgs += "--verbose"
}

if ($Target) {
    $buildArgs += @("--target", $Target)
    Write-Info "Building target: $Target"
}

& cmake @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Build failed (exit $LASTEXITCODE)"
    Write-Info "Re-run with -VerboseBuild to see full compiler lines."
    Write-Info "Check that all .cpp/.h files listed in target_sources() actually exist."
    exit $LASTEXITCODE
}
Write-Ok "Build succeeded"

# ---------------------------------------------------------------------------
# 6. Locate artefacts
# ---------------------------------------------------------------------------

Write-Step "Locating build artefacts"

$artefacts = Get-BuildArtefacts -BuildDir $buildDir -Config $Config

if ($artefacts.VST3) {
    Write-Ok "VST3: $($artefacts.VST3.FullName)"
} else {
    Write-Warn "No .vst3 bundle found for config '$Config'."
    Write-Info "Searched under build/. Check FORMATS in juce_add_plugin and artefact paths."
}

if ($artefacts.Standalone) {
    Write-Ok "Standalone: $($artefacts.Standalone.FullName)"
}

# ---------------------------------------------------------------------------
# 7. Optional install
# ---------------------------------------------------------------------------

if ($Install) {
    Write-Step "Installing"

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Fail "Install requires Administrator rights."
        Write-Info "Re-run from an elevated PowerShell:  .\Build-Juce.ps1 -Install ..."
        exit 1
    }

    if (-not $artefacts.VST3) {
        Write-Fail "No VST3 to install."
        exit 1
    }

    $dest = Join-Path $env:CommonProgramFiles "VST3"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest | Out-Null
    }

    $targetName = $artefacts.VST3.Name
    $destPath   = Join-Path $dest $targetName

    if (Test-Path $destPath) {
        Write-Info "Removing previous installation: $destPath"
        Remove-Item -Recurse -Force $destPath
    }

    Copy-Item -Path $artefacts.VST3.FullName -Destination $dest -Recurse -Force
    Write-Ok "Installed → $dest\$targetName"
}

Write-Host "`nDone." -ForegroundColor Green