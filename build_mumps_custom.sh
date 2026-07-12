#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin"

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"

export OPAL_DESTDIR="$DESTDIR"
export OPAL_PREFIX="$APP_PREFIX"
export OPAL_INCLUDEDIR="$FAKE_USR/include"

if [ ! -x "$FAKE_USR/bin/mpicc" ] || [ ! -x "$FAKE_USR/bin/mpifort" ]; then
  echo "ERROR: mpicc/mpifort no encontrados en $FAKE_USR/bin"
  exit 1
fi

export CC="$FAKE_USR/bin/mpicc"
export FC="$FAKE_USR/bin/mpifort"
export FL="$FAKE_USR/bin/mpifort"

export AR="llvm-ar"
export ARFLAGS="vr"
export RANLIB="llvm-ranlib"

echo "=== Verificando que METIS/ParMETIS/Scotch previos esten en 64 bits ==="

if [ ! -f "$FAKE_USR/include/metis.h" ]; then
  echo "ERROR: no se encontro $FAKE_USR/include/metis.h. Compila METIS antes de MUMPS."
  exit 1
fi

if grep -q "NOT THE ORIGINAL INCLUDE FILE" "$FAKE_USR/include/metis.h" 2>/dev/null; then
  echo "ERROR: metis.h es el de compatibilidad de Scotch, no el real. Restauralo antes de continuar."
  exit 1
fi

IDXW="$(grep -oE '^#define[[:space:]]+IDXTYPEWIDTH[[:space:]]+[0-9]+' "$FAKE_USR/include/metis.h" | awk '{print $3}' | tail -1 || true)"

if [ -z "$IDXW" ] || [ "$IDXW" != "64" ]; then
  echo "ERROR: metis.h no esta en IDXTYPEWIDTH=64 (valor encontrado: '${IDXW}'). Aborta antes de compilar MUMPS."
  exit 1
fi
echo "OK: METIS confirmado en 64 bits, MUMPS puede compilarse en modo INTSIZE64"

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"
export OPTC="-fPIC -O2 -ffile-prefix-map=$DESTDIR= -DINTSIZE64 -Wno-error=implicit-function-declaration -Wno-format -Wno-absolute-value $CPPFLAGS"

# CORRECCION CLAVE: se elimina "-fdefault-integer-8" de OPTF.
# MUMPS ya usa macros #ifdef INTSIZE64 dentro de los .F para promover a
# INTEGER(8) SOLO donde corresponde, dejando adrede en INTEGER de 4 bytes
# las interfaces que deben coincidir con MPI estandar (id%COMM, etc).
export OPTF="-fPIC -O2 -ffile-prefix-map=$DESTDIR= -cpp -DINTSIZE64 -fallow-argument-mismatch $CPPFLAGS"

export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -shared -L$FAKE_USR/lib -L$TMX_PREFIX/lib -landroid-shmem -landroid-posix-semaphore -lpthread"

SRC="$HOME/mumps-aster"

echo "=== Descargando MUMPS 5.1.1 (rama for_aster) ==="
rm -rf "$SRC"
hg clone -b for_aster http://hg.code.sf.net/p/prereq/mumps "$SRC"

cd "$SRC" || exit 1

echo "=== Configurando Makefile.inc ==="
rm -f Makefile.inc

{
  echo "LPORDDIR    = $SRC/PORD/lib"
  echo "IPORD       = -I$SRC/PORD/include"
  echo "LPORD       = -L\$(LPORDDIR) -lpord"
  echo "IMETIS      = -I$FAKE_USR/include"
  echo "LMETIS      = -L$FAKE_USR/lib -lparmetis -lmetis"
  echo "ISCOTCH     = -I$FAKE_USR/include"
  echo "LSCOTCH     = -L$FAKE_USR/lib -lptesmumps -lptscotch -lptscotcherr -lscotch -lscotcherr"
  echo "ORDERINGSF  = -Dmetis -Dpord -Dparmetis -Dscotch -Dptscotch"
  echo "CDEFS       = -DINTSIZE64 -DAdd_"
  echo "CC          = $CC"
  echo "OPTC        = $OPTC"
  echo "FC          = $FC"
  echo "FL          = $FL"
  echo "OPTF        = $OPTF"
  echo "OPTL        = -O2"
  echo "INCPAR      = -I$FAKE_USR/include"
  echo "LIBPAR      = -L$FAKE_USR/lib -lscalapack -lopenblas"
  echo "INCSEQ      ="
  echo "LIBSEQ      ="
  echo "AR          = $AR $ARFLAGS "
  echo "RANLIB      = $RANLIB"
  echo "OUTC        = -o "
  echo "OUTF        = -o "
  echo "RM          = rm -f"
  echo "LIBEXT      = .a"
} >> Makefile.inc

echo "--- Contenido de Makefile.inc generado ---"
cat Makefile.inc

echo "=== Limpieza preventiva (por si quedan .mod/.o de intentos previos) ==="
make clean 2>/dev/null || true
find "$SRC" -name "*.mod" -delete 2>/dev/null || true
find "$SRC" -name "*.o" -delete 2>/dev/null || true

echo "=== Compilando PORD manualmente ==="
cd PORD/lib
for file in graph.c gbipart.c gbisect.c ddcreate.c ddbisect.c nestdiss.c multisector.c gelim.c bucket.c tree.c symbfac.c interface.c sort.c minpriority.c; do
    echo "Compilando $file..."
    $CC -I../include $OPTC -c "$file" -o "${file%.c}.o"
done

echo "Empaquetando libpord.a..."
$AR $ARFLAGS libpord.a *.o
$RANLIB libpord.a
cd ../../

mkdir -p lib
cp PORD/lib/libpord.a lib/libpord.a

echo "=== Compilando el resto de MUMPS (usando TODOS los nucleos disponibles) ==="
NCPU="$(nproc)"
echo "Usando -j${NCPU} nucleos"
make d -j"$NCPU"
make z -j"$NCPU"
make s -j"$NCPU"
make c -j"$NCPU"

echo "=== Transformando archivos estaticos .a en .so ==="
cd lib

convert_to_so() {
    local libname="$1"
    local deps="$2"
    if [ ! -f "${libname}.a" ]; then
      echo "ERROR: la biblioteca ${libname}.a no se genero."
      exit 1
    fi
    echo " -> Transformando ${libname}.so"
    mkdir -p "tmp_${libname}"
    (cd "tmp_${libname}" && llvm-ar x "../${libname}.a")
    $FC $SHARED_LDFLAGS -o "${libname}.so" tmp_${libname}/*.o $deps
    rm -rf "tmp_${libname}"
}

convert_to_so libpord ""
convert_to_so libmumps_common "-L. -lpord -L$FAKE_USR/lib -lptesmumps -lptscotch -lptscotcherr -lscotch -lscotcherr -lparmetis -lmetis -lscalapack -lopenblas"
convert_to_so libsmumps "-L. -lmumps_common"
convert_to_so libdmumps "-L. -lmumps_common"
convert_to_so libcmumps "-L. -lmumps_common"
convert_to_so libzmumps "-L. -lmumps_common"

echo "=== Instalando MUMPS en fake_root ==="
cd ../
cp -r include/*.h "$FAKE_USR/include/"
cp -r lib/*.so "$FAKE_USR/lib/"

echo "=== Verificando Dependencias ==="
if [ -f "$FAKE_USR/lib/libdmumps.so" ]; then
    readelf -d "$FAKE_USR/lib/libdmumps.so" | grep NEEDED || true
    echo "--- Alineacion ---"
    readelf -l "$FAKE_USR/lib/libdmumps.so" | grep LOAD || true
fi

echo "=== VERIFICACION FINAL: MUMPS en enteros largos (64-bit) ==="

grep -E "MUMPS_INTSIZE64|MUMPS_INT" "$FAKE_USR/include/mumps_c_types.h" || true

cat > "$HOME/check_mumps_int.c" <<'EOC'
#include <stdio.h>
#include "mumps_c_types.h"
int main(void) {
#ifdef INTSIZE64
    printf("INTSIZE64 esta definido (activado via -DINTSIZE64)\n");
#else
    printf("INTSIZE64 NO esta definido\n");
#endif
    printf("sizeof(MUMPS_INT)=%zu bytes (%zu bits)\n", sizeof(MUMPS_INT), sizeof(MUMPS_INT)*8);
    printf("sizeof(MUMPS_INT8)=%zu bytes (%zu bits)\n", sizeof(MUMPS_INT8), sizeof(MUMPS_INT8)*8);
    return (sizeof(MUMPS_INT) == 8) ? 0 : 1;
}
EOC

"$CC" -DINTSIZE64 -I"$FAKE_USR/include" "$HOME/check_mumps_int.c" -o "$HOME/check_mumps_int"

if "$HOME/check_mumps_int"; then
  echo "OK: MUMPS_INT confirmado en 64 bits"
else
  echo "ERROR: MUMPS_INT NO quedo en 64 bits."
  exit 1
fi

rm -f "$HOME/check_mumps_int" "$HOME/check_mumps_int.c"

echo "=== RESULTADO: MUMPS 5.1.1 (for_aster) compilado y VERIFICADO en enteros largos (64-bit) ==="
