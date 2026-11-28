# Getting out of base environment + getting venv ready
conda deactivate

sudo apt update
sudo apt install -y git wget curl build-essential python3-venv

# Installing blackhole ttsim
mkdir -p ~/sim
cd ~/sim

wget https://github.com/tenstorrent/ttsim/releases/latest/download/libttsim_bh.so

# Checking that it worked
file libttsim_bh.so
ls -lh libttsim_bh.so

# Cloning tt-metal
cd ~
git clone --recurse-submodules \
    https://github.com/tenstorrent/tt-metal.git
cd tt-metal

# Building TT metalium 
cd ~/tt-metal
sudo ./install_dependencies.sh

cd ~/tt-metal

CMAKE_BUILD_PARALLEL_LEVEL=8 ./build_metal.sh \
    --release \
    --build-programming-examples \
    --without-python-bindings \
    --without-distributed \
    --disable-profiler \
    --export-compile-commands \
    --cxx-compiler-path /usr/bin/clang++-20 \
    --c-compiler-path /usr/bin/clang-20

# Configure TTsim
export TT_METAL_HOME="$HOME/tt-metal"
export TT_METAL_SIMULATOR="$HOME/sim/libttsim_bh.so"
export TT_METAL_SLOW_DISPATCH_MODE=1

file "$TT_METAL_SIMULATOR"

find ~/tt-metal -type f \
    -name 'metal_example_add_2_integers_in_riscv'
