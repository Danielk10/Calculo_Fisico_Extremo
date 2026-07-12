#!/bin/bash
set -euo pipefail

cd "$HOME" || exit 1

export APPPREFIX="/data/data/com.diamon.aster/files/usr"
export DESTDIR="$HOME/fake_root"
export FAKEUSR="$DESTDIR$APPPREFIX"
export TMXPREFIX="/data/data/com.termux/files/usr"

# Asegurar directorios base
mkdir -p "$FAKEUSR/include" "$FAKEUSR/lib" "$FAKEUSR/bin" "$FAKEUSR/lib/pkgconfig"

# ==============================================================================
# ESTRATEGIA: RESGUARDAR ARCHIVOS .LA (SIN BORRAR NADA)
# ==============================================================================
LA_BACKUP="$HOME/la_files_backup"
rm -rf "$LA_BACKUP"
mkdir -p "$LA_BACKUP"

if [ -d "$FAKEUSR/lib" ]; then
  echo "=== Resguardando archivos .la temporalmente para la compilación ==="
  find "$FAKEUSR/lib" -name "*.la" -exec mv {} "$LA_BACKUP/" \; 2>/dev/null || true
fi

# Instalar dependencias necesarias en Termux
pkg update -y
pkg install -y wget tar make autoconf automake libtool pkg-config clang binutils \
  coreutils findutils grep sed perl

# Configurar compiladores
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export LD=ld.lld

# ==============================================================================
# SOLUCIÓN: Crear micro-biblioteca de compatibilidad para Android (rindex y getdtablesize)
# ==============================================================================
echo "=== Creando parches de compatibilidad para Android Bionic ==="
echo '
#include <unistd.h>
#include <string.h>
int getdtablesize(void) { 
    return sysconf(_SC_OPEN_MAX); 
}
char *rindex(const char *s, int c) { 
    return strrchr(s, c); 
}
' > "$HOME/prrte_compat.c"
$CC -fPIC -O2 -c "$HOME/prrte_compat.c" -o "$HOME/prrte_compat.o"
$AR rcs "$FAKEUSR/lib/libprrte_compat.a" "$HOME/prrte_compat.o"
rm -f "$HOME/prrte_compat.c" "$HOME/prrte_compat.o"

# Inclusión de cabeceras de la raíz simulada y subcarpeta pmix
export PATH="$FAKEUSR/bin:$TMXPREFIX/bin:$PATH"
export CPPFLAGS="-I$FAKEUSR/include -I$FAKEUSR/include/pmix -I$TMXPREFIX/include"
export CFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration $CPPFLAGS"
export CXXFLAGS="-fPIC -fPIE -O2 -ffile-prefix-map=$DESTDIR= -Wno-error=implicit-function-declaration $CPPFLAGS"

# NOTA: Se añade '-lprrte_compat' al final de LDFLAGS para resolver los símbolos ausentes
export LDFLAGS="-pie -Wl,-z,max-page-size=16384 -L$FAKEUSR/lib -L$TMXPREFIX/lib -lprrte_compat"
export PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$TMXPREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$FAKEUSR/lib:$TMXPREFIX/lib:${LD_LIBRARY_PATH:-}"

# Versión y rutas de PRRTE
VER="3.0.13"
TAR="$HOME/prrte-${VER}.tar.gz"
SRC="$HOME/prrte-${VER}"
BUILD="$HOME/prrte-build-${VER}"

rm -rf "$SRC" "$BUILD"
rm -f "$TAR"

# Descarga y extracción
wget -O "$TAR" "https://github.com/openpmix/prrte/releases/download/v${VER}/prrte-${VER}.tar.gz"
tar -xzf "$TAR" -C "$HOME"

mkdir -p "$BUILD"
cd "$BUILD" || exit 1

# Verificar detección de dependencias antes de configurar
echo "=== Verificando dependencias en fake_root ==="
PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --modversion pmix || true
PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --modversion hwloc || true
PKG_CONFIG_PATH="$FAKEUSR/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --modversion libevent || true

set +e
bash "$SRC/configure" \
  --prefix="$APPPREFIX" \
  --libdir="$APPPREFIX/lib" \
  --disable-static \
  --enable-shared \
  --disable-debug \
  --with-libevent="$FAKEUSR" \
  --with-hwloc="$FAKEUSR" \
  --with-pmix="$FAKEUSR" \
  CC="$CC" \
  CXX="$CXX" \
  CPPFLAGS="$CPPFLAGS" \
  CFLAGS="$CFLAGS" \
  CXXFLAGS="$CXXFLAGS" \
  LDFLAGS="$LDFLAGS" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
cfg_status=$?
set -e

if [ "$cfg_status" -ne 0 ]; then
  # RECOVERY: Si falla el configure, restaurar de todos modos
  if [ -d "$LA_BACKUP" ] && [ "$(ls -A "$LA_BACKUP" 2>/dev/null)" ]; then
    mv "$LA_BACKUP"/*.la "$FAKEUSR/lib/" 2>/dev/null || true
  fi
  tail -n 120 config.log || true
  exit "$cfg_status"
fi

# Compilación e instalación
make -j"$(nproc)"
make install DESTDIR="$DESTDIR"

# ==============================================================================
# RESTAURACIÓN: DEVOLVER ARCHIVOS .LA A SU ESTADO Y RUTA ORIGINAL
# ==============================================================================
if [ -d "$LA_BACKUP" ] && [ "$(ls -A "$LA_BACKUP" 2>/dev/null)" ]; then
  echo "=== Restaurando archivos .la resguardados a su ubicación original ==="
  mv "$LA_BACKUP"/*.la "$FAKEUSR/lib/" 2>/dev/null || true
  rm -rf "$LA_BACKUP"
fi

echo "=== Binarios de PRRTE instalados ==="
find "$FAKEUSR/bin" -maxdepth 1 \( -name 'prte*' -o -name 'pterm*' -o -name 'prun*' \) | sort || true

echo "=== Bibliotecas de PRRTE instaladas ==="
find "$FAKEUSR/lib" -maxdepth 1 -name 'libprrte*.so*' | sort || true

echo "=== Dependencias de libprrte.so ==="
if [ -f "$FAKEUSR/lib/libprrte.so" ]; then
  readelf -d "$FAKEUSR/lib/libprrte.so" | grep NEEDED || true
fi
