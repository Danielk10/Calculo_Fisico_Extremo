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
export FC="${FC:-gfortran}"
export F77="${F77:-gfortran}"
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

export PATH="$FAKEUSR/bin:$TMXPREFIX/bin:$PATH"
export CPPFLAGS="-I$FAKEUSR/include -I$FAKEUSR/include/pmix -I$TMXPREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export FCFLAGS="-fPIC -fPIE -O2"
export FFLAGS="-fPIC -fPIE -O2"
export LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$FAKEUSR/lib -L$TMXPREFIX/lib"
export PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$TMXPREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$FAKEUSR/lib:$TMXPREFIX/lib:${LD_LIBRARY_PATH:-}"

VER="4.1.8"
TAR="$HOME/openmpi-${VER}.tar.gz"
SRC="$HOME/openmpi-${VER}"
BUILD="$HOME/openmpi-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

wget -O "$TAR" "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== pkg-config previo ==="
pkg-config --modversion libevent || true
pkg-config --modversion hwloc || true
pkg-config --modversion pmix || true

bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --disable-static \
  --enable-shared \
  --with-libevent="$FAKEUSR" \
  --with-hwloc="$FAKEUSR" \
  --with-pmix="$FAKEUSR" \
  --enable-mpi-fortran=all \
  CC="$CC" \
  CXX="$CXX" \
  FC="$FC" \
  F77="$F77" \
  CPPFLAGS="$CPPFLAGS" \
  CFLAGS="$CFLAGS" \
  CXXFLAGS="$CXXFLAGS" \
  FCFLAGS="$FCFLAGS" \
  FFLAGS="$FFLAGS" \
  LDFLAGS="$LDFLAGS" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH"

make -j"$(nproc)"
make install DESTDIR="$DESTDIR"

echo "=== Binarios instalados ==="
find "$FAKEUSR/bin" -maxdepth 1 \( -name 'mpicc' -o -name 'mpic++' -o -name 'mpifort' -o -name 'mpirun' -o -name 'ompi_info' \) | sort || true

echo "=== Bibliotecas instaladas ==="
find "$FAKEUSR/lib" -maxdepth 1 \( -name 'libmpi*.so*' -o -name 'libopen-pal*.so*' -o -name 'libopen-rte*.so*' \) | sort || true

echo "=== Dependencias de libmpi.so ==="
if [ -f "$FAKEUSR/lib/libmpi.so" ]; then
  readelf -d "$FAKEUSR/lib/libmpi.so" | grep NEEDED || true
fi

echo "=== Wrappers ==="
"$FAKEUSR/bin/mpicc" --showme || true
"$FAKEUSR/bin/mpifort" --showme || true
"$FAKEUSR/bin/ompi_info" | head -n 80 || true
