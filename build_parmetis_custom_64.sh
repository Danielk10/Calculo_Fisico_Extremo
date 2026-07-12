#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin"

# Dependencias base
pkg update -y
pkg install -y wget tar make cmake clang binutils grep sed coreutils \
  libandroid-shmem libandroid-posix-semaphore

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"

# Variables de entorno criticas para que mpicc encuentre su configuracion
export OPAL_DESTDIR="$DESTDIR"
export OPAL_PREFIX="$APP_PREFIX"

if [ ! -x "$FAKE_USR/bin/mpicc" ]; then
  echo "ERROR: no se encontro mpicc en $FAKE_USR/bin. Compila e instala OpenMPI antes de ParMETIS."
  exit 1
fi

export CC="$FAKE_USR/bin/mpicc"
export CXX="$FAKE_USR/bin/mpic++"
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

echo "=== Verificando que METIS (rama code_aster) este instalado en 64 bits ANTES de compilar ParMETIS ==="
if [ ! -f "$FAKE_USR/include/metis.h" ]; then
  echo "ERROR: no se encontro $FAKE_USR/include/metis.h. Compila METIS de la rama code_aster primero."
  exit 1
fi

IDXW=$(grep -oE '^#define[[:space:]]+IDXTYPEWIDTH[[:space:]]+[0-9]+' "$FAKE_USR/include/metis.h" | awk '{print $3}' | tail -1)
if [ "$IDXW" != "64" ]; then
  echo "ERROR: metis.h instalado no esta en IDXTYPEWIDTH=64 (valor actual: ${IDXW:-desconocido})."
  exit 1
fi
echo "OK: METIS externo ya instalado con IDXTYPEWIDTH=64"

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -Wno-error=implicit-function-declaration -ffile-prefix-map=$DESTDIR= $CPPFLAGS"

export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread"

VER="4.0.3"
TAR="$HOME/parmetis-${VER}.tar.gz"
SRC="$HOME/parmetis-${VER}"
BUILD="$SRC/build"

rm -rf "$SRC"
echo "=== Descargando ParMETIS 4.0.3 (MacPorts Mirror) ==="
wget -O "$TAR" "https://distfiles.macports.org/parmetis/parmetis-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

cd "$SRC" || exit 1

echo "=== Parcheando CMakeLists para aislamiento total de METIS y GKlib (patron robusto) ==="

# 1. Actualizamos la version minima de CMake requerida en todos los archivos
find . -name CMakeLists.txt -exec sed -i 's/cmake_minimum_required(VERSION 2.8)/cmake_minimum_required(VERSION 3.10)/g' {} +

# 2. Eliminacion TOTAL de GKlibSystem y symlinks
sed -i '/GKlibSystem.cmake/d' CMakeLists.txt
sed -i '/create_symlink/d' CMakeLists.txt

# 3. Eliminamos el subdirectorio de METIS interno (patron tolerante a variables y mayusculas)
#    Cubre variantes como: add_subdirectory(libmetis), add_subdirectory(${METIS_PATH}/libmetis GKlib)
sed -i -E '/add_subdirectory\([^)]*[Ll]ib[Mm]etis[^)]*\)/d' CMakeLists.txt
sed -i -E '/add_subdirectory\([^)]*[Pp]rograms[^)]*\)/d' CMakeLists.txt

# 4. Eliminamos include_directories/link_directories que apunten a GKLIB_PATH o METIS_PATH internos
sed -i -E '/include_directories\([^)]*GKLIB_PATH[^)]*\)/d' CMakeLists.txt
sed -i -E '/include_directories\([^)]*METIS_PATH[^)]*\)/d' CMakeLists.txt
sed -i -E '/link_directories\([^)]*GKLIB_PATH[^)]*\)/d' CMakeLists.txt
sed -i -E '/link_directories\([^)]*METIS_PATH[^)]*\)/d' CMakeLists.txt

# 5. Redirigimos los headers explicitamente a nuestro fake_root (METIS externo)
cat >> CMakeLists.txt <<EOF

include_directories("$FAKE_USR/include")
link_directories("$FAKE_USR/lib")
EOF

echo "=== Parches en libparmetis/CMakeLists.txt ==="
# Forzar SHARED
sed -i 's|add_library(parmetis|add_library(parmetis SHARED|g' libparmetis/CMakeLists.txt
# Enlace contra metis externo y math ('m')
sed -i 's|target_link_libraries(parmetis metis)|target_link_libraries(parmetis metis m)|g' libparmetis/CMakeLists.txt

# Anadir la instruccion de instalacion para libparmetis (solo si no existe ya)
if ! grep -q "install(TARGETS parmetis" libparmetis/CMakeLists.txt; then
cat << 'EOF' >> libparmetis/CMakeLists.txt

install(TARGETS parmetis
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
EOF
fi

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== Ejecutando CMake para ParMETIS ==="
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$APP_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DSHARED=1 \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SHARED_LDFLAGS"

echo "=== Compilando ParMETIS ==="
cmake --build . -j"$(nproc)"

echo "=== Instalando ParMETIS en fake_root ==="
DESTDIR="$DESTDIR" cmake --install .

echo "=== Copiando header parmetis.h a include (respaldo si el install no lo copio) ==="
find "$SRC" -maxdepth 2 -name "parmetis.h" -exec cp -f {} "$FAKE_USR/include/" \;

echo "=== Bibliotecas instaladas ==="
find "$FAKE_USR/lib" -maxdepth 1 \( -name 'libparmetis.so*' -o -name 'libparmetis.a' \) | sort || true

echo "=== Dependencias de libparmetis.so ==="
if [ -f "$FAKE_USR/lib/libparmetis.so" ]; then
  readelf -d "$FAKE_USR/lib/libparmetis.so" | grep NEEDED || true
fi

echo "=== Alineacion 16KB ==="
if [ -f "$FAKE_USR/lib/libparmetis.so" ]; then
  readelf -l "$FAKE_USR/lib/libparmetis.so" | grep LOAD || true
fi

echo "=== Headers instalados ==="
ls -lh "$FAKE_USR/include/parmetis.h" || true

echo "=== VERIFICACION FINAL: ParMETIS en enteros largos (64-bit) ==="

grep -E "^#define[[:space:]]+(IDXTYPEWIDTH|REALTYPEWIDTH)" "$FAKE_USR/include/metis.h" || {
  echo "ERROR: metis.h instalado no tiene las macros esperadas"
  exit 1
}

cat > "$HOME/check_parmetis_idx.c" <<'EOC'
#include <stdio.h>
#include <mpi.h>
#include "metis.h"
#include "parmetis.h"
int main(void) {
    printf("IDXTYPEWIDTH=%d\n", IDXTYPEWIDTH);
    printf("REALTYPEWIDTH=%d\n", REALTYPEWIDTH);
    printf("sizeof(idx_t)=%zu bytes (%zu bits)\n", sizeof(idx_t), sizeof(idx_t)*8);
    printf("sizeof(real_t)=%zu bytes (%zu bits)\n", sizeof(real_t), sizeof(real_t)*8);
    printf("PARMETIS_MAJOR_VERSION=%d\n", PARMETIS_MAJOR_VERSION);
    return (sizeof(idx_t) == 8) ? 0 : 1;
}
EOC

"$CC" -I"$FAKE_USR/include" -I"$TMX_PREFIX/include" "$HOME/check_parmetis_idx.c" \
  -o "$HOME/check_parmetis_idx" -L"$FAKE_USR/lib" -lparmetis -lmetis
"$HOME/check_parmetis_idx" || {
  echo "ERROR: idx_t en ParMETIS NO quedo en 64 bits."
  exit 1
}
rm -f "$HOME/check_parmetis_idx" "$HOME/check_parmetis_idx.c"

echo "--- Simbolos clave en libparmetis.so ---"
if [ -f "$FAKE_USR/lib/libparmetis.so" ]; then
  nm -D "$FAKE_USR/lib/libparmetis.so" 2>/dev/null | grep -i "ParMETIS_V3_PartKway" || true
fi

echo "=== RESULTADO: ParMETIS 4.0.3 compilado y VERIFICADO en enteros largos (64-bit), enlazado contra METIS externo ==="
