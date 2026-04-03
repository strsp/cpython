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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_TOP="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_TOP="$SRC_TOP/bee"
DEPS_DIR="$LOCAL_TOP/deps"
PATCHES_DIR="$LOCAL_TOP/patches"
ANDROID_BUILD_TOP="$SRC_TOP"

# PYTHON_BUILD is global so regen_configure and regen_frozen_and_config share it
PYTHON_BUILD="$ANDROID_BUILD_TOP/out/python"

mkdir -p "$PYTHON_BUILD"
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

BUILD_TRIPLET="$(uname -m)-pc-linux-gnu"
[ "$(uname)" = "Darwin" ] && BUILD_TRIPLET="$(uname -m)-apple-darwin"

# ====================== TERMUX NATIVE DETECTION ======================
# Detect Termux: if TERMUX_PREFIX or PREFIX points to a Termux installation,
# honour it — but don't let it clobber the deps install prefix we set below.
TERMUX_PREFIX_DETECTED=""
_tp="${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}"
if [ -d "$_tp" ] && [ "$_tp" != "/" ]; then
  TERMUX_PREFIX_DETECTED="$_tp"
fi

# ====================== PREFIX FOR DEPENDENCIES ======================
# Use an explicit deps install dir; never inherit a Termux prefix as PREFIX
# because that would cause dep builds to overwrite system Termux files.
export PREFIX="${DEPS_PREFIX:-$DEPS_DIR/install}"
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin"
export PATH="$PREFIX/bin:$PATH"

# ====================== CROSS / NDK TOOLCHAIN ======================
CROSS=${CROSS:-0}
CROSS_TARGET=${CROSS_TARGET:-aarch64-linux-android34}

# CROSS_HOST: the GNU triplet passed to ./configure --host=
# In native builds this stays empty; configure is called without --host.
CROSS_HOST=""

if [ $CROSS -eq 1 ]; then
  echo "=== CROSS-COMPILE MODE (NDK) - target=$CROSS_TARGET ==="

  # Derive GNU triplet (no API suffix) and API level from CROSS_TARGET.
  # e.g. aarch64-linux-android34  -> HOST=aarch64-linux-android  API=34
  #      armv7a-linux-androideabi21 -> HOST=arm-linux-androideabi  API=21
  export HOST
  HOST="$(echo "$CROSS_TARGET" | sed 's/[0-9]*$//')"
  export ANDROID_API_LEVEL
  ANDROID_API_LEVEL="$(echo "$CROSS_TARGET" | grep -o '[0-9]*$')"
  export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-21}"

  # Normalise armv7a -> arm for autoconf
  if echo "$HOST" | grep -q 'armv7a-linux-androideabi'; then
    export HOST=arm-linux-androideabi
  fi

  ANDROID_ENV="$SRC_TOP/Android/android-env.sh"
  [ -f "$ANDROID_ENV" ] || fail \
    "Android/android-env.sh not found at $ANDROID_ENV. Run from a CPython source tree."

  if [ -z "${ANDROID_HOME:-}" ]; then
    for _p in "$HOME/Android/Sdk" "$HOME/android-sdk" \
              "${ANDROID_SDK_ROOT:-__none__}"; do
      [ -d "$_p" ] && export ANDROID_HOME="$_p" && break
    done
    [ -z "${ANDROID_HOME:-}" ] && fail \
      "ANDROID_HOME not set and no SDK found in default locations."
  fi

  # Source the official android-env.sh (sets CC, CXX, AR, CFLAGS, LDFLAGS …)
  # shellcheck source=Android/android-env.sh
  . "$ANDROID_ENV"

  # After sourcing, HOST is the canonical GNU triplet; use it for --host=
  CROSS_HOST="$HOST"

  # Derive ANDROID_ABI for CMake from HOST / CROSS_TARGET
  # NDK CMake toolchain uses ANDROID_ABI, not the GNU triplet.
  if [ -z "${ANDROID_ABI:-}" ]; then
    case "$HOST" in
      aarch64-linux-android*)  export ANDROID_ABI=arm64-v8a ;;
      arm-linux-androideabi*)  export ANDROID_ABI=armeabi-v7a ;;
      x86_64-linux-android*)   export ANDROID_ABI=x86_64 ;;
      i686-linux-android*)     export ANDROID_ABI=x86 ;;
      *) fail "Unknown HOST triplet '$HOST'; cannot derive ANDROID_ABI." ;;
    esac
  fi

  # Locate the NDK CMake toolchain file if not already set.
  # android-env.sh does not export ANDROID_CMAKE_TOOLCHAIN_FILE, so we
  # derive it ourselves from ANDROID_HOME and the NDK version in use.
  if [ -z "${ANDROID_CMAKE_TOOLCHAIN_FILE:-}" ]; then
    _ndk_dir="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk}}"
    # If ndk/ is a directory of versioned NDKs, pick the highest version.
    if [ -d "$_ndk_dir" ] && ! [ -f "$_ndk_dir/build/cmake/android.toolchain.cmake" ]; then
      _ndk_dir="$(find "$_ndk_dir" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)"
    fi
    _tc="$_ndk_dir/build/cmake/android.toolchain.cmake"
    [ -f "$_tc" ] && export ANDROID_CMAKE_TOOLCHAIN_FILE="$_tc"
  fi

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

  if [ "$(uname)" = "Darwin" ]; then
    CPU_COUNT="$(sysctl -n hw.ncpu)"
  else
    CPU_COUNT="$(nproc)"
  fi
  export CPU_COUNT

  # Append dep prefix flags manually (android-env.sh does this when PREFIX is set).
  export CFLAGS="${CFLAGS:+$CFLAGS }-I$PREFIX/include"
  export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-I$PREFIX/include"
  export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L$PREFIX/lib"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

# ====================== HELPER: portable in-place sed ======================
sedi() {
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ====================== HELPER: autoconf --host / --build flags =============
# In native builds CROSS_HOST is empty and --host must be omitted entirely.
# (Passing --host=$(uname -m)-pc-linux-gnu in a native build is harmless on
# Linux but causes configure to enable cross-compilation mode on macOS.)
cross_flags() {
  if [ -n "$CROSS_HOST" ]; then
    echo "--host=$CROSS_HOST --build=$BUILD_TRIPLET"
  fi
}

# ====================== BUILD DEPENDENCIES ======================

build_zlib() {
  local name=zlib ver=1.3.1
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://zlib.net/zlib-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/zlib-${ver}" "$dir"
  }

  if [ $CROSS -eq 1 ]; then
    # zlib's configure does not support autoconf --host; use CC override instead.
    (cd "$dir" && \
      CFLAGS="$CFLAGS" \
      ./configure --prefix="$PREFIX" --static && \
      make -j"$CPU_COUNT" && \
      make install)
  else
    (cd "$dir" && \
      ./configure --prefix="$PREFIX" --static && \
      make -j"$CPU_COUNT" && \
      make install)
  fi
}

build_openssl() {
  local name=openssl ver=3.3.2
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://www.openssl.org/source/openssl-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/openssl-${ver}" "$dir"
  }

  # Map GNU triplet / ANDROID_ABI to an OpenSSL target name.
  local ossl_target="linux-generic64"
  if [ $CROSS -eq 1 ]; then
    case "${ANDROID_ABI:-}" in
      arm64-v8a)   ossl_target=android-arm64 ;;
      armeabi-v7a) ossl_target=android-arm ;;
      x86_64)      ossl_target=android-x86_64 ;;
      x86)         ossl_target=android-x86 ;;
    esac
  else
    case "$(uname -m)" in
      x86_64)  ossl_target=linux-x86_64 ;;
      aarch64) ossl_target=linux-aarch64 ;;
      arm*)    ossl_target=linux-armv4 ;;
      darwin*) ossl_target=darwin64-$(uname -m)-cc ;;
    esac
    [ "$(uname)" = "Darwin" ] && \
      ossl_target="darwin64-$(uname -m)-cc"
  fi

  (cd "$dir" && \
    ./Configure \
      "$ossl_target" \
      --prefix="$PREFIX" \
      --openssldir="$PREFIX/ssl" \
      no-shared \
      no-tests \
      no-ui-console \
      -D__ANDROID_API__="${ANDROID_API_LEVEL:-21}" \
      "${CROSS_HOST:+--cross-compile-prefix=}" && \
    make -j"$CPU_COUNT" && \
    make install_sw)
}

build_zstd() {
  local name=zstd ver=1.5.7
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    wget -q "https://github.com/facebook/zstd/releases/download/v${ver}/zstd-${ver}.tar.gz" -O "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/zstd-${ver}" "$dir"
  }

  local cmake_cross_flags=""
  if [ $CROSS -eq 1 ] && [ -n "${ANDROID_CMAKE_TOOLCHAIN_FILE:-}" ]; then
    cmake_cross_flags="-DCMAKE_TOOLCHAIN_FILE=$ANDROID_CMAKE_TOOLCHAIN_FILE \
      -DANDROID_ABI=${ANDROID_ABI} \
      -DANDROID_PLATFORM=android-${ANDROID_API_LEVEL} \
      -DANDROID_STL=none"
  fi

  # shellcheck disable=SC2086
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
  # shellcheck disable=SC2046
  (cd "$dir/unix" && \
    ./configure --prefix="$PREFIX" --disable-shared $(cross_flags) && \
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
  # shellcheck disable=SC2046
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --disable-shared $(cross_flags) && \
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
  # shellcheck disable=SC2046
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --disable-shared $(cross_flags) \
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
  # shellcheck disable=SC2046
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" \
      --disable-shared $(cross_flags) \
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
  # shellcheck disable=SC2046
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" --with-curses --disable-shared $(cross_flags) && \
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
  # shellcheck disable=SC2046
  (cd "$dir" && \
    [ -f configure ] || autoreconf -fi && \
    ./configure --prefix="$PREFIX" --disable-shared $(cross_flags) \
      --disable-obsolete-api && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_deps() {
  echo "=== Building all dependencies ==="
  build_zlib
  build_openssl
  build_zstd
  build_tcl
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

  rm -rf "$PYTHON_BUILD"
  cp -rp "$SRC_TOP" "$PYTHON_BUILD"
  cd "$PYTHON_BUILD"

  # Apply patches from bee/patches/ in sorted order.
  if [ -d "$PATCHES_DIR" ]; then
    for p in $(find "$PATCHES_DIR" -maxdepth 1 \( -name '*.patch' -o -name '*.diff' \) | sort); do
      [ -f "$p" ] || continue
      name="$(basename "$p")"
      if patch -p1 --dry-run < "$p" >/dev/null 2>&1; then
        echo "Applying patch: $name"
        patch -p1 < "$p"
      elif patch -p1 -R --dry-run < "$p" >/dev/null 2>&1; then
        echo "Skipping already-applied patch: $name"
      else
        fail "Patch failed to apply and is not already applied: $name"
      fi
    done
  fi

  autoreconf -fi

  # Build --host/--build flags for configure (empty in native builds).
  local host_build_flags
  host_build_flags="$(cross_flags)"

  BZIP2_CFLAGS="-I$ANDROID_BUILD_TOP/external/bzip2" \
  BZIP2_LIBS="-lbz2" \
  LIBFFI_CFLAGS=" " \
  LIBFFI_LIBS="-lffi" \
  LIBSQLITE3_CFLAGS="-I$PREFIX/include" \
  LIBSQLITE3_LIBS="-L$PREFIX/lib -lsqlite3" \
  OPENSSL_CFLAGS="-I$PREFIX/include" \
  OPENSSL_LIBS="-L$PREFIX/lib -lssl -lcrypto" \
  ZLIB_CFLAGS="-I$PREFIX/include" \
  ZLIB_LIBS="-L$PREFIX/lib -lz" \
    ./configure \
      --disable-test-modules \
      --enable-optimizations \
      --with-readline \
      --with-openssl="$PREFIX" \
      --with-zlib \
      $host_build_flags \
      --prefix="$PREFIX"

  # Enable modules in Setup.stdlib
  sedi "s/^#_sqlite3 /_sqlite3 /"   Modules/Setup.stdlib
  sedi "s/^#_curses /_curses /"     Modules/Setup.stdlib
  sedi "s/^#_ssl /_ssl /"           Modules/Setup.stdlib 2>/dev/null || true
  sedi "s/^#zlib /_zlib /"          Modules/Setup.stdlib 2>/dev/null || true
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

  # regen-frozen requires a working host Python interpreter; skip in
  # cross-compile mode because the built binaries cannot run on the host.
  if [ $CROSS -eq 0 ]; then
    make -j"$CPU_COUNT" regen-frozen
    rm -rf "$LOCAL_TOP/Python/frozen_modules"
    mkdir -p "$LOCAL_TOP/Python"
    cp -rp Python/frozen_modules "$LOCAL_TOP/Python/"
  else
    echo "Skipping regen-frozen in cross-compile mode (host cannot run target binaries)."
  fi

  mkdir -p "$variant_dir"
  [ -f "$variant_dir/Setup.local" ] || echo "*static*" > "$variant_dir/Setup.local"

  # Switch to static linking in Setup.stdlib
  sedi 's/\*shared\*/\*static\*/' Modules/Setup.stdlib

  # makesetup -c <output_config.c> writes the file to the given path.
  # Specify an explicit output path so we always know where it lands.
  local config_c_out="$PYTHON_BUILD/config_${variant}.c"
  printf '' > Makefile.pre
  Modules/makesetup \
    -c "$config_c_out" \
    -s Modules \
    -m Makefile.pre \
    "$variant_dir/Setup.local" \
    Modules/Setup.stdlib \
    Modules/Setup.bootstrap \
    Modules/Setup 2>/dev/null || true

  [ -f "$config_c_out" ] && cp "$config_c_out" "$variant_dir/config.c"
}

# ====================== MAIN ======================
case "${1:-all}" in
  deps)
    build_deps
    ;;
  zlib)
    build_zlib
    ;;
  openssl)
    build_openssl
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
    echo "  ./bee/regen.sh zlib"
    echo "  ./bee/regen.sh openssl"
    echo "  ./bee/regen.sh configure [--variant=bionic|termux|official|all]"
    exit 1
    ;;
esac

echo "Patches loaded from: $PATCHES_DIR"
echo "All generated files are in: bee/{bionic,termux,official,$HOST_DIR}/"
