#!/bin/zsh
# Rebuilds the Embedded Swift concurrency runtime for armv7 with -ffixed-r9, as ARM code.
#
#   Scripts/build-concurrency-runtime.sh <swift toolchain> <output directory>
#
# The toolchain's libswift_Concurrency.a for armv7-apple-none-macho is built
# for bare metal, where r9 is callee-saved, and its C++ code keeps values in
# r9 across calls. On iOS r9 is a scratch register, so a call into iOS (malloc,
# UIKit, ...) can overwrite it, and the runtime then crashes on a bad pointer.
#
# This script fetches the runtime's C++ sources for the toolchain's exact
# release tag and compiles them with the flags of the official build plus
# -ffixed-r9 and -marm. Without those two, these flags reproduce the shipped
# objects exactly, except for C++ standard library template code, which comes
# from this Mac's SDK headers. The archive's Swift object (_Concurrency.o) is
# empty, since Embedded Swift compiles that code into the app, and is copied
# as is.

set -euo pipefail
setopt nullglob

TOOLCHAIN=${1:?usage: $0 <swift toolchain> <output directory>}
OUT=${2:?usage: $0 <swift toolchain> <output directory>}
OUT=${OUT:a}

SHIPPED=$TOOLCHAIN/usr/lib/swift/embedded/armv7-apple-none-macho/libswift_Concurrency.a
CXX=$TOOLCHAIN/usr/bin/clang++
TAG=$($TOOLCHAIN/usr/bin/swiftc --version 2>&1 | sed -nE 's/.*\((swift-[^)]*-RELEASE)\).*/\1/p')
[[ -n $TAG ]] || { echo "error: no release tag in the toolchain's version" >&2; exit 1; }

SRC=$OUT/swift-$TAG
OBJ=$OUT/obj
mkdir -p $OUT $OBJ

# Only the runtime's sources and headers are needed.
if [[ ! -d $SRC/.git ]]; then
    git clone --quiet --depth 1 --branch $TAG --filter=blob:none --sparse \
        https://github.com/swiftlang/swift.git $SRC
    git -C $SRC sparse-checkout set stdlib/public stdlib/include include/swift
fi

# The official build generates this header with CMake.
mkdir -p $OUT/gen/swift/Runtime
cat > $OUT/gen/swift/Runtime/CMakeConfig.h <<EOF
#ifndef SWIFT_RUNTIME_CMAKECONFIG_H
#define SWIFT_RUNTIME_CMAKECONFIG_H
#define SWIFT_VERSION_MAJOR "$(echo $TAG | cut -d- -f2 | cut -d. -f1)"
#define SWIFT_VERSION_MINOR "$(echo $TAG | cut -d- -f2 | cut -d. -f2)"
#endif
EOF

# From stdlib/public/Concurrency/CMakeLists.txt and AddSwiftStdlib.cmake for
# the "embedded" SDK, as built on a macOS host.
MACSDK=$(xcrun --show-sdk-path --sdk macosx)
FLAGS=(
    -target armv7-apple-none-macho -std=c++17 -O2 -g -DNDEBUG
    -fno-exceptions -fno-cxx-exceptions -fno-unwind-tables -fno-rtti
    -ffunction-sections -fdata-sections
    -stdlib=libc++ -isystem$MACSDK/usr/include/c++/v1 -isystem$MACSDK/usr/include
    -D__APPLE__ -DTARGET_CPU_ARM=1
    -DSWIFT_RUNTIME '-DSWIFT_LIB_SUBDIR="embedded"' '-DSWIFT_ARCH="armv7"'
    -DSWIFT_TARGET_LIBRARY_NAME=swift_Concurrency -Dswift_Concurrency_EXPORTS
    -DSWIFT_CONCURRENCY_ENABLE_DISPATCH=0 -fswift-async-fp=never -D__STDC_WANT_LIB_EXT1__=1
    -DSWIFT_CONCURRENCY_EMBEDDED=1 -DSWIFT_RUNTIME_EMBEDDED=1
    -DSWIFT_THREADING_NONE -DSWIFT_OBJC_INTEROP=0 -DSWIFT_LIBRARY_EVOLUTION=0
    -I$OUT/gen -I$SRC/stdlib/include -I$SRC/include
    -I$SRC/stdlib/public/Concurrency -I$SRC/stdlib/public/SwiftShims
    -ffixed-r9
    # Xcode's linker doesn't set the Thumb bit in pointers to Thumb functions,
    # so a call through one runs Thumb code in ARM state. Like the rest of the
    # app, the runtime is built as ARM.
    -marm
)

# Rebuild every C++ object in the shipped archive whose source is part of the
# concurrency runtime; keep the rest.
rm -f $OBJ/*.o
(cd $OBJ && xcrun ar -x $SHIPPED)
rm -f $OBJ/__.SYMDEF*
for object in $OBJ/*.cpp.o; do
    name=${${object:t}%.cpp.o}
    source=$SRC/stdlib/public/Concurrency/$name.cpp
    [[ -f $source ]] || source=$SRC/stdlib/public/Threading/$name.cpp
    [[ -f $source ]] || continue
    $CXX $FLAGS -c $source -o $object
done

# r9 may only be saved and restored, never used.
for object in $OBJ/*.o; do
    uses=$(xcrun otool -arch armv7 -tV $object | grep -E '\br9\b' \
        | grep -vE '(push|pop)(eq|ne|cs|hs|cc|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le)?(\.w)?[[:space:]]+\{[^}]*r9' || true)
    if [[ -n $uses ]]; then
        echo "error: ${object:t} still uses r9:" >&2
        echo $uses >&2
        exit 1
    fi
done

for object in $OBJ/*.o; do
    if nm -m $object 2>/dev/null | grep -q '\[Thumb\]'; then
        echo "error: ${object:t} contains Thumb code" >&2
        exit 1
    fi
done

rm -f $OUT/libswift_Concurrency.a
xcrun ar -rcs $OUT/libswift_Concurrency.a $OBJ/*.o
echo "$OUT/libswift_Concurrency.a"
