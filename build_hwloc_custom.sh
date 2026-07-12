#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APPPREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKEUSR="$DESTDIR$APPPREFIX"
export TMXPREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKEUSR/include" "$FAKEUSR/lib" "$FAKEUSR/bin" "$FAKEUSR/lib/pkgconfig"

pkg update -y
pkg install -y wget tar make autoconf automake libtool pkg-config clang binutils \
  coreutils findutils grep sed libxml2 libpciaccess ncurses perl

export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

export PATH="$FAKEUSR/bin:$TMXPREFIX/bin:$PATH"
export CPPFLAGS="-I$FAKEUSR/include -I$TMXPREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$FAKEUSR/lib -L$TMXPREFIX/lib"
export PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$TMXPREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$FAKEUSR/lib:$TMXPREFIX/lib:${LD_LIBRARY_PATH:-}"

VER="2.11.2"
TAR="$HOME/hwloc-${VER}.tar.gz"
SRC="$HOME/hwloc-${VER}"
BUILD="$HOME/hwloc-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

wget -O "$TAR" "https://download.open-mpi.org/release/hwloc/v2.11/hwloc-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

if PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$TMXPREFIX/lib/pkgconfig" pkg-config --exists cairo; then
  HWLOC_CAIRO_FLAG="--enable-cairo"
else
  HWLOC_CAIRO_FLAG="--disable-cairo"
fi

bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --disable-static \
  --enable-shared \
  "$HWLOC_CAIRO_FLAG" \
  --enable-libxml2 \
  --disable-opencl \
  --disable-cuda \
  CC="$CC" \
  CPPFLAGS="$CPPFLAGS" \
  CFLAGS="$CFLAGS" \
  LDFLAGS="$LDFLAGS" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH"

make -j"$(nproc)"
make install DESTDIR="$DESTDIR"

echo "=== Bibliotecas instaladas ==="
find "$FAKEUSR/lib" -maxdepth 1 -name 'libhwloc*.so*' | sort

echo "=== Headers instalados ==="
find "$FAKEUSR/include" -maxdepth 3 \( -name 'hwloc.h' -o -path '*/hwloc/*.h' \) | sort | head -n 100

echo "=== pkg-config ==="
find "$FAKEUSR/lib/pkgconfig" -maxdepth 1 -name 'hwloc*.pc' | sort
sed -n '1,120p' "$FAKEUSR/lib/pkgconfig/hwloc.pc" || true

echo "=== Dependencias de libhwloc.so ==="
if [ -f "$FAKEUSR/lib/libhwloc.so" ]; then
  readelf -d "$FAKEUSR/lib/libhwloc.so" | grep NEEDED || true
fi

echo "=== Alineación 16KB ==="
if [ -f "$FAKEUSR/lib/libhwloc.so" ]; then
  readelf -l "$FAKEUSR/lib/libhwloc.so" | grep LOAD || true
fi
