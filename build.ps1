param(
    [string]$kfver = "v6.23.0"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. "$PSScriptRoot\buildutils.ps1"

#region Configuration
$plasmaver = "v6.5.91"
#endregion

#region Initialize build Env and VSDev Shell
. Initialize-BuildEnvironment
if ($IsWindows) {
    Initialize-VSDevShell -DevCmdArguments "-arch=x64 -host_arch=x64"
}
#endregion

#region Check pre-requirements
# For ki18n
Check-ExecutableExists -ExecutableName "xgettext"
Check-ExecutableExists -ExecutableName "python"
#endregion

#region Build

# For ki18n
Build-CMakeProject `
    -RepoUrl "https://github.com/BLumia/libintl.git" `
    -Version "master" `
    -RepoName "libintl" `
    -InstallPrefix "kf6redist-install"

Build-KF6Module -KfVer $kfver -RepoName "extra-cmake-modules"
# Requires python3 with lxml if WITH_ICON_GENERATION is enabled
Build-KF6Module -KfVer $kfver -RepoName "breeze-icons" `
    -PatchFiles "./patches/breeze-icons-std-filesystem-to-generate-symlink.diff" `
    -CMakeArgs "-DBUILD_TESTING=OFF", "-DSKIP_INSTALL_ICONS=ON", "-DWITH_ICON_GENERATION=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kcoreaddons" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kitemviews" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kconfig" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kcodecs" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kguiaddons" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "ki18n" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kwidgetsaddons" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kcolorscheme" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kconfigwidgets" -CMakeArgs "-DBUILD_TESTING=OFF"

# For KArchive
Build-CMakeProject `
    -RepoUrl "https://github.com/madler/zlib.git" `
    -Version "v1.3.1.2" `
    -RepoName "zlib" `
    -InstallPrefix "kf6redist-install"

Build-KF6Module -KfVer $kfver -RepoName "karchive" `
    -CMakeArgs "-DBUILD_TESTING=OFF", "-DWITH_LIBZSTD=OFF", "-DWITH_BZIP2=OFF", "-DWITH_LIBLZMA=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kiconthemes" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kxmlgui" -CMakeArgs "-DBUILD_TESTING=OFF"
Build-KF6Module -KfVer $kfver -RepoName "kwindowsystem" -CMakeArgs "-DBUILD_TESTING=OFF"

Build-CMakeProject `
    -RepoUrl "https://invent.kde.org/plasma/breeze.git" `
    -Version $plasmaver `
    -RepoName "breeze" `
    -InstallPrefix "kf6redist-install" `
    -PatchFiles "./patches/breeze-option-no-quick-n-cursor.diff" `
    -CMakeArgs "-DBUILD_TESTING=OFF", "-DBUILD_QT5=OFF", "-DWITH_DECORATIONS=OFF", "-DBUILD_WITH_QTQUICK=OFF", "-DBUILD_CURSOR=OFF"
#endregion
