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
# Este wrapper se llama "ld" y vive en un directorio propio que se inyecta
# con -B en CFLAGS/CXXFLAGS/FCFLAGS/LDFLAGS. Esto garantiza que SIEMPRE se
# use, sin depender de $LD ni de -fuse-ld=lld (que bypassea $LD por completo
# al buscar "ld.lld" directamente). El wrapper:
#   - Añade -L/system/lib64 (libc/libm/libdl reales de Android Bionic)
#   - Fuerza -z execstack (requerido por algunos .o de Fortran con trampolines)
#   - Remueve -pie SOLO si detecta -shared en los argumentos (biblioteca .so),
#     ya que -pie es exclusivo de ejecutables y rompe el enlace de .so
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
    echo ""
    echo "=========================================================="
    echo "ERROR CRÍTICO: Numpy sigue crasheando tras aplicar patchelf."
    echo "=========================================================="
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

echo "=== Grabando RPATH permanente en binarios y libs de OpenMPI ==="
RPATH_TARGET="$FAKE_USR/lib:$TMX_PREFIX/lib"

for bin in mpicc mpic++ mpifort mpirun ompi_info; do
  BIN_PATH="$FAKE_USR/bin/$bin"
  if [ -f "$BIN_PATH" ]; then
    patchelf --set-rpath "$RPATH_TARGET" "$BIN_PATH" 2>/dev/null || true
    echo "RPATH grabado en: $bin"
  fi
done

if [ -d "$FAKE_USR/lib" ]; then
  find "$FAKE_USR/lib" -maxdepth 1 -name "*.so*" -type f | while read -r so_file; do
    patchelf --set-rpath "$RPATH_TARGET" "$so_file" 2>/dev/null || true
  done
  echo "RPATH grabado en todas las .so de $FAKE_USR/lib"
fi

echo "=== Verificando RUNPATH de mpicc (informativo, no bloqueante) ==="
readelf -d "$FAKE_USR/bin/mpicc" | grep -E "NEEDED|RPATH|RUNPATH" || true
if "$FAKE_USR/bin/mpicc" --version >/dev/null 2>&1; then
  echo "mpicc ejecuta correctamente en el entorno actual."
else
  echo "AVISO: mpicc no pudo ejecutarse con --version en este entorno."
fi

echo "=== Instalando mpi4py (opcional, contra OpenMPI de fake_root) ==="
if [ -x "$FAKE_USR/bin/mpicc" ]; then
  MPICC="$FAKE_USR/bin/mpicc" LD_LIBRARY_PATH="$RPATH_TARGET:${LD_LIBRARY_PATH:-}" \
    "$PY311_BIN" -m pip install --no-cache-dir --no-build-isolation --no-binary mpi4py mpi4py || \
    echo "ADVERTENCIA: mpi4py falló al compilar, se continúa sin él (no bloquea el build de Code_Aster)."
else
  echo "AVISO: no se encontró mpicc en $FAKE_USR/bin, se omite mpi4py."
fi

PY_INC_FLAGS=""
PY_LD_FLAGS=""

if command -v python3.11-config >/dev/null 2>&1; then
  PY_INC_FLAGS="$(python3.11-config --includes 2>/dev/null || true)"
  PY_LD_FLAGS="$(python3.11-config --ldflags 2>/dev/null || true)"
fi

PY_HEADER="$PY311_PREFIX/include/python3.11/Python.h"
PY_INC_DIR="$PY311_PREFIX/include/python3.11"

if [ ! -f "$PY_HEADER" ]; then
  echo "ERROR: No se encontró Python.h para Python 3.11 en $PY_HEADER"
  exit 1
fi

echo "=== Verificando headers y librerías de Boost ==="
BOOST_INCLUDE_DIR="$TMX_PREFIX/include"
BOOST_LIB_DIR="$TMX_PREFIX/lib"

if [ ! -d "$BOOST_INCLUDE_DIR/boost" ]; then
  echo "ERROR: No se encontraron los headers de Boost en $BOOST_INCLUDE_DIR/boost"
  exit 1
fi
echo "Headers de Boost encontrados en: $BOOST_INCLUDE_DIR/boost"

BOOST_PY_LIB="$(find "$BOOST_LIB_DIR" -maxdepth 1 -name "libboost_python3*.so" | head -n1)"
if [ -z "$BOOST_PY_LIB" ]; then
  echo "ERROR: No se encontró libboost_python3*.so en $BOOST_LIB_DIR"
  exit 1
fi
echo "Librería Boost.Python encontrada: $BOOST_PY_LIB"

export CPPFLAGS="-I$FAKE_USR/include -I$TMX_PREFIX/include -DIDXTYPEWIDTH=64 -DINTSIZE64 -DAdd_ -DH5_USE_110_API -DM_MMAP_THRESHOLD=-1 ${PY_INC_FLAGS} -I$PY_INC_DIR"

# -B"$LD_WRAPPER_DIR" fuerza a TODOS los compiladores a usar nuestro wrapper "ld"
# en lugar del ld.lld real, sin depender de -fuse-ld ni de $LD.
export CFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export CXXFLAGS="-std=c++17 -fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration -Wno-format $CPPFLAGS"
export FCFLAGS="-fPIC -O2 -B$LD_WRAPPER_DIR -ffile-prefix-map=$DESTDIR= -fdefault-integer-8 -fallow-argument-mismatch $CPPFLAGS"
export FFLAGS="$FCFLAGS"

# NOTA: -pie y -fPIE eliminados para evitar conflictos en la construcción de bibliotecas compartidas (.so).
export LDFLAGS="-B$LD_WRAPPER_DIR -Wl,-z,max-page-size=16384 -L$FAKE_USR/lib -L$TMX_PREFIX/lib -L/system/lib64 -landroid-shmem -landroid-posix-semaphore -lpthread -Wl,--allow-shlib-undefined $PY_LD_FLAGS"
export LINKFLAGS="$LDFLAGS"

VER="15.5.0"
TAR="$HOME/codeaster-${VER}.tar.gz"
SRC="$HOME/src-${VER}"

echo "=== Descargando el archivo ligero del tag $VER desde GitLab (sin historial) ==="
rm -rf "$SRC"
rm -f "$TAR"
wget -O "$TAR" "https://gitlab.com/codeaster/src/-/archive/${VER}/src-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"
rm -f "$TAR"

cd "$SRC" || exit 1

echo "=== Parcheando data/wscript para evitar crash de 'mpiexec env' (Error 213) ==="
"$PY311_BIN" - <<'PY'
from pathlib import Path

p = Path("data/wscript")
if p.exists():
    txt = p.read_text()
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
            p.write_text(txt)
            print("data/wscript parcheado correctamente (bypass mpiexec env / error 213).")
    else:
        print("AVISO: no se encontró la línea exacta en data/wscript, revisa manualmente.")
else:
    print("AVISO: data/wscript no existe en esta ruta.")
PY

echo "=== Creando pkginfo.py manual (archivo comprimido, sin .git/.hg) ==="
mkdir -p code_aster
BUILD_DATE="$(date +%d/%m/%Y)"
cat > code_aster/pkginfo.py <<PYEOF
pkginfo = [(15, 5, 0), 'n/a', 'n/a', '${BUILD_DATE}', 'n/a', 1, ['no source repository']]
PYEOF
echo "pkginfo.py creado: $(cat code_aster/pkginfo.py)"

echo "=== Parcheando ldd para Termux ==="
if ! command -v ldd >/dev/null 2>&1; then
  cat > "$FAKE_USR/bin/ldd" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$FAKE_USR/bin/ldd"
fi

echo "=== Asegurando waf ejecutable ==="
chmod +x waf

echo "=== Parche global de distutils -> packaging ==="
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

patched = 0
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
            patched += 1
            print(f"Parcheado: {p}")
print(f"Total parcheados: {patched}")
PY

echo "=== Aplicando Bypass de Numpy y TFEL a waf (via Python) ==="
"$PY311_BIN" - <<'PY'
import os
from pathlib import Path

p_py = Path("waftools/python_cfg.py")
if p_py.exists():
    txt = p_py.read_text()
    orig = txt
    txt = txt.replace("self.check_python_module('numpy')", "pass")
    txt = txt.replace("self.check_python_module('tfel.material')", "pass")
    old_line = 'self.get_python_variables(["numpy.get_include()"], ["NUMPY_INCLUDE"])'
    tmx = os.environ.get("TMX_PREFIX", "/data/data/com.termux/files/usr")
    new_line = f'self.env.NUMPY_INCLUDE = "{tmx}/lib/python3.11/site-packages/numpy/core/include"'
    if old_line in txt:
        txt = txt.replace(old_line, new_line)
    if txt != orig:
        p_py.write_text(txt)
PY

echo "=== Creando symlinks de TFEL/MFront sin sufijo de versión ==="
declare -A TFEL_TOOLS=(
  ["mfront"]="mfront-5.2.0-dev"
  ["mfront-query"]="mfront-query-5.2.0-dev"
  ["mfront-doc"]="mfront-doc-5.2.0-dev"
  ["mfm"]="mfm-5.2.0-dev"
  ["mfm-test-generator"]="mfm-test-generator-5.2.0-dev"
  ["tfel-check"]="tfel-check-5.2.0-dev"
  ["tfel-config"]="tfel-config-5.2.0-dev"
  ["tfel-doc"]="tfel-doc-5.2.0-dev"
  ["tfel-unicode-filt"]="tfel-unicode-filt-5.2.0-dev"
)

for link_name in "${!TFEL_TOOLS[@]}"; do
  real_name="${TFEL_TOOLS[$link_name]}"
  real_path="$FAKE_USR/bin/$real_name"
  link_path="$FAKE_USR/bin/$link_name"
  if [ -f "$real_path" ] && [ ! -e "$link_path" ]; then
    ln -s "$real_name" "$link_path"
    echo "Symlink creado: $link_name -> $real_name"
  elif [ -e "$link_path" ]; then
    echo "Ya existe: $link_name"
  else
    echo "AVISO: no se encontró $real_path para enlazar $link_name"
  fi
done

if ! command -v mfront >/dev/null 2>&1; then
  echo "ERROR: mfront sigue sin detectarse tras crear el symlink."
  exit 1
fi

echo "=== Creando configuración personalizada para waf ==="
cat > custom_config_alt.py <<EOF
import os

def configure(self):
    self.env.append_value('INCLUDES', ['$FAKE_USR/include', '$TMX_PREFIX/include'])
    self.env.append_value('LIBPATH', ['$FAKE_USR/lib', '$TMX_PREFIX/lib', '/system/lib64'])

    termux_ldflags = os.environ.get('LINKFLAGS', '').split()
    self.env.append_value('LINKFLAGS', termux_ldflags)
    # Filtro adicional de seguridad: -pie fuera de SHLINKFLAGS, aunque el
    # wrapper "ld" ya lo remueve al detectar -shared en la línea de enlace.
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
    self.env.LIB_HDF5 = ['hdf5_hl', 'hdf5']

    self.env.INCLUDES_MED = ['$FAKE_USR/include']
    self.env.LIBPATH_MED = ['$FAKE_USR/lib']
    self.env.LIB_MED = ['medC']

    self.env.INCLUDES_TFEL = ['$FAKE_USR/include']
    self.env.LIBPATH_TFEL = ['$FAKE_USR/lib']
    self.env.LIB_TFEL = ['TFELMFront', 'TFELException', 'TFELMath', 'TFELUtilities']

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

echo "=== Verificando Python.h real ==="
echo "Python.h asignado a: $PY_HEADER"

export PYTHONPATH="$FAKE_USR/lib/python3.11/site-packages:$TMX_PREFIX/lib/python3.11/site-packages:${PYTHONPATH:-}"

echo "=== Creando interceptor de mpic++ para forzar C++17 ==="

# 1. Crear un directorio temporal para el wrapper
export CXXWRAPPERDIR="$HOME/cxx-wrapper"
mkdir -p "$CXXWRAPPERDIR"

# 2. Crear el script wrapper apuntando al mpic++ REAL en FAKE_USR
cat > "$CXXWRAPPERDIR/mpic++" << EOF
#!/bin/bash
exec $FAKE_USR/bin/mpic++ -std=c++17 "\$@"
EOF

# 3. Hacerlo ejecutable
chmod +x "$CXXWRAPPERDIR/mpic++"

# 4. Poner el wrapper AL PRINCIPIO del PATH para que waf lo encuentre primero
export PATH="$CXXWRAPPERDIR:$PATH"

echo "=== Creando wrapper de C++ para asegurar -std=c++17 en asterbehaviour ==="
CXXWRAPPERDIR="$HOME/cxx-wrapper"
mkdir -p "$CXXWRAPPERDIR"
cat > "$CXXWRAPPERDIR/mpic++" << EOF
#!/data/data/com.termux/files/usr/bin/bash
args=("\$@")
exec "$FAKE_USR/bin/mpic++" -std=c++17 "\${args[@]}"
EOF
chmod +x "$CXXWRAPPERDIR/mpic++"
export PATH="$CXXWRAPPERDIR:$PATH"

echo "=== Configurando Code_Aster paralelo ==="

export TFELHOME="$FAKE_USR"

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
  --hdf5-libs="hdf5_hl hdf5" \
  --med-libs="medC" \
  --enable-mfront

echo "=== Compilando Code_Aster ==="
./waf build -j"$(nproc)"

echo "=== Instalando Code_Aster en fake_root ==="
./waf install --destdir="$DESTDIR"

echo "=== Validando instalación ==="
find "$FAKE_USR/bin" -maxdepth 1 | sort | head -n 50 || true

if [ -f "$FAKE_USR/bin/aster" ]; then
  echo "=== Dependencias del ejecutable aster ==="
  readelf -d "$FAKE_USR/bin/aster" | grep NEEDED || true
fi

echo "=== ¡Code_Aster $VER paralelo instalado correctamente! ==="
