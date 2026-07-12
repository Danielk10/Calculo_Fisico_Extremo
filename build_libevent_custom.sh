#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APPPREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKEUSR="$DESTDIR$APPPREFIX"
export TMXPREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKEUSR/include" "$FAKEUSR/lib" "$FAKEUSR/bin" "$FAKEUSR/lib/pkgconfig"

pkg update -y
pkg install -y wget tar make autoconf automake libtool pkg-config clang binutils coreutils findutils grep sed perl

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

VER="2.1.12-stable"
TAR="$HOME/libevent-${VER}.tar.gz"
SRC="$HOME/libevent-${VER}"
BUILD="$HOME/libevent-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

wget -O "$TAR" "https://github.com/libevent/libevent/releases/download/release-${VER}/libevent-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --disable-static \
  --enable-shared \
  --disable-openssl \
  CC="$CC" \
  CPPFLAGS="$CPPFLAGS" \
  CFLAGS="$CFLAGS" \
  LDFLAGS="$LDFLAGS"

make -j"$(nproc)"
make install DESTDIR="$DESTDIR"

echo "=== Bibliotecas instaladas ==="
find "$FAKEUSR/lib" -maxdepth 1 -name 'libevent*.so*' | sort

echo "=== Headers instalados ==="
find "$FAKEUSR/include" -maxdepth 2 \( -name 'event.h' -o -path '*/event2/*' \) | sort | head -n 50

echo "=== pkg-config ==="
find "$FAKEUSR/lib/pkgconfig" -maxdepth 1 -name 'libevent*.pc' | sort
sed -n '1,120p' "$FAKEUSR/lib/pkgconfig/libevent.pc" || true

echo "=== Dependencias de libevent.so ==="
if [ -f "$FAKEUSR/lib/libevent.so" ]; then
  readelf -d "$FAKEUSR/lib/libevent.so" | grep NEEDED || true
fi

echo "=== Alineación 16KB ==="
if [ -f "$FAKEUSR/lib/libevent.so" ]; then
  readelf -l "$FAKEUSR/lib/libevent.so" | grep LOAD || true
fi
