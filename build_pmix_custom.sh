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
  coreutils findutils grep sed perl

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

# Última versión estable de la serie 5
VER="5.0.11"
TAR="$HOME/pmix-${VER}.tar.gz"
SRC="$HOME/pmix-${VER}"
BUILD="$HOME/pmix-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

wget -O "$TAR" "https://github.com/openpmix/openpmix/releases/download/v${VER}/pmix-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --modversion libevent || true
PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --modversion hwloc || true

set +e
bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --includedir="$APPPREFIX/include" \
  --disable-static \
  --enable-shared \
  --enable-devel-headers \
  --with-libevent="$FAKEUSR" \
  --with-libevent-libdir="$FAKEUSR/lib" \
  --with-hwloc="$FAKEUSR" \
  --with-hwloc-libdir="$FAKEUSR/lib" \
  CC="$CC" \
  CXX="$CXX" \
  CPPFLAGS="$CPPFLAGS" \
  CFLAGS="$CFLAGS" \
  CXXFLAGS="$CXXFLAGS" \
  LDFLAGS="$LDFLAGS" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
cfg_status=$?
set -e

if [ "$cfg_status" -ne 0 ]; then
  tail -n 120 config.log || true
  exit "$cfg_status"
fi

make -j"$(nproc)"
make install DESTDIR="$DESTDIR"

echo "=== Bibliotecas instaladas ==="
find "$FAKEUSR/lib" -maxdepth 1 -name 'libpmix*.so*' | sort

echo "=== Headers instalados ==="
find "$FAKEUSR/include" -maxdepth 3 \( -name 'pmix*.h' -o -path '*/pmix/*.h' \) | sort | head -n 120

echo "=== Binarios instalados ==="
find "$FAKEUSR/bin" -maxdepth 1 \( -name 'pmix*' -o -name 'p*tool*' \) | sort || true

echo "=== pkg-config ==="
find "$FAKEUSR/lib/pkgconfig" -maxdepth 1 -name 'pmix*.pc' | sort
sed -n '1,180p' "$FAKEUSR/lib/pkgconfig/pmix.pc" || true
