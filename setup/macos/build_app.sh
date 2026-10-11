#!/bin/bash
#
# Builds a self-contained "DOOM 2 RT.app" for macOS (Apple silicon, RTGL1's Metal backend):
#
#   DOOM 2 RT.app/Contents/MacOS/
#     gzdoom, *.pk3, rt_metal.pk3     the engine (build-mac)
#     lib*.dylib                       libraries that are not part of macOS (Homebrew, zmusic),
#                                      with their install names rewritten to the executable's folder
#     rt/bin/                          libRTGL1.dylib and the Metal shaders (RTGL/Build/bin)
#     rt/{data,mat,replace,scenes,wad,*.ktx2}
#                                      the DOOM 2 RT data, from a gzdoom-rt release
#
# The game's IWAD (DOOM2.WAD) is not included: the installer copies it from the user's copy
# of the game to ~/Library/Application Support/GZDoom, which gzdoom searches for IWADs.
#
# Usage: setup/macos/build_app.sh [output dir]
#   RTGL_ROOT     RTGL1's repository              (default: ../RTGL)
#   RT_DATA       a gzdoom-rt release's rt folder (default: ../release/gzdoom-rt-1.0.2/rt)
#   GZDOOM_BUILD  the CMake build of gzdoom-rt    (default: build-mac)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RTGL_ROOT="${RTGL_ROOT:-$(cd "${ROOT}/../RTGL" && pwd)}"
RT_DATA="${RT_DATA:-${ROOT}/../release/gzdoom-rt-1.0.2/rt}"
GZDOOM_BUILD="${GZDOOM_BUILD:-${ROOT}/build-mac}"
OUT="${1:-${ROOT}/build-macos-dist}"

APP_NAME="DOOM 2 RT"
APP="${OUT}/${APP_NAME}.app"
MACOS="${APP}/Contents/MacOS"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "${RT_DATA}/wad" && -d "${RT_DATA}/replace" ]] || die "RT_DATA=${RT_DATA} is not a gzdoom-rt release's rt folder"
[[ -f "${RTGL_ROOT}/Build/metal/CMakeCache.txt" ]] || die "RTGL1 is not configured: ${RTGL_ROOT}/Build/metal"
[[ -f "${GZDOOM_BUILD}/CMakeCache.txt" ]] || die "gzdoom-rt is not configured: ${GZDOOM_BUILD}"

#
# Build
#
cmake --build "${RTGL_ROOT}/Build/metal"
# twice: a pk3 is repacked on the build after its files changed (add_pk3 touches zipdir after the check)
RTGL1_SDK_PATH="${RTGL_ROOT}" cmake --build "${GZDOOM_BUILD}" -j "$(sysctl -n hw.ncpu)"
RTGL1_SDK_PATH="${RTGL_ROOT}" cmake --build "${GZDOOM_BUILD}" -j "$(sysctl -n hw.ncpu)"

SRC_APP="${GZDOOM_BUILD}/gzdoom.app"
[[ -x "${SRC_APP}/Contents/MacOS/gzdoom" ]] || die "no ${SRC_APP}"

#
# The bundle: real files instead of the development build's symlinks
#
rm -rf "${APP}"
mkdir -p "${MACOS}" "${APP}/Contents/Resources"
cp "${SRC_APP}/Contents/Info.plist" "${APP}/Contents/"
cp -R "${SRC_APP}/Contents/Resources/." "${APP}/Contents/Resources/"
for f in "${SRC_APP}/Contents/MacOS/"*; do
    name="$(basename "$f")"
    # the rest is assembled below
    [[ "${name}" == "rt" || "${name}" == lib*.dylib ]] && continue
    cp -R "$f" "${MACOS}/"
done

echo "Copying the DOOM 2 RT data ($(du -sh "${RT_DATA}" | cut -f1))"
mkdir -p "${MACOS}/rt"
# not needed on macOS: the Windows launcher, binaries and Vulkan shaders
rsync -a --copy-links \
    --exclude "/launcher" --exclude "/bin" --exclude "/shaders" --exclude "*.py" \
    "${RT_DATA}/" "${MACOS}/rt/"
mkdir -p "${MACOS}/rt/bin"
rsync -a --copy-links "${RTGL_ROOT}/Build/bin/" "${MACOS}/rt/bin/"

#
# Libraries: copy what's not part of macOS next to the executable, and load it from there
#
# loaded with dlopen by name from the executable's folder (OpenAL, and zmusic's sndfile / mpg123)
DLOPENED=(
    /opt/homebrew/opt/openal-soft/lib/libopenal.1.dylib
    /opt/homebrew/opt/libsndfile/lib/libsndfile.1.dylib
    /opt/homebrew/opt/mpg123/lib/libmpg123.0.dylib
)
# where @rpath references of the development build point to
RPATHS=()
while read -r p; do RPATHS+=("$p"); done < <(otool -l "${MACOS}/gzdoom" | awk '/LC_RPATH/ { getline; getline; print $2 }')

resolve() {
    local dep="$1"
    if [[ "${dep}" == @rpath/* ]]; then
        for r in "${RPATHS[@]}"; do
            [[ "$r" == @* ]] && continue
            [[ -f "$r/${dep#@rpath/}" ]] && { echo "$r/${dep#@rpath/}"; return; }
        done
        return
    fi
    echo "${dep}"
}

is_external() {
    case "$1" in
        /System/* | /usr/lib/*) return 1 ;;
        @executable_path/* | @loader_path/*) return 1 ;;
        *) return 0 ;;
    esac
}

declare -a QUEUE=( "${MACOS}/gzdoom" )
for lib in "${DLOPENED[@]}"; do
    [[ -f "${lib}" ]] || die "${lib} is missing (brew install openal-soft libsndfile mpg123)"
    cp -L "${lib}" "${MACOS}/"
    chmod u+w "${MACOS}/$(basename "${lib}")"
    QUEUE+=( "${MACOS}/$(basename "${lib}")" )
done

while (( ${#QUEUE[@]} > 0 )); do
    file="${QUEUE[0]}"
    QUEUE=( "${QUEUE[@]:1}" )

    # the first line is the file itself; a dylib's own install name is the second
    while read -r dep; do
        is_external "${dep}" || continue
        [[ "$(basename "${dep}")" == "$(basename "${file}")" ]] && continue

        real="$(resolve "${dep}")"
        [[ -n "${real}" && -f "${real}" ]] || die "can't find ${dep} (needed by ${file})"
        name="$(basename "${dep}")"

        if [[ ! -f "${MACOS}/${name}" ]]; then
            cp -L "${real}" "${MACOS}/${name}"
            chmod u+w "${MACOS}/${name}"
            QUEUE+=( "${MACOS}/${name}" )
        fi
        install_name_tool -change "${dep}" "@loader_path/${name}" "${file}" 2>/dev/null
    done < <(otool -L "${file}" | tail -n +2 | awk '{ print $1 }')

    if [[ "${file}" == *.dylib ]]; then
        install_name_tool -id "@loader_path/$(basename "${file}")" "${file}" 2>/dev/null
    fi
done

# only the executable's folder
for r in "${RPATHS[@]}"; do
    [[ "$r" == "@executable_path" ]] && continue
    install_name_tool -delete_rpath "$r" "${MACOS}/gzdoom" 2>/dev/null || true
done

#
# Info.plist
#
PLIST="${APP}/Contents/Info.plist"
VERSION="$(git -C "${ROOT}" describe --tags --always 2>/dev/null || echo 1.0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${PLIST}" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier org.drdteam.gzdoom-rt" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}" 2>/dev/null || true
# icon: setup/macos/icon.png (pixel art, scaled with nearest neighbor)
xcrun swift "${ROOT}/setup/macos/make_icon.swift" "${ROOT}/setup/macos/icon.png" "${APP}/Contents/Resources/doom2rt.icns"
rm -f "${APP}/Contents/Resources/zdoom.icns"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string doom2rt" "${PLIST}"
/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 26.0" "${PLIST}"

#
# Signature: Apple silicon only runs signed code, and install_name_tool invalidated it.
# Ad hoc (SIGN_ID=-) runs on this Mac; to distribute, use a Developer ID and notarize.
#
# The bundle itself can't be sealed: gzdoom keeps its data (pk3s, rt/) next to the executable,
# in Contents/MacOS. So each binary is signed on its own (the main executable outside the bundle,
# as codesign would treat it as the bundle); the installer removes the quarantine attribute.
SIGN_ID="${SIGN_ID:--}"
while read -r f; do
    file "$f" | grep -q "Mach-O" || continue
    tmp="$(mktemp -d)/$(basename "$f")"
    cp "$f" "${tmp}"
    codesign --force --sign "${SIGN_ID}" "${tmp}"
    mv "${tmp}" "$f"
done < <(find "${MACOS}" -type f \( -name "*.dylib" -o -perm -u+x \) -not -path "*/rt/replace/*" -not -path "*/rt/scenes/*")

echo "Created ${APP} ($(du -sh "${APP}" | cut -f1))"
