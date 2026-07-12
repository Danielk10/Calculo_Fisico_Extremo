#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APPPREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKEUSR="$DESTDIR$APPPREFIX"
export TMXPREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKEUSR/include" "$FAKEUSR/lib" "$FAKEUSR/bin" "$FAKEUSR/lib/pkgconfig"

# Aseguramos la instalación de las librerías de compatibilidad del sistema de Termux
pkg update -y
pkg install -y wget tar make autoconf automake libtool pkg-config clang binutils \
  coreutils findutils grep sed perl libandroid-shmem libandroid-posix-semaphore

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

# AGREGAMOS LAS LIBRERÍAS DE COMPATIBILIDAD Y EL FLAG DE TOLERANCIA AL ENLAZADOR
export LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$FAKEUSR/lib -L$TMXPREFIX/lib -landroid-shmem -landroid-posix-semaphore -Wl,--allow-shlib-undefined"
export PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$TMXPREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$FAKEUSR/lib:$TMXPREFIX/lib:${LD_LIBRARY_PATH:-}"

VER="5.0.9"
TAR="$HOME/openmpi-${VER}.tar.gz"
SRC="$HOME/openmpi-${VER}"
BUILD="$HOME/openmpi-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

wget -O "$TAR" "https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

# Bypass para la trampa de malloc.h
echo "=== Protegiendo malloc.h contra inclusiones tempranas del sistema ==="
echo '#ifndef BEGIN_C_DECLS
#include_next <malloc.h>
#else' > "$SRC/opal/util/malloc.h.tmp"
cat "$SRC/opal/util/malloc.h" >> "$SRC/opal/util/malloc.h.tmp"
echo '#endif' >> "$SRC/opal/util/malloc.h.tmp"
mv "$SRC/opal/util/malloc.h.tmp" "$SRC/opal/util/malloc.h"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== Ejecutando Configure ==="
bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --disable-static \
  --enable-shared \
  --disable-io-romio \
  --disable-picky \
  --with-libevent="$FAKEUSR" \
  --with-hwloc="$FAKEUSR" \
  --with-pmix="$FAKEUSR" \
  --with-prrte="$FAKEUSR" \
  --enable-mca-no-build=memory_patcher \
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

# ==============================================================================
# WRAPPERS DEL COMPILADOR ACTUALIZADOS (Inyección de bcmp)
# ==============================================================================
echo "=== Creando interceptores de compilación seguros ==="

# Agregamos -Dbcmp=memcmp para desaparecer el error de la función obsoleta de golpe
FORCED_FLAGS="-include stdlib.h -include string.h -include strings.h -DSHMLBA=4096 -Dbcmp=memcmp -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-int-conversion"

echo "#!/bin/bash
exec clang $FORCED_FLAGS \"\$@\"" > "$HOME/ompi_clang_wrapper"

echo "#!/bin/bash
exec clang++ $FORCED_FLAGS \"\$@\"" > "$HOME/ompi_clangxx_wrapper"

chmod +x "$HOME/ompi_clang_wrapper" "$HOME/ompi_clangxx_wrapper"

echo "=== Lanzando compilación global ==="
make -j"$(nproc)" CC="$HOME/ompi_clang_wrapper" CXX="$HOME/ompi_clangxx_wrapper"
make install DESTDIR="$DESTDIR"

rm -f "$HOME/ompi_clang_wrapper" "$HOME/ompi_clangxx_wrapper"

echo "=== ¡Proceso Finalizado! ==="
find "$FAKEUSR/bin" -maxdepth 1 \( -name 'mpicc' -o -name 'mpirun' -o -name 'ompi_info' \) | sort || true
