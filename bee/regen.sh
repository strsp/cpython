#!/bin/bash -ex
#
# android/regen.sh
# Regenerates configuration for hybrid Python (AOSP + Termux enhanced)
# Patches are loaded from android/patches/
# After this script, use official android.py for building

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC_TOP=$(pwd)
LOCAL_TOP=$SRC_TOP/android
DEPS_DIR="$LOCAL_TOP/deps"
PATCHES_DIR="$LOCAL_TOP/patches"
ANDROID_BUILD_TOP=$(cd ../../..; pwd)

mkdir -p "$DEPS_DIR" "$LOCAL_TOP" "$PATCHES_DIR"

# ====================== HOST DETECTION ======================
if [ "$(uname)" = "Darwin" ]; then
  HOST_DIR=darwin
elif [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
  HOST_DIR=linux_arm64
else
  HOST_DIR=linux_x86_64
fi

# Termux native
TERMUX_PREFIX=${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}
[ -d "$TERMUX_PREFIX" ] && export PREFIX="$TERMUX_PREFIX"

# ====================== CROSS WITH NDK (auto-detect) ======================
CROSS=${CROSS:-0}
CROSS_TARGET=${CROSS_TARGET:-aarch64-linux-android34}
ANDROID_API=${ANDROID_API:-34}

if [ $CROSS -eq 1 ]; then
  echo "=== CROSS-COMPILE MODE (NDK) - target=$CROSS_TARGET ==="
  if [ -z "$ANDROID_NDK" ]; then
    for p in "$ANDROID_SDK_ROOT/ndk/"* "$HOME/Android/Sdk/ndk/"* "$ANDROID_BUILD_TOP/prebuilts/ndk/"*; do
      [ -d "$p" ] && ANDROID_NDK="$p" && break
    done
  fi
  [ -z "$ANDROID_NDK" ] && { echo "ERROR: NDK not found. Set ANDROID_NDK"; exit 1; }

  NDK_CLANG="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  NDK_SYSROOT="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

  export CC="$NDK_CLANG --target=$CROSS_TARGET"
  export CFLAGS="--sysroot=$NDK_SYSROOT -D__ANDROID_API__=$ANDROID_API"
  export LDFLAGS="--sysroot=$NDK_SYSROOT"
  export CROSS_HOST="${CROSS_TARGET%%-*}-linux-android"
else
  # Native
  CLANG_VERSION=$(cd "$ANDROID_BUILD_TOP" 2>/dev/null && build/soong/scripts/get_clang_version.py || echo "host")
  [ "$HOST_DIR" = "linux_x86_64" ] && export CC="$ANDROID_BUILD_TOP/prebuilts/clang/host/linux-x86/${CLANG_VERSION}/bin/clang" || export CC=clang
fi

export PREFIX=${PREFIX:-$DEPS_DIR/install}
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin"
export CFLAGS="$CFLAGS -I$PREFIX/include"
export LDFLAGS="$LDFLAGS -L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export PATH="$PREFIX/bin:$PATH"

# ====================== BUILD DEPENDENCIES ======================
build_deps() {
  echo "=== Building ncurses, readline, libxcrypt + cpython-source-deps ==="

  cd "$DEPS_DIR"

  # cpython-source-deps
  for dep in zstd-1.5.7 tcl-9.0.3.0 tk-9.0.3.0 sqlite-3.50.4.0 xz-5.8.1.1; do
    name=${dep%-*}
    [ -d "$name" ] || {
      wget -q "https://github.com/python/cpython-source-deps/archive/refs/tags/$dep.zip" -O "$dep.zip"
      unzip -q "$dep.zip"
      mv cpython-source-deps-* "$name" 2>/dev/null || true
    }
    cd "$DEPS_DIR/$name"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-x || true
    make -j"$(nproc || echo 4)" && make install
  done

  # ncurses (wide-char)
  [ -d "ncurses" ] || {
    wget -q https://invisible-island.net/archives/ncurses/ncurses-6.5.tar.gz -O ncurses.tar.gz
    tar xzf ncurses.tar.gz && mv ncurses-6.5 ncurses
  }
  cd ncurses
  ./configure --prefix="$PREFIX" --with-shared --enable-widec --without-normal --without-progs --disable-rpath
  make -j"$(nproc || echo 4)" && make install

  # readline
  cd "$DEPS_DIR"
  [ -d "readline" ] || {
    wget -q https://ftp.gnu.org/gnu/readline/readline-8.2.tar.gz -O readline.tar.gz
    tar xzf readline.tar.gz && mv readline-8.2 readline
  }
  cd readline
  ./configure --prefix="$PREFIX" --with-curses --disable-shared --enable-static
  make -j"$(nproc || echo 4)" && make install

  # libxcrypt
  cd "$DEPS_DIR"
  [ -d "libxcrypt" ] || {
    wget -q https://github.com/besser82/libxcrypt/archive/refs/tags/v4.5.2.tar.gz -O libxcrypt.tar.gz
    tar xzf libxcrypt.tar.gz && mv libxcrypt-4.5.2 libxcrypt
  }
  cd libxcrypt
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-obsolete-api
  make -j"$(nproc || echo 4)" && make install
}

# ====================== REGEN CONFIGURE ======================
regen_configure() {
  local variant=${1:-all}
  echo "=== Regenerating configuration for variant: $variant ==="

  PYTHON_BUILD="$ANDROID_BUILD_TOP/out/python"
  rm -rf "$PYTHON_BUILD"
  cp -rp "$SRC_TOP" "$PYTHON_BUILD"
  cd "$PYTHON_BUILD"

  # Apply patches from android/patches/
  if [ -d "$PATCHES_DIR" ]; then
    for p in "$PATCHES_DIR"/*.patch; do
      [ -f "$p" ] || continue
      patch -p1 -N --dry-run < "$p" >/dev/null 2>&1 || continue
      echo "Applying patch: $(basename "$p")"
      patch -p1 < "$p"
    done
  fi

  autoreconf -fi

  local cfg_flags="--disable-test-modules --enable-optimizations --without-readline=no"
  [ $CROSS -eq 1 ] && cfg_flags="$cfg_flags --host=$CROSS_HOST"

  BZIP2_CFLAGS="-I$ANDROID_BUILD_TOP/external/bzip2" BZIP2_LIBS="-lbz2" \
    LIBFFI_CFLAGS=" " LIBFFI_LIBS="-lffi" \
    LIBSQLITE3_CFLAGS="-I$PREFIX/include" LIBSQLITE3_LIBS="-L$PREFIX/lib -lsqlite3" \
    ./configure $cfg_flags \
      --with-ncurses=ncursesw \
      --with-tcltk-includes="-I$PREFIX/include" \
      --with-tcltk-libs="-L$PREFIX/lib -ltcl9.0 -ltk9.0" \
      --with-sqlite3="$PREFIX" \
      --with-lzma="$PREFIX" \
      --with-zstd="$PREFIX" \
      --prefix="$PREFIX"

  # Enable modules
  sed -i.bak "s/^#_sqlite3 /_sqlite3 /" Modules/Setup.stdlib
  sed -i.bak "s/^#_curses /_curses /" Modules/Setup.stdlib
  sed -i.bak "s/^#_readline /_readline /" Modules/Setup.stdlib 2>/dev/null || true
  sed -i.bak 's%/\* #undef HAVE_LIBSQLITE3 \*/%#define HAVE_LIBSQLITE3 1%' pyconfig.h

  # General hybrid fixes
  cat >> pyconfig.h << 'EOF'
/* Enhanced hybrid fixes for your Termux Python */
#undef HAVE_CONFSTR
#undef HAVE_LIBINTL_H
#undef HAVE_STROPTS_H
#undef HAVE_WAIT3
#undef HAVE_STATX
#undef HAVE_FEXECVE
#undef HAVE_GETLOADAVG
#undef HAVE_PWRITEV2
#undef HAVE_PREADV2
#undef HAVE_GETPWENT
#undef HAVE_LINK
EOF

  if [ "$HOST_DIR" != "darwin" ]; then
    cat >> pyconfig.h << 'EOF'
#undef PY_HAVE_PERF_TRAMPOLINE
#if defined(__x86_64__) || defined(__aarch64__)
  #define PY_HAVE_PERF_TRAMPOLINE 1
#endif
EOF
  fi

  # Copy base pyconfig
  mkdir -p "$LOCAL_TOP/$HOST_DIR/pyconfig"
  cp pyconfig.h "$LOCAL_TOP/$HOST_DIR/pyconfig/"

  # Bionic variant - minimal size fixes only (no forced crypt/confstr undef)
  if [ "$variant" = "all" ] || [ "$variant" = "bionic" ]; then
    mkdir -p "$LOCAL_TOP/bionic/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/bionic/pyconfig/pyconfig.h"
    bionic_pyconfig="$LOCAL_TOP/bionic/pyconfig/pyconfig.h"

    # Only size adjustments (as per your request)
    sed -i 's%#define SIZEOF_FPOS_T .*%#define SIZEOF_FPOS_T 8%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_LONG .*%#ifdef __LP64__\n#define SIZEOF_LONG 8\n#else\n#define SIZEOF_LONG 4\n#endif%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_LONG_DOUBLE .*%#define SIZEOF_LONG_DOUBLE (SIZEOF_LONG * 2)%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_PTHREAD_T .*%#define SIZEOF_PTHREAD_T SIZEOF_LONG%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_SIZE_T .*%#define SIZEOF_SIZE_T SIZEOF_LONG%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_TIME_T .*%#define SIZEOF_TIME_T SIZEOF_LONG%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_UINTPTR_T .*%#define SIZEOF_UINTPTR_T SIZEOF_LONG%' "$bionic_pyconfig"
    sed -i 's%#define SIZEOF_VOID_P .*%#define SIZEOF_VOID_P SIZEOF_LONG%' "$bionic_pyconfig"
  fi

  # Termux and official variants
  if [ "$variant" = "all" ] || [ "$variant" = "termux" ]; then
    mkdir -p "$LOCAL_TOP/termux/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/termux/pyconfig/pyconfig.h"
  fi
  if [ "$variant" = "all" ] || [ "$variant" = "official" ]; then
    mkdir -p "$LOCAL_TOP/official/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/official/pyconfig/pyconfig.h"
  fi
}

# ====================== FROZEN + CONFIG.C ======================
regen_frozen_and_config() {
  local variant=$1
  cd "$PYTHON_BUILD"

  make -j"$(nproc || echo 8)" Python/frozen.o
  rm -rf "$LOCAL_TOP/Python/frozen_modules"
  cp -rp Python/frozen_modules "$LOCAL_TOP/Python"

  sed -i.bak 's/\*shared\*/\*static\*/' Modules/Setup.stdlib

  echo > Makefile.pre
  Modules/makesetup -c Modules/config.c.in -s Modules -m Makefile.pre \
    "$LOCAL_TOP/$variant/Setup.local" Modules/Setup.stdlib \
    Modules/Setup.bootstrap Modules/Setup 2>/dev/null || true

  cp config.c "$LOCAL_TOP/$variant/"
}

# ====================== MAIN ======================
case "${1:-all}" in
  deps)
    build_deps
    ;;
  configure)
    regen_configure "${2#--variant=}"
    ;;
  all)
    build_deps
    regen_configure all
    for v in "$HOST_DIR" bionic termux official; do
      regen_frozen_and_config "$v"
    done
    echo "=== All regeneration done ==="
    echo "Next step: Run the official modified android.py for building"
    ;;
  *)
    echo "Usage:"
    echo "  ./android/regen.sh all"
    echo "  CROSS=1 CROSS_TARGET=aarch64-linux-android34 ./android/regen.sh all"
    echo "  ./android/regen.sh deps"
    exit 1
    ;;
esac

echo "Patches were loaded from: $PATCHES_DIR"
echo "Generated files are ready in android/{bionic,termux,official,$HOST_DIR}/"
