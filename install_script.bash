#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# Configuration
# ==========================================
#
# Pinned versions (as of 2026-11-28). Override any of these with
# environment variables, e.g. METAL_COMMIT=v0.84.0 ./install-ttsim.sh
# If you change TTSIM_VERSION, update TTSIM_SHA256 too (or set it to
# an empty string to skip verification).

SIM_DIR="${SIM_DIR:-$HOME/sim}"
METAL_DIR="${METAL_DIR:-$HOME/tt-metal}"

# tt-metal release tag v0.83.0 = commit 87f9a228a061449fd6aa1614bbd1f9206c56962c
METAL_COMMIT="${METAL_COMMIT:-v0.83.0}"

TTSIM_VERSION="${TTSIM_VERSION:-v1.17.0}"
TTSIM_URL="${TTSIM_URL:-https://github.com/tenstorrent/ttsim/releases/download/${TTSIM_VERSION}/libttsim_bh.so}"
TTSIM_SHA256="${TTSIM_SHA256-743eaf474b4360bc68a8a0bd3c689d856486aeb10d7a9ae9b3c65a3ca3b430eb}"

SOC_DESCRIPTOR="blackhole_140_arch.yaml"

MIN_DISK_GB=40
MIN_RAM_GB=4

# ==========================================
# Utility functions
# ==========================================

info() {
    printf '\n[INFO] %s\n' "$*"
}

warn() {
    printf '\n[WARNING] %s\n' "$*" >&2
}

fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

trap 'echo "[ERROR] Installation failed at line $LINENO" >&2' ERR

apt_install() {
    sudo apt-get \
        -o DPkg::Lock::Timeout=600 \
        install -y "$@"
}

# ==========================================
# Detect host environment
# ==========================================

info "Detecting host environment..."

source /etc/os-release

ARCH=$(uname -m)
CPU_THREADS=$(nproc)

RAM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)

AVAILABLE_RAM_MB=$(awk \
    '/^MemAvailable:/ {print int($2/1024)}' \
    /proc/meminfo)

# Check the filesystem that will hold the tt-metal checkout.
# Walk up to the nearest existing directory, since METAL_DIR may not exist yet.
DISK_CHECK_DIR="$METAL_DIR"
while [[ ! -d "$DISK_CHECK_DIR" ]]; do
    DISK_CHECK_DIR=$(dirname "$DISK_CHECK_DIR")
done

DISK_GB=$(df -BG -P "$DISK_CHECK_DIR" | awk \
    'NR==2 {gsub("G","",$4); print $4}')

echo "OS:             $PRETTY_NAME"
echo "Architecture:   $ARCH"
echo "CPU threads:    $CPU_THREADS"
echo "Total RAM:      $RAM_MB MiB"
echo "Available RAM:  $AVAILABLE_RAM_MB MiB"
echo "Free disk:      $DISK_GB GiB (at $DISK_CHECK_DIR)"

# ==========================================
# Compatibility checks
# ==========================================

if [[ "$ARCH" != "x86_64" ]]; then
    fail "This installer currently requires x86-64."
fi

if [[ "$ID" != "ubuntu" ]]; then
    fail "This installer currently supports Ubuntu."
fi

if [[ "$VERSION_ID" != "24.04" ]]; then
    fail "This installer has been designed for Ubuntu 24.04."
fi

if (( RAM_MB < MIN_RAM_GB * 1024 )); then
    fail "Insufficient RAM for compilation."
fi

if (( DISK_GB < MIN_DISK_GB )); then
    fail "At least $MIN_DISK_GB GiB of free disk space recommended."
fi

if [[ -n "${CONDA_PREFIX:-}" ]]; then
    fail "Conda is active. Run conda deactivate and retry."
fi

if (( EUID == 0 )); then
    fail "Run this script as a normal user, not root."
fi

# ==========================================
# Automatically calculate build parallelism
# ==========================================

# Reserve approximately 2 GiB for the OS.
# Budget approximately 3 GiB per compiler job.
# (build_metal.sh builds via `cmake --build`, which honours
# CMAKE_BUILD_PARALLEL_LEVEL.)

SAFE_RAM_MB=$(( AVAILABLE_RAM_MB - 2048 ))
AUTO_JOBS=$(( SAFE_RAM_MB / 3072 ))

if (( AUTO_JOBS < 1 )); then
    AUTO_JOBS=1
fi

if (( AUTO_JOBS > CPU_THREADS )); then
    AUTO_JOBS=$CPU_THREADS
fi

BUILD_JOBS="${BUILD_JOBS:-$AUTO_JOBS}"

if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    fail "BUILD_JOBS must be a positive integer."
fi

info "Build configuration"

echo "TT-Metalium version:            $METAL_COMMIT"
echo "TTSim version:                  $TTSIM_VERSION"
echo "Automatically recommended jobs: $AUTO_JOBS"
echo "Selected compilation jobs:      $BUILD_JOBS"

# ==========================================
# Acquire sudo and keep it alive
# ==========================================

# The clone and build can outlast sudo's credential cache, so ask for the
# password once now and refresh it in the background until the script exits.

info "Requesting sudo access (needed for package installation)..."

sudo -v

( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) \
    2>/dev/null &
SUDO_KEEPALIVE_PID=$!

trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ==========================================
# Install basic dependencies
# ==========================================

info "Installing basic dependencies..."

sudo apt-get -o DPkg::Lock::Timeout=600 update

apt_install \
    git \
    wget \
    curl \
    build-essential \
    python3-venv \
    tmux \
    file

# ==========================================
# Install TTSim
# ==========================================

info "Installing Blackhole simulator ($TTSIM_VERSION)..."

mkdir -p "$SIM_DIR"

verify_ttsim() {
    [[ -z "$TTSIM_SHA256" ]] && return 0
    printf '%s  %s\n' "$TTSIM_SHA256" "$1" | sha256sum -c --status -
}

# Re-download if the library is missing or doesn't match the pinned checksum
# (e.g. an older version left over from a previous install).
if [[ -f "$SIM_DIR/libttsim_bh.so" ]] && verify_ttsim "$SIM_DIR/libttsim_bh.so"; then
    info "Existing simulator matches the pinned version. Skipping download."
else
    if [[ -f "$SIM_DIR/libttsim_bh.so" ]]; then
        warn "Existing simulator does not match the pinned checksum. Replacing it."
    fi

    wget \
        -O "$SIM_DIR/libttsim_bh.so.tmp" \
        "$TTSIM_URL"

    if ! verify_ttsim "$SIM_DIR/libttsim_bh.so.tmp"; then
        rm -f "$SIM_DIR/libttsim_bh.so.tmp"
        fail "Downloaded simulator failed SHA256 verification."
    fi

    mv "$SIM_DIR/libttsim_bh.so.tmp" \
       "$SIM_DIR/libttsim_bh.so"
fi

if [[ -z "$TTSIM_SHA256" ]]; then
    warn "TTSIM_SHA256 is empty; simulator checksum was not verified."
fi

file "$SIM_DIR/libttsim_bh.so"
ls -lh "$SIM_DIR/libttsim_bh.so"

# ==========================================
# Clone TT-Metalium
# ==========================================

info "Preparing TT-Metalium repository..."

if [[ ! -d "$METAL_DIR/.git" ]]; then

    git clone \
        https://github.com/tenstorrent/tt-metal.git \
        "$METAL_DIR"

else
    info "Existing repository found."
fi

cd "$METAL_DIR"

if [[ -n "$METAL_COMMIT" ]]; then

    git fetch --tags origin

    # Resolve branch names against origin so we never check out a
    # stale local branch.
    if git show-ref --verify --quiet "refs/remotes/origin/$METAL_COMMIT"; then
        git checkout --detach "origin/$METAL_COMMIT"
    else
        git checkout --detach "$METAL_COMMIT"
    fi

fi

git submodule update --init --recursive

# ==========================================
# Install TT-Metalium dependencies
# ==========================================

info "Installing TT-Metalium dependencies..."

if ! sudo ./install_dependencies.sh; then

    warn "Dependency installation failed."

    # Process substitution instead of a pipe: under pipefail, `cmd | grep -q`
    # can report failure when grep exits early and cmd gets SIGPIPE.
    if grep -q 'llvm-toolchain-noble-20' <(apt-cache policy); then

        info "Attempting known LLVM dependency fix..."

        apt_install \
            -t llvm-toolchain-noble-20 \
            clang-20 \
            clangd-20 \
            lld-20 \
            lldb-20 \
            libllvm20 \
            llvm-20-dev

        info "Retrying dependency installation..."

        sudo ./install_dependencies.sh

    else

        fail "Dependency installation failed. Check output."

    fi

fi

# ==========================================
# Verify compiler toolchain
# ==========================================

info "Verifying toolchain..."

for tool in clang-20 clang++-20 g++-14 cmake ninja; do

    command -v "$tool" >/dev/null ||
        fail "Missing required tool: $tool"

done

clang++-20 --version
g++-14 --version
cmake --version
ninja --version

# ==========================================
# Build TT-Metalium
# ==========================================

info "Building TT-Metalium..."

echo "Using $BUILD_JOBS parallel jobs."

CMAKE_BUILD_PARALLEL_LEVEL="$BUILD_JOBS" \
    ./build_metal.sh \
    --release \
    --build-programming-examples \
    --without-python-bindings \
    --without-distributed \
    --disable-profiler \
    --export-compile-commands \
    --cxx-compiler-path /usr/bin/clang++-20 \
    --c-compiler-path /usr/bin/clang-20

# ==========================================
# Install SOC descriptor
# ==========================================

# TTSim requires a SOC descriptor YAML in the same directory as the .so.
# Re-copied on every run so it always matches the checked-out tt-metal.

info "Installing SOC descriptor..."

SOC_SRC="$METAL_DIR/tt_metal/soc_descriptors/$SOC_DESCRIPTOR"

[[ -f "$SOC_SRC" ]] ||
    fail "SOC descriptor not found: $SOC_SRC"

cp "$SOC_SRC" "$SIM_DIR/soc_descriptor.yaml"

# ==========================================
# Generate activation script
# ==========================================

info "Creating activation script..."

{
    echo '#!/usr/bin/env bash'

    printf 'export TT_METAL_HOME=%q\n' \
        "$METAL_DIR"

    printf 'export TT_METAL_SIMULATOR=%q\n' \
        "$SIM_DIR/libttsim_bh.so"

    echo 'export TT_METAL_SLOW_DISPATCH_MODE=1'

    echo 'echo "Tenstorrent Blackhole simulator configured."'

} > "$SIM_DIR/activate.sh"

chmod +x "$SIM_DIR/activate.sh"

# ==========================================
# Activate environment
# ==========================================

source "$SIM_DIR/activate.sh"

# ==========================================
# Run verification test
# ==========================================

info "Running simulator verification test..."

TEST_BINARY="$METAL_DIR/build/programming_examples/metal_example_add_2_integers_in_riscv"

if [[ ! -x "$TEST_BINARY" ]]; then
    TEST_BINARY=$(find "$METAL_DIR/build" \
        -type f \
        -executable \
        -name 'metal_example_add_2_integers_in_riscv' \
        -print -quit)
fi

if [[ -z "$TEST_BINARY" ]]; then
    fail "Could not locate verification executable."
fi

cd "$METAL_DIR"

"$TEST_BINARY"

# ==========================================
# Record installed versions
# ==========================================

{
    echo "Installation date:  $(date -Iseconds)"
    echo "TT-Metalium ref:    $METAL_COMMIT"
    echo "TT-Metalium commit: $(git rev-parse HEAD)"
    echo "TTSim version:      $TTSIM_VERSION"
    echo "TTSim URL:          $TTSIM_URL"
    echo "SOC descriptor:     $SOC_DESCRIPTOR"
    echo "Simulator checksum:"
    sha256sum "$SIM_DIR/libttsim_bh.so"

} > "$SIM_DIR/install-info.txt"

# ==========================================
# Complete
# ==========================================

info "Installation successful!"

echo ""
echo "TT-Metalium: $METAL_DIR"
echo "Simulator:   $SIM_DIR/libttsim_bh.so"
echo "Build jobs:  $BUILD_JOBS"
echo ""
echo "To activate the simulator:"
printf 'source %q\n' "$SIM_DIR/activate.sh"
echo ""
echo "Installation information:"
cat "$SIM_DIR/install-info.txt"
