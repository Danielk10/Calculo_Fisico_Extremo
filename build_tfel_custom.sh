#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin" "$FAKE_USR/share"

echo "=== Usando Python 3.11 pre-instalado ==="
PY311_BIN="/data/data/com.termux/files/usr/bin/python3.11"
if [ ! -x "$PY311_BIN" ]; then
  echo "ERROR: No se encontró python3.11 en $PY311_BIN"
  exit 1
fi
echo "=== Python seleccionado: $PY311_BIN ==="

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$FAKE_USR/lib/pkgconfig:$TMX_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

export CC=clang
export CXX=clang++
export FC=gfortran
export F77=gfortran
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= $CPPFLAGS"
export FFLAGS="-fPIC -fPIE -O2"
export FCFLAGS="-fPIC -fPIE -O2"

# CORRECCIÓN 1: Se añade -lexecinfo. TFEL maneja excepciones C++ complejas y trazas de error;
# al tener instalado libandroid-execinfo, evitamos "undefined reference to backtrace" en tiempo de ejecución.
export SHARED_LDFLAGS="-Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -lexecinfo -landroid-posix-semaphore -landroid-shmem -lpthread"
export EXE_LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -lexecinfo -landroid-posix-semaphore -landroid-shmem -lpthread"

export CMAKE_PREFIX_PATH="$FAKE_USR;$TMX_PREFIX"

SRC="$HOME/tfel"
BUILD="$HOME/tfel-build"

rm -rf "$SRC" "$BUILD"

echo "=== Clonando TFEL/MFront ==="
git clone --depth 1 https://github.com/thelfer/tfel.git "$SRC"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

echo "=== Verificando nombre real de la opción Aster en el árbol de fuentes ==="
grep -ri "aster" "$SRC/CMakeLists.txt" 2>/dev/null | grep -i "option" || true
grep -rli "enable-aster" "$SRC" --include="CMakeLists.txt" 2>/dev/null || true

echo "=== Configurando TFEL/MFront ==="
# CORRECCIÓN 2: Se inyecta RPATH explícito. Si no lo hacemos, cuando Code_Aster intente
# invocar las librerías dinámicas de TFEL fuera de Termux, no sabrá dónde encontrarse entre sí.
# CORRECCIÓN 3 (LA CRÍTICA): Se añade -Denable-aster=ON. Sin esta bandera, CMake nunca
# construye la interfaz específica de Code_Aster y por eso "libAsterInterface" no se genera,
# lo que hace fallar el ./waf configure de Code_Aster con "Checking for library AsterInterface: not found".
# CORRECCIÓN 4: -Denable-mfront=ON y -Denable-cyrano=ON explícitos, ya que Code_Aster
# también usa la interfaz Cyrano de MFront para ciertos comportamientos y algunas versiones
# de TFEL desactivan estos módulos por defecto si no se declaran.
export Python_EXECUTABLE="$PY311_BIN"

cmake "$SRC" \
  -Wno-dev \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$APP_PREFIX" \
  -DCMAKE_INSTALL_RPATH="$APP_PREFIX/lib" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DPython_EXECUTABLE="$PY311_BIN" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_Fortran_COMPILER="$FC" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_Fortran_FLAGS="$FFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXE_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SHARED_LDFLAGS" \
  -DCMAKE_MODULE_LINKER_FLAGS="$SHARED_LDFLAGS" \
  -DCMAKE_Fortran_IMPLICIT_LINK_LIBRARIES="gfortran;m;dl;lexecinfo;android-posix-semaphore;android-shmem;pthread" \
  -DTFEL_APPEND_VERSION=OFF \
  -Denable-portable-build=ON \
  -Denable-static=OFF \
  -Denable-python=ON \
  -Denable-python-bindings=ON \
  -Denable-fortran=ON \
  -Denable-fortran-bindings=ON \
  -Denable-doc=OFF \
  -Denable-doxygen-doc=OFF \
  -Denable-website=OFF \
  -Denable-mfront=ON \
  -Denable-aster=ON \
  -Denable-cyrano=ON \
  -Denable-castem=OFF \
  -Denable-abaqus=OFF \
  -Denable-ansys=OFF \
  -Denable-europlexus=OFF \
  -Denable-calculix=OFF \
  -Denable-comsol=OFF \
  -Denable-diana-fea=OFF \
  -Denable-lsdyna=OFF \
  -Denable-zmat=OFF

echo "=== Compilando TFEL/MFront con todos los núcleos ==="
cmake --build . -j"$(nproc)" --verbose

echo "=== Instalando TFEL/MFront ==="
DESTDIR="$DESTDIR" cmake --install .

echo "=== Binarios instalados ==="
find "$FAKE_USR/bin" -maxdepth 1 \( \
  -name 'mfront*' -o \
  -name 'mtest*' -o \
  -name 'tfel-config*' -o \
  -name 'tfel-check*' \
\) | sort || true

echo "=== Bibliotecas TFEL instaladas ==="
find "$FAKE_USR/lib" -maxdepth 1 \( \
  -name 'libTFEL*' -o \
  -name 'libMFront*' \
\) | sort | head -n 300 || true

echo "=== VERIFICACIÓN CRÍTICA: libAsterInterface ==="
ASTER_LIB="$(find "$FAKE_USR/lib" -maxdepth 1 -iname 'libAsterInterface*' | head -n 1 || true)"
if [ -n "${ASTER_LIB:-}" ] && [ -f "$ASTER_LIB" ]; then
  echo "OK: libAsterInterface encontrada en: $ASTER_LIB"
  readelf -d "$ASTER_LIB" | grep NEEDED || true
else
  echo "ERROR CRÍTICO: libAsterInterface.so NO se generó."
  echo "Revisa la salida del grep de arriba para confirmar el nombre exacto de la opción CMake"
  echo "en esta versión de TFEL (puede variar entre 'enable-aster' y otras variantes)."
  exit 1
fi

echo "=== Share / CMake instalados ==="
find "$FAKE_USR/share" -maxdepth 4 \( \
  -iname '*tfel*' -o \
  -iname '*mfront*' \
\) | sort | head -n 300 || true

echo "=== Test rápido de tfel-config ==="
TFELCFG="$(find "$FAKE_USR/bin" -maxdepth 1 -type f -name 'tfel-config*' | head -n 1 || true)"
if [ -n "${TFELCFG:-}" ] && [ -x "$TFELCFG" ]; then
  "$TFELCFG" --include-path || true
fi

echo "=== Test rápido de mfront ==="
MFRONT_BIN="$(find "$FAKE_USR/bin" -maxdepth 1 -type f -name 'mfront*' | head -n 1 || true)"
if [ -n "${MFRONT_BIN:-}" ] && [ -x "$MFRONT_BIN" ]; then
  "$MFRONT_BIN" --help 2>/dev/null | head -n 20 || true
fi

echo "=== Dependencias de una biblioteca TFEL ==="
TFEL_SO="$(find "$FAKE_USR/lib" -maxdepth 1 -name 'libTFEL*.so' | head -n 1 || true)"
if [ -n "${TFEL_SO:-}" ] && [ -f "$TFEL_SO" ]; then
  readelf -d "$TFEL_SO" | grep NEEDED || true
  echo "=== Alineación 16KB ==="
  readelf -l "$TFEL_SO" | grep LOAD || true
fi

echo "=== Dependencias de tfel-check ==="
TFEL_CHECK_BIN="$(find "$BUILD" -type f -name 'tfel-check*' | head -n 1 || true)"
if [ -n "${TFEL_CHECK_BIN:-}" ] && [ -f "$TFEL_CHECK_BIN" ]; then
  readelf -d "$TFEL_CHECK_BIN" | grep NEEDED || true
fi

echo "=== TFEL/MFront compilado correctamente (con AsterInterface) ==="
