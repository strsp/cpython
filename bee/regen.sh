#!/bin/bash -ex
#
# bee/regen.sh
# Regenerates configuration for hybrid Python (AOSP + Enhanced Termux)
# Patches loaded from bee/patches/
# After running this, use your modified official android.py for building

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC_TOP=$(pwd)
LOCAL_TOP=$SRC_TOP/bee
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

# Termux native detection
TERMUX_PREFIX=${TERMUX_PREFIX:-${PREFIX:-/data/data/com.termux/files/usr}}
[ -d "$TERMUX_PREFIX" ] && export PREFIX="$TERMUX_PREFIX"

# ====================== CROSS WITH NDK ======================
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

  # Strip the API level suffix to get a valid --host triple
  # e.g. aarch64-linux-android34 -> aarch64-linux-android
  CROSS_HOST=$(echo "$CROSS_TARGET" | sed 's/[0-9]*$//')
  export CROSS_HOST
else
  # Native AOSP clang
  CLANG_VERSION=$(cd "$ANDROID_BUILD_TOP" 2>/dev/null && build/soong/scripts/get_clang_version.py || echo "host")
  [ "$HOST_DIR" = "linux_x86_64" ] && export CC="$ANDROID_BUILD_TOP/prebuilts/clang/host/linux-x86/${CLANG_VERSION}/bin/clang" || export CC=clang
fi

# Common PREFIX for dependencies
export PREFIX=${PREFIX:-$DEPS_DIR/install}
mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/bin"
export CFLAGS="${CFLAGS} -I$PREFIX/include"
export LDFLAGS="${LDFLAGS} -L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PREFIX/bin:$PATH"

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
  cmake -S "$dir/build/cmake" -B "$dir/build_out" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$dir/build_out" --parallel "$(nproc || echo 4)"
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
    make -j"$(nproc || echo 4)" && \
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
  if [ -d "$PATCHES_DIR" ]; then
    for p in "$PATCHES_DIR"/*.patch; do
      [ -f "$p" ] || continue
      if patch -p1 -N --dry-run < "$p" >/dev/null 2>&1; then
        echo "Applying patch: $(basename "$p")"
        patch -p1 < "$p"
      else
        echo "Skipping already-applied patch: $(basename "$p")"
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
  make -j"$(nproc || echo 8)" regen-frozen
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
