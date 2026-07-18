#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

# ---------- Cargar manifiesto de dependencias ya compiladas (Boost + Numpy) ----------
if [ ! -f "$HOME/aster-deps/deps.env" ]; then
  echo "ERROR: No se encontró $HOME/aster-deps/deps.env."
  echo "Corre primero build_all_deps.sh que genera ese manifiesto."
  exit 1
fi
source "$HOME/aster-deps/deps.env"

# ---------- CRÍTICO: limpiar PYTHONPATH residual de sesiones/intentos anteriores ----------
unset PYTHONPATH

export DESTDIR="$DEST_DIR"
export FAKE_USR="$DESTDIR$APP_PREFIX"

# ---------- Verificar que el manifiesto apunte a rutas reales ----------
echo "=== Verificando manifiesto de dependencias ==="
for var in PY311_BIN BOOST_INCLUDE_DIR BOOST_LIB_DIR NUMPY_INCLUDE_DIR TMX_PREFIX; do
  val="${!var:-}"
  if [ -z "$val" ]; then
    echo "ERROR: La variable $var no está definida en deps.env."
    exit 1
  fi
done

if [ ! -x "$PY311_BIN" ]; then
  echo "ERROR: PY311_BIN ($PY311_BIN) no es ejecutable."
  exit 1
fi
if [ ! -f "$BOOST_LIB_DIR/libboost_python311.so" ]; then
  echo "ERROR: No se encontró $BOOST_LIB_DIR/libboost_python311.so."
  echo "Corre build_all_deps.sh antes de continuar."
  exit 1
fi
if [ ! -d "$BOOST_INCLUDE_DIR/boost" ]; then
  echo "ERROR: No se encontró $BOOST_INCLUDE_DIR/boost (headers de Boost)."
  exit 1
fi
if [ ! -d "$NUMPY_INCLUDE_DIR" ]; then
  echo "ERROR: No se encontró $NUMPY_INCLUDE_DIR (headers de Numpy)."
  echo "Verifica que Numpy 1.26.4 esté instalado correctamente."
  exit 1
fi
echo "OK: manifiesto verificado. Boost en $BOOST_LIB_DIR, Numpy headers en $NUMPY_INCLUDE_DIR."

# ---------- NO borrar fake_root: ahí viven MUMPS/METIS/SCOTCH/HDF5/MED ya compilados ----------
# ---------- Solo se limpia el árbol fuente de Code_Aster, nunca las dependencias en fake_root ----------
echo "=== Limpiando únicamente el árbol fuente de Code_Aster (src-15.5.0) ==="
rm -rf "$HOME/src-15.5.0"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/include_seq" "$FAKE_USR/lib" "$FAKE_USR/bin" "$FAKE_USR/lib/pkgconfig"

echo "=== Verificando dependencias numéricas ya compiladas en fake_root ==="
for lib in libmetis.so libscotch.so libhdf5_hl_fortran.so libmed.so libdmumps.so; do
  if [ ! -f "$FAKE_USR/lib/$lib" ] && [ ! -f "$TMX_PREFIX/lib/$lib" ]; then
    echo "ADVERTENCIA: no se encontró $lib en $FAKE_USR/lib ni $TMX_PREFIX/lib."
    echo "Verifica que Metis/Scotch/HDF5/MED/MUMPS estén compilados antes de continuar."
  fi
done

export ORIGINAL_PATH="$PATH"

echo "=== Creando wrapper de enlazador robusto (via -B, ignora -fuse-ld) ==="
LD_WRAPPER_DIR="$HOME/ld_wrapper"
mkdir -p "$LD_WRAPPER_DIR"
cat > "$LD_WRAPPER_DIR/ld" <<'LDEOF'
#!/data/data/com.termux/files/usr/bin/bash
args=("$@")
if [[ " ${args[*]} " == *" -shared "* ]]; then
filtered=()
for a in "${args[@]}"; do
[[ "$a" == "-pie" ]] && continue
filtered+=("$a")
done
exec -a ld.lld "/data/data/com.termux/files/usr/bin/ld.lld" -L/system/lib64 -z execstack "${filtered[@]}"
else
exec -a ld.lld "/data/data/com.termux/files/usr/bin/ld.lld" -L/system/lib64 -z execstack "$@"
fi
LDEOF
chmod +x "$LD_WRAPPER_DIR/ld"
echo "Wrapper creado en: $LD_WRAPPER_DIR/ld"

echo "=== Actualizando paquetes base ==="
pkg update -y
pkg install -y \
tur-repo \
wget tar make clang binutils grep sed coreutils findutils gawk \
ninja patchelf cmake build-essential pkg-config \
libandroid-shmem libandroid-posix-semaphore \
gcc-default-14

echo "=== Python 3.11 (desde deps.env): $PY311_BIN ==="

echo "=== Habilitando pip para Python 3.11 ==="
"$PY311_BIN" -m ensurepip --upgrade || true

echo "=== Instalando dependencias Python para Code_Aster ==="
"$PY311_BIN" -m pip install --upgrade pip setuptools wheel packaging
"$PY311_BIN" -m pip install meson meson-python ninja patchelf

echo "=== Verificando Numpy $NUMPY_VERSION (ya compilado desde fuente, con OpenBLAS) ==="
NUMPY_FILE="$("$PY311_BIN" -c "import numpy; print(numpy.__file__)" 2>/dev/null || echo "None")"
if [ "$NUMPY_FILE" = "None" ] || [ -z "$NUMPY_FILE" ]; then
  echo "ERROR CRITICO: Numpy no está disponible o es un namespace package vacío."
  echo "Corre primero build_all_deps.sh (con PYTHONPATH limpio) antes de continuar."
  exit 1
fi
"$PY311_BIN" -c "import numpy; print('Numpy version:', numpy.__version__)"
echo "Numpy cargó correctamente desde: $NUMPY_FILE"

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PY311_PREFIX/bin:$ORIGINAL_PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$BOOST_LIB_DIR:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$FAKE_USR/lib/pkgconfig:$BOOST_LIB_DIR/pkgconfig:$TMX_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- Compiladores estandar (SIN OpenMPI) ---
export CC="$TMX_PREFIX/bin/clang"
export CXX="$TMX_PREFIX/bin/clang++"
export FC="$TMX_PREFIX/bin/gfortran"
export F77="$TMX_PREFIX/bin/gfortran"
export PYTHON="$PY311_BIN"

PY_INC_FLAGS=""
PY_LD_FLAGS=""

if command -v python3.11-config >/dev/null 2>&1; then
PY_INC_FLAGS="$(python3.11-config --includes 2>/dev/null || true)"
PY_LD_FLAGS="$(python3.11-config --ldflags 2>/dev/null || true)"
fi

PY_INC_DIR="$PY311_PREFIX/include/python3.11"

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include -I$BOOST_INCLUDE_DIR -I$NUMPY_INCLUDE_DIR -DIDXTYPEWIDTH=64 -DINTSIZE64 -DAdd_ -DH5_USE_110_API -DM_MMAP_THRESHOLD=-1 ${PY_INC_FLAGS} -I$PY_INC_DIR"

export CFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export CXXFLAGS="-std=c++17 -fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export FCFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -fdefault-integer-8 -fallow-argument-mismatch $CPPFLAGS"
export FFLAGS="$FCFLAGS"

export LDFLAGS="-B$LD_WRAPPER_DIR -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$BOOST_LIB_DIR -L$TMX_PREFIX/lib -L/system/lib64 -landroid-shmem -landroid-posix-semaphore -lpthread -Wl,--allow-shlib-undefined $PY_LD_FLAGS"
export LINKFLAGS="$LDFLAGS"

# ---------- MUMPS usa enteros de 64 bits (IDXTYPEWIDTH=64 / INTSIZE64). OpenBLAS estandar se deja en 4 bytes (default) ----------
export ASTER_MUMPS_INT_SIZE=8

VER="15.5.0"
TAR="$HOME/codeaster-${VER}.tar.gz"
SRC="$HOME/src-${VER}"

echo "=== Descargando el archivo ligero del tag $VER ==="
rm -rf "$SRC"
rm -f "$TAR"
wget -O "$TAR" "https://gitlab.com/codeaster/src/-/archive/${VER}/src-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"
rm -f "$TAR"

cd "$SRC" || exit 1

echo "=== Creando pkginfo.py manual ==="
mkdir -p code_aster
BUILD_DATE="$(date +%d/%m/%Y)"
cat > code_aster/pkginfo.py <<PYEOF
pkginfo = [(15, 5, 0), 'n/a', 'n/a', '${BUILD_DATE}', 'n/a', 1, ['no source repository']]
PYEOF

if ! command -v ldd >/dev/null 2>&1; then
cat > "$FAKE_USR/bin/ldd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKE_USR/bin/ldd"
fi

chmod +x waf

echo "=== Parche global de distutils -> packaging ==="
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

for root, _, files in os.walk("."):
    for name in files:
        if not (name.endswith(".py") or name == "wscript"):
            continue
        p = Path(root) / name
        try:
            txt = p.read_text()
        except Exception:
            continue
        orig = txt
        txt = txt.replace(
            "from distutils.version import LooseVersion",
            "from packaging.version import Version as LooseVersion"
        )
        txt = txt.replace(
            "from setuptools._distutils.version import LooseVersion",
            "from packaging.version import Version as LooseVersion"
        )
        if txt != orig:
            p.write_text(txt)
PY

echo "=== Parche para Android Bionic: Deshabilitar y simular backtrace ==="
# 1. Comentar cualquier inclusión accidental de execinfo.h en el código fuente
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

for root, _, files in os.walk("."):
    for name in files:
        if not (name.endswith(".c") or name.endswith(".cpp") or name.endswith(".h")):
            continue
        p = Path(root) / name
        try:
            txt = p.read_text()
        except Exception:
            continue
        orig = txt
        if "<execinfo.h>" in txt:
            txt = txt.replace("#include <execinfo.h>", "/* #include <execinfo.h> deshabilitado para Android */")
        if '"execinfo.h"' in txt:
            txt = txt.replace('#include "execinfo.h"', '/* #include "execinfo.h" deshabilitado para Android */')
        if txt != orig:
            p.write_text(txt)
PY

# 2. Encontrar un archivo C que vaya dentro de libbibc.so e inyectarle los stubs vacíos
TARGET_C_FILE=$(find . -path "*/bibc/*" -name "*.c" | head -n 1)
if [ -n "$TARGET_C_FILE" ]; then
  echo "Inyectando stubs de backtrace en: $TARGET_C_FILE"
  cat >> "$TARGET_C_FILE" << 'EOF'

/* --- STUBS DE BACKTRACE PARA ANDROID BIONIC (TERMUX) --- */
int backtrace(void **buffer, int size) {
    (void)buffer;
    (void)size;
    return 0;
}
char **backtrace_symbols(void *const *buffer, int size) {
    (void)buffer;
    (void)size;
    return (char**)0;
}
void backtrace_symbols_fd(void *const *buffer, int size, int fd) {
    (void)buffer;
    (void)size;
    (void)fd;
}
EOF
else
  echo "ERROR: No se encontró ningún archivo fuente en bibc para inyectar los stubs."
  exit 1
fi

echo "=== Aplicando Bypass de Numpy a waf (ruta real desde deps.env) ==="
export NUMPY_INCLUDE_DIR_ENV="$NUMPY_INCLUDE_DIR"
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

p_py = Path("waftools/python_cfg.py")
if p_py.exists():
    txt = p_py.read_text()
    orig = txt
    txt = txt.replace("self.check_python_module('numpy')", "pass")
    old_line = 'self.get_python_variables(["numpy.get_include()"], ["NUMPY_INCLUDE"])'
    numpy_inc = os.environ.get("NUMPY_INCLUDE_DIR_ENV", "")
    new_line = f'self.env.NUMPY_INCLUDE = "{numpy_inc}"'
    if old_line in txt:
        txt = txt.replace(old_line, new_line)
    if txt != orig:
        p_py.write_text(txt)
PY

echo "=== Creando configuracion personalizada para waf (Boost real + OpenBLAS + MUMPS/METIS/SCOTCH/HDF5/MED en fake_root) ==="
cat > custom_config_alt.py <<PYEOF
# -*- coding: utf-8 -*-
def configure(self):
    self.env.append_value("INCLUDES", ["$FAKE_USR/include", "$BOOST_INCLUDE_DIR", "$TMX_PREFIX/include"])
    self.env.append_value("LIBPATH", ["$FAKE_USR/lib", "$BOOST_LIB_DIR", "$TMX_PREFIX/lib"])

    self.env.INCLUDES_BOOST = ["$BOOST_INCLUDE_DIR"]
    self.env.LIBPATH_BOOST = ["$BOOST_LIB_DIR"]
    self.env.LIB_BOOST = ["boost_python311"]

    self.env.append_value("LIB_MATH", ["openblas"])

    # --- MUMPS: include e include_seq son obligatorios por separado (doc oficial) ---
    self.env.INCLUDES_MUMPS = ["$FAKE_USR/include", "$FAKE_USR/include_seq"]
    self.env.LIBPATH_MUMPS = ["$FAKE_USR/lib", "$TMX_PREFIX/lib"]

    self.env.INCLUDES_METIS = ["$FAKE_USR/include"]
    self.env.LIBPATH_METIS = ["$FAKE_USR/lib", "$TMX_PREFIX/lib"]

    self.env.INCLUDES_SCOTCH = ["$FAKE_USR/include"]
    self.env.LIBPATH_SCOTCH = ["$FAKE_USR/lib", "$TMX_PREFIX/lib"]

    self.env.INCLUDES_HDF5 = ["$FAKE_USR/include"]
    self.env.LIBPATH_HDF5 = ["$FAKE_USR/lib", "$TMX_PREFIX/lib"]

    self.env.INCLUDES_MED = ["$FAKE_USR/include"]
    self.env.LIBPATH_MED = ["$FAKE_USR/lib", "$TMX_PREFIX/lib"]

    self.env.INCLUDES = list(dict.fromkeys(self.env.INCLUDES))
    self.env.LIBPATH = list(dict.fromkeys(self.env.LIBPATH))
PYEOF

echo "=== Ajustando PYTHONPATH de catalo/wscript (sin MPI) ==="
export DESTDIR_ENV="$DESTDIR"
export APP_PREFIX_ENV="$APP_PREFIX"

"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

p_cata = Path("catalo/wscript")
if p_cata.exists():
    txt = p_cata.read_text()
    orig = txt

    destdir = os.environ.get("DESTDIR_ENV", "")
    app_prefix = os.environ.get("APP_PREFIX_ENV", "")
    src_dir = os.getcwd()
    pp1 = f"{destdir}{app_prefix}/lib/python3.11/site-packages"
    pp2 = f"{destdir}{app_prefix}/lib/aster"
    new_env = f'dict(environ, PYTHONPATH="{pp1}:{pp2}:{src_dir}:" + environ.get("PYTHONPATH", ""))'
    txt = txt.replace('env=environ', f'env={new_env}')

    if txt != orig:
        p_cata.write_text(txt)
        print("catalo/wscript parcheado (solo PYTHONPATH, sin bypass de mpiexec).")
PY

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$ORIGINAL_PATH"

echo "=== Configurando Code_Aster secuencial (Boost 1.90.0 + Numpy 1.26.4 propios) ==="
./waf configure \
--prefix="$APP_PREFIX" \
--install-tests \
--without-hg \
--use-config="custom_config_alt" \
--python="$PY311_BIN" \
--boost-includes="$BOOST_INCLUDE_DIR" \
--boost-libs="$BOOST_LIB_DIR" \
--maths-libs="openblas" \
--mumps-libs="dmumps zmumps smumps cmumps mumps_common pord" \
--metis-libs="metis" \
--scotch-libs="scotch scotcherr esmumps" \
--hdf5-libs="hdf5_hl_fortran hdf5_fortran hdf5_hl hdf5" \
--med-libs="med medC"

echo "=== Compilando Code_Aster ==="
./waf build -j"$(nproc)"

echo "=== Aplicando FIX FINAL DE LIBRERIAS PARA INSTALL ==="
export LD_LIBRARY_PATH="$FAKE_USR/lib/aster:$FAKE_USR/lib:$BOOST_LIB_DIR:$TMX_PREFIX/lib"
export PYTHONPATH="$FAKE_USR/lib/aster:$FAKE_USR/lib/python3.11/site-packages:$TMX_PREFIX/lib/python3.11/site-packages"

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"

echo "=== Instalando Code_Aster en fake_root ==="
./waf install --destdir="$DESTDIR"

echo "=== Code_Aster $VER secuencial instalado correctamente, con Boost 1.90.0 y Numpy 1.26.4 propios ==="
