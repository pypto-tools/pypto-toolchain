#!/usr/bin/env bash
# Install the shared simpler development environment into the versioned prefix.
# Runs in the AlmaLinux 8 build image, after CPython and GCC are built.
set -euo pipefail

: "${PREFIX:?PREFIX must be set}"
: "${NODE_VERSION:?NODE_VERSION must be set}"
: "${GTEST_VERSION:?GTEST_VERSION must be set}"
: "${PYPI_INDEX:?PYPI_INDEX must be set}"

export LD_LIBRARY_PATH="$PREFIX/gcc/lib64:$PREFIX/python/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$PREFIX/node/bin:$PREFIX/python/bin:$PREFIX/bin:$PATH"

python="$PREFIX/python/bin/python3.10"
wheelhouse="$PREFIX/wheelhouse"
mkdir -p "$wheelhouse" "$PREFIX/bin" "$PREFIX/node" \
    "$PREFIX/node-markdownlint" "$PREFIX/libexec/graphviz"

# The exact +cpu version cannot resolve to a CUDA wheel.
"$python" -m pip download --only-binary=:all: -d "$wheelhouse" \
    --index-url https://download.pytorch.org/whl/cpu \
    --extra-index-url "$PYPI_INDEX" 'torch==2.6.0+cpu'
"$python" -m pip download --only-binary=:all: -d "$wheelhouse" \
    -i "$PYPI_INDEX" -r /usr/local/share/simpler-requirements.txt

# The base interpreter owns these packages. A project-local venv made with
# --system-site-packages then sees them, including torch and the build backend.
"$python" -m pip install --no-index --find-links "$wheelhouse" \
    -r /usr/local/share/simpler-requirements.txt 'torch==2.6.0+cpu'
"$python" -m pip check
"$python" -m pip freeze --local > "$PREFIX/PYTHON-PACKAGES"

arch="$(uname -m)"
case "$arch" in
    aarch64) node_arch=arm64
             node_sha=d462267863ae8ee556039ebdf559055a8ec562c633889ef1403f3adb449ba1dd ;;
    x86_64) node_arch=x64
            node_sha=315046739a513a70e03a4a55a8afda8cf979f30852e576075c340084e3f8ac0f ;;
    *) echo "unsupported Node architecture: $arch" >&2; exit 1 ;;
esac
node_archive="/build/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
curl -fsSL --retry 5 \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
    -o "$node_archive"
printf '%s  %s\n' "$node_sha" "$node_archive" | sha256sum -c -
tar xJf "$node_archive" --strip-components=1 -C "$PREFIX/node"
rm -f "$node_archive"
cp /usr/local/share/simpler-node/package*.json "$PREFIX/node-markdownlint/"
"$PREFIX/node/bin/npm" ci --prefix "$PREFIX/node-markdownlint" \
    --omit=dev --ignore-scripts --no-audit --no-fund
ln -s ../node-markdownlint/node_modules/.bin/markdownlint-cli2 \
    "$PREFIX/bin/markdownlint-cli2"

# Graphviz from the AlmaLinux 8 base has the same glibc floor as the bundle.
# Its plugins and non-glibc libraries are copied into the versioned prefix.
for engine in dot neato sfdp fdp circo twopi; do
    cp -L "/usr/bin/$engine" "$PREFIX/libexec/graphviz/$engine"
done
cat > "$PREFIX/bin/dot" <<'DOT_EOF'
#!/usr/bin/env bash
prefix=@PREFIX@
export GVBINDIR="$prefix/lib/graphviz"
# Scope these dependencies to Graphviz so host OpenSSL is not displaced.
export LD_LIBRARY_PATH="$prefix/lib/bundled:$prefix/gcc/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$prefix/libexec/graphviz/${0##*/}" "$@"
DOT_EOF
sed -i "s|@PREFIX@|$PREFIX|" "$PREFIX/bin/dot"
chmod +x "$PREFIX/bin/dot"
for engine in neato sfdp fdp circo twopi; do
    ln -s dot "$PREFIX/bin/$engine"
done
mkdir -p "$PREFIX/lib/graphviz"
cp -a /usr/lib64/graphviz/libgvplugin_core.so.6* \
      /usr/lib64/graphviz/libgvplugin_dot_layout.so.6* \
      /usr/lib64/graphviz/libgvplugin_neato_layout.so.6* \
      "$PREFIX/lib/graphviz/"
"$PREFIX/bin/dot" -c

# Build GoogleTest with this bundle's GCC 15 and C++ ABI.
gtest_archive="/build/googletest-${GTEST_VERSION}.tar.gz"
curl -fsSL --retry 5 \
    "https://github.com/google/googletest/archive/refs/tags/v${GTEST_VERSION}.tar.gz" \
    -o "$gtest_archive"
printf '%s  %s\n' 8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7 \
    "$gtest_archive" | sha256sum -c -
tar xzf "$gtest_archive" -C /build
CC="$PREFIX/gcc/bin/gcc-15" CXX="$PREFIX/gcc/bin/g++-15" \
    "$PREFIX/python/bin/cmake" -S "/build/googletest-${GTEST_VERSION}" \
    -B /build/gtest-build -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$PREFIX/python/bin/ninja" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_GMOCK=OFF
"$PREFIX/python/bin/cmake" --build /build/gtest-build -j"$(nproc)"
"$PREFIX/python/bin/cmake" --install /build/gtest-build
rm -rf "/build/googletest-${GTEST_VERSION}" /build/gtest-build "$gtest_archive"

# No device management happens during the image build.
"$python" -c 'import torch,nanobind,scikit_build_core,pytest,numpy,safetensors; assert torch.version.cuda is None'
"$PREFIX/node/bin/node" --version
"$PREFIX/bin/markdownlint-cli2" --version
"$PREFIX/bin/dot" -Tsvg <<< 'digraph { a -> b }' | grep -q '<svg'
printf '#include <stddef.h>\nint main() { return 0; }\n' > /build/clang-resource-probe.cpp
"$PREFIX/python/bin/clang-tidy" /build/clang-resource-probe.cpp -- -std=c++17
rm -f /build/clang-resource-probe.cpp
