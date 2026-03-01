#!/bin/bash
# MSBuild-compatible wrapper for building the Source SDK 2013 TF2 server binary.
# Unlike src/buildallprojects, this script runs Podman non-interactively (no -it)
# so it can be invoked from MSBuild Exec targets.
#
# Usage: ./build-native.sh [debug|release] [jobs]
# Output: game/mod_tf/bin/linux64/server.so

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Determine build configuration.
build_mode="release"
ninja_jobs=""

for arg in "$@"; do
    case "$arg" in
        debug|release) build_mode="$arg" ;;
        [0-9]*) ninja_jobs="$arg" ;;
        *) echo "Usage: $0 [debug|release] [jobs]"; exit 1 ;;
    esac
done

solution_out="_vpc_/ninja/sdk_everything_$build_mode"

# Build commands to run inside the container (or directly if already in one).
build_commands=$(cat <<SCRIPT
set -euo pipefail
cd /my_mod/src
export VPC_NINJA_BUILD_MODE="$build_mode"

if [[ ! -e "$solution_out.ninja" ]]; then
    devtools/bin/vpc /hl2mp /tf /linux64 /ninja /define:SOURCESDK +everything /mksln "$solution_out"

    ninja -f "$solution_out.ninja" -t compdb > compile_commands.json
    sed -i 's/-fpredictive-commoning//g; s/-fvar-tracking-assignments//g' compile_commands.json
    sed -i 's|/my_mod/src|.|g' compile_commands.json
fi

jobs=\${NINJA_JOBS:-${ninja_jobs:-\$(nproc)}}
echo "Building with -j\$jobs"
ninja -f "$solution_out.ninja" -j\$jobs
SCRIPT
)

# If already inside a container, run directly.
if [[ -f /run/.containerenv ]]; then
    bash -c "$build_commands"
    exit 0
fi

# Check for podman.
if ! command -v podman &> /dev/null; then
    echo "Error: podman is not installed."
    exit 1
fi

image="registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest"
echo "Building Source SDK 2013 ($build_mode) inside $image"

# Ensure ccache directory exists.
ccache_dir="${CCACHE_DIR:-$HOME/.ccache}"
mkdir -p "$ccache_dir"

exec podman run \
    --env "VPC_NINJA_BUILD_MODE=$build_mode" \
    --env "CCACHE_DIR=$ccache_dir" \
    --userns=keep-id \
    --rm \
    --mount type=bind,"source=$ccache_dir,target=$ccache_dir" \
    --mount type=bind,"source=$script_dir",target=/my_mod/ \
    "$image" \
    bash -c "$build_commands"
