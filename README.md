# KDE Framework 6 Unofficial Binary Redistribution

This repository contains build scripts for building KDE Frameworks 6 binaries for Windows, with GitHub Actions CI build them automatically. You can also build them manually by yourself as well.

## Building

To build the binaries, you need to have the following tools installed:

### Regular C++/Qt development requirements

Before starting, at least ensure you can build a Qt application without any non-Qt dependencies. Thus, you at least need:

- CMake
- Visual Studio with C++ support
- Qt 6.y.z (You can get official binaries via [`aqtinstall`](https://github.com/miurahr/aqtinstall)'s `aqt` command)

### KDE Framework 6 dependencies

These are required mainly by `ki18n`.

- Python 3
- gettext (can install from [Scoop](https://scoop.sh/) via: `scoop install gettext`)

This is optional but suggested. It's available in GitHub Actions Windows environment.

- openssl (needed by `karchive`, can be disable by adding `-DWITH_OPENSSL=OFF` to `karchive`'s `CMakeArgs` list)

And these two dependencies will be automatically downloaded and built by the script so you don't need to worry about them:

- zlib
- libintl (we use [GNUWin32's libintl](https://gnuwin32.sourceforge.net/packages/libintl.htm) with [a CMake patch](https://github.com/BLumia/libintl/commit/5d6d942675518a726c14145e599c2eebb9f1300e) for easier build)

### Start building

Before starting, I suggest you create a `env.local.ps1` file to set up your environment variables. You need to tell CMake where to find your Qt installation. Following is a sample `env.local.ps1`:

```powershell
$env:QT_DIR = "D:\SDK\aqt\6.10.2\msvc2022_64"
$env:PATH = "$env:QT_DIR\bin;$env:PATH"
$env:CMAKE_PREFIX_PATH = "kf6redist-install"
```

After that, simply run `build.ps1` to start build. The script will fetch required sources and build them.

## Using

After build, you can find the built binaries in `kf6redist-install` directory.

The pre-built binaries are also a simple zip file which contains the built binaries, but you'll need a matching Qt installation to use them.

To consume them, you need to set up your environment variables while building your own Qt/KF6 application. Simply add the path to `kf6redist-install` to `CMAKE_PREFIX_PATH` environment variable.

> [!NOTE]
> If you need to use `Ki18n`, you are very likely need to also have `python` and `gettext` installed.

## Notes

### `ECMAddAppIcon`

If you want to use `ecm_add_app_icon()` to generate application icon, you will also need `icoutils` (be able to find `icotool.exe` in your `PATH` will be enough), otherwise icon generation will be skipped.

There are multiple ways to get `icoutils`, you can either:

- Use [`icoutils-rs`](https://crates.io/crates/icoutils-rs) which is maintained by myself: `cargo binstall icoutils-rs`.
- Get `icoutils` package from MSYS2 and use its `icotool.exe` binary (needs 4 extra DLLs also from MSYS2).
- Other possible methods...

### Why build `breeze`? Isn't it from Plasma instead of KF?

You'll likely need `Breeze` style for Qt widgets to make the application look nice.

### Deploying KF6 applications

Beside regular KF DLLs, be sure you don't forget the following ones:

- `data/locale/<localeCode>/LC_MESSAGES/*.{mo,qm}` for localization
- `iconengines/KIconEnginePlugin.dll` to ensure icon color follows your application theme
- `styles/breeze6.dll` provides `Breeze` style
