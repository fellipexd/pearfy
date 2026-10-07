#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine_dir=$(CDPATH= cd -- "$package_dir/../../../pearfy-engine" && pwd)
sources_dir="$package_dir/Sources"
source_link="$package_dir/Sources/PearfyNetwork"
created_sources_dir=0

if [ ! -d "$engine_dir/Sources/PearfyNetwork" ]; then
    printf '%s\n' "PearfyEngine checkout not found at $engine_dir" >&2
    exit 2
fi
if [ -e "$source_link" ] || [ -L "$source_link" ]; then
    printf '%s\n' "Refusing to replace existing path: $source_link" >&2
    exit 2
fi

if [ ! -d "$sources_dir" ]; then
    mkdir -p "$sources_dir"
    created_sources_dir=1
fi
ln -s "$engine_dir/Sources/PearfyNetwork" "$source_link"
cleanup() {
    rm -f "$source_link"
    if [ "$created_sources_dir" -eq 1 ]; then
        rmdir "$sources_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

swift test --package-path "$package_dir" "$@"
