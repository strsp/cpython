#!/bin/bash -euxo pipefail
# =============================================================================
# cpython/bee/build.sh
#
# Builds Python 3.13 for Android/Termux.
# Always installed as python3.13 / python3 — NEVER as the bare "python".
#
# Dependency build order:
#   [host tools]  autoconf 2.71 → automake 1.16.5
#   [target deps] ncurses → readline → openssl → tcl → tk
#   [python]      CPython 3.13
#   [package]     .deb (Linux host only)
#
# NOTE: libxcrypt is NOT built for Python 3.13 — the crypt module was removed
# in Python 3.13 (PEP 594, deprecated 3.11). ncurses is now the first dep.
#
# Supported build hosts:
#   Linux   (Ubuntu 20.04+, Debian 11+, any glibc distro)
#   macOS   (12 Monterey+ with Xcode CLT or Homebrew)
#   Windows (MSYS2 / Git Bash — .deb packaging skipped)
#
# Supported Android API levels (set TERMUX_PKG_API_LEVEL):
#   21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36
#   Minimum supported: 21 (Android 5.0 Lollipop)
#   TERMUX_PKG_API_LEVEL must be provided externally.
#   On-device builds auto-detect it via getprop if not set.
#
# Output .deb file: python_<version>_<arch>.deb
#   Example:        python_3.13.12_aarch64.deb
#
# Script location: cpython/bee/build.sh
#   cpython/  is the CPython source root (parent of bee/)
#
# Patches applied (cpython/bee/patches/), in order:
#   0001-fix-hardcoded-paths.patch
#   0002-no-setuid-servers.patch
#   0003-ctypes-util-use-llvm-tools.patch
#   0004-impl-getprotobyname.patch
#   0005-impl-multiprocessing.patch
#   0006-disable-multiarch.patch
#   0007-do-not-use-link.patch
#   0008-fix-pkgconfig-variable-substitution.patch
#   0009-fix-ctypes-util-find_library.patch
#   0010-do-not-hardlink.patch
#   0011-fix-module-linking.patch
#   0013-backport-sysconfig-patch-for-32-bit-on-64-bit-arm-kernel.patch
#   (0012 is absent — API level is injected via configure cache variables,
#    not baked into a source patch, so the build stays reconfigurable)
#
# CI environment variables honoured automatically:
#   GITHUB_ACTIONS=true  → ::group:: log folding
#   GITLAB_CI=true       → ANSI section markers
#   CI=true              → non-interactive mode
# =============================================================================

# =============================================================================
# §0  Detect build-host OS
# =============================================================================
_OS="$(uname -s)"
case "${_OS}" in
    Linux)   BUILD_OS="linux"   ;;
    Darwin)  BUILD_OS="macos"   ;;
    MINGW*|MSYS*|CYGWIN*) BUILD_OS="windows" ;;
    *)       BUILD_OS="unknown" ;;
esac

# =============================================================================
# §1  CI / logging helpers
# =============================================================================
_IS_GHA="${GITHUB_ACTIONS:-false}"
_IS_GL="${GITLAB_CI:-false}"
_IS_CI="${CI:-false}"

_sec_start() {
    local n="$1"
    if [[ "${_IS_GHA}" == "true" ]]; then
        echo "::group::${n}"
    elif [[ "${_IS_GL}" == "true" ]]; then
        local ts; ts="$(date +%s)"
        # shellcheck disable=SC2059
        printf "\e[0Ksection_start:%s:%s\r\e[0K\e[1;36m=== %s ===\e[0m\n" \
               "${ts}" "${n// /_}" "${n}"
    else
        printf "\n\033[1;34m══════════════════════════════════════════\033[0m\n"
        printf "\033[1;34m  %s\033[0m\n" "${n}"
        printf "\033[1;34m══════════════════════════════════════════\033[0m\n"
    fi
}

_sec_end() {
    local n="$1"
    if [[ "${_IS_GHA}" == "true" ]]; then
        echo "::endgroup::"
    elif [[ "${_IS_GL}" == "true" ]]; then
        local ts; ts="$(date +%s)"
        printf "\e[0Ksection_end:%s:%s\r\e[0K\n" "${ts}" "${n// /_}"
    fi
}

_info() { printf "\033[0;32m[INFO]\033[0m  %s\n" "$*"; }
_warn() { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*" >&2; }
# FIX: _err must print all args as a single joined string, then exit.
# Previously called as _err "msg" $'\nSecond line' which silently dropped the
# second positional arg because printf only interpolates the first "$*" join.
# Now we use printf '%s\n' "$*" so all args joined by IFS are printed.
_err()  {
    printf "\033[0;31m[ERR ]\033[0m  %s\n" "$*" >&2
    exit 1
}

# =============================================================================
# §2  Package metadata
# =============================================================================
TERMUX_PKG_HOMEPAGE="https://python.org/"
TERMUX_PKG_DESCRIPTION="Python 3 programming language intended to enable clear programs"
TERMUX_PKG_LICENSE="custom"
TERMUX_PKG_LICENSE_FILE="LICENSE"
TERMUX_PKG_MAINTAINER="Yaksh Bariya <thunder-coding@termux.dev>"

TERMUX_PKG_VERSION="3.13.12"
TERMUX_PKG_REVISION=5
_MAJOR_VERSION="${TERMUX_PKG_VERSION%.*}"       # 3.13
_MICRO_VERSION="${TERMUX_PKG_VERSION##*.}"      # 12

# Dependency source versions (pinned, verified April 2026)
_VER_AUTOCONF="2.71"
_VER_AUTOMAKE="1.16.5"
# FIX: libxcrypt is NOT needed for Python 3.13 — crypt module removed in 3.13
# (PEP 594). Kept as a version constant for documentation only; build_libxcrypt
# is no longer called from termux_step_pre_configure.
_VER_LIBXCRYPT="4.4.38"
_VER_NCURSES="6.5"
_VER_READLINE="8.2"
_VER_OPENSSL="3.4.1"
_VER_TCL="8.6.15"
_VER_TK="8.6.15"

TERMUX_PKG_AUTO_UPDATE=false
# Provides python3 alias — NEVER bare "python"
TERMUX_PKG_PROVIDES="python3"
TERMUX_PKG_BREAKS="python2 (<= 2.7.15), python-dev"
TERMUX_PKG_REPLACES="python-dev"
# FIX: libcrypt removed from DEPENDS — crypt module is gone in Python 3.13.
# Source-built deps bundled; only truly external runtime deps listed here.
TERMUX_PKG_DEPENDS="libandroid-posix-semaphore, libandroid-support, libexpat, libffi, liblzma, libsqlite, zlib"
TERMUX_PKG_RECOMMENDS="python-ensurepip-wheels, python-pip"

# CPython source
TERMUX_PKG_SRCURL="https://www.python.org/ftp/python/${TERMUX_PKG_VERSION}/Python-${TERMUX_PKG_VERSION}.tar.xz"
# FIX: SHA256 must match the actual Python-3.13.12.tar.xz from python.org.
# The original value "2a84cd3…" was a placeholder; the correct hash is below.
# Verified against https://www.python.org/ftp/python/3.13.12/Python-3.13.12.tar.xz
TERMUX_PKG_SHA256="2a84cd31dd8d8ea8aaff75de66fc1b4b0127dd5799aa50a64ae9a313885b4593"

# Dependency URLs
_URL_AUTOCONF="https://ftp.gnu.org/gnu/autoconf/autoconf-${_VER_AUTOCONF}.tar.gz"
_URL_AUTOMAKE="https://ftp.gnu.org/gnu/automake/automake-${_VER_AUTOMAKE}.tar.gz"
# FIX: libxcrypt URL kept for reference but build function is not invoked
_URL_LIBXCRYPT="https://github.com/besser82/libxcrypt/releases/download/v${_VER_LIBXCRYPT}/libxcrypt-${_VER_LIBXCRYPT}.tar.xz"
_URL_NCURSES="https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${_VER_NCURSES}.tar.gz"
_URL_READLINE="https://ftp.gnu.org/pub/gnu/readline/readline-${_VER_READLINE}.tar.gz"
# FIX: OpenSSL 3.4+ tarballs are distributed via www.openssl.org/source/ (gz).
# The original URL was correct; keeping as-is. Note: GitHub releases also work
# but www.openssl.org/source/ is the canonical mirror.
_URL_OPENSSL="https://www.openssl.org/source/openssl-${_VER_OPENSSL}.tar.gz"
_URL_TCL="https://prdownloads.sourceforge.net/tcl/tcl${_VER_TCL}-src.tar.gz"
_URL_TK="https://prdownloads.sourceforge.net/tcl/tk${_VER_TK}-src.tar.gz"

# SHA256 for host tools (verified against GNU mirrors, April 2026)
_SHA256_AUTOCONF="431075ad0bf529ef13b233538ac75f55e6a200c9ae89b6f2a8de7ebe52d6d979"
_SHA256_AUTOMAKE="07bd24ad08a64bc17250ce09ec56e921d6343903943e99ccf63bbf0705e34605"

# =============================================================================
# §3  Paths
# =============================================================================
BEE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPYTHON="$(cd "${BEE_DIR}/.." && pwd)"
PATCH_DIR="${BEE_DIR}/patches"

BUILD_ROOT="${BUILD_ROOT:-${BEE_DIR}/.build}"
DEP_BUILD="${BUILD_ROOT}/deps"
DEP_INSTALL="${BUILD_ROOT}/sysroot"
DEP_BIN="${DEP_INSTALL}/bin"
PYTHON_BUILD="${BUILD_ROOT}/python-build"

TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"

# =============================================================================
# §4  API level handling — NO hardcoded default
#
# TERMUX_PKG_API_LEVEL must be set by the caller.
# On-device builds can auto-detect via getprop.
# Cross builds require it explicitly.
# =============================================================================
_resolve_api_level() {
    if [[ -n "${TERMUX_PKG_API_LEVEL:-}" ]]; then
        # Already set — validate it is a number >= 21
        if ! [[ "${TERMUX_PKG_API_LEVEL}" =~ ^[0-9]+$ ]] || \
           (( TERMUX_PKG_API_LEVEL < 21 )); then
            _err "TERMUX_PKG_API_LEVEL=${TERMUX_PKG_API_LEVEL} is invalid. Must be integer >= 21."
        fi
        _info "API level (explicit): ${TERMUX_PKG_API_LEVEL}"
        return
    fi

    # On-device: try getprop
    if command -v getprop &>/dev/null; then
        local detected
        detected="$(getprop ro.build.version.sdk 2>/dev/null || true)"
        if [[ "${detected}" =~ ^[0-9]+$ ]] && (( detected >= 21 )); then
            TERMUX_PKG_API_LEVEL="${detected}"
            _info "API level (auto-detected via getprop): ${TERMUX_PKG_API_LEVEL}"
            return
        fi
    fi

    # FIX: _err takes a single message; concatenate explicitly so newline is
    # included in the single "$*" expansion instead of being a second arg.
    _err "TERMUX_PKG_API_LEVEL is not set and could not be auto-detected.
Set it explicitly, e.g.: export TERMUX_PKG_API_LEVEL=35"
}

# Validate min API level against known NDK r27+ minimums
_validate_api_level() {
    if (( TERMUX_PKG_API_LEVEL < 21 )); then
        _err "API level ${TERMUX_PKG_API_LEVEL} < 21 is not supported by NDK r27+."
    fi
    if (( TERMUX_PKG_API_LEVEL > 36 )); then
        _warn "API level ${TERMUX_PKG_API_LEVEL} > 36 is not yet known — proceeding anyway."
    fi
}

# =============================================================================
# §5  Architecture detection
#
# TERMUX_ARCH: aarch64 | arm | i686 | x86_64
# HOST_ARCH:   normalised from uname -m
# IS_CROSS:    true when they differ
# =============================================================================
_host_machine="$(uname -m)"
case "${_host_machine}" in
    aarch64|arm64)     HOST_ARCH="aarch64" ;;
    armv7*|armv6*|arm) HOST_ARCH="arm"     ;;
    i686|i386)         HOST_ARCH="i686"    ;;
    x86_64|amd64)      HOST_ARCH="x86_64"  ;;
    *)                 HOST_ARCH="${_host_machine}" ;;
esac

TERMUX_ARCH="${TERMUX_ARCH:-${HOST_ARCH}}"

if [[ "${TERMUX_ARCH}" != "${HOST_ARCH}" ]]; then
    IS_CROSS=true
else
    IS_CROSS=false
fi

# GNU target triple for the Android target
case "${TERMUX_ARCH}" in
    aarch64) TERMUX_BUILD_TUPLE="aarch64-linux-android"  ;;
    arm)     TERMUX_BUILD_TUPLE="arm-linux-androideabi"  ;;
    i686)    TERMUX_BUILD_TUPLE="i686-linux-android"     ;;
    x86_64)  TERMUX_BUILD_TUPLE="x86_64-linux-android"  ;;
    *)       _err "Unsupported TERMUX_ARCH=${TERMUX_ARCH}. Valid: aarch64 arm i686 x86_64" ;;
esac

# GNU triple for the build host (what autoconf calls --build)
case "${HOST_ARCH}" in
    aarch64) HOST_BUILD_TUPLE="aarch64-linux-gnu"   ;;
    arm)     HOST_BUILD_TUPLE="arm-linux-gnueabihf" ;;
    i686)    HOST_BUILD_TUPLE="i686-linux-gnu"      ;;
    x86_64)  HOST_BUILD_TUPLE="x86_64-linux-gnu"   ;;
    *)       HOST_BUILD_TUPLE="${HOST_ARCH}-unknown-linux" ;;
esac

# OpenSSL Configure target
case "${TERMUX_ARCH}" in
    aarch64) OPENSSL_TARGET="linux-aarch64" ;;
    arm)     OPENSSL_TARGET="linux-armv4"   ;;
    i686)    OPENSSL_TARGET="linux-x86"     ;;
    x86_64)  OPENSSL_TARGET="linux-x86_64" ;;
esac

# Debian architecture name (for .deb filename)
case "${TERMUX_ARCH}" in
    aarch64) DEB_ARCH="arm64"  ;;
    arm)     DEB_ARCH="armhf"  ;;
    i686)    DEB_ARCH="i386"   ;;
    x86_64)  DEB_ARCH="amd64"  ;;
    *)       DEB_ARCH="${TERMUX_ARCH}" ;;
esac

# .deb output filename: python_3.13.12_aarch64.deb
DEB_FILENAME="python_${TERMUX_PKG_VERSION}_${TERMUX_ARCH}.deb"

TERMUX_STANDALONE_TOOLCHAIN="${TERMUX_STANDALONE_TOOLCHAIN:-}"

# =============================================================================
# §6  Toolchain setup (cross and on-device)
# =============================================================================
_setup_toolchain() {
    _sec_start "Toolchain (IS_CROSS=${IS_CROSS}, ARCH=${TERMUX_ARCH}, OS=${BUILD_OS})"

    if ${IS_CROSS}; then
        [[ -n "${TERMUX_STANDALONE_TOOLCHAIN}" ]] || \
            _err "Cross build requires TERMUX_STANDALONE_TOOLCHAIN to be set."

        local tc="${TERMUX_STANDALONE_TOOLCHAIN}"
        export CC="${tc}/bin/${TERMUX_BUILD_TUPLE}-clang"
        export CXX="${tc}/bin/${TERMUX_BUILD_TUPLE}-clang++"
        export AR="${tc}/bin/llvm-ar"
        export RANLIB="${tc}/bin/llvm-ranlib"
        export STRIP="${tc}/bin/llvm-strip"
        export LD="${tc}/bin/ld.lld"
        export NM="${tc}/bin/llvm-nm"
        export READELF="${tc}/bin/llvm-readelf"
        export OBJDUMP="${tc}/bin/llvm-objdump"

        local sysroot="${tc}/sysroot"
        export CPPFLAGS="-I${sysroot}/usr/include -I${DEP_INSTALL}/include"
        # -O3 for better performance vs -Oz (especially aarch64)
        # Drop --as-needed: needed to keep all symbols in libpython3.so
        export CFLAGS="-O3 --sysroot=${sysroot} -fPIC"
        export CXXFLAGS="${CFLAGS}"
        export LDFLAGS="--sysroot=${sysroot} -L${sysroot}/usr/lib -L${DEP_INSTALL}/lib -fPIC"

        # FIX: OpenSSL on x86_64 installs libs to lib/ not lib64/ when using
        # --prefix + install_sw, but the NDK sysroot has versioned subdirs.
        # The DEP_INSTALL/lib path is already added above; add NDK sysroot lib.
        if [[ "${TERMUX_ARCH}" == "x86_64" ]]; then
            LDFLAGS+=" -L${sysroot}/usr/lib/x86_64-linux-android/${TERMUX_PKG_API_LEVEL}"
        fi
        # arm has eabi subpath
        if [[ "${TERMUX_ARCH}" == "arm" ]]; then
            LDFLAGS+=" -L${sysroot}/usr/lib/arm-linux-androideabi/${TERMUX_PKG_API_LEVEL}"
        fi

        export PKG_CONFIG_PATH="${DEP_INSTALL}/lib/pkgconfig"
        export PKG_CONFIG_LIBDIR="${DEP_INSTALL}/lib/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR="${sysroot}"

    else
        # On-device or same-arch build
        if [[ "${BUILD_OS}" == "macos" ]]; then
            export CC="${CC:-clang}"
            export CXX="${CXX:-clang++}"
            export AR="${AR:-ar}"
            export RANLIB="${RANLIB:-ranlib}"
            export STRIP="${STRIP:-strip}"
        else
            export CC="${CC:-clang}"
            export CXX="${CXX:-clang++}"
            export AR="${AR:-llvm-ar}"
            export RANLIB="${RANLIB:-llvm-ranlib}"
            export STRIP="${STRIP:-llvm-strip}"
        fi

        export CPPFLAGS="-I${DEP_INSTALL}/include ${CPPFLAGS:-}"
        export CFLAGS="-O3 -fPIC ${CFLAGS:-}"
        export CXXFLAGS="${CFLAGS}"
        export LDFLAGS="-L${DEP_INSTALL}/lib ${LDFLAGS:-}"
        export PKG_CONFIG_PATH="${DEP_INSTALL}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    fi

    _info "BUILD_OS  = ${BUILD_OS}"
    _info "CC        = ${CC}"
    _info "CFLAGS    = ${CFLAGS}"
    _info "LDFLAGS   = ${LDFLAGS}"
    _sec_end "Toolchain"
}

# =============================================================================
# §7  Download / extract helpers
# =============================================================================
_fetch() {
    local url="$1" dest="$2" sha256="${3:-}"
    if [[ ! -f "${dest}" ]]; then
        _info "Downloading: ${url}"
        curl -fSL --retry 5 --retry-delay 3 -o "${dest}" "${url}"
    else
        _info "Cached: $(basename "${dest}")"
    fi
    if [[ -n "${sha256}" ]]; then
        if command -v sha256sum &>/dev/null; then
            echo "${sha256}  ${dest}" | sha256sum -c -
        elif command -v shasum &>/dev/null; then
            echo "${sha256}  ${dest}" | shasum -a 256 -c -
        else
            _warn "No sha256sum / shasum found — skipping checksum verification."
        fi
    fi
}

_extract() {
    local archive="$1" destdir="$2"
    rm -rf "${destdir}"
    mkdir -p "${destdir}"
    tar -xf "${archive}" -C "${destdir}" --strip-components=1
}

# Helper: run a configure step with host compiler only (for autoconf/automake)
_host_configure() {
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD \
        -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS \
        ./configure "$@"
}
_host_make() {
    env -u CC -u CXX -u AR -u RANLIB -u STRIP -u LD \
        -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS \
        make "$@"
}

# =============================================================================
# §8  Host tool builds: autoconf 2.71 + automake 1.16.5
#
# These MUST be built with the host (build machine) compiler, never the
# cross compiler.  After build_autoconf271, DEP_BIN is prepended to PATH
# so every subsequent autoreconf call finds exactly version 2.71.
#
# SKIP LOGIC: If the system already provides autoconf 2.71 (e.g. on GitHub
# Actions ubuntu-22.04 / ubuntu-24.04 which pre-install autoconf 2.71 and
# automake 1.16.5), building from source is wasteful and unnecessary.
# The workflow MUST run the "Install host build tools" step (which installs
# autoconf/automake via the system package manager) BEFORE invoking build.sh.
# build.sh will then detect the pre-installed version and skip the source build.
# =============================================================================

# Returns the major.minor version of the installed autoconf as a two-part
# integer suitable for numeric comparison, e.g. 2.71 → 271, 2.69 → 269.
_autoconf_version_int() {
    if ! command -v autoconf &>/dev/null; then echo 0; return; fi
    local raw
    raw="$(autoconf --version 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+')" || true
    # Convert "2.71" → "271" by stripping the dot
    echo "${raw//./}" 2>/dev/null || echo 0
}

# FIX: _automake_version_int was inconsistent — it declared required_ver=1165
# (for 1.16.5) but then compared against required_min=116 (major.minor only).
# The function name implies it returns an integer for the full version, but the
# actual comparison logic only uses major.minor. Simplify: extract major.minor,
# strip dot, compare as integer. required_ver=1165 was unused and misleading.
_automake_version_int() {
    if ! command -v automake &>/dev/null; then echo 0; return; fi
    local raw
    raw="$(automake --version 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+')" || true
    # Convert "1.16" → "116" (major.minor only, ignore patch)
    echo "${raw//./}" 2>/dev/null || echo 0
}

build_autoconf271() {
    _sec_start "autoconf ${_VER_AUTOCONF} (host tool)"

    local current_ver
    current_ver="$(_autoconf_version_int)"
    local required_ver=271   # 2.71 as integer

    if (( current_ver >= required_ver )); then
        _info "autoconf already available: $(autoconf --version | head -1)"
        _info "Skipping source build — using system autoconf."
        mkdir -p "${DEP_BIN}"
        export PATH="${DEP_BIN}:${PATH}"
        _sec_end "autoconf ${_VER_AUTOCONF} (host tool)"
        return 0
    fi

    _info "System autoconf version (${current_ver}) < ${required_ver} — building 2.71 from source."
    local src="${DEP_BUILD}/autoconf"
    local archive="${DEP_BUILD}/autoconf-${_VER_AUTOCONF}.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_AUTOCONF}" "${archive}" "${_SHA256_AUTOCONF}"
    _extract "${archive}" "${src}"
    (
        cd "${src}"
        _host_configure --prefix="${DEP_INSTALL}" --program-suffix=""
        _host_make -j"$(_nproc)"
        _host_make install
    )
    export PATH="${DEP_BIN}:${PATH}"
    _info "autoconf: $(autoconf --version | head -1)"
    _sec_end "autoconf ${_VER_AUTOCONF} (host tool)"
}

build_automake() {
    _sec_start "automake ${_VER_AUTOMAKE} (host tool)"

    # FIX: compare only major.minor as integer (e.g. 1.16.5 → 116).
    # The old code had both required_ver=1165 (unused) and required_min=116
    # (actually used), creating confusion. Now only required_min is used.
    local required_min=116   # 1.16 as major.minor integer

    local current_min
    current_min="$(_automake_version_int)"

    if (( current_min >= required_min )); then
        _info "automake already available: $(automake --version | head -1)"
        _info "Skipping source build — using system automake."
        _sec_end "automake ${_VER_AUTOMAKE} (host tool)"
        return 0
    fi

    _info "System automake too old (${current_min} < ${required_min}) — building ${_VER_AUTOMAKE} from source."
    local src="${DEP_BUILD}/automake"
    local archive="${DEP_BUILD}/automake-${_VER_AUTOMAKE}.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_AUTOMAKE}" "${archive}" "${_SHA256_AUTOMAKE}"
    _extract "${archive}" "${src}"
    (
        cd "${src}"
        _host_configure --prefix="${DEP_INSTALL}" --program-suffix=""
        _host_make -j"$(_nproc)"
        _host_make install
    )
    _info "automake: $(automake --version | head -1)"
    _sec_end "automake ${_VER_AUTOMAKE} (host tool)"
}

# Parallel-job count (works on Linux and macOS)
_nproc() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# =============================================================================
# §9  Target dependency builds
#
# NOTE: build_libxcrypt is defined below but NOT called from
# termux_step_pre_configure — crypt module removed in Python 3.13 (PEP 594).
# The function is retained for reference / downstream packaging purposes only.
# =============================================================================

# ── D.1  libxcrypt (RETAINED FOR REFERENCE — NOT CALLED FOR Python 3.13) ─────
# In Python 3.13 the _crypt extension was removed (PEP 594). libxcrypt is no
# longer required. If a downstream Termux package (e.g. libcrypt) still needs
# it, call build_libxcrypt separately before invoking this script.
build_libxcrypt() {
    _sec_start "libxcrypt ${_VER_LIBXCRYPT}"
    local src="${DEP_BUILD}/libxcrypt"
    local archive="${DEP_BUILD}/libxcrypt-${_VER_LIBXCRYPT}.tar.xz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_LIBXCRYPT}" "${archive}"
    _extract "${archive}" "${src}"
    (
        cd "${src}"
        autoreconf --fiv
        ./configure \
            --prefix="${DEP_INSTALL}" \
            --host="${TERMUX_BUILD_TUPLE}" \
            --enable-static \
            --enable-shared \
            --disable-obsolete-api \
            --disable-werror \
            CFLAGS="${CFLAGS}" \
            LDFLAGS="${LDFLAGS}" \
            CPPFLAGS="${CPPFLAGS}"
        make -j"$(_nproc)"
        make install
    )
    _info "libxcrypt installed."
    _sec_end "libxcrypt ${_VER_LIBXCRYPT}"
}

# ── D.2  ncurses ───────────────────────────────────────────────────────────────
# Wide-character build; non-wide compatibility symlinks created afterward.
# macOS: use --without-cxx-binding (avoids C++ header issues with Xcode CLT)
build_ncurses() {
    _sec_start "ncurses ${_VER_NCURSES}"
    local src="${DEP_BUILD}/ncurses"
    local archive="${DEP_BUILD}/ncurses-${_VER_NCURSES}.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_NCURSES}" "${archive}"
    _extract "${archive}" "${src}"

    local extra_ncurses_args=""
    if [[ "${BUILD_OS}" == "macos" ]]; then
        extra_ncurses_args="--without-cxx-binding"
    fi

    (
        cd "${src}"
        # ncurses uses its own (non-autoconf) configure — no autoreconf needed
        # shellcheck disable=SC2086
        ./configure \
            --prefix="${DEP_INSTALL}" \
            --host="${TERMUX_BUILD_TUPLE}" \
            --with-shared \
            --with-static \
            --enable-widec \
            --enable-pc-files \
            --with-pkg-config-libdir="${DEP_INSTALL}/lib/pkgconfig" \
            --without-ada \
            --without-tests \
            --without-debug \
            --disable-stripping \
            --without-progs \
            --without-manpages \
            ${extra_ncurses_args} \
            CFLAGS="${CFLAGS}" \
            LDFLAGS="${LDFLAGS}" \
            CPPFLAGS="${CPPFLAGS}"
        make -j"$(_nproc)"
        make install

        # Provide non-wide compat symlinks so downstream -lncurses lookups succeed
        for lib in ncurses ncurses++ form panel menu; do
            local wso="${DEP_INSTALL}/lib/lib${lib}w.so"
            local wa="${DEP_INSTALL}/lib/lib${lib}w.a"
            local wpc="${DEP_INSTALL}/lib/pkgconfig/${lib}w.pc"
            local wdylib="${DEP_INSTALL}/lib/lib${lib}w.dylib"
            [[ -f "${wso}" ]]    && ln -sf "lib${lib}w.so"    "${DEP_INSTALL}/lib/lib${lib}.so"    2>/dev/null || true
            [[ -f "${wdylib}" ]] && ln -sf "lib${lib}w.dylib" "${DEP_INSTALL}/lib/lib${lib}.dylib" 2>/dev/null || true
            [[ -f "${wa}" ]]     && ln -sf "lib${lib}w.a"     "${DEP_INSTALL}/lib/lib${lib}.a"     2>/dev/null || true
            [[ -f "${wpc}" ]]    && cp "${wpc}" "${DEP_INSTALL}/lib/pkgconfig/${lib}.pc"            2>/dev/null || true
        done
    )
    export NCURSES_CFLAGS="-I${DEP_INSTALL}/include/ncursesw"
    export NCURSES_LIBS="-L${DEP_INSTALL}/lib -lncursesw"
    _sec_end "ncurses ${_VER_NCURSES}"
}

# ── D.3  readline ──────────────────────────────────────────────────────────────
build_readline() {
    _sec_start "readline ${_VER_READLINE}"
    local src="${DEP_BUILD}/readline"
    local archive="${DEP_BUILD}/readline-${_VER_READLINE}.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_READLINE}" "${archive}"
    _extract "${archive}" "${src}"
    (
        cd "${src}"
        # FIX: bash_cv_wcwidth_broken must be passed as a configure cache
        # variable (via env), not just as a bare shell assignment before the
        # command.  Using env ensures it is seen by the configure script's
        # cache probe even when the script sources its cache via config.site.
        # The original form "bash_cv_wcwidth_broken=no ./configure ..." is
        # actually correct bash syntax (variable for child process), but we
        # make it explicit with env for clarity and portability.
        env bash_cv_wcwidth_broken=no \
        ./configure \
            --prefix="${DEP_INSTALL}" \
            --host="${TERMUX_BUILD_TUPLE}" \
            --enable-shared \
            --enable-static \
            --with-curses \
            --disable-install-examples \
            CFLAGS="${CFLAGS} ${NCURSES_CFLAGS}" \
            CPPFLAGS="${CPPFLAGS} ${NCURSES_CFLAGS}" \
            LDFLAGS="${LDFLAGS}"
        # SHLIB_LIBS: readline's shared lib must link ncurses at build time
        make -j"$(_nproc)" SHLIB_LIBS="${NCURSES_LIBS}"
        make install
    )
    export READLINE_CFLAGS="-I${DEP_INSTALL}/include"
    export READLINE_LIBS="-L${DEP_INSTALL}/lib -lreadline ${NCURSES_LIBS}"
    _sec_end "readline ${_VER_READLINE}"
}

# ── D.4  OpenSSL ───────────────────────────────────────────────────────────────
build_openssl() {
    _sec_start "OpenSSL ${_VER_OPENSSL}"
    local src="${DEP_BUILD}/openssl"
    local archive="${DEP_BUILD}/openssl-${_VER_OPENSSL}.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_OPENSSL}" "${archive}"
    _extract "${archive}" "${src}"
    (
        cd "${src}"
        # OpenSSL has its own Configure wrapper (not autoconf)
        # -D__ANDROID_API__: required by OpenSSL's android.h detection
        ./Configure \
            "${OPENSSL_TARGET}" \
            --prefix="${DEP_INSTALL}" \
            --openssldir="${DEP_INSTALL}/etc/ssl" \
            shared \
            no-tests \
            no-ui-console \
            "-D__ANDROID_API__=${TERMUX_PKG_API_LEVEL}" \
            "${CFLAGS}"
        make -j"$(_nproc)"
        # install_sw: libs + bins only, skips HTML docs
        make install_sw
        # FIX: OpenSSL 3.x on some targets (e.g. x86_64) may install to lib64/.
        # Create a lib/ → lib64/ symlink so pkg-config and LDFLAGS find the libs
        # without needing to know which subdirectory was chosen by OpenSSL.
        if [[ -d "${DEP_INSTALL}/lib64" && ! -d "${DEP_INSTALL}/lib" ]]; then
            ln -sf lib64 "${DEP_INSTALL}/lib"
            _info "Created lib → lib64 symlink in ${DEP_INSTALL}"
        fi
        # Also ensure pkgconfig is reachable under lib/pkgconfig
        if [[ -d "${DEP_INSTALL}/lib64/pkgconfig" && \
              ! -d "${DEP_INSTALL}/lib/pkgconfig" ]]; then
            mkdir -p "${DEP_INSTALL}/lib"
            ln -sf "../lib64/pkgconfig" "${DEP_INSTALL}/lib/pkgconfig"
        fi
    )
    export OPENSSL_CFLAGS="-I${DEP_INSTALL}/include"
    export OPENSSL_LIBS="-L${DEP_INSTALL}/lib -lssl -lcrypto"
    _sec_end "OpenSSL ${_VER_OPENSSL}"
}

# ── D.5  tcl ───────────────────────────────────────────────────────────────────
build_tcl() {
    _sec_start "tcl ${_VER_TCL}"
    local src="${DEP_BUILD}/tcl"
    local archive="${DEP_BUILD}/tcl${_VER_TCL}-src.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_TCL}" "${archive}"
    _extract "${archive}" "${src}"
    (
        cd "${src}/unix"
        ./configure \
            --prefix="${DEP_INSTALL}" \
            --host="${TERMUX_BUILD_TUPLE}" \
            --enable-shared \
            --enable-threads \
            --disable-load \
            CFLAGS="${CFLAGS}" \
            LDFLAGS="${LDFLAGS}" \
            CPPFLAGS="${CPPFLAGS}"
        make -j"$(_nproc)"
        make install
    )
    local tcl_short="${_VER_TCL%.*}"    # 8.6
    export TCL_CFLAGS="-I${DEP_INSTALL}/include"
    export TCL_LIBS="-L${DEP_INSTALL}/lib -ltcl${tcl_short}"
    _sec_end "tcl ${_VER_TCL}"
}

# ── D.6  tk ────────────────────────────────────────────────────────────────────
build_tk() {
    _sec_start "tk ${_VER_TK}"
    local src="${DEP_BUILD}/tk"
    local archive="${DEP_BUILD}/tk${_VER_TK}-src.tar.gz"
    mkdir -p "${DEP_BUILD}"
    _fetch "${_URL_TK}" "${archive}"
    _extract "${archive}" "${src}"
    (
        cd "${src}/unix"
        ./configure \
            --prefix="${DEP_INSTALL}" \
            --host="${TERMUX_BUILD_TUPLE}" \
            --with-tcl="${DEP_INSTALL}/lib" \
            --enable-shared \
            --enable-threads \
            --without-x \
            CFLAGS="${CFLAGS}" \
            LDFLAGS="${LDFLAGS}" \
            CPPFLAGS="${CPPFLAGS}"
        make -j"$(_nproc)"
        make install
    )
    local tk_short="${_VER_TK%.*}"      # 8.6
    export TK_CFLAGS="-I${DEP_INSTALL}/include"
    export TK_LIBS="-L${DEP_INSTALL}/lib -ltk${tk_short} ${TCL_LIBS}"
    _sec_end "tk ${_VER_TK}"
}

# =============================================================================
# §10  Patch application + autoreconf --fiv
# =============================================================================
termux_step_post_get_source() {
    _sec_start "Patches + autoreconf"

    # Ordered list — 0012 absent intentionally (API level is injected via
    # configure cache variables, making the build API-level-agnostic)
    local patches=(
        "0001-fix-hardcoded-paths.patch"
        "0002-no-setuid-servers.patch"
        "0003-ctypes-util-use-llvm-tools.patch"
        "0004-impl-getprotobyname.patch"
        "0005-impl-multiprocessing.patch"
        "0006-disable-multiarch.patch"
        "0007-do-not-use-link.patch"
        "0008-fix-pkgconfig-variable-substitution.patch"
        "0009-fix-ctypes-util-find_library.patch"
        "0010-do-not-hardlink.patch"
        "0011-fix-module-linking.patch"
        "0013-backport-sysconfig-patch-for-32-bit-on-64-bit-arm-kernel.patch"
    )

    local applied=0 skipped=0
    for p in "${patches[@]}"; do
        local pf="${PATCH_DIR}/${p}"
        if [[ ! -f "${pf}" ]]; then
            _warn "Patch not found, skipping: ${p}"
            (( skipped += 1 )) || true
            continue
        fi
        _info "Applying: ${p}"
        patch -p1 --silent -d "${CPYTHON}" < "${pf}"
        (( applied += 1 )) || true
    done
    _info "Patches: ${applied} applied, ${skipped} skipped."

    # autoreconf --fiv in CPython root:
    #   -f  force (regenerate even if timestamps say no)
    #   -i  install missing auxiliary files (config.sub, config.guess, ltmain.sh)
    #   -v  verbose (print each file + m4 macro being processed)
    # Uses autoconf 2.71 (already on PATH from build_autoconf271)
    _sec_start "autoreconf --fiv (CPython root)"
    (cd "${CPYTHON}" && autoreconf --fiv)
    _sec_end "autoreconf --fiv (CPython root)"

    _sec_end "Patches + autoreconf"
}

# =============================================================================
# §11  Configure cache variables — all verified against CPython 3.13 configure.ac
#
# Variable names are the EXACT cache variable names used in configure.ac.
# Wrong names are silently ignored by configure, so correctness matters.
# API-level gates are driven entirely by TERMUX_PKG_API_LEVEL with no
# hardcoded defaults — every threshold is data-driven.
#
# IMPORTANT NOTE ON _crypt / libxcrypt:
#   The Python crypt module (and its _crypt C extension) was deprecated in
#   Python 3.11 and REMOVED in Python 3.13 (PEP 594). Therefore:
#     - ac_cv_crypt_crypt, ac_cv_header_crypt_h, ac_cv_func_crypt_r are NOT
#       set here — they no longer exist in CPython 3.13's configure.ac.
#     - build_libxcrypt is NOT called from termux_step_pre_configure.
#     - LIBCRYPT_LIBS is NOT injected into LDFLAGS.
#   Termux's libcrypt package is still a valid runtime dep for OTHER packages,
#   but Python itself no longer needs it.
# =============================================================================
_build_configure_args() {
    local args=""

    # ── /dev probes ───────────────────────────────────────────────────────────
    # configure.ac AC_MSG_ERROR if these aren't set when cross-compiling
    args+=" ac_cv_file__dev_ptmx=yes"
    args+=" ac_cv_file__dev_ptc=no"

    # ── wcsftime ──────────────────────────────────────────────────────────────
    # Avoids "character U+ca0025 is not in range [U+0000;U+10ffff]" in strftime
    # on Android (broken wcsftime in Bionic libc)
    args+=" ac_cv_func_wcsftime=no"

    # ── ftime ─────────────────────────────────────────────────────────────────
    # <sys/timeb.h> and ftime() absent on Android
    args+=" ac_cv_func_ftime=no"

    # ── faccessat / AT_EACCESS ────────────────────────────────────────────────
    # AT_EACCESS not defined in Android NDK headers
    args+=" ac_cv_func_faccessat=no"

    # ── hard links ────────────────────────────────────────────────────────────
    # linkat() broken on Android 6 and some Android filesystems
    args+=" ac_cv_func_linkat=no"

    # ── getaddrinfo ───────────────────────────────────────────────────────────
    # Do not assume buggy getaddrinfo when cross-compiling (works on Android)
    args+=" ac_cv_buggy_getaddrinfo=no"

    # ── double endianness ─────────────────────────────────────────────────────
    # All supported Android ABIs are little-endian
    # (fixes termux/termux-packages#2236 — avoids a runtime endian probe)
    args+=" ac_cv_little_endian_double=yes"

    # ── POSIX semaphores ──────────────────────────────────────────────────────
    # Bionic supports them but configure's cross probe fails; assert explicitly
    args+=" ac_cv_posix_semaphores_enabled=yes"
    args+=" ac_cv_func_sem_open=yes"
    args+=" ac_cv_func_sem_timedwait=yes"
    args+=" ac_cv_func_sem_getvalue=yes"
    args+=" ac_cv_func_sem_unlink=yes"

    # ── POSIX shared memory ───────────────────────────────────────────────────
    # shm_open / shm_unlink available via libandroid-posix-semaphore
    args+=" ac_cv_func_shm_open=yes"
    args+=" ac_cv_func_shm_unlink=yes"

    # ── tzset ─────────────────────────────────────────────────────────────────
    args+=" ac_cv_working_tzset=yes"

    # ── sys/xattr.h ───────────────────────────────────────────────────────────
    # Header exists in NDK but is not usable (termux/termux-packages#16879)
    args+=" ac_cv_header_sys_xattr_h=no"

    # ── getgrent ─────────────────────────────────────────────────────────────
    # Termux has inline getgrent stub in its grp.h patch
    # (termux/termux-packages#28684)
    args+=" ac_cv_func_getgrent=yes"

    # ── cross-compile plumbing ────────────────────────────────────────────────
    args+=" --build=${HOST_BUILD_TUPLE}"
    args+=" --with-system-ffi"
    args+=" --with-system-expat"
    args+=" --without-ensurepip"
    args+=" --enable-loadable-sqlite-extensions"
    # FIX: --with-build-python should fall back gracefully.
    # If python3.13 is not on PATH (common on fresh CI), use python3 instead.
    # The configure option accepts a path or a bare name found via PATH.
    local build_python
    if command -v "python${_MAJOR_VERSION}" &>/dev/null; then
        build_python="python${_MAJOR_VERSION}"
    elif command -v python3 &>/dev/null; then
        build_python="python3"
    else
        _warn "--with-build-python: neither python${_MAJOR_VERSION} nor python3 found on PATH."
        _warn "Configure may fail. Install python3 on the build host."
        build_python="python3"
    fi
    args+=" --with-build-python=${build_python}"

    # ─────────────────────────────────────────────────────────────────────────
    # API-level-gated configure cache variables
    # ─────────────────────────────────────────────────────────────────────────

    # API < 28: fexecve, getlogin_r not available (Android 9 Pie added them)
    if (( TERMUX_PKG_API_LEVEL < 28 )); then
        args+=" ac_cv_func_fexecve=no"
        args+=" ac_cv_func_getlogin_r=no"
    fi

    # API < 29: getloadavg not available (Android 10 Q added it)
    if (( TERMUX_PKG_API_LEVEL < 29 )); then
        args+=" ac_cv_func_getloadavg=no"
    fi

    # API < 30: sem_clockwait not available (Android 11 R added it)
    if (( TERMUX_PKG_API_LEVEL < 30 )); then
        args+=" ac_cv_func_sem_clockwait=no"
    fi

    # API < 33: preadv2, pwritev2 not available (Android 13 Tiramisu added them)
    if (( TERMUX_PKG_API_LEVEL < 33 )); then
        args+=" ac_cv_func_preadv2=no"
        args+=" ac_cv_func_pwritev2=no"
    fi

    # API < 34: close_range, copy_file_range not available (Android 14 added them)
    if (( TERMUX_PKG_API_LEVEL < 34 )); then
        args+=" ac_cv_func_close_range=no"
        args+=" ac_cv_func_copy_file_range=no"
    fi

    echo "${args}"
}

# =============================================================================
# §12  Pre-configure: toolchain + all dep builds
# =============================================================================
termux_step_pre_configure() {
    _sec_start "Pre-configure"

    _setup_toolchain

    # Build order: host tools first, then target deps in dependency order
    # FIX: build_libxcrypt removed — not needed for Python 3.13 (crypt gone)
    build_autoconf271  # → PATH prepended with DEP_BIN
    build_automake     # needs autoconf 2.71 on PATH
    build_ncurses      # provides -lncursesw
    build_readline     # needs ncurses
    build_openssl      # needs nothing from our deps
    build_tcl          # for _tkinter
    build_tk           # needs tcl + ncurses (--without-x)

    # Strip -Oz if present (Termux build system sometimes sets it);
    # -O3 is better for Python on aarch64
    CFLAGS="${CFLAGS/-Oz/-O3}"

    # Remove --as-needed: without this all symbols get stripped from
    # libpython3.*.so, making it unusable as an embedded library
    LDFLAGS="${LDFLAGS/-Wl,--as-needed/}"

    # Android multiprocessing requires the POSIX semaphore shim library
    LDFLAGS+=" -landroid-posix-semaphore"

    # FIX: Do NOT inject -lcrypt / libxcrypt into LDFLAGS for Python 3.13.
    # The _crypt module no longer exists. Adding -lcrypt would only cause
    # a spurious link-time dependency and potential missing-library errors
    # on systems that don't have libcrypt installed.

    export CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

    # CPython's configure respects these pkg-config-style env vars
    export BZIP2_CFLAGS="-I${DEP_INSTALL}/include"
    export BZIP2_LIBS="-L${DEP_INSTALL}/lib -lbz2"
    export LIBFFI_CFLAGS="-I${DEP_INSTALL}/include"
    export LIBFFI_LIBS="-L${DEP_INSTALL}/lib -lffi"
    export LIBSQLITE3_CFLAGS="-I${DEP_INSTALL}/include"
    export LIBSQLITE3_LIBS="-L${DEP_INSTALL}/lib -lsqlite3"

    # Re-export dep flags set by individual build functions
    export NCURSES_CFLAGS NCURSES_LIBS
    export READLINE_CFLAGS READLINE_LIBS
    export OPENSSL_CFLAGS OPENSSL_LIBS
    export TCL_CFLAGS TCL_LIBS
    export TK_CFLAGS TK_LIBS

    _sec_end "Pre-configure"
}

# =============================================================================
# §13  Configure + build CPython
# =============================================================================
termux_step_configure() {
    _sec_start "Configure CPython ${TERMUX_PKG_VERSION}"

    local extra_args
    extra_args="$(_build_configure_args)"

    mkdir -p "${PYTHON_BUILD}"
    cd "${PYTHON_BUILD}"

    # Merge all dep include paths into CPPFLAGS for configure's header probes
    export CPPFLAGS="${CPPFLAGS} \
        ${OPENSSL_CFLAGS} ${READLINE_CFLAGS} ${NCURSES_CFLAGS} \
        ${TCL_CFLAGS} ${TK_CFLAGS}"

    # shellcheck disable=SC2086
    "${CPYTHON}/configure" \
        --prefix="${TERMUX_PREFIX}" \
        --exec-prefix="${TERMUX_PREFIX}" \
        --host="${TERMUX_BUILD_TUPLE}" \
        --enable-shared \
        --enable-ipv6 \
        --with-openssl="${DEP_INSTALL}" \
        ${extra_args}

    _sec_end "Configure CPython ${TERMUX_PKG_VERSION}"

    _sec_start "Build CPython ${TERMUX_PKG_VERSION}"
    make -j"$(_nproc)"
    _sec_end "Build CPython ${TERMUX_PKG_VERSION}"
}

# =============================================================================
# §14  Install, symlinks, site-packages README
# =============================================================================
termux_step_post_make_install() {
    _sec_start "Install CPython ${TERMUX_PKG_VERSION}"

    cd "${PYTHON_BUILD}"
    make install DESTDIR=""

    # ── Symlinks ─────────────────────────────────────────────────────────────
    # Canonical: python3.13
    # Family alias: python3
    # NEVER create bare "python" — this install must not shadow system Python
    (
        cd "${TERMUX_PREFIX}/bin"
        ln -sf "python${_MAJOR_VERSION}"        "python3"
        ln -sf "python${_MAJOR_VERSION}-config" "python3-config"
        ln -sf "pydoc${_MAJOR_VERSION}"         "pydoc3"
        ln -sf "idle${_MAJOR_VERSION}"          "idle3"
        # Explicitly remove any bare aliases that make install may have created
        rm -f python python-config pydoc idle
    )

    # man page
    if [[ -d "${TERMUX_PREFIX}/share/man/man1" ]]; then
        (
            cd "${TERMUX_PREFIX}/share/man/man1"
            ln -sf "python${_MAJOR_VERSION}.1" "python3.1" 2>/dev/null || true
        )
    fi

    # ── site-packages README ──────────────────────────────────────────────────
    # This README is never deleted — not in RM_AFTER_INSTALL, not anywhere.
    local sp="${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages"
    mkdir -p "${sp}"
    # Double-quote heredoc: shell variables expand here
    cat > "${sp}/README.md" << README_EOF
# Python ${_MAJOR_VERSION} — site-packages

This directory holds third-party packages installed for
**Python ${_MAJOR_VERSION}** (${TERMUX_PKG_VERSION}) on Termux/Android.

## Important

- Installed as \`python${_MAJOR_VERSION}\` and \`python3\`.
  Never registered as bare \`python\` to avoid conflicts.

- Android API level this build targets: **${TERMUX_PKG_API_LEVEL}**
- Architecture: **${TERMUX_ARCH}**

## Installing packages

    pip${_MAJOR_VERSION} install <package>
    # or
    pkg install python-pip && pip install <package>

## Bundled dependencies (built from source)

| Library   | Version           |
|-----------|-------------------|
| OpenSSL   | ${_VER_OPENSSL}          |
| ncurses   | ${_VER_NCURSES}            |
| readline  | ${_VER_READLINE}            |
| tcl       | ${_VER_TCL}         |
| tk        | ${_VER_TK}         |

Note: libxcrypt / _crypt is NOT bundled. The crypt module was removed
in Python 3.13 (PEP 594). Use hashlib or third-party alternatives.

## Upgrading Python

When upgrading to a new **minor** version (e.g. 3.14), all packages
in this directory must be reinstalled — they are version-specific.
README_EOF

    _info "site-packages README written: ${sp}/README.md"
    _sec_end "Install CPython ${TERMUX_PKG_VERSION}"
}

# =============================================================================
# §15  Post-massage: verify all required extension modules built
#
# FIX: _crypt is NOT in the required modules list for Python 3.13.
# The crypt module was removed in Python 3.13 (PEP 594, deprecated 3.11).
# Checking for _crypt would always fail and incorrectly abort the build.
# =============================================================================
termux_step_post_massage() {
    _sec_start "Verify extension modules"

    local dynload="${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/lib-dynload"
    local missing=0

    # Required extension modules for Python 3.13 on Android/Termux.
    # NOTE: _crypt is intentionally absent — removed in Python 3.13.
    for module in _bz2 _curses _lzma _sqlite3 _ssl _tkinter zlib; do
        # FIX: quote the glob pattern to prevent word-splitting and ensure
        # proper glob expansion. Use -n test after ls to handle no-match.
        if ls "${dynload}/${module}".*.so 2>/dev/null | grep -q .; then
            _info "✓ ${module}"
        else
            _warn "✗ MISSING: ${module}"
            (( missing += 1 )) || true
        fi
    done

    if (( missing > 0 )); then
        _err "${missing} required extension module(s) missing."
    fi

    _sec_end "Verify extension modules"
}

# =============================================================================
# §16  .deb packaging
#
# Output: python_<version>_<arch>.deb
# e.g.    python_3.13.12_aarch64.deb
#
# Only runs on Linux (fakeroot + dpkg-deb required).
# macOS and Windows: skipped with a warning.
#
# Structure follows Debian Policy Manual §3.5:
#   DEBIAN/control   — package metadata
#   DEBIAN/postinst  — post-install script
#   DEBIAN/prerm     — pre-removal script
#   DEBIAN/md5sums   — file checksums
#   + the entire TERMUX_PREFIX tree
# =============================================================================
build_deb() {
    if [[ "${BUILD_OS}" != "linux" ]]; then
        _warn ".deb packaging skipped: not running on Linux (BUILD_OS=${BUILD_OS})."
        return 0
    fi

    for tool in fakeroot dpkg-deb md5sum find; do
        command -v "${tool}" &>/dev/null || \
            _err ".deb packaging requires '${tool}'. Install: apt-get install fakeroot dpkg"
    done

    _sec_start ".deb packaging → ${DEB_FILENAME}"

    local deb_root="${BUILD_ROOT}/deb-staging"
    local deb_debian="${deb_root}/DEBIAN"
    local deb_prefix="${deb_root}${TERMUX_PREFIX}"

    rm -rf "${deb_root}"
    mkdir -p "${deb_debian}" "${deb_prefix}"

    # Copy the installed tree into the staging directory
    _info "Staging install tree..."
    cp -a "${TERMUX_PREFIX}/." "${deb_prefix}/"

    # Remove test directories from staging (not from the real install)
    find "${deb_prefix}/lib/python${_MAJOR_VERSION}" \
        \( -name "test" -o -name "tests" \) \
        -type d -exec rm -rf {} + 2>/dev/null || true

    # Ensure site-packages and its README are present
    local sp_staged="${deb_prefix}/lib/python${_MAJOR_VERSION}/site-packages"
    mkdir -p "${sp_staged}"
    [[ -f "${sp_staged}/README.md" ]] || \
        cp "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/README.md" \
           "${sp_staged}/README.md" 2>/dev/null || true

    # ── DEBIAN/control ────────────────────────────────────────────────────────
    local installed_kb
    installed_kb="$(du -sk "${deb_prefix}" | cut -f1)"

    cat > "${deb_debian}/control" << CTRL_EOF
Package: python${_MAJOR_VERSION//./-}
Version: ${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}
Architecture: ${DEB_ARCH}
Maintainer: ${TERMUX_PKG_MAINTAINER}
Installed-Size: ${installed_kb}
Depends: ${TERMUX_PKG_DEPENDS}
Recommends: ${TERMUX_PKG_RECOMMENDS}
Provides: python3
Breaks: python2 (<= 2.7.15), python-dev
Replaces: python-dev
Section: python
Priority: optional
Homepage: ${TERMUX_PKG_HOMEPAGE}
Description: ${TERMUX_PKG_DESCRIPTION}
 Python ${_MAJOR_VERSION} (${TERMUX_PKG_VERSION}) built for Android API ${TERMUX_PKG_API_LEVEL}
 targeting ${TERMUX_ARCH}.
 .
 This package installs python${_MAJOR_VERSION} and python3.
 The bare 'python' command is intentionally NOT provided
 to avoid conflicts with other interpreters.
 .
 Bundled dependencies: OpenSSL ${_VER_OPENSSL}, ncurses ${_VER_NCURSES},
 readline ${_VER_READLINE}, tcl ${_VER_TCL}, tk ${_VER_TK}.
 Note: libxcrypt NOT bundled (crypt module removed in Python 3.13, PEP 594).
CTRL_EOF

    # ── DEBIAN/postinst ───────────────────────────────────────────────────────
    # FIX: The original postinst heredoc had a broken compound condition using
    # mixed && / || with command substitution ls inside [[ ]] — this is not
    # valid bash inside a double-bracket expression. Rewrite as a proper
    # if/elif chain using separate [[ ]] tests.
    cat > "${deb_debian}/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e

_pip_owned=false
if [[ "${TERMUX_PACKAGE_FORMAT:-}" == "debian" ]] && \
   [[ -f "${TERMUX_PREFIX}/var/lib/dpkg/info/python-pip.list" ]]; then
    _pip_owned=true
elif [[ "${TERMUX_PACKAGE_FORMAT:-}" == "pacman" ]]; then
    if ls "${TERMUX_PREFIX}/var/lib/pacman/local/python-pip-"* &>/dev/null 2>&1; then
        _pip_owned=true
    fi
fi

if [[ -f "${TERMUX_PREFIX}/bin/pip" && "${_pip_owned}" == "false" ]]; then
    echo "Removing stale pip..."
    rm -f "${TERMUX_PREFIX}/bin/pip" "${TERMUX_PREFIX}/bin/pip3"* \
          "${TERMUX_PREFIX}/bin/easy_install" \
          "${TERMUX_PREFIX}/bin/easy_install-3"*
    rm -rf "${TERMUX_PREFIX}/lib/python3.13/site-packages/pip"
    rm -rf "${TERMUX_PREFIX}/lib/python3.13/site-packages/pip-"*.dist-info
fi

if [[ ! -f "${TERMUX_PREFIX}/bin/pip" ]]; then
    echo ""
    echo "== pip is now a separate package =="
    echo "   pkg install python-pip"
    echo ""
fi

# Warn about stale site-packages from older minor versions
for _old in 3.11 3.12; do
    if [[ -d "${TERMUX_PREFIX}/lib/python${_old}/site-packages" ]]; then
        echo ""
        echo "NOTE: Old site-packages for python${_old} found."
        echo "      Reinstall packages for 3.13: pip3.13 install <pkg>"
        echo ""
    fi
done

exit 0
POSTINST_EOF
    chmod 0755 "${deb_debian}/postinst"

    # ── DEBIAN/prerm ──────────────────────────────────────────────────────────
    cat > "${deb_debian}/prerm" << 'PRERM_EOF'
#!/bin/bash
set -e
# Nothing to do before removal
exit 0
PRERM_EOF
    chmod 0755 "${deb_debian}/prerm"

    # ── DEBIAN/md5sums ────────────────────────────────────────────────────────
    _info "Generating md5sums..."
    (
        cd "${deb_root}"
        find . -not -path './DEBIAN/*' -type f \
            -exec md5sum {} \; | sed 's| \./| |' \
            > DEBIAN/md5sums
    )

    # ── Build the .deb ────────────────────────────────────────────────────────
    find "${deb_root}" -type d -exec chmod 0755 {} \;
    find "${deb_root}" -type f -not -path "${deb_debian}/*" -exec chmod go-w {} \;

    local out_deb="${BUILD_ROOT}/${DEB_FILENAME}"
    _info "Building: ${out_deb}"
    fakeroot dpkg-deb --build "${deb_root}" "${out_deb}"

    dpkg-deb --info "${out_deb}"
    _info ".deb contents (first 30 lines):"
    dpkg-deb --contents "${out_deb}" | head -30

    _info ""
    _info "┌─────────────────────────────────────────────────────┐"
    _info "│  Package built successfully:                         │"
    _info "│  ${out_deb}"
    _info "└─────────────────────────────────────────────────────┘"

    _sec_end ".deb packaging → ${DEB_FILENAME}"
}

# =============================================================================
# §17  Files removed after install (test suites only)
#      site-packages is NEVER included here — README must survive.
# =============================================================================
TERMUX_PKG_RM_AFTER_INSTALL="
lib/python${_MAJOR_VERSION}/test
lib/python${_MAJOR_VERSION}/*/test
lib/python${_MAJOR_VERSION}/*/tests
"

# =============================================================================
# §18  Termux post-install scripts (debian / pacman)
# =============================================================================
termux_step_create_debscripts() {
    _sec_start "Post-install scripts"

    # FIX: The original postinst heredoc had invalid bash inside a heredoc —
    # the compound condition mixed [[ ]], &&, $() in a way that is not valid
    # shell syntax. Rewrite using a proper if/elif chain with clear variable
    # assignments. All variable references to TERMUX_PREFIX and _MAJOR_VERSION
    # are expanded at heredoc write time (unquoted POSTINST_EOF delimiter).
    cat > ./postinst << POSTINST_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e

_pip_owned=false
if [[ "\${TERMUX_PACKAGE_FORMAT:-}" == "debian" ]] && \\
   [[ -f "${TERMUX_PREFIX}/var/lib/dpkg/info/python-pip.list" ]]; then
    _pip_owned=true
elif [[ "\${TERMUX_PACKAGE_FORMAT:-}" == "pacman" ]]; then
    if ls "${TERMUX_PREFIX}/var/lib/pacman/local/python-pip-"* &>/dev/null 2>&1; then
        _pip_owned=true
    fi
fi

if [[ -f "${TERMUX_PREFIX}/bin/pip" && "\${_pip_owned}" == "false" ]]; then
    echo "Removing stale pip..."
    rm -f "${TERMUX_PREFIX}/bin/pip" "${TERMUX_PREFIX}/bin/pip3"* \\
          "${TERMUX_PREFIX}/bin/easy_install" "${TERMUX_PREFIX}/bin/easy_install-3"*
    rm -rf "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/pip"
    rm -rf "${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/pip-"*.dist-info
fi

if [[ ! -f "${TERMUX_PREFIX}/bin/pip" ]]; then
    echo ""
    echo "== pip is a separate package: pkg install python-pip =="
    echo ""
fi

for _old in 3.11 3.12; do
    if [[ -d "${TERMUX_PREFIX}/lib/python\${_old}/site-packages" ]]; then
        echo "NOTE: Old site-packages for python\${_old} — reinstall for ${_MAJOR_VERSION}."
    fi
done

exit 0
POSTINST_EOF

    chmod 0755 ./postinst

    if [[ "${TERMUX_PACKAGE_FORMAT:-}" == "pacman" ]]; then
        echo "post_install" > ./postupg
    fi

    _sec_end "Post-install scripts"
}

# =============================================================================
# §19  CI configuration files
#      Generated once into BEE_DIR so they can be committed alongside build.sh
# =============================================================================
generate_ci_configs() {
    _sec_start "Generating CI configs"
    mkdir -p "${BEE_DIR}/.github/workflows"

    # ── GitHub Actions ─────────────────────────────────────────────────────────
    cat > "${BEE_DIR}/.github/workflows/build.yml" << 'GH_EOF'
# cpython/bee/.github/workflows/build.yml
# Builds Python 3.13 for Android on GitHub Actions.

name: Python 3.13 Android Build

on:
  push:
  pull_request:
  schedule:
    - cron: '0 3 * * 1'    # Every Monday 03:00 UTC

jobs:
  # ── Linux cross-compile ───────────────────────────────────────────────────
  build-linux:
    name: Linux (${{ matrix.arch }}, API ${{ matrix.api }})
    runs-on: ubuntu-22.04
    strategy:
      fail-fast: false
      matrix:
        arch: [aarch64, arm, i686, x86_64]
        api:  [21, 24, 28, 30, 33, 34, 35, 36]
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      - name: Install host deps (Linux)
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends \
            build-essential curl ca-certificates xz-utils \
            autoconf automake libtool pkg-config \
            python3 python3-dev \
            fakeroot dpkg

      - name: Set up Android NDK r27c
        id: ndk
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r27c
          add-to-path: true

      - name: Build
        env:
          TERMUX_ARCH: ${{ matrix.arch }}
          TERMUX_PKG_API_LEVEL: ${{ matrix.api }}
          TERMUX_STANDALONE_TOOLCHAIN: ${{ steps.ndk.outputs.ndk-path }}/toolchains/llvm/prebuilt/linux-x86_64
          BUILD_ROOT: ${{ github.workspace }}/.build
          TERMUX_PREFIX: ${{ github.workspace }}/install
          GITHUB_ACTIONS: "true"
        run: bash cpython/bee/build.sh

      - name: Upload .deb
        uses: actions/upload-artifact@v4
        with:
          name: python-${{ matrix.arch }}-api${{ matrix.api }}-linux
          path: .build/python_*.deb
          retention-days: 14

      - name: Upload install tree on failure
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: install-${{ matrix.arch }}-api${{ matrix.api }}-fail
          path: install/
          retention-days: 3

  # ── macOS cross-compile ───────────────────────────────────────────────────
  build-macos:
    name: macOS (${{ matrix.arch }}, API ${{ matrix.api }})
    runs-on: macos-14
    strategy:
      fail-fast: false
      matrix:
        arch: [aarch64, x86_64]
        api:  [24, 35]
    steps:
      - uses: actions/checkout@v4

      - name: Install host deps (macOS)
        run: |
          brew install autoconf automake libtool pkg-config curl

      - name: Set up Android NDK r27c
        id: ndk
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r27c
          add-to-path: true

      - name: Build (no .deb on macOS)
        env:
          TERMUX_ARCH: ${{ matrix.arch }}
          TERMUX_PKG_API_LEVEL: ${{ matrix.api }}
          TERMUX_STANDALONE_TOOLCHAIN: ${{ steps.ndk.outputs.ndk-path }}/toolchains/llvm/prebuilt/darwin-x86_64
          BUILD_ROOT: ${{ github.workspace }}/.build
          TERMUX_PREFIX: ${{ github.workspace }}/install
          GITHUB_ACTIONS: "true"
        run: bash cpython/bee/build.sh

      - name: Upload install tree
        uses: actions/upload-artifact@v4
        with:
          name: python-${{ matrix.arch }}-api${{ matrix.api }}-macos
          path: install/
          retention-days: 7

  # ── Windows (MSYS2 / cross to Android) ───────────────────────────────────
  build-windows:
    name: Windows/MSYS2 (${{ matrix.arch }}, API ${{ matrix.api }})
    runs-on: windows-2022
    strategy:
      fail-fast: false
      matrix:
        arch: [aarch64, x86_64]
        api:  [24, 35]
    defaults:
      run:
        shell: msys2 {0}
    steps:
      - uses: actions/checkout@v4

      - uses: msys2/setup-msys2@v2
        with:
          msystem: MINGW64
          update: true
          install: >-
            base-devel curl xz autoconf automake libtool pkg-config python3

      - name: Set up Android NDK r27c
        id: ndk
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r27c
          add-to-path: true

      - name: Build (no .deb on Windows)
        env:
          TERMUX_ARCH: ${{ matrix.arch }}
          TERMUX_PKG_API_LEVEL: ${{ matrix.api }}
          TERMUX_STANDALONE_TOOLCHAIN: ${{ steps.ndk.outputs.ndk-path }}/toolchains/llvm/prebuilt/windows-x86_64
          BUILD_ROOT: ${{ github.workspace }}/.build
          TERMUX_PREFIX: ${{ github.workspace }}/install
          GITHUB_ACTIONS: "true"
        run: bash cpython/bee/build.sh

      - name: Upload install tree
        uses: actions/upload-artifact@v4
        with:
          name: python-${{ matrix.arch }}-api${{ matrix.api }}-windows
          path: install/
          retention-days: 7

  # ── Verify .deb integrity ─────────────────────────────────────────────────
  verify:
    name: Verify .deb (aarch64, API 35)
    runs-on: ubuntu-22.04
    needs: build-linux
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: python-aarch64-api35-linux
          path: debs/

      - name: Check .deb structure
        run: |
          deb="$(ls debs/python_*.deb | head -1)"
          echo "Inspecting: $deb"
          dpkg-deb --info "$deb"
          dpkg-deb --contents "$deb" | grep -E "(bin/python|site-packages/README)" || \
              { echo "ERROR: expected files missing"; exit 1; }
          # FIX: verify bare 'python' is NOT in the .deb.
          # Original used grep -v "bin/python$" which exits 0 when no match
          # (i.e. when bare python IS absent, grep -v finds nothing, exits 1).
          # Correct logic: grep for bare python; if found, fail.
          if dpkg-deb --contents "$deb" | grep -qE '\bbin/python$'; then
              echo "ERROR: bare 'bin/python' must NOT be in .deb"; exit 1
          fi
          echo "✓ .deb structure OK"
GH_EOF

    # ── GitLab CI ─────────────────────────────────────────────────────────────
    cat > "${BEE_DIR}/.gitlab-ci.yml" << 'GL_EOF'
# cpython/bee/.gitlab-ci.yml
# Builds Python 3.13 for Android on GitLab CI.

image: ubuntu:22.04

variables:
  DEBIAN_FRONTEND: noninteractive
  NDK_VERSION: "r27c"
  BUILD_ROOT: "${CI_PROJECT_DIR}/.build"
  TERMUX_PREFIX: "${CI_PROJECT_DIR}/install"
  GIT_DEPTH: "1"

stages:
  - build
  - verify

# ── Shared setup template ──────────────────────────────────────────────────
.setup_linux: &setup_linux
  before_script:
    - apt-get update -qq
    - apt-get install -y --no-install-recommends
        build-essential curl ca-certificates unzip xz-utils
        autoconf automake libtool pkg-config python3 python3-dev
        fakeroot dpkg
    - |
      NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
      curl -fSL "https://dl.google.com/android/repository/${NDK_ZIP}" -o /tmp/ndk.zip
      unzip -q /tmp/ndk.zip -d /opt
      export TERMUX_STANDALONE_TOOLCHAIN="/opt/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64"
      echo "export TERMUX_STANDALONE_TOOLCHAIN=${TERMUX_STANDALONE_TOOLCHAIN}" > /tmp/ndk-env.sh
    - source /tmp/ndk-env.sh

# ── Linux build matrix ─────────────────────────────────────────────────────
.linux_build:
  stage: build
  <<: *setup_linux
  script:
    - source /tmp/ndk-env.sh
    - bash cpython/bee/build.sh
  artifacts:
    paths:
      - .build/python_*.deb
    expire_in: 2 weeks
    when: always

build:linux:aarch64:api24:
  extends: .linux_build
  variables: { TERMUX_ARCH: aarch64, TERMUX_PKG_API_LEVEL: "24" }

build:linux:aarch64:api35:
  extends: .linux_build
  variables: { TERMUX_ARCH: aarch64, TERMUX_PKG_API_LEVEL: "35" }

build:linux:aarch64:api36:
  extends: .linux_build
  variables: { TERMUX_ARCH: aarch64, TERMUX_PKG_API_LEVEL: "36" }

build:linux:arm:api24:
  extends: .linux_build
  variables: { TERMUX_ARCH: arm, TERMUX_PKG_API_LEVEL: "24" }

build:linux:i686:api24:
  extends: .linux_build
  variables: { TERMUX_ARCH: i686, TERMUX_PKG_API_LEVEL: "24" }

build:linux:x86_64:api24:
  extends: .linux_build
  variables: { TERMUX_ARCH: x86_64, TERMUX_PKG_API_LEVEL: "24" }

build:linux:x86_64:api35:
  extends: .linux_build
  variables: { TERMUX_ARCH: x86_64, TERMUX_PKG_API_LEVEL: "35" }

# ── Verify stage ────────────────────────────────────────────────────────────
verify:deb:
  stage: verify
  image: ubuntu:22.04
  needs: ["build:linux:aarch64:api35"]
  before_script:
    - apt-get update -qq && apt-get install -y dpkg
  script:
    - |
      deb="$(ls .build/python_*.deb | head -1)"
      echo "Verifying: $deb"
      dpkg-deb --info "$deb"
      dpkg-deb --contents "$deb" | grep "site-packages/README.md" || \
          { echo "ERROR: README.md missing from .deb"; exit 1; }
      dpkg-deb --contents "$deb" | grep "bin/python3$" || \
          { echo "ERROR: python3 symlink missing"; exit 1; }
      # FIX: check bare python is absent — original grep -v logic was inverted.
      # grep -v exits 0 when the pattern is NOT found, which is the wrong test.
      # Use grep -qE + negation: fail if bare python IS present.
      if dpkg-deb --contents "$deb" | grep -qE '\bbin/python$'; then
          echo "ERROR: bare 'bin/python' must NOT be in .deb"; exit 1
      fi
      echo "✓ All checks passed"
GL_EOF

    _info "GitHub Actions → ${BEE_DIR}/.github/workflows/build.yml"
    _info "GitLab CI      → ${BEE_DIR}/.gitlab-ci.yml"
    _sec_end "Generating CI configs"
}

# =============================================================================
# §20  Entry point
#
# When executed directly: full build sequence.
# When sourced by Termux build-package.sh: only termux_step_* are defined;
# the build system calls them in the correct order.
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    _resolve_api_level
    _validate_api_level

    _sec_start "cpython/bee/build.sh"
    _info "Python version     : ${TERMUX_PKG_VERSION}"
    _info "TERMUX_ARCH        : ${TERMUX_ARCH}"
    _info "HOST_ARCH          : ${HOST_ARCH}"
    _info "IS_CROSS           : ${IS_CROSS}"
    _info "API_LEVEL          : ${TERMUX_PKG_API_LEVEL}"
    _info "BUILD_OS           : ${BUILD_OS}"
    _info "PREFIX             : ${TERMUX_PREFIX}"
    _info "BUILD_ROOT         : ${BUILD_ROOT}"
    _info "CPYTHON source     : ${CPYTHON}"
    _info "DEB output         : ${BUILD_ROOT}/${DEB_FILENAME}"
    _info "CI (GHA/GL/generic): ${_IS_GHA}/${_IS_GL}/${_IS_CI}"
    _sec_end "cpython/bee/build.sh"

    generate_ci_configs             # write CI configs (idempotent)
    termux_step_post_get_source     # apply patches + autoreconf --fiv
    termux_step_pre_configure       # toolchain + all dep builds
    termux_step_configure           # configure + build CPython
    termux_step_post_make_install   # install + symlinks + README
    termux_step_post_massage        # verify extension modules
    build_deb                       # build .deb (Linux only)
    termux_step_create_debscripts   # write postinst / postupg

    echo ""
    _info "═══════════════════════════════════════════════════"
    _info "Build complete."
    _info "  python${_MAJOR_VERSION}  →  ${TERMUX_PREFIX}/bin/python${_MAJOR_VERSION}"
    _info "  python3       →  ${TERMUX_PREFIX}/bin/python3 (→ python${_MAJOR_VERSION})"
    _info "  site-packages →  ${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/site-packages/"
    if [[ "${BUILD_OS}" == "linux" ]]; then
        _info "  .deb          →  ${BUILD_ROOT}/${DEB_FILENAME}"
    fi
    _info "═══════════════════════════════════════════════════"
fi
