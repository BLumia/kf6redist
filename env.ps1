$env:CMAKE_PREFIX_PATH = "kf6redist-install"

if ($IsMacOS) {
    $env:MACOSX_DEPLOYMENT_TARGET = "13.0"
}