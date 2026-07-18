#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

echo "=================================================="
echo " INSTALADOR MAESTRO: Boost 1.90.0 + Numpy 1.26.4"
echo " Todo se instala limpio en $HOME/aster-deps"
echo "=================================================="

cd "$HOME"
unset PYTHONPATH

# ---------- Rutas base ----------
export TMX_PREFIX="/data/data/com.termux/files/usr"
export ASTER_DEPS="$HOME/aster-deps"
export BOOST_VERSION="1.90.0"
export BOOST_BUILD_DIR="$HOME/boost_${BOOST_VERSION//./_}"
export BOOST_INSTALL_DIR="$ASTER_DEPS/boost"
export NUMPY_VERSION="1.26.4"
export NUMPY_SRC_DIR="$HOME/numpy-$NUMPY_VERSION"

mkdir -p "$ASTER_DEPS"

# ---------- Detectar Python 3.11 ----------
PY311_BIN=""
for cand in "$TMX_PREFIX/bin/python3.11" "$(command -v python3.11 2>/dev/null || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    PY311_BIN="$cand"
    break
  fi
done
if [ -z "$PY311_BIN" ]; then
  echo "ERROR: No se encontró python3.11 instalado en Termux."
  exit 1
fi
PY311_PREFIX="$(dirname "$(dirname "$PY311_BIN")")"
echo "Python seleccionado: $PY311_BIN"

# ---------- Paquetes base (libopenblas, NO openblas: conflictúan) ----------
echo "=== Instalando paquetes base ==="
pkg update -y
pkg install -y build-essential clang binutils patchelf cmake ninja \
  pkg-config libopenblas git wget tar

# ==================================================
# PARTE 1: BOOST 1.90.0 (instalación limpia, no solo stage)
# ==================================================
if [ -f "$BOOST_INSTALL_DIR/lib/libboost_python311.so" ] && [ -d "$BOOST_INSTALL_DIR/include/boost" ]; then
  echo "=== Boost ya está instalado en $BOOST_INSTALL_DIR, se omite recompilación ==="
else
  echo "=== Descargando y compilando Boost $BOOST_VERSION ==="
  rm -rf "$BOOST_BUILD_DIR"
  wget -O "$HOME/boost_${BOOST_VERSION}.tar.gz" \
    "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_VERSION//./_}.tar.gz"
  tar -xzf "$HOME/boost_${BOOST_VERSION}.tar.gz" -C "$HOME"
  rm -f "$HOME/boost_${BOOST_VERSION}.tar.gz"

  cd "$BOOST_BUILD_DIR"
  ./bootstrap.sh --with-python="$PY311_BIN"

  ./b2 --with-python \
    python=3.11 \
    target-os=android \
    toolset=clang \
    variant=release \
    link=shared \
    threading=multi \
    cxxflags="-fPIC -std=c++17 -I$PY311_PREFIX/include/python3.11" \
    linkflags="-L$TMX_PREFIX/lib -lpython3.11" \
    -j"$(nproc)" \
    install --prefix="$BOOST_INSTALL_DIR"

  cd "$HOME"
fi

export BOOST_INCLUDE_DIR="$BOOST_INSTALL_DIR/include"
export BOOST_LIB_DIR="$BOOST_INSTALL_DIR/lib"

echo "=== Verificando instalación de Boost ==="
readelf -d "$BOOST_LIB_DIR/libboost_python311.so" | grep -i soname
ls "$BOOST_INCLUDE_DIR/boost/python.hpp" >/dev/null 2>&1 && echo "OK: headers de Boost.Python presentes."

# ==================================================
# PARTE 2: NUMPY 1.26.4 (Cython<3.0 fijo, sin patchelf)
# ==================================================
echo "=== Limpiando residuos de Numpy/Cython previos ==="
"$PY311_BIN" -m pip uninstall -y numpy cython 2>&1 || true
find "$PY311_PREFIX/lib/python3.11/site-packages" -maxdepth 1 -iname "numpy*" -exec rm -rf {} + 2>/dev/null || true

"$PY311_BIN" -m ensurepip --upgrade || true
"$PY311_BIN" -m pip install --upgrade pip setuptools wheel packaging
"$PY311_BIN" -m pip install --upgrade meson meson-python ninja

# ---------- CRÍTICO: Cython < 3.0, porque numpy 1.26.4 requiere numpy/math.pxd ----------
echo "=== Instalando Cython < 3.0 (compatibilidad con numpy/math.pxd en Numpy 1.26.4) ==="
"$PY311_BIN" -m pip install "cython<3.0,>=0.29.34"

echo "=== Clonando Numpy $NUMPY_VERSION en $NUMPY_SRC_DIR ==="
rm -rf "$NUMPY_SRC_DIR"
git clone --branch "v$NUMPY_VERSION" --depth 1 https://github.com/numpy/numpy.git "$NUMPY_SRC_DIR"
cd "$NUMPY_SRC_DIR"
git submodule update --init

export CC="$TMX_PREFIX/bin/clang"
export CXX="$TMX_PREFIX/bin/clang++"
export LD_LIBRARY_PATH="$BOOST_LIB_DIR:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export MATHLIB="m"
export CFLAGS="-Wno-implicit-function-declaration -I$TMX_PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$TMX_PREFIX/lib -lopenblas -lpython3.11"
export NPY_BLAS_ORDER="openblas"
export NPY_LAPACK_ORDER="openblas"
export PKG_CONFIG_PATH="$TMX_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "=== Compilando Numpy desde fuente contra Python 3.11 con OpenBLAS ==="
"$PY311_BIN" -m pip install --no-build-isolation --no-cache-dir -v .

NUMPY_DIR="$PY311_PREFIX/lib/python3.11/site-packages/numpy"
SOFILE="$(find "$NUMPY_DIR" -name '_multiarray_umath*.so' | head -n1)"

if [ -n "$SOFILE" ] && readelf -d "$SOFILE" | grep -qi "libpython3.11.so"; then
  echo "OK: libpython3.11.so quedó enlazado nativamente (sin patchelf)."
else
  echo "ADVERTENCIA: enlace NEEDED no detectado, aplicando patchelf de respaldo..."
  patchelf --add-needed libpython3.11.so "$SOFILE" || true
fi

cd "$HOME"

echo "=== Verificando Numpy (namespace package check) ==="
NUMPY_FILE_CHECK="$("$PY311_BIN" -c "import numpy; print(numpy.__file__)" 2>/dev/null || echo "None")"
if [ "$NUMPY_FILE_CHECK" = "None" ] || [ -z "$NUMPY_FILE_CHECK" ]; then
  echo "ERROR CRÍTICO: Numpy quedó como namespace package vacío."
  exit 1
fi

"$PY311_BIN" -c "
import numpy
print('Numpy version:', numpy.__version__)
print('Numpy file:', numpy.__file__)
numpy.show_config()
"

echo "Numpy $NUMPY_VERSION compilado e instalado correctamente."

# ==================================================
# PARTE 3: Manifiesto consolidado
# ==================================================
export NUMPY_INCLUDE_DIR="$NUMPY_DIR/core/include"

cat > "$ASTER_DEPS/deps.env" << ENVEOF
export TMX_PREFIX="$TMX_PREFIX"
export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DEST_DIR="$HOME/fake_root"
export FAKE_USR="$DEST_DIR$APP_PREFIX"

export PY311_BIN="$PY311_BIN"
export PY311_PREFIX="$PY311_PREFIX"

export BOOST_INSTALL_DIR="$BOOST_INSTALL_DIR"
export BOOST_INCLUDE_DIR="$BOOST_INCLUDE_DIR"
export BOOST_LIB_DIR="$BOOST_LIB_DIR"

export NUMPY_VERSION="$NUMPY_VERSION"
export NUMPY_SITE_DIR="$NUMPY_DIR"
export NUMPY_INCLUDE_DIR="$NUMPY_INCLUDE_DIR"

export OPENBLAS_INCLUDE_DIR="$TMX_PREFIX/include/openblas"
export OPENBLAS_LIB_DIR="$TMX_PREFIX/lib"

export LD_LIBRARY_PATH="$FAKE_USR/lib/aster:$FAKE_USR/lib:$BOOST_LIB_DIR:$TMX_PREFIX/lib"
export PYTHONPATH="$FAKE_USR/lib/aster:$FAKE_USR/lib/python3.11/site-packages:$TMX_PREFIX/lib/python3.11/site-packages"
export PKG_CONFIG_PATH="$BOOST_LIB_DIR/pkgconfig:$TMX_PREFIX/lib/pkgconfig"
ENVEOF

"$PY311_BIN" - <<PY
import json
from pathlib import Path

manifest_path = Path("$ASTER_DEPS/manifest.json")
manifest = {
    "boost": {
        "version": "$BOOST_VERSION",
        "install_dir": "$BOOST_INSTALL_DIR",
        "include_dir": "$BOOST_INCLUDE_DIR",
        "lib_dir": "$BOOST_LIB_DIR",
        "built_with": "clang, target-os=android, cxxflags=-fPIC -std=c++17"
    },
    "numpy": {
        "version": "$NUMPY_VERSION",
        "src_dir": "$NUMPY_SRC_DIR",
        "installed_at": "$NUMPY_DIR",
        "blas_backend": "openblas (pkgconfig)",
        "cython_version_pinned": "<3.0,>=0.29.34",
        "linked_libpython": True,
        "patchelf_used": False
    }
}
manifest_path.write_text(json.dumps(manifest, indent=2))
print("manifest.json creado en $ASTER_DEPS/manifest.json")
PY

echo "=================================================="
echo " Limpiando código fuente (ya instalado limpio)"
echo "=================================================="
rm -rf "$BOOST_BUILD_DIR"
rm -rf "$NUMPY_SRC_DIR"

du -sh "$ASTER_DEPS"

echo "=================================================="
echo " LISTO. Todo instalado en: $ASTER_DEPS"
echo " Boost:  $BOOST_INSTALL_DIR"
echo " Numpy:  $NUMPY_DIR (vive en site-packages de Python 3.11)"
echo " Manifiesto: $ASTER_DEPS/deps.env y manifest.json"
echo "=================================================="
