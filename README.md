# DOOM 2 RT: Metal

**DOOM 2 RT: Metal** is a native macOS port of DOOM 2 RT (GZDoom: Ray Traced), bringing its
real-time path tracer to Apple Silicon through the Metal API.

The game runs on a Metal backend for RTGL1, the path tracing library behind DOOM 2 RT,
[RTGL-D2-Metal](https://github.com/NightSightProductions/RTGL-D2-Metal). It runs the same path tracer as
the Vulkan version, compiled from the same shaders, with the same lighting, denoising,
volumetrics, fluid and post-processing passes, so the game looks and behaves like the original.

This is an unofficial community project. It is not affiliated with or endorsed
by id Software, Bethesda or the original DOOM 2 RT authors. The original
[gzdoom-rt repository](https://github.com/vs-shirokii/gzdoom-rt) is Windows only.

## Playing on macOS

  1. Download `DOOM2RT-macOS.dmg` from the [Releases](https://github.com/NightSightProductions/Doom-2-RT-Metal/releases) page.
  2. Open it and run **Install DOOM 2 RT**. The installer finds `DOOM2.WAD` from your copy of
     DOOM II (Steam, also inside CrossOver bottles), or lets you choose it, and installs
     **DOOM 2 RT** to your Applications folder. The WAD is not included: you need your own copy of the game.
  3. Launch **DOOM 2 RT** from your Applications folder.

Note: release builds are not notarized by Apple yet, so macOS blocks the installer the
first time it is opened. To allow it, go to **System Settings > Privacy & Security** and
click **Open Anyway**.

Some settings worth knowing about on a Mac (in the DOOM 2 RT options menu):
  - **MetalFX** replaces DLSS and FSR for upscaling, with the same quality presets.
  - **Denoiser**: the game's default denoiser, or the MetalFX denoiser.
  - **Frame Generation** uses MetalFX frame interpolation. It needs MetalFX upscaling.
  - **VSync**: Off, On, or Half Rate, which presents every other display refresh for steady frame pacing.
  - **HDR** works on displays with HDR enabled in **System Settings > Displays**.

## Original README

**GZDoom: Ray Traced** introduces a path tracing renderer to **GZDoom**, a Doom source port.

**DOOM 2 RT: Metal** adds:
  - A Metal backend for RTGL1 with the features of the Vulkan renderer that DOOM 2 RT uses
  - MetalFX upscaling, denoising and frame generation
  - Native macOS app and installer

### Local Build

Windows

1. Run `auto-setup-windows.cmd` to configure and build via CMake
    * This will produce `build/RelWithDebInfo/gzdoom.exe` (and Visual Studio solution `build/GZDoom.sln`)
1. Copy from a release package into `build/RelWithDebInfo/` folder:
    1. `rt` folder
    1. `libsndfile-1.dll`
    1. `openal32.dll`
    1. `zmusic.dll`
1. Run `build/RelWithDebInfo/gzdoom.exe`

##

Licensed under the [GNU General Public License Version 3](LICENSE).
Copyright (c) 1998-2023 ZDoom + GZDoom teams, and contributors.
Doom Source (c) 1997 id Software, Raven Software, and contributors.
Please see license files for individual contributor licenses.

---

[Home Page](https://zdoom.org/) |
[Forum](https://forum.zdoom.org/) |
[Wiki](https://zdoom.org/wiki/) |
[Discord Server](https://dsc.gg/zdoom) |
[Translation sheet (Google Docs)](https://docs.google.com/spreadsheets/d/1pvwXEgytkor9SClCiDn4j5AH7FedyXS-ocCbsuQIXDU/edit?usp=sharing)

## System Requirements

|             | macOS                          |
|-------------|--------------------------------|
| Min Version | macOS 26, Apple Silicon        |

Note: Metal ray tracing runs on every Apple Silicon Mac, but an M3 or later, with hardware
ray tracing, is recommended. Intel Macs are not supported.

## Building on macOS

  1. Install Xcode, then the Metal compiler, which recent Xcode versions download separately:

     `xcodebuild -downloadComponent MetalToolchain`

  2. Install the dependencies with [Homebrew](https://brew.sh):

     `brew install cmake glslang spirv-cross openal-soft libsndfile mpg123 libvpx webp`

  3. Clone this repository and its submodules, and RTGL1 with the Metal backend next to it, as `RTGL`:

     `git clone --recursive https://github.com/NightSightProductions/Doom-2-RT-Metal.git`  
     `git clone --recursive https://github.com/NightSightProductions/RTGL-D2-Metal.git RTGL`  
     `cd Doom-2-RT-Metal`

     The rest of the commands are run from the `Doom-2-RT-Metal` folder.

  4. Build [ZMusic](https://github.com/ZDoom/ZMusic) and install it into `../deps`:

     `git clone --branch 1.1.14 https://github.com/ZDoom/ZMusic.git ../ZMusic`  
     `cmake -S ../ZMusic -B ../ZMusic/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/../deps"`  
     `cmake --build ../ZMusic/build --target install`

  5. Build RTGL1:

     `cmake -S ../RTGL -B ../RTGL/Build/metal -DCMAKE_BUILD_TYPE=Release -DRG_WITH_METAL=ON`  
     `cmake --build ../RTGL/Build/metal`

     This builds `libRTGL1.dylib` and its Metal shaders into `../RTGL/Build/bin`.

  6. Configure and build gzdoom-rt. `RTGL1_SDK_PATH` must be set for both commands:

     `export RTGL1_SDK_PATH="$PWD/../RTGL"`  
     `cmake -B build-mac -DCMAKE_BUILD_TYPE=RelWithDebInfo -DHAVE_RT=ON -DCMAKE_PREFIX_PATH="$PWD/../deps;/opt/homebrew"`  
     `cmake --build build-mac`

     Note: a `.pk3` is repacked on the build after its files changed, so after editing
     `wadsrc*` files, build twice.

  7. To run the development build, copy the `rt` folder from a
     [DOOM 2 RT release](https://github.com/vs-shirokii/gzdoom-rt/releases) (without its Windows `bin` folder)
     next to the executable, link RTGL1 as `rt/bin`, and link the audio libraries that are loaded at run time:

     `MACOS=build-mac/gzdoom.app/Contents/MacOS`  
     `rsync -a --exclude /bin /path/to/gzdoom-rt-1.0.2/rt/ "$MACOS/rt/"`  
     `ln -s "$PWD/../RTGL/Build/bin" "$MACOS/rt/bin"`  
     `for lib in openal-soft/lib/libopenal.1 libsndfile/lib/libsndfile.1 mpg123/lib/libmpg123.0; do ln -sf "/opt/homebrew/opt/$lib.dylib" "$MACOS/"; done`  
     `"$MACOS/gzdoom" -iwad /path/to/DOOM2.WAD`

  8. To build the app and the installer disk image, run:

     `RT_DATA=/path/to/gzdoom-rt-1.0.2/rt setup/macos/build_installer.sh`

     This creates `build-macos-dist/DOOM 2 RT.app` and `build-macos-dist/DOOM2RT-macOS.dmg`.
     The app is self-contained: it bundles the `rt` data, RTGL1 and the libraries that are not part of macOS.

## Support and Feedback

  * [GitHub Issue Tracker](https://github.com/NightSightProductions/Doom-2-RT-Metal/issues) for this port
