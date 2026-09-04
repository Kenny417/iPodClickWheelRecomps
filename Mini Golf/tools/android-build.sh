#!/bin/sh
# Build the Android build (an .apk), and optionally put it on a device.
#
#   tools/android-build.sh [install] [clean]
#
# What comes out is build-android/minigolf.apk, for arm64-v8a — every Android handheld worth
# playing this on is arm64, and a second ABI doubles the download to serve machines that are not
# out there.
#
# **There is no Java, and no Gradle.** SDL ships org.libsdl.app.SDLActivity already compiled in
# its .aar, and that activity loads "SDL3" and then "main" and calls SDL_main in the second — so
# the port is built as `libmain.so` (CMakeLists.txt renames it) and the app needs no class of its
# own. What is left is the four steps below, which are what Gradle would have run anyway: dex
# SDL's classes, link a manifest, add the libraries, sign. Adding Gradle would mean a JDK, an
# Android Gradle Plugin, and a wrapper, to save four lines.
#
# Unlike the Windows and Switch builds this is not containerised, because the pieces are all
# no-root downloads that live under ~/Android:
#
#   ANDROID_NDK   the NDK              (r28c or newer; SDL asks for r28c)
#   ANDROID_SDK   platform + build-tools (API 35)
#   SDL3_ANDROID  SDL's .aar, unpacked — the .aar is also a Python script that does it:
#                     python3 SDL3-<version>.aar -o <prefix>
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
: "${ANDROID_NDK:=$HOME/Android/android-ndk-r28c}"
: "${ANDROID_SDK:=$HOME/Android/Sdk}"
: "${ANDROID_BUILD_TOOLS:=$ANDROID_SDK/build-tools/35.0.0}"
: "${ANDROID_PLATFORM_JAR:=$ANDROID_SDK/platforms/android-35/android.jar}"
: "${SDL3_ANDROID:=$HOME/Android/sdl3/prefix}"
: "${ANDROID_KEYSTORE:=$HOME/Android/debug.keystore}"
abi=arm64-v8a

for required in "$ANDROID_NDK/build/cmake/android.toolchain.cmake" "$ANDROID_PLATFORM_JAR" \
                "$ANDROID_BUILD_TOOLS/aapt2" "$SDL3_ANDROID/lib/cmake/SDL3/SDL3Config.cmake"; do
    if [ ! -e "$required" ]; then
        echo "android-build.sh: missing $required" >&2
        echo "See the header of this script for what each piece is and where it comes from." >&2
        exit 2
    fi
done

build="$here/build-android"
if [ "${1:-}" = "clean" ] || [ "${2:-}" = "clean" ]; then
    rm -rf "$build"
fi

# ---------------------------------------------------------------------------------------------
# The native side. -ffp-contract=off so the rasteriser rounds the way every other build of it
# does: clang on ARM fuses a multiply and an add into one instruction that rounds once instead of
# twice, which is faster and shifts about one pixel in five hundred by a single value. That is
# invisible to play and fatal to comparing a frame against another machine's, which is how this
# port is checked.
# ---------------------------------------------------------------------------------------------
cmake -B "$build" -G Ninja -S "$here" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM=android-21 \
    -DCMAKE_CXX_FLAGS=-ffp-contract=off \
    -DSDL3_DIR="$SDL3_ANDROID/lib/cmake/SDL3" > /dev/null
cmake --build "$build" --target minigolf

# ---------------------------------------------------------------------------------------------
# The package.
# ---------------------------------------------------------------------------------------------
stage="$build/apk"
rm -rf "$stage"
mkdir -p "$stage/lib/$abi"

# SDL's Java, dexed. --lib is the framework it was compiled against, without which d8 cannot
# desugar the interfaces SDLSurface implements and says so.
"$ANDROID_BUILD_TOOLS/d8" --release --min-api 21 --lib "$ANDROID_PLATFORM_JAR" \
    --output "$stage" "$SDL3_ANDROID"/share/java/SDL3/SDL3-*.jar

# The manifest. No resources of our own: the label is a literal and the theme is the framework's.
"$ANDROID_BUILD_TOOLS/aapt2" link -I "$ANDROID_PLATFORM_JAR" \
    --manifest "$here/android/AndroidManifest.xml" -o "$stage/base.apk" \
    --min-sdk-version 21 --target-sdk-version 35

# The libraries. Stripped: the debug information is a tenth of the download and nothing on the
# device reads it.
"$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
    "$build/libmain.so" -o "$stage/lib/$abi/libmain.so"
cp "$SDL3_ANDROID/lib/$abi/libSDL3.so" "$stage/lib/$abi/libSDL3.so"

(cd "$stage" && zip -q -r base.apk classes.dex lib)

# A debug key, made once. Signing for real is the same decision as signing the Windows and macOS
# builds — see ../RELEASING.md — and is nothing this script should assume.
if [ ! -f "$ANDROID_KEYSTORE" ]; then
    keytool -genkeypair -keystore "$ANDROID_KEYSTORE" -storepass android -keypass android \
        -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
        -keyalg RSA -keysize 2048 -validity 10000
fi
"$ANDROID_BUILD_TOOLS/zipalign" -p -f 4 "$stage/base.apk" "$stage/aligned.apk"
"$ANDROID_BUILD_TOOLS/apksigner" sign --ks "$ANDROID_KEYSTORE" --ks-pass pass:android \
    --key-pass pass:android --out "$build/minigolf.apk" "$stage/aligned.apk" 2>/dev/null

ls -l "$build/minigolf.apk"

if [ "${1:-}" = "install" ]; then
    adb install -r "$build/minigolf.apk"
    echo
    echo "The game's own files go in"
    echo "    /sdcard/Android/data/org.ipodrecomp.minigolf/files/88888"
    echo "which the app itself will name on screen if they are not there."
fi
