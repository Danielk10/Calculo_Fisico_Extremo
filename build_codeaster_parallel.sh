#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APP_PREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKE_USR="$DESTDIR$APP_PREFIX"
export TMX_PREFIX="/data/data/com.termux/files/usr"

mkdir -p "$FAKE_USR/include" "$FAKE_USR/lib" "$FAKE_USR/bin" "$FAKE_USR/lib/pkgconfig"

export ORIGINAL_PATH="$PATH"

echo "=== Creando wrapper de enlazador robusto (vía -B, ignora -fuse-ld) ==="
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
  libandroid-shmem libandroid-posix-semaphore

pkg update -y

echo "=== Intentando instalar Python 3.11 compatible ==="
pkg install -y python3.11 || true

PY311_BIN=""
for cand in \
  /data/data/com.termux/files/usr/bin/python3.11 \
  "$(command -v python3.11 2>/dev/null || true)"
do
  if [ -n "${cand:-}" ] && [ -x "$cand" ]; then
    PY311_BIN="$cand"
    break
  fi
done

if [ -z "$PY311_BIN" ]; then
  echo "ERROR: No se encontró python3.11 instalado en Termux."
  exit 1
fi

echo "=== Python seleccionado: $PY311_BIN ==="
PY311_PREFIX="$(dirname "$(dirname "$PY311_BIN")")"

echo "=== Habilitando pip para Python 3.11 ==="
"$PY311_BIN" -m ensurepip --upgrade || true

echo "=== Instalando dependencias Python para Code_Aster ==="
"$PY311_BIN" -m pip install --upgrade pip setuptools wheel packaging
"$PY311_BIN" -m pip install meson meson-python ninja patchelf

export MATHLIB="m"
export CFLAGS="-Wno-implicit-function-declaration"
export LDFLAGS="-lm -lpython3.11"
"$PY311_BIN" -m pip install "numpy<2"

echo "=== PARCHEANDO ELF DE NUMPY PARA TERMUX ==="
NUMPY_DIR="$PY311_PREFIX/lib/python3.11/site-packages/numpy"
if [ -d "$NUMPY_DIR" ]; then
    find "$NUMPY_DIR" -name "*.so" | while read -r so_file; do
        patchelf --add-needed libpython3.11.so.1.0 "$so_file" || true
        patchelf --add-needed libpython3.11.so "$so_file" || true
    done
    echo "Librerías .so de Numpy parcheadas con patchelf."
else
    echo "ADVERTENCIA: No se encontró directorio de Numpy en $NUMPY_DIR"
fi

echo "=== PRUEBA DE FUEGO: Importando Numpy en terminal ==="
if ! "$PY311_BIN" -c "import numpy; print('Numpy version:', numpy.__version__)"; then
    echo "ERROR CRÍTICO: Numpy sigue crasheando tras aplicar patchelf."
    exit 1
fi
echo "Numpy cargó correctamente."

export PATH="$FAKE_USR/bin:$TMX_PREFIX/bin:$PY311_PREFIX/bin:$ORIGINAL_PATH"
export LD_LIBRARY_PATH="$FAKE_USR/lib:$TMX_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$FAKE_USR/lib/pkgconfig:$TMX_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

export OPAL_DESTDIR="$DESTDIR"
export OPAL_PREFIX="$APP_PREFIX"
export OPAL_INCLUDEDIR="$FAKE_USR/include"

export CC="$FAKE_USR/bin/mpicc"
export CXX="$FAKE_USR/bin/mpic++"
export FC="$FAKE_USR/bin/mpifort"
export F77="$FAKE_USR/bin/mpifort"
export PYTHON="$PY311_BIN"

# --- FIX CRÍTICO PARA OPENMPI EN TERMUX ---
export OMPI_MCA_rmaps_base_oversubscribe=1
export OMPI_MCA_hwloc_base_binding_policy=none
export OMPI_MCA_btl_tcp_if_include="lo"
export OMPI_MCA_oob_tcp_if_include="lo"
export PRTE_MCA_oob_tcp_if_include="lo"
# ------------------------------------------

echo "=== Grabando RPATH permanente en binarios y libs de OpenMPI ==="
RPATH_TARGET="$FAKE_USR/lib:$TMX_PREFIX/lib"

for bin in mpicc mpic++ mpifort mpirun ompi_info; do
  BIN_PATH="$FAKE_USR/bin/$bin"
  if [ -f "$BIN_PATH" ]; then
    patchelf --set-rpath "$RPATH_TARGET" "$BIN_PATH" 2>/dev/null || true
  fi
done

if [ -d "$FAKE_USR/lib" ]; then
  find "$FAKE_USR/lib" -maxdepth 1 -name "*.so*" -type f | while read -r so_file; do
    patchelf --set-rpath "$RPATH_TARGET" "$so_file" 2>/dev/null || true
  done
fi

echo "=== Instalando mpi4py (opcional) ==="
if [ -x "$FAKE_USR/bin/mpicc" ]; then
  MPICC="$FAKE_USR/bin/mpicc" LD_LIBRARY_PATH="$RPATH_TARGET:${LD_LIBRARY_PATH:-}" \
    "$PY311_BIN" -m pip install --no-cache-dir --no-build-isolation --no-binary mpi4py mpi4py || true
fi

PY_INC_FLAGS=""
PY_LD_FLAGS=""

if command -v python3.11-config >/dev/null 2>&1; then
  PY_INC_FLAGS="$(python3.11-config --includes 2>/dev/null || true)"
  PY_LD_FLAGS="$(python3.11-config --ldflags 2>/dev/null || true)"
fi

PY_HEADER="$PY311_PREFIX/include/python3.11/Python.h"
PY_INC_DIR="$PY311_PREFIX/include/python3.11"

BOOST_INCLUDE_DIR="$TMX_PREFIX/include"
BOOST_LIB_DIR="$TMX_PREFIX/lib"

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include -DIDXTYPEWIDTH=64 -DINTSIZE64 -DAdd_ -DH5_USE_110_API -DM_MMAP_THRESHOLD=-1 ${PY_INC_FLAGS} -I$PY_INC_DIR"

export CFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export CXXFLAGS="-std=c++17 -fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export FCFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -fdefault-integer-8 -fallow-argument-mismatch $CPPFLAGS"
export FFLAGS="$FCFLAGS"

export LDFLAGS="-B$LD_WRAPPER_DIR -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -L/system/lib64 -landroid-shmem -landroid-posix-semaphore -lpthread -Wl,--allow-shlib-undefined $PY_LD_FLAGS"
export LINKFLAGS="$LDFLAGS"

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

# --- PREPARAR BYPASS MPI ANTES DE CONFIGURAR ---
mkdir -p "$HOME/mpi-bypass"
cat > "$HOME/mpi-bypass/mpiexec" << 'EOF'
#!/bin/bash
args=("$@")
cmd=()
capture=0
for arg in "${args[@]}"; do
    if [[ "$arg" == *python3.11* ]]; then
        capture=1
    fi
    if [[ $capture -eq 1 ]]; then
        cmd+=("$arg")
    fi
done
exec "${cmd[@]}"
EOF
chmod +x "$HOME/mpi-bypass/mpiexec"

echo "=== Parcheando wscripts (data y catalo) para evitar crashes de mpiexec en Android ==="
export DESTDIR_ENV="$DESTDIR"
export APP_PREFIX_ENV="$APP_PREFIX"

"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

# Parche 1: data/wscript
p_data = Path("data/wscript")
if p_data.exists():
    txt = p_data.read_text()
    orig = txt
    old_snippet = '    out = self.cmd_and_log(self.env["base_mpiexec"] + ["env"])'
    new_snippet = (
        "    try:\n"
        "        out = self.cmd_and_log(self.env[\"base_mpiexec\"] + [\"env\"])\n"
        "    except Exception:\n"
        "        out = \"OMPI_COMM_WORLD_RANK\""
    )
    if old_snippet in txt:
        txt = txt.replace(old_snippet, new_snippet)
        if txt != orig:
            p_data.write_text(txt)
            print("data/wscript parcheado.")

# Parche 2: catalo/wscript (Bypass de mpiexec y arreglo de PYTHONPATH en fake_root)
p_cata = Path("catalo/wscript")
if p_cata.exists():
    txt = p_cata.read_text()
    orig = txt
    
    # Bypass mpiexec para build_cata
    txt = txt.replace('self.env["base_mpiexec"]', '[]')
    txt = txt.replace("self.env['base_mpiexec']", '[]')
    
    # Asegurar que post-install (elem.1) reconozca la librería en fake_root
    destdir = os.environ.get("DESTDIR_ENV", "")
    app_prefix = os.environ.get("APP_PREFIX_ENV", "")
    src_dir = os.getcwd()
    pp1 = f"{destdir}{app_prefix}/lib/python3.11/site-packages"
    pp2 = f"{destdir}{app_prefix}/lib/aster"
    new_env = f'dict(environ, PYTHONPATH="{pp1}:{pp2}:{src_dir}:" + environ.get("PYTHONPATH", ""))'
    txt = txt.replace('env=environ', f'env={new_env}')

    if txt != orig:
        p_cata.write_text(txt)
        print("catalo/wscript parcheado (mpiexec bypass + PYTHONPATH).")
PY

echo "=== Creando pkginfo.py manual ==="
mkdir -p code_aster
BUILD_DATE="$(date +%d/%m/%Y)"
cat > code_aster/pkginfo.py <<PYEOF
pkginfo = [(15, 5, 0), 'n/a', 'n/a', '${BUILD_DATE}', 'n/a', 1, ['no source repository']]
PYEOF

echo "=== Parcheando ldd para Termux ==="
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

echo "=== Aplicando Bypass de Numpy a waf ==="
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

p_py = Path("waftools/python_cfg.py")
if p_py.exists():
    txt = p_py.read_text()
    orig = txt
    txt = txt.replace("self.check_python_module('numpy')", "pass")
    old_line = 'self.get_python_variables(["numpy.get_include()"], ["NUMPY_INCLUDE"])'
    tmx = os.environ.get("TMX_PREFIX", "/data/data/com.termux/files/usr")
    new_line = f'self.env.NUMPY_INCLUDE = "{tmx}/lib/python3.11/site-packages/numpy/core/include"'
    if old_line in txt:
        txt = txt.replace(old_line, new_line)
    if txt != orig:
        p_py.write_text(txt)
PY

echo "=== Creando configuración personalizada para waf ==="
cat > custom_config_alt.py <<EOF
import os

def configure(self):
    self.env.append_value('INCLUDES', ['$FAKE_USR/include', '$TMX_PREFIX/include'])
    self.env.append_value('LIBPATH', ['$FAKE_USR/lib', '$TMX_PREFIX/lib', '/system/lib64'])

    termux_ldflags = os.environ.get('LINKFLAGS', '').split()
    self.env.append_value('LINKFLAGS', termux_ldflags)
    shlib_ldflags = [f for f in termux_ldflags if f != '-pie']
    self.env.append_value('SHLINKFLAGS', shlib_ldflags)

    self.env.INCLUDES_MPI = ['$FAKE_USR/include']
    self.env.LIBPATH_MPI = ['$FAKE_USR/lib']
    self.env.LIB_MPI = ['mpi_usempif08', 'mpi_usempi_ignore_tkr', 'mpi_mpifh', 'mpi']

    self.env.INCLUDES_MATH = ['$FAKE_USR/include']
    self.env.LIBPATH_MATH = ['$FAKE_USR/lib']
    self.env.LIB_MATH = ['openblas']

    self.env.INCLUDES_SCALAPACK = ['$FAKE_USR/include']
    self.env.LIBPATH_SCALAPACK = ['$FAKE_USR/lib']
    self.env.LIB_SCALAPACK = ['scalapack']

    self.env.INCLUDES_MUMPS = ['$FAKE_USR/include']
    self.env.LIBPATH_MUMPS = ['$FAKE_USR/lib']
    self.env.LIB_MUMPS = ['dmumps', 'zmumps', 'smumps', 'cmumps', 'mumps_common', 'pord']

    self.env.INCLUDES_METIS = ['$FAKE_USR/include']
    self.env.LIBPATH_METIS = ['$FAKE_USR/lib']
    self.env.LIB_METIS = ['parmetis', 'metis']

    self.env.INCLUDES_SCOTCH = ['$FAKE_USR/include']
    self.env.LIBPATH_SCOTCH = ['$FAKE_USR/lib']
    self.env.LIB_SCOTCH = ['ptesmumps', 'ptscotch', 'ptscotcherr', 'scotch', 'scotcherr', 'esmumps']

    self.env.INCLUDES_HDF5 = ['$FAKE_USR/include']
    self.env.LIBPATH_HDF5 = ['$FAKE_USR/lib']
    self.env.LIB_HDF5 = ['hdf5_hl_fortran', 'hdf5_fortran', 'hdf5_hl', 'hdf5']

    self.env.INCLUDES_MED = ['$FAKE_USR/include']
    self.env.LIBPATH_MED = ['$FAKE_USR/lib']
    self.env.LIB_MED = ['medfC', 'medC']

    self.env.INCLUDES_TCL = ['$FAKE_USR/include', '$TMX_PREFIX/include']
    self.env.LIBPATH_TCL = ['$FAKE_USR/lib', '$TMX_PREFIX/lib']
    self.env.LIB_TCL = ['tk8.6', 'tcl8.6']

    self.env.INCLUDES_PYTHON = ['$TMX_PREFIX/include/python3.11', '$TMX_PREFIX/lib/python3.11/site-packages/numpy/core/include']
    self.env.LIBPATH_PYTHON = ['$TMX_PREFIX/lib', '$TMX_PREFIX/lib/python3.11']
    self.env.LIB_PYTHON = ['python3.11']

    self.env.INCLUDES_BOOST = ['$TMX_PREFIX/include']
    self.env.LIBPATH_BOOST = ['$TMX_PREFIX/lib']

    self.env.INCLUDES = list(dict.fromkeys(self.env.INCLUDES))
    self.env.LIBPATH = list(dict.fromkeys(self.env.LIBPATH))
EOF

export PYTHONPATH="$FAKE_USR/lib/python3.11/site-packages:$TMX_PREFIX/lib/python3.11/site-packages:${PYTHONPATH:-}"

echo "=== Creando interceptor de mpic++ para forzar C++17 ==="
export CXXWRAPPERDIR="$HOME/cxx-wrapper"
mkdir -p "$CXXWRAPPERDIR"

cat > "$CXXWRAPPERDIR/mpic++" << EOF
#!/bin/bash
exec $FAKE_USR/bin/mpic++ -std=c++17 "\$@"
EOF
chmod +x "$CXXWRAPPERDIR/mpic++"
export PATH="$HOME/mpi-bypass:$CXXWRAPPERDIR:$FAKE_USR/bin:$TMX_PREFIX/bin:$ORIGINAL_PATH"

python3.11 -c "
from pathlib import Path
import re
p = Path('build/c4che/_cache.py')
if p.exists():
    txt = p.read_text()
    txt = re.sub(r\"'base_mpiexec': \[.*?\],\", \"'base_mpiexec': [],\", txt)
    p.write_text(txt)
" || true

echo "=== Configurando Code_Aster paralelo ==="
./waf configure \
  --prefix="$APP_PREFIX" \
  --install-tests \
  --enable-mpi \
  --without-hg \
  --use-config="custom_config_alt" \
  --python="$PY311_BIN" \
  --boost-includes="$BOOST_INCLUDE_DIR" \
  --boost-libs="$BOOST_LIB_DIR" \
  --maths-libs="openblas scalapack" \
  --mumps-libs="dmumps zmumps smumps cmumps mumps_common pord" \
  --metis-libs="parmetis metis" \
  --parmetis-libs="parmetis" \
  --scotch-libs="ptesmumps ptscotch ptscotcherr scotch scotcherr esmumps" \
  --hdf5-libs="hdf5_hl_fortran hdf5_fortran hdf5_hl hdf5" \
  --med-libs="medfC medC"

echo "=== Compilando Code_Aster ==="
./waf build -j"$(nproc)"

echo "=== Aplicando FIX FINAL DE LIBRERIAS PARA INSTALL ==="
export LD_LIBRARY_PATH="$FAKE_USR/lib/aster:$FAKE_USR/lib:$TMX_PREFIX/lib"
export PYTHONPATH="$FAKE_USR/lib/aster:$FAKE_USR/lib/python3.11/site-packages:$TMX_PREFIX/lib/python3.11/site-packages"

# Mantenemos el bypass de mpiexec que creamos en el paso anterior
export PATH="$HOME/mpi-bypass:$HOME/cxx-wrapper:$FAKE_USR/bin:$TMX_PREFIX/bin:$PATH"

echo "=== Instalando Code_Aster en fake_root ==="
./waf install --destdir="$DESTDIR"

echo "=== ¡Code_Aster $VER paralelo instalado correctamente sin TFEL! ==="
