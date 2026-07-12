#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin" "$FAKE_USR/lib/pkgconfig"

pkg update -y
pkg install -y wget tar make cmake clang binutils coreutils findutils grep sed perl jsoncpp \
  libandroid-shmem libandroid-posix-semaphore

export OPAL_DESTDIR="$DESTDIR"
export OPAL_PREFIX="$APP_PREFIX"

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"

export CC="$FAKE_USR/bin/mpicc"
export FC="$FAKE_USR/bin/mpifort"
export CXX="$FAKE_USR/bin/mpic++"
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"

# Añadimos compatibilidad para Clang moderno (-Wno-error=implicit-function-declaration)
export CFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export FFLAGS="-fPIC -fPIE -O2"
export FCFLAGS="-fPIC -fPIE -O2"

# ==============================================================================
# CONFIGURACIÓN DE ENLAZADORES (FLAGS DE SOLUCCIÓN)
# ==============================================================================
# Forzamos '-fuse-ld=lld' para que gfortran no use el ld.bfd viejo que rompe la compilación.

# 1. Para ejecutables (SÍ lleva -pie para cumplir con Android)
export EXE_LDFLAGS="-pie -fuse-ld=lld -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread"

# 2. Para la librería compartida .so (NO lleva -pie para evitar el error de 'main')
export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread"

export PKG_CONFIG_PATH="$FAKE_USR/lib/pkgconfig:$TMX_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

VER="2.2.2"
TAR="$HOME/scalapack-${VER}.tar.gz"
SRC="$HOME/scalapack-${VER}"
BUILD="$HOME/scalapack-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

echo "=== Descargando ScaLAPACK ${VER} ==="
wget -O "$TAR" "https://github.com/Reference-ScaLAPACK/scalapack/archive/refs/tags/v${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"
mv "$HOME/scalapack-${VER}" "$SRC" 2>/dev/null || true

echo "=== Actualizando políticas de compatibilidad para CMake 4 ==="
find "$SRC" -name "CMakeLists.txt" -exec sed -i 's/cmake_minimum_required\s*(VERSION\s*[0-9.]*)/cmake_minimum_required(VERSION 3.10)/g' {} +

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== Verificando entorno OpenMPI/OpenBLAS ==="
"$FAKE_USR/bin/mpicc" --showme || true
"$FAKE_USR/bin/mpifort" --showme || true

cmake "$SRC" \
  -DCMAKE_INSTALL_PREFIX="$APP_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_Fortran_COMPILER="$FC" \
  -DMPI_C_COMPILER="$CC" \
  -DMPI_CXX_COMPILER="$CXX" \
  -DMPI_Fortran_COMPILER="$FC" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_Fortran_FLAGS="$FFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SHARED_LDFLAGS" \
  -DBLAS_LIBRARIES="$FAKE_USR/lib/libopenblas.so" \
  -DLAPACK_LIBRARIES="$FAKE_USR/lib/libopenblas.so" \
  -DSCALAPACK_BUILD_TESTS=OFF

echo "=== Compilando ScaLAPACK ==="
cmake --build . -j"$(nproc)"

echo "=== Instalando ScaLAPACK en fake_root ==="
DESTDIR="$DESTDIR" cmake --install .

echo "=== Bibliotecas instaladas ==="
find "$FAKE_USR/lib" -maxdepth 1 -name 'libscalapack*.so*' | sort || true

echo "=== Dependencias de libscalapack.so ==="
if [ -f "$FAKE_USR/lib/libscalapack.so" ]; then
  readelf -d "$FAKE_USR/lib/libscalapack.so" | grep NEEDED || true
fi

echo "=== Alineación 16KB ==="
if [ -f "$FAKE_USR/lib/libscalapack.so" ]; then
  readelf -l "$FAKE_USR/lib/libscalapack.so" | grep LOAD || true
fi

echo "=== ScaLAPACK ${VER} compilado correctamente ==="
