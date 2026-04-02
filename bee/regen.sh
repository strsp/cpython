#!/bin/bash -ex
#
# bee/regen.sh
# Regenerates configuration for hybrid Python (AOSP + Enhanced Termux)
# Patches loaded from bee/patches/
# After running this, use your modified official android.py for building
#
# Cross-compile usage:
#   CROSS=1 CROSS_TARGET=aarch64-linux-android34 \
#     ANDROID_HOME=/path/to/sdk ./bee/regen.sh all
#
# Native AOSP usage (no NDK):
#   ./bee/regen.sh all
#
# You may also pre-source android-toolchain.sh yourself and then call this
# script; it will detect the already-exported toolchain and skip re-sourcing.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC_TOP=$(pwd)
LOCAL_TOP=$SRC_TOP/bee
DEPS_DIR="$LOCAL_TOP/deps"
PATCHES_DIR="$LOCAL_TOP/patches"
ANDROID_BUILD_TOP=$(cd ../../..; pwd)

mkdir -p "$DEPS_DIR" "$LOCAL_TOP" "$PATCHES_DIR"

fail() { echo "ERROR: $1" >&2; exit 1; }

# ====================== HOST DETECTION (build machine) ======================
if [ "$(uname)" = "Darwin" ]; then
  HOST_DIR=darwin
elif [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
  HOST_DIR=linux_arm64
else
  HOST_DIR=linux_x86_64
fi

# ====================== TERMUX NATIVE DETECTION ======================
TERMUX_PREFIX=${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}
[ -d "$TERMUX_PREFIX" ] && export PREFIX="$TERMUX_PREFIX"

# ====================== PREFIX FOR DEPENDENCIES ======================
export PREFIX=${PREFIX:-$DEPS_DIR/install}
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin"
export PATH="$PREFIX/bin:$PATH"

# ====================== CROSS / NDK TOOLCHAIN ======================
CROSS=${CROSS:-0}
CROSS_TARGET=${CROSS_TARGET:-aarch64-linux-android34}

if [ $CROSS -eq 1 ]; then
  echo "=== CROSS-COMPILE MODE (NDK) - target=$CROSS_TARGET ==="

  # android-env.sh requires HOST (GNU triplet, no API suffix) and
  # ANDROID_API_LEVEL as separate variables.  Derive both from CROSS_TARGET
  # which encodes them together, e.g.:
  #   aarch64-linux-android34   -> HOST=aarch64-linux-android   API=34
  #   armv7a-linux-androideabi21 -> HOST=arm-linux-androideabi  API=21
  export HOST=$(echo "$CROSS_TARGET" | sed 's/[0-9]*$//')
  export ANDROID_API_LEVEL=$(echo "$CROSS_TARGET" | grep -o '[0-9]*$')
  export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-21}

  # armv7a-linux-androideabi is the NDK clang-launcher triplet; the GNU
  # triplet used by autoconf and regen.sh is arm-linux-androideabi.
  # android-env.sh already maps arm-linux-androideabi -> armv7a for the
  # clang launcher internally, so normalise HOST to the GNU form here.
  if echo "$HOST" | grep -q 'armv7a-linux-androideabi'; then
    export HOST=arm-linux-androideabi
  fi

  # Locate android-env.sh: it lives in Android/ relative to the CPython
  # source root (SRC_TOP), which is two levels above bee/.
  ANDROID_ENV="$SRC_TOP/Android/android-env.sh"
  [ -f "$ANDROID_ENV" ] || {
    echo "ERROR: Android/android-env.sh not found at $ANDROID_ENV"
    echo "       This script must be run from within a CPython source tree."
    exit 1
  }

  # android-env.sh requires ANDROID_HOME; try common locations if unset.
  if [ -z "${ANDROID_HOME:-}" ]; then
    for _p in "$HOME/Android/Sdk" "$HOME/android-sdk" \
              "${ANDROID_SDK_ROOT:-__none__}"; do
      [ -d "$_p" ] && export ANDROID_HOME="$_p" && break
    done
    [ -z "${ANDROID_HOME:-}" ] && {
      echo "ERROR: ANDROID_HOME not set and no SDK found in default locations."
      echo "       Set ANDROID_HOME=/path/to/android/sdk and re-run."
      exit 1
    }
  fi

  # Source the official android-env.sh.  After this point the following are
  # set and exported by android-env.sh (with our two suggested patches applied):
  #   CC CXX AR AS LD NM RANLIB READELF STRIP
  #   CFLAGS CXXFLAGS LDFLAGS
  #   PKG_CONFIG PKG_CONFIG_LIBDIR   (when PREFIX is set)
  #   CPU_COUNT                      (requires the export fix in android-env.sh)
  #   HOST                           (requires the export fix in android-env.sh)
  # shellcheck source=Android/android-env.sh
  . "$ANDROID_ENV"

  # CROSS_HOST is what regen.sh passes to ./configure --host=.
  # It is identical to HOST after android-env.sh has been sourced.
  export CROSS_HOST="$HOST"

else
  # ---- Native AOSP build (no NDK, no android-env.sh) ----
  CLANG_VERSION=$(cd "$ANDROID_BUILD_TOP" 2>/dev/null \
    && build/soong/scripts/get_clang_version.py 2>/dev/null \
    || echo "host")
  if [ "$HOST_DIR" = "linux_x86_64" ]; then
    export CC="$ANDROID_BUILD_TOP/prebuilts/clang/host/linux-x86/${CLANG_VERSION}/bin/clang"
  else
    export CC=clang
  fi
  export CXX="${CC}++"

  # CPU_COUNT: mirror the same Darwin/Linux logic that android-env.sh uses,
  # so all build_* functions always have a valid $CPU_COUNT regardless of path.
  if [ "$(uname)" = "Darwin" ]; then
    CPU_COUNT="$(sysctl -n hw.ncpu)"
  else
    CPU_COUNT="$(nproc)"
  fi
  export CPU_COUNT

  # In the native path android-env.sh is not sourced, so append the dep
  # prefix flags manually (android-env.sh does this when PREFIX is set).
  export CFLAGS="${CFLAGS:+$CFLAGS }-I$PREFIX/include"
  export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-I$PREFIX/include"
  export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L$PREFIX/lib"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

# ====================== BUILD DEPENDENCIES ======================

# Helper: portable in-place sed (no .bak debris)
sedi() {
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

build_zstd() {
  local name=zstd ver=1.5.7
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://github.com/facebook/zstd/releases/download/v${ver}/zstd-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/zstd-${ver}" "$dir"
  }

  # When cross-compiling with the NDK, pass the NDK's own CMake toolchain
  # file plus the ABI and API level.  android-toolchain.sh exports both
  # ANDROID_CMAKE_TOOLCHAIN_FILE and ANDROID_ABI for exactly this purpose.
  local cmake_cross_flags=""
  if [ $CROSS -eq 1 ] && [ -n "${ANDROID_CMAKE_TOOLCHAIN_FILE:-}" ]; then
    cmake_cross_flags="-DCMAKE_TOOLCHAIN_FILE=$ANDROID_CMAKE_TOOLCHAIN_FILE \
      -DANDROID_ABI=${ANDROID_ABI} \
      -DANDROID_PLATFORM=android-${ANDROID_API_LEVEL} \
      -DANDROID_STL=none"
  fi

  # shellcheck disable=SC2086  (word-splitting of cmake_cross_flags is intentional)
  cmake -S "$dir/build/cmake" -B "$dir/build_out" \
    $cmake_cross_flags \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$dir/build_out" --parallel "$CPU_COUNT"
  cmake --install "$dir/build_out"
}

build_tcl() {
  local name=tcl ver=9.0.3
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://prdownloads.sourceforge.net/tcl/tcl${ver}-src.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/tcl${ver}" "$dir"
  }
  (cd "$dir/unix" && \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-tzdata && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_tk() {
  local name=tk ver=9.0.3
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://prdownloads.sourceforge.net/tcl/tk${ver}-src.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/tk${ver}" "$dir"
  }
  (cd "$dir/unix" && \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static \
      --with-tcl="$DEPS_DIR/tcl/unix" --without-x && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_sqlite() {
  local name=sqlite ver=3500400
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://sqlite.org/2024/sqlite-autoconf-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/sqlite-autoconf-${ver}" "$dir"
  }
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_xz() {
  local name=xz ver=5.8.1
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://github.com/tukaani-project/xz/releases/download/v${ver}/xz-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/xz-${ver}" "$dir"
  }
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static \
      --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
      --disable-lzma-links --disable-scripts --disable-doc && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_ncurses() {
  local name=ncurses ver=6.5
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://invisible-island.net/archives/ncurses/ncurses-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/ncurses-${ver}" "$dir"
  }
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" \
      --disable-shared --enable-static \
      --enable-widec \
      --without-normal --without-progs --without-x --disable-rpath && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_readline() {
  local name=readline ver=8.2
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://ftp.gnu.org/gnu/readline/readline-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/readline-${ver}" "$dir"
  }
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --with-curses --disable-shared --enable-static && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_libxcrypt() {
  local name=libxcrypt ver=4.5.2
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://github.com/besser82/libxcrypt/archive/refs/tags/v${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/libxcrypt-${ver}" "$dir"
  }
  (cd "$dir" && \
    [ -f configure ] || autoreconf -fi && \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-obsolete-api && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_deps() {
  echo "=== Building all dependencies ==="
  build_zstd
  build_tcl
  build_tk
  build_sqlite
  build_xz
  build_ncurses
  build_readline
  build_libxcrypt
}

# ====================== REGEN CONFIGURE ======================
regen_configure() {
  local variant=${1:-all}
  echo "=== Regenerating configuration for variant: $variant ==="

  PYTHON_BUILD="$ANDROID_BUILD_TOP/out/python"
  rm -rf "$PYTHON_BUILD"
  cp -rp "$SRC_TOP" "$PYTHON_BUILD"
  cd "$PYTHON_BUILD"

  # Apply patches from bee/patches/
  # Patches are sorted by filename so numbered prefixes (e.g. 001-foo.patch)
  # control application order reliably.
  if [ -d "$PATCHES_DIR" ]; then
    for p in $(find "$PATCHES_DIR" -maxdepth 1 \( -name '*.patch' -o -name '*.diff' \) | sort); do
      [ -f "$p" ] || continue
      name="$(basename "$p")"

      # Forward dry-run: can the patch be applied cleanly?
      if patch -p1 --dry-run < "$p" >/dev/null 2>&1; then
        echo "Applying patch: $name"
        patch -p1 < "$p"

      # Reverse dry-run: is the patch already applied?
      elif patch -p1 -R --dry-run < "$p" >/dev/null 2>&1; then
        echo "Skipping already-applied patch: $name"

      # Neither forward nor reverse worked — this is a real failure.
      else
        fail "Patch failed to apply and is not already applied: $name"
      fi
    done
  fi

  autoreconf -fi

  # --with-readline (not --without-readline=no which is invalid)
  local cfg_flags="--disable-test-modules --enable-optimizations --with-readline"
  [ $CROSS -eq 1 ] && cfg_flags="$cfg_flags --host=$CROSS_HOST"

  BZIP2_CFLAGS="-I$ANDROID_BUILD_TOP/external/bzip2" \
  BZIP2_LIBS="-lbz2" \
  LIBFFI_CFLAGS=" " \
  LIBFFI_LIBS="-lffi" \
  LIBSQLITE3_CFLAGS="-I$PREFIX/include" \
  LIBSQLITE3_LIBS="-L$PREFIX/lib -lsqlite3" \
    ./configure $cfg_flags \
      --with-ncurses=ncursesw \
      --with-tcltk-includes="-I$PREFIX/include" \
      --with-tcltk-libs="-L$PREFIX/lib -ltcl9.0 -ltk9.0" \
      --with-sqlite3="$PREFIX" \
      --with-lzma="$PREFIX" \
      --with-zstd="$PREFIX" \
      --prefix="$PREFIX"

  # Enable modules
  sedi "s/^#_sqlite3 /_sqlite3 /" Modules/Setup.stdlib
  sedi "s/^#_curses /_curses /"   Modules/Setup.stdlib
  sedi "s/^#_readline /_readline /" Modules/Setup.stdlib 2>/dev/null || true
  sedi 's%/\* #undef HAVE_LIBSQLITE3 \*/%#define HAVE_LIBSQLITE3 1%' pyconfig.h

  # General hybrid fixes
  cat >> pyconfig.h << 'EOF'
/* Enhanced hybrid fixes for Termux Python */
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

  # Copy base (host-specific)
  mkdir -p "$LOCAL_TOP/$HOST_DIR/pyconfig"
  cp pyconfig.h "$LOCAL_TOP/$HOST_DIR/pyconfig/"

  # --- Bionic variant ---
  if [ "$variant" = "all" ] || [ "$variant" = "bionic" ]; then
    mkdir -p "$LOCAL_TOP/bionic/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/bionic/pyconfig/pyconfig.h"
    local bionic_pyconfig="$LOCAL_TOP/bionic/pyconfig/pyconfig.h"

    # Portable multi-line sed replacements using awk instead of \n in sed
    awk '{
      if ($0 ~ /^#define SIZEOF_LONG /) {
        print "#ifdef __LP64__"
        print "#define SIZEOF_LONG 8"
        print "#else"
        print "#define SIZEOF_LONG 4"
        print "#endif"
      } else { print }
    }' "$bionic_pyconfig" > "$bionic_pyconfig.tmp" && mv "$bionic_pyconfig.tmp" "$bionic_pyconfig"

    sedi 's%#define SIZEOF_FPOS_T .*%#define SIZEOF_FPOS_T 8%'                            "$bionic_pyconfig"
    sedi 's%#define SIZEOF_LONG_DOUBLE .*%#define SIZEOF_LONG_DOUBLE (SIZEOF_LONG * 2)%'  "$bionic_pyconfig"
    sedi 's%#define SIZEOF_PTHREAD_T .*%#define SIZEOF_PTHREAD_T SIZEOF_LONG%'            "$bionic_pyconfig"
    sedi 's%#define SIZEOF_SIZE_T .*%#define SIZEOF_SIZE_T SIZEOF_LONG%'                  "$bionic_pyconfig"
    sedi 's%#define SIZEOF_TIME_T .*%#define SIZEOF_TIME_T SIZEOF_LONG%'                  "$bionic_pyconfig"
    sedi 's%#define SIZEOF_UINTPTR_T .*%#define SIZEOF_UINTPTR_T SIZEOF_LONG%'            "$bionic_pyconfig"
    sedi 's%#define SIZEOF_VOID_P .*%#define SIZEOF_VOID_P SIZEOF_LONG%'                  "$bionic_pyconfig"
  fi

  # --- Termux variant ---
  if [ "$variant" = "all" ] || [ "$variant" = "termux" ]; then
    mkdir -p "$LOCAL_TOP/termux/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/termux/pyconfig/pyconfig.h"
  fi

  # --- Official variant ---
  if [ "$variant" = "all" ] || [ "$variant" = "official" ]; then
    mkdir -p "$LOCAL_TOP/official/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/official/pyconfig/pyconfig.h"
  fi
}

# ====================== FROZEN MODULES + CONFIG.C ======================
regen_frozen_and_config() {
  local variant=$1
  local variant_dir="$LOCAL_TOP/$variant"

  cd "$PYTHON_BUILD"

  # Regenerate frozen modules via the correct make target
  make -j"$CPU_COUNT" regen-frozen
  rm -rf "$LOCAL_TOP/Python/frozen_modules"
  mkdir -p "$LOCAL_TOP/Python"
  cp -rp Python/frozen_modules "$LOCAL_TOP/Python/"

  # Ensure variant directory and a minimal Setup.local exist
  mkdir -p "$variant_dir"
  [ -f "$variant_dir/Setup.local" ] || echo "*static*" > "$variant_dir/Setup.local"

  # Switch to static linking in Setup.stdlib
  sedi 's/\*shared\*/\*static\*/' Modules/Setup.stdlib

  # Generate config.c into the build dir, then copy to variant dir
  printf '' > Makefile.pre
  Modules/makesetup -c Modules/config.c.in -s Modules -m Makefile.pre \
    "$variant_dir/Setup.local" \
    Modules/Setup.stdlib \
    Modules/Setup.bootstrap \
    Modules/Setup 2>/dev/null || true

  # config.c is written to the current directory ($PYTHON_BUILD)
  [ -f config.c ] && cp config.c "$variant_dir/config.c"
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
    echo "=== Regeneration completed successfully ==="
    echo "Next: Run your modified official android.py to build Python"
    ;;
  *)
    echo "Usage:"
    echo "  ./bee/regen.sh all"
    echo "  CROSS=1 CROSS_TARGET=aarch64-linux-android34 ./bee/regen.sh all"
    echo "  ./bee/regen.sh deps"
    echo "  ./bee/regen.sh configure [--variant=bionic|termux|official|all]"
    exit 1
    ;;
esac

echo "Patches loaded from: $PATCHES_DIR"
echo "All generated files are in: bee/{bionic,termux,official,$HOST_DIR}/"

