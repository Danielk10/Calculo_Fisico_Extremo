#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin"

# Dependencias necesarias
pkg update -y
pkg install -y wget tar make cmake clang binutils grep sed coreutils \
  bison flex zlib libandroid-shmem libandroid-posix-semaphore

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"

# Variables OPAL para los wrappers de Open MPI en fake_root
export OPAL_DESTDIR="$DESTDIR"
export OPAL_PREFIX="$APP_PREFIX"
export OPAL_INCLUDEDIR="$FAKE_USR/include"

if [ ! -x "$FAKE_USR/bin/mpicc" ]; then
  echo "ERROR: no se encontro mpicc en $FAKE_USR/bin. Compila OpenMPI antes de Scotch."
  exit 1
fi

export CC="$FAKE_USR/bin/mpicc"
export CXX="$FAKE_USR/bin/mpic++"
export AR=llvm-ar
export RANLIB=llvm-ranlib

echo "=== Verificando que METIS real ya este instalado (no debe sobrescribirse) ==="
if [ ! -f "$FAKE_USR/include/metis.h" ]; then
  echo "ADVERTENCIA: no existe $FAKE_USR/include/metis.h todavia. Se recomienda compilar METIS antes de Scotch."
else
  if grep -q "NOT THE ORIGINAL INCLUDE FILE" "$FAKE_USR/include/metis.h" 2>/dev/null; then
    echo "ADVERTENCIA: el metis.h actual ya es el de compatibilidad de Scotch, no el real."
  else
    echo "OK: metis.h real detectado, este script no lo sobrescribira."
  fi
fi

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"

# -DINTSIZE64 controla SCOTCH_Num (el tipo que ve MUMPS/ParMETIS).
# -DIDXSIZE64 hace que SCOTCH_Idx tambien quede en 64 bits, para coherencia
# total con METIS/ParMETIS ya compilados en 64 bits.
export COMMON_CFLAGS="-fPIC -O2 -ffile-prefix-map=$DESTDIR= -DINTSIZE64 -DIDXSIZE64 -DCOMMON_FILE_COMPRESS_GZ -DCOMMON_RANDOM_FIXED_SEED -DSCOTCH_RENAME -DSCOTCH_PTHREAD -Drestrict=__restrict -DCOMMON_PTHREAD $CPPFLAGS"
export CFLAGS="$COMMON_CFLAGS -Wno-error=implicit-function-declaration"

export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -shared -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread -lz -lm"

VER="6.0.4"
SRC="$HOME/scotch-${VER}"

echo "=== Descargando Scotch/PT-Scotch 6.0.4 ==="
rm -rf "$SRC"
hg clone http://hg.code.sf.net/p/prereq/scotch "$SRC"

cd "$SRC/src" || exit 1

echo "=== Parche Bionic: deshabilitar backtrace/execinfo si common.c lo usa ==="
if [ -f "libscotch/common.c" ] && grep -q "execinfo.h" libscotch/common.c; then
  sed -i 's/#include <execinfo.h>/\/* execinfo.h deshabilitado para Bionic *\//' libscotch/common.c
  sed -i 's/backtrace(/\/\/backtrace(/g' libscotch/common.c
fi

echo "=== Configurando Makefile.inc para generacion de archivos (.a) ==="
cat << EOF > Makefile.inc
EXE =
LIB = .a
OBJ = .o

MAKE = make
AR = $AR
ARFLAGS = -ruv
CAT = cat
CCS = $CC
CCP = $CC
CCD = $CC
CFLAGS = $CFLAGS
CLIBFLAGS =
LDFLAGS = -lz -lm -lpthread

CP = cp
LEX = flex -Pscotchyy -olex.yy.c
LN = ln
MKDIR = mkdir -p
MV = mv
RANLIB = $RANLIB
YACC = bison -pscotchyy -y -b y
EOF

echo "=== Compilando Scotch Secuencial y sus dependencias de ESMUMPS ==="
make scotch esmumps -j"$(nproc)"

echo "=== Compilando PT-Scotch Paralelo y sus dependencias de PT-ESMUMPS ==="
make ptscotch ptesmumps -j"$(nproc)"

echo "=== Reempaquetando archivos .a en .so dinamicos (Metodo MUMPS) ==="
cd ../lib

convert_to_so() {
    local libname="$1"
    local deps="$2"
    if [ ! -f "${libname}.a" ]; then
      echo "ERROR: no se encontro ${libname}.a. Algo fallo en make."
      exit 1
    fi
    echo " -> Creando ${libname}.so"
    mkdir -p "tmp_${libname}"
    (cd "tmp_${libname}" && llvm-ar x "../${libname}.a")
    $CC $SHARED_LDFLAGS -o "${libname}.so" tmp_${libname}/*.o $deps
    rm -rf "tmp_${libname}"
}

convert_to_so libscotcherr ""
convert_to_so libscotcherrexit ""
convert_to_so libscotch "-L. -lscotcherr"
convert_to_so libesmumps "-L. -lscotch -lscotcherr"

convert_to_so libptscotcherr ""
convert_to_so libptscotcherrexit ""
convert_to_so libptscotch "-L. -lscotch -lptscotcherr"
convert_to_so libptesmumps "-L. -lptscotch -lptscotcherr -lesmumps -lscotch -lscotcherr"

echo "=== Instalando librerias y headers en fake_root ==="
cd ../src

# PARCHE INTEGRADO: excluir el metis.h de compatibilidad de Scotch,
# para NO sobrescribir el metis.h REAL (compilado en 64 bits desde la rama code_aster).
echo "--- Copiando headers de Scotch (excluyendo metis.h falso de compatibilidad) ---"
for h in ../include/*.h; do
  base="$(basename "$h")"
  if [ "$base" = "metis.h" ]; then
    echo "SALTANDO metis.h de compatibilidad de Scotch (no sobrescribe el METIS real)"
    continue
  fi
  cp -f "$h" "$FAKE_USR/include/"
done

# El metis.h de compatibilidad se guarda aparte, por si algun dia lo necesitas
mkdir -p "$FAKE_USR/include/scotch-metis-compat"
if [ -f "../include/metis.h" ]; then
  cp -f "../include/metis.h" "$FAKE_USR/include/scotch-metis-compat/metis.h"
fi

cp -r ../lib/*.so "$FAKE_USR/lib/"

echo "=== Bibliotecas Scotch/PT-Scotch instaladas en fake_root ==="
ls -lh "$FAKE_USR/lib/"*scotch* "$FAKE_USR/lib/"*esmumps* || true

echo "=== Verificando que metis.h REAL siga intacto tras la instalacion ==="
if [ -f "$FAKE_USR/include/metis.h" ]; then
  if grep -q "NOT THE ORIGINAL INCLUDE FILE" "$FAKE_USR/include/metis.h"; then
    echo "ERROR: metis.h fue sobrescrito por el de compatibilidad de Scotch."
    exit 1
  fi
  grep -E "^#define[[:space:]]+IDXTYPEWIDTH" "$FAKE_USR/include/metis.h" || echo "ADVERTENCIA: metis.h no tiene IDXTYPEWIDTH definido."
  echo "OK: metis.h real permanece intacto."
fi

echo "=== Verificando dependencias de libptscotch.so ==="
if [ -f "$FAKE_USR/lib/libptscotch.so" ]; then
    readelf -d "$FAKE_USR/lib/libptscotch.so" | grep NEEDED || true
fi

echo "=== Verificando alineacion 16KB ==="
if [ -f "$FAKE_USR/lib/libptscotch.so" ]; then
    readelf -l "$FAKE_USR/lib/libptscotch.so" | grep LOAD || true
fi

echo "=== VERIFICACION FINAL: Scotch/PT-Scotch en enteros largos (64-bit) ==="

grep -E "^#define[[:space:]]+(SCOTCH_Num|SCOTCH_Idx)" "$FAKE_USR/include/scotch.h" || true

cat > "$HOME/check_scotch_num.c" <<'EOC'
#include <stdio.h>
#include "scotch.h"
int main(void) {
    printf("sizeof(SCOTCH_Num)=%zu bytes (%zu bits)\n", sizeof(SCOTCH_Num), sizeof(SCOTCH_Num)*8);
    printf("sizeof(SCOTCH_Idx)=%zu bytes (%zu bits)\n", sizeof(SCOTCH_Idx), sizeof(SCOTCH_Idx)*8);
    return (sizeof(SCOTCH_Num) == 8) ? 0 : 1;
}
EOC

"$CC" -I"$FAKE_USR/include" -I"$TMX_PREFIX/include" "$HOME/check_scotch_num.c" \
  -o "$HOME/check_scotch_num" -L"$FAKE_USR/lib" -lscotch -lscotcherr -lz -lm -lpthread

if "$HOME/check_scotch_num"; then
  echo "OK: SCOTCH_Num confirmado en 64 bits"
else
  echo "ERROR: SCOTCH_Num NO quedo en 64 bits. Revisa CFLAGS (-DINTSIZE64)."
  exit 1
fi

rm -f "$HOME/check_scotch_num" "$HOME/check_scotch_num.c"

echo "=== RESULTADO: Scotch y PT-Scotch compilados y VERIFICADOS en enteros largos (64-bit) ==="
