#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin"

# Instalación de dependencias en Termux (sin mercurial)
pkg update -y
pkg install -y wget tar make cmake clang binutils grep sed coreutils \
  libandroid-shmem libandroid-posix-semaphore

export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"

export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread"

SRC="$HOME/metis-aster"
BUILD="$SRC/build"

rm -rf "$SRC"

echo "=== Descargando METIS 5.1.0 (rama code_aster) ==="
hg clone -b code_aster http://hg.code.sf.net/p/prereq/metis "$SRC"

cd "$SRC" || exit 1

echo "=== Parcheando TODOS los CMakeLists para CMake moderno ==="
find "$SRC" -maxdepth 3 -name CMakeLists.txt -exec \
  sed -E -i 's/cmake_minimum_required[[:space:]]*(VERSION[[:space:]]*[0-9.]+)/cmake_minimum_required(VERSION 3.10)/g' {} +

echo "=== Verificando líneas parcheadas ==="
grep -R "^cmake_minimum_required" "$SRC" || true

echo "=== Configurando METIS para enteros largos (64-bit) ==="
sed -i 's/#define IDXTYPEWIDTH .*/#define IDXTYPEWIDTH 64/g' include/metis.h
sed -i 's/#define REALTYPEWIDTH .*/#define REALTYPEWIDTH 64/g' include/metis.h

echo "=== Parche GKlib para Android Bionic (execinfo) ==="
if [ -f "GKlib/error.c" ]; then
  sed -i 's/HAVE_EXECINFO_H/HAVE_EXECINFO_H_DISABLED/g' GKlib/error.c
fi

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== Ejecutando CMake ==="
cmake .. \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$APP_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DSHARED=1 \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SHARED_LDFLAGS" \
  -DGKLIB_PATH="../GKlib"

echo "=== Compilando METIS ==="
cmake --build . -j"$(nproc)"

echo "=== Instalando METIS en fake_root ==="
DESTDIR="$DESTDIR" cmake --install .

echo "=== Copiando TODOS los headers exigidos por Code_Aster y ParMETIS ==="
cp -rf ../include/*.h "$FAKE_USR/include/"
cp -rf ../GKlib/*.h "$FAKE_USR/include/"

echo "=== Bibliotecas instaladas ==="
find "$FAKE_USR/lib" -maxdepth 1 \( -name 'libmetis.so*' -o -name 'libmetis.a' \) | sort || true

echo "=== Dependencias de libmetis.so ==="
if [ -f "$FAKE_USR/lib/libmetis.so" ]; then
  readelf -d "$FAKE_USR/lib/libmetis.so" | grep NEEDED || true
fi

echo "=== Alineación 16KB ==="
if [ -f "$FAKE_USR/lib/libmetis.so" ]; then
  readelf -l "$FAKE_USR/lib/libmetis.so" | grep LOAD || true
fi

echo "=== Headers instalados ==="
ls -lh "$FAKE_USR/include/metis.h" || true

echo "=== METIS 5.1.0 (CMake, enteros largos) compilado correctamente ==="
