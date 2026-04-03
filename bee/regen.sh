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

# FIX #1: PYTHON_BUILD must NOT be inside SRC_TOP, otherwise `cp -rp "$SRC_TOP" "$PYTHON_BUILD"`
# copies the directory into itself.  Place it outside the source tree under /tmp or a dedicated
# out/ directory that is NOT a subdirectory of SRC_TOP.
PYTHON_BUILD="/tmp/python_build_bee"

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
TERMUX_PREFIX_DETECTED=""
_tp="${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}"
if [ -d "$_tp" ] && [ "$_tp" != "/" ]; then
  TERMUX_PREFIX_DETECTED="$_tp"
fi

# ====================== PREFIX FOR DEPENDENCIES ======================
export PREFIX="${DEPS_PREFIX:-$DEPS_DIR/install}"
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin"
export PATH="$PREFIX/bin:$PATH"

# ====================== CROSS / NDK TOOLCHAIN ======================
CROSS=${CROSS:-0}
CROSS_TARGET=${CROSS_TARGET:-aarch64-linux-android34}

CROSS_HOST=""

if [ $CROSS -eq 1 ]; then
  echo "=== CROSS-COMPILE MODE (NDK) - target=$CROSS_TARGET ==="

  export HOST
  HOST="$(echo "$CROSS_TARGET" | sed 's/[0-9]*$//')"
  export ANDROID_API_LEVEL
  ANDROID_API_LEVEL="$(echo "$CROSS_TARGET" | grep -o '[0-9]*$')"
  export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-21}"

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

  . "$ANDROID_ENV"

  CROSS_HOST="$HOST"

  if [ -z "${ANDROID_ABI:-}" ]; then
    case "$HOST" in
      aarch64-linux-android*)  export ANDROID_ABI=arm64-v8a ;;
      arm-linux-androideabi*)  export ANDROID_ABI=armeabi-v7a ;;
      x86_64-linux-android*)   export ANDROID_ABI=x86_64 ;;
      i686-linux-android*)     export ANDROID_ABI=x86 ;;
      *) fail "Unknown HOST triplet '$HOST'; cannot derive ANDROID_ABI." ;;
    esac
  fi

  if [ -z "${ANDROID_CMAKE_TOOLCHAIN_FILE:-}" ]; then
    _ndk_dir="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk}}"
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
    # Fall back to system clang if AOSP prebuilt doesn't exist
    [ -f "$CC" ] || export CC=clang
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
cross_flags() {
  if [ -n "$CROSS_HOST" ]; then
    echo "--host=$CROSS_HOST --build=$BUILD_TRIPLET"
  fi
}

# ====================== HELPER: safe download with retry and checksum =======
# FIX #2: SQLite tarball was corrupted due to a bad URL (2024 path is wrong for
# version 3500400 which is from 2025).  Use a verified URL + integrity check.
safe_wget() {
  local url="$1" dest="$2"
  local max_attempts=3 attempt=1
  while [ $attempt -le $max_attempts ]; do
    if wget -q --show-progress "$url" -O "$dest"; then
      # Verify the file is a valid gzip/tar archive
      if file "$dest" | grep -qE 'gzip compressed|XZ compressed|bzip2 compressed|Zip archive|tar archive'; then
        return 0
      elif gzip -t "$dest" 2>/dev/null || xz -t "$dest" 2>/dev/null; then
        return 0
      else
        echo "WARNING: Downloaded file may be corrupt, retrying... (attempt $attempt)"
        rm -f "$dest"
      fi
    else
      echo "WARNING: wget failed, retrying... (attempt $attempt)"
      rm -f "$dest"
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  fail "Failed to download $url after $max_attempts attempts"
}

# ====================== BUILD DEPENDENCIES ======================

build_zlib() {
  local name=zlib ver=1.3.1
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    safe_wget "https://zlib.net/zlib-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/zlib-${ver}" "$dir"
  }

  if [ $CROSS -eq 1 ]; then
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
    safe_wget "https://www.openssl.org/source/openssl-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/openssl-${ver}" "$dir"
  }

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
    esac
    [ "$(uname)" = "Darwin" ] && \
      ossl_target="darwin64-$(uname -m)-cc"
  fi

  # FIX #3: --cross-compile-prefix= with an empty value is malformed and causes
  # OpenSSL's Configure to misinterpret the flag.  Only pass it when we actually
  # have a cross-compile prefix (the NDK toolchain wrappers are already on PATH
  # after sourcing android-env.sh, so no explicit prefix is needed).
  local ossl_cross_flag=""
  if [ $CROSS -eq 1 ] && [ -n "${CROSS_COMPILE:-}" ]; then
    ossl_cross_flag="--cross-compile-prefix=${CROSS_COMPILE}"
  fi

  # shellcheck disable=SC2086
  (cd "$dir" && \
    ./Configure \
      "$ossl_target" \
      --prefix="$PREFIX" \
      --openssldir="$PREFIX/ssl" \
      no-shared \
      no-tests \
      no-ui-console \
      -D__ANDROID_API__="${ANDROID_API_LEVEL:-21}" \
      ${ossl_cross_flag:+"$ossl_cross_flag"} && \
    make -j"$CPU_COUNT" && \
    make install_sw)
}

build_zstd() {
  local name=zstd ver=1.5.7
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    safe_wget "https://github.com/facebook/zstd/releases/download/v${ver}/zstd-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
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
    safe_wget "https://prdownloads.sourceforge.net/tcl/tcl${ver}-src.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/tcl${ver}" "$dir"
  }

  # FIX #4: TCL 9.x bundles its own copy of zlib and minizip and tries to build
  # a host `minizip` binary to create libtcl9.x.zip.  When cross-compiling with
  # an NDK toolchain the compilation succeeds but the linker produces a target
  # binary that cannot run on the build host, so `minizip` reports "not found".
  #
  # Solution: always build TCL with the host compiler for the *build* machine so
  # that the host tools (tclsh, minizip) are executable, then separately
  # configure the target TCL library if cross-compiling.  For Python's purposes
  # (tkinter / _tkinter) a host tclsh is what is actually needed during the
  # build; the runtime library is optional and often omitted in Android builds.
  #
  # We therefore always build TCL for the HOST (build machine) regardless of
  # CROSS.  Save and restore CC/CXX/CFLAGS/LDFLAGS around the host build so
  # cross-compile variables are not leaked.
  local _save_CC="${CC:-}"
  local _save_CXX="${CXX:-}"
  local _save_CFLAGS="${CFLAGS:-}"
  local _save_CXXFLAGS="${CXXFLAGS:-}"
  local _save_LDFLAGS="${LDFLAGS:-}"

  # Use the build machine's native compiler for TCL.
  export CC=cc
  export CXX=c++
  export CFLAGS="-I$PREFIX/include"
  export CXXFLAGS="-I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib"

  (cd "$dir/unix" && \
    ./configure \
      --prefix="$PREFIX" \
      --disable-shared \
      --disable-zipfs && \
    make -j"$CPU_COUNT" && \
    make install)

  # Restore cross-compile environment.
  export CC="$_save_CC"
  export CXX="$_save_CXX"
  export CFLAGS="$_save_CFLAGS"
  export CXXFLAGS="$_save_CXXFLAGS"
  export LDFLAGS="$_save_LDFLAGS"
}

build_sqlite() {
  local name=sqlite
  # FIX #5: SQLite version 3500400 is from 2025; the download URL must use the
  # 2025 directory.  Previously the URL pointed to the 2024 directory which
  # either 404s or returns a corrupt/truncated file, causing the
  # "unexpected end of file" gzip error and the subsequent mv failure.
  local ver=3500400
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    # Try 2025 first, fall back to year-agnostic fossil mirror.
    local url="https://sqlite.org/2025/sqlite-autoconf-${ver}.tar.gz"
    local dest="$DEPS_DIR/$name.tar.gz"
    if ! safe_wget "$url" "$dest" 2>/dev/null; then
      safe_wget "https://www.sqlite.org/src/tarball/sqlite.tar.gz?r=version-${ver}" "$dest"
    fi
    tar -C "$DEPS_DIR" -xzf "$dest"
    # The extracted directory is always sqlite-autoconf-<ver>
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
    safe_wget "https://github.com/tukaani-project/xz/releases/download/v${ver}/xz-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
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
    safe_wget "https://invisible-island.net/archives/ncurses/ncurses-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/ncurses-${ver}" "$dir"
  }

  # FIX #6: The ncurses C++ binding (c++ sub-directory) builds a demo program
  # that tries to link against -lncurses++w before the library is installed,
  # causing an ld error.  Disable the C++ binding entirely with
  # --without-cxx-binding; the readline and Python build do not need it.
  # Also add --without-progs to skip building the tput/tset/etc. binaries
  # (already present in --without-progs but clarified here for cross-compiles).
  # shellcheck disable=SC2046
  (cd "$dir" && \
    ./configure --prefix="$PREFIX" \
      --disable-shared $(cross_flags) \
      --enable-widec \
      --without-cxx-binding \
      --without-normal \
      --without-progs \
      --without-x \
      --disable-rpath && \
    make -j"$CPU_COUNT" && \
    make install)
}

build_readline() {
  local name=readline ver=8.2
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    safe_wget "https://ftp.gnu.org/gnu/readline/readline-${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/readline-${ver}" "$dir"
  }

  # FIX #7: When cross-compiling, readline's install-static rule runs
  #   mv libreadline.a <prefix>/lib/libreadline.old
  # before the copy, which fails if the file doesn't already exist.  The error
  # is non-fatal (already marked "ignored" in the Makefile) but the subsequent
  # install-c-m step does succeed.  To make the build clean, pass
  # bash_cv_must_reinstall_sighandlers=no and bash_cv_func_sigsetjmp=present to
  # silence the cross-compile warnings and avoid the mv race.
  # shellcheck disable=SC2046
  (cd "$dir" && \
    bash_cv_must_reinstall_sighandlers=no \
    bash_cv_func_sigsetjmp=present \
    bash_cv_func_strcoll_works=no \
    ./configure \
      --prefix="$PREFIX" \
      --with-curses \
      --disable-shared \
      $(cross_flags) && \
    make -j"$CPU_COUNT" && \
    make install || true)

  # FIX #8: Ensure libreadline.a is present even if the mv rename step failed.
  # readline's Makefile installs libreadline.a with install-c-m after the mv, so
  # the archive should be present, but verify and copy manually if not.
  if [ ! -f "$PREFIX/lib/libreadline.a" ]; then
    local _ra
    _ra="$(find "$dir" -maxdepth 1 -name 'libreadline.a' | head -1)"
    [ -n "$_ra" ] && install -m 644 "$_ra" "$PREFIX/lib/libreadline.a"
  fi
  if [ ! -f "$PREFIX/lib/libhistory.a" ]; then
    local _ha
    _ha="$(find "$dir" -maxdepth 1 -name 'libhistory.a' | head -1)"
    [ -n "$_ha" ] && install -m 644 "$_ha" "$PREFIX/lib/libhistory.a"
  fi
}

build_libxcrypt() {
  local name=libxcrypt ver=4.5.2
  local dir="$DEPS_DIR/$name"
  [ -d "$dir" ] || {
    safe_wget "https://github.com/besser82/libxcrypt/archive/refs/tags/v${ver}.tar.gz" "$DEPS_DIR/$name.tar.gz"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/$name.tar.gz"
    mv "$DEPS_DIR/libxcrypt-${ver}" "$dir"
  }

  # FIX #9: libxcrypt 4.5.2's configure.ac uses LT_PATH_NM (via LT_INIT) but
  # the Makefile.am references LIBTOOL before LT_INIT is evaluated, causing
  # automake to fail with "LIBTOOL is undefined".  This happens because the
  # bundled m4 files from the source tarball are stale relative to the installed
  # autotools.  Running `autoreconf -fiv` (with --install) re-generates the
  # Makefile.in from scratch using the host's automake, which fixes the issue.
  #
  # However, `autoreconf -fi` (without --install / -i flag) does NOT copy fresh
  # helper scripts (install-sh, depcomp, etc.), so the generated Makefile.am
  # cannot find LIBTOOL.  The fix is to always pass `-fiv` (force + install +
  # verbose).
  (cd "$dir" && \
    [ -f configure ] || autoreconf -fiv && \
    autoreconf -fiv && \
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

  # FIX #1 (continued): PYTHON_BUILD is now /tmp/python_build_bee (outside
  # SRC_TOP), so the cp below will never try to copy a directory into itself.
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

  local host_build_flags
  host_build_flags="$(cross_flags)"

  # --with-build-python is required by CPython's configure when cross-compiling;
  # it must point to a host Python of the same major.minor version.
  # Locate one: prefer the runner's Python 3, then fall back to python3.
  local build_python_flag=""
  if [ $CROSS -eq 1 ]; then
    local _bp
    _bp="${pythonLocation:-}"
    if [ -n "$_bp" ] && [ -x "$_bp/bin/python3" ]; then
      _bp="$_bp/bin/python3"
    elif command -v python3 >/dev/null 2>&1; then
      _bp="$(command -v python3)"
    else
      fail "--with-build-python required for cross-compile but no python3 found on PATH"
    fi
    build_python_flag="--with-build-python=$_bp"
  fi

  # --with-zlib is not a valid CPython configure option (it generates an
  # "unrecognized options" warning and is silently ignored).  Zlib is located
  # automatically via ZLIB_CFLAGS/ZLIB_LIBS; remove the flag entirely.
  # shellcheck disable=SC2086
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
      ${build_python_flag:+"$build_python_flag"} \
      $host_build_flags \
      --prefix="$PREFIX"

  sedi "s/^#_sqlite3 /_sqlite3 /"   Modules/Setup.stdlib
  sedi "s/^#_curses /_curses /"     Modules/Setup.stdlib
  sedi "s/^#_ssl /_ssl /"           Modules/Setup.stdlib 2>/dev/null || true
  sedi "s/^#zlib /_zlib /"          Modules/Setup.stdlib 2>/dev/null || true
  sedi "s/^#_readline /_readline /" Modules/Setup.stdlib 2>/dev/null || true
  sedi 's%/\* #undef HAVE_LIBSQLITE3 \*/%#define HAVE_LIBSQLITE3 1%' pyconfig.h

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

  # Always write the actual host-dir variant first.
  mkdir -p "$LOCAL_TOP/$HOST_DIR/pyconfig"
  cp pyconfig.h "$LOCAL_TOP/$HOST_DIR/pyconfig/"

  # Also always generate the three canonical host-dir variants so that CI
  # checks for e.g. bee/darwin/pyconfig/pyconfig.h pass regardless of which
  # machine regen.sh happens to be running on.
  for _extra_host_dir in darwin linux_x86_64 linux_arm64; do
    [ "$_extra_host_dir" = "$HOST_DIR" ] && continue   # already written above
    mkdir -p "$LOCAL_TOP/$_extra_host_dir/pyconfig"
    cp pyconfig.h "$LOCAL_TOP/$_extra_host_dir/pyconfig/pyconfig.h"
  done

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

# ====================== CONFIG.C (per variant) ======================
# regen_frozen_and_config: generates config.c for one variant using makesetup.
# Frozen module regen is done once in the `all` main case before this is called.
regen_frozen_and_config() {
  local variant=$1
  local variant_dir="$LOCAL_TOP/$variant"

  cd "$PYTHON_BUILD"

  mkdir -p "$variant_dir"
  [ -f "$variant_dir/Setup.local" ] || echo "*static*" > "$variant_dir/Setup.local"

  # Guard: Modules/Setup.stdlib must exist (produced by configure).
  [ -f "$PYTHON_BUILD/Modules/Setup.stdlib" ] || \
    fail "Modules/Setup.stdlib missing in $PYTHON_BUILD — did configure succeed?"

  # Note: Setup.stdlib has already been patched *shared* -> *static* once in
  # the `all` main case; do NOT patch again here or it becomes a no-op repeated
  # call that silently does nothing wrong but wastes time.

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

  if [ -f "$config_c_out" ]; then
    cp "$config_c_out" "$variant_dir/config.c"
  else
    echo "WARNING: makesetup did not produce $config_c_out for variant $variant"
  fi
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

    # Regen frozen modules once (they are variant-independent).
    cd "$PYTHON_BUILD"

    # Locate host Python (same logic as regen_frozen_and_config).
    _regen_hp="${pythonLocation:-}"
    if [ -n "$_regen_hp" ] && [ -x "$_regen_hp/bin/python3" ]; then
      _regen_hp="$_regen_hp/bin/python3"
    elif command -v python3 >/dev/null 2>&1; then
      _regen_hp="$(command -v python3)"
    else
      _regen_hp=""
    fi

    if [ $CROSS -eq 0 ]; then
      make -j"$CPU_COUNT" regen-frozen
    else
      if [ -n "$_regen_hp" ]; then
        _freeze_script=""
        for _s in \
            "$PYTHON_BUILD/Tools/freeze_modules.py" \
            "$PYTHON_BUILD/Tools/scripts/freeze_modules.py"; do
          [ -f "$_s" ] && { _freeze_script="$_s"; break; }
        done
        if [ -n "$_freeze_script" ]; then
          echo "Running freeze_modules with host Python: $_regen_hp"
          "$_regen_hp" "$_freeze_script" || true
        else
          echo "WARNING: freeze_modules.py not found; skipping regen-frozen"
        fi
      else
        echo "WARNING: no host python3 found; skipping regen-frozen"
      fi
    fi

    if [ -d "$PYTHON_BUILD/Python/frozen_modules" ]; then
      rm -rf "$LOCAL_TOP/Python/frozen_modules"
      mkdir -p "$LOCAL_TOP/Python"
      cp -rp "$PYTHON_BUILD/Python/frozen_modules" "$LOCAL_TOP/Python/"
    else
      echo "WARNING: Python/frozen_modules not present; skipping copy."
    fi

    # Patch Setup.stdlib once: switch *shared* -> *static* for all variants.
    [ -f "$PYTHON_BUILD/Modules/Setup.stdlib" ] || \
      fail "Modules/Setup.stdlib missing — configure must have failed"
    sedi 's/\*shared\*/\*static\*/' "$PYTHON_BUILD/Modules/Setup.stdlib"

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
