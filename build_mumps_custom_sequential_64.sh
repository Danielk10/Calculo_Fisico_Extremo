#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/include_seq" "$FAKE_USR/lib" "$FAKE_USR/bin"

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"

# --- Compiladores nativos (sin MPI) ---
export CC="$TMX_PREFIX/bin/clang"
export FC="$TMX_PREFIX/bin/gfortran"
export FL="$TMX_PREFIX/bin/gfortran"

if [ ! -x "$CC" ] || [ ! -x "$FC" ]; then
  echo "ERROR: clang/gfortran no encontrados en $TMX_PREFIX/bin"
  exit 1
fi

export AR="llvm-ar"
export ARFLAGS="vr"
export RANLIB="llvm-ranlib"

echo "=== Verificando que METIS/Scotch previos esten en 64 bits ==="

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

# ---------- tolerar el mismatch INTEGER(4)/INTEGER(8) de gfortran 14 en libseq ----------
export OPTF="-fPIC -O2 -ffile-prefix-map=$DESTDIR= -cpp -DINTSIZE64 -fallow-argument-mismatch -w $CPPFLAGS"

export SHARED_LDFLAGS="-fuse-ld=lld -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -shared -L$FAKE_USR/lib -L$TMX_PREFIX/lib -lpthread"

SRC="$HOME/mumps-aster"

echo "=== Descargando MUMPS (rama for_aster) ==="
rm -rf "$SRC"
hg clone -b for_aster http://hg.code.sf.net/p/prereq/mumps "$SRC"

cd "$SRC" || exit 1

echo "=== Detectando version real del repositorio clonado ==="
MUMPS_VERSION_RAW="$(tr -d '\r' < "$SRC/VERSION" 2>/dev/null | head -n 1 || true)"
if [ -z "$MUMPS_VERSION_RAW" ]; then
  echo "ERROR: no se pudo leer $SRC/VERSION"
  exit 1
fi
MUMPS_VERSION_CLEAN="$(printf '%s\n' "$MUMPS_VERSION_RAW" | sed -E 's/^MUMPS[[:space:]]+//; s/[[:space:]]+$//')"
echo "VERSION detectada en repo: $MUMPS_VERSION_RAW"
echo "VERSION limpia para waf: $MUMPS_VERSION_CLEAN"

echo "=== Configurando Makefile.inc (modo SECUENCIAL) ==="
rm -f Makefile.inc

# ---------- mantener \$(topdir) y \$(LPORDDIR) literales para make ----------
{
  echo 'LPORDDIR    = $(topdir)/PORD'
  echo 'IPORD       = -I$(LPORDDIR)/include'
  echo 'LPORD       = -L$(LPORDDIR)/lib -lpord'
  echo "IMETIS      = -I$FAKE_USR/include"
  echo "LMETIS      = -L$FAKE_USR/lib -lmetis"
  echo "ISCOTCH     = -I$FAKE_USR/include"
  echo "LSCOTCH     = -L$FAKE_USR/lib -lesmumps -lscotch -lscotcherr"
  echo "ORDERINGSF  = -Dmetis -Dpord -Dscotch"
  echo "CDEFS       = -DINTSIZE64 -DAdd_"
  echo "CC          = $CC"
  echo "OPTC        = $OPTC"
  echo "FC          = $FC"
  echo "FL          = $FL"
  echo "OPTF        = $OPTF"
  echo "OPTL        = -O2"
  echo "INCPAR      ="
  echo "LIBPAR      ="
  echo 'INCSEQ      = -I$(topdir)/libseq'
  echo 'LIBSEQ      = -L$(topdir)/libseq -lmpiseq'
  echo "LIBSEQNEEDED = libseqneeded"
  echo "LIBBLAS     = -L$FAKE_USR/lib -lopenblas"
  echo "LIBOTHERS   = -lpthread"
  echo "AR          = $AR $ARFLAGS "
  echo "RANLIB      = $RANLIB"
  echo "OUTC        = -o "
  echo "OUTF        = -o "
  echo "RM          = rm -f"
  echo "LIBEXT      = .a"
} >> Makefile.inc

echo "--- Contenido de Makefile.inc generado ---"
cat Makefile.inc

echo "=== Limpieza preventiva (por si quedan .mod/.o/.a de intentos previos) ==="
make clean 2>/dev/null || true
find "$SRC" -name "*.mod" -delete 2>/dev/null || true
find "$SRC" -name "*.o" -delete 2>/dev/null || true
find "$SRC" -name "*.a" -delete 2>/dev/null || true

echo "=== Compilando PORD manualmente (CORREGIDO) ==="
cd PORD/lib
# Se cambia la lista estática por *.c para incorporar pordf_wnd.c dinámicamente
for file in *.c; do
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

echo "=== Verificando que libseq haya generado libmpiseq.a ==="
if [ ! -f "$SRC/libseq/libmpiseq.a" ]; then
  echo "ERROR: no se genero $SRC/libseq/libmpiseq.a"
  exit 1
fi

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
convert_to_so libmumps_common "-L. -lpord -L$FAKE_USR/lib -lesmumps -lscotch -lscotcherr -lmetis -lopenblas -L../libseq -lmpiseq"
convert_to_so libsmumps "-L. -lmumps_common"
convert_to_so libdmumps "-L. -lmumps_common"
convert_to_so libcmumps "-L. -lmumps_common"
convert_to_so libzmumps "-L. -lmumps_common"

echo "=== Instalando MUMPS en fake_root (preservando include/ y include_seq/ SEPARADOS) ==="
cd ../

# include/ -> headers principales MUMPS
cp -f include/*.h "$FAKE_USR/include/"

# libseq/ -> headers secuenciales, separados para waf de Code_Aster
cp -f libseq/*.h "$FAKE_USR/include_seq/" 2>/dev/null || true

# bibliotecas compartidas generadas
cp -f lib/*.so "$FAKE_USR/lib/"

# biblioteca estatica secuencial que waf y/o el link final pueden necesitar
cp -f libseq/libmpiseq.a "$FAKE_USR/lib/"

# metadata de version: generar siempre desde VERSION real del repo
printf '%s\n' "$MUMPS_VERSION_CLEAN" > "$FAKE_USR/include/MUMPS_VERSION_INFO"
echo "MUMPS_VERSION_INFO generado: $(cat "$FAKE_USR/include/MUMPS_VERSION_INFO")"

echo "=== Verificacion de copia a fake_root ==="
for f in \
  "$FAKE_USR/include/dmumps_c.h" \
  "$FAKE_USR/include/mumps_c_types.h" \
  "$FAKE_USR/include_seq/mpif.h" \
  "$FAKE_USR/lib/libdmumps.so" \
  "$FAKE_USR/lib/libzmumps.so" \
  "$FAKE_USR/lib/libsmumps.so" \
  "$FAKE_USR/lib/libcmumps.so" \
  "$FAKE_USR/lib/libmumps_common.so" \
  "$FAKE_USR/lib/libpord.so" \
  "$FAKE_USR/lib/libmpiseq.a" \
  "$FAKE_USR/include/MUMPS_VERSION_INFO"; do
  if [ ! -e "$f" ]; then
    echo "ERROR: falta artefacto instalado: $f"
    exit 1
  fi
done
echo "OK: copia de headers, include_seq, .so, libmpiseq.a y MUMPS_VERSION_INFO verificada"

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

echo "=== RESULTADO: MUMPS (for_aster) SECUENCIAL compilado y VERIFICADO ==="
echo "Version instalada: $MUMPS_VERSION_CLEAN"
echo "Headers MUMPS en: $FAKE_USR/include"
echo "Headers secuenciales en: $FAKE_USR/include_seq"
echo "Bibliotecas en: $FAKE_USR/lib"
