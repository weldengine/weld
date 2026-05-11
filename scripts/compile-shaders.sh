#!/usr/bin/env sh
# Compile the S2 spike shaders to SPIR-V. POSIX-shell, expects `glslc`
# (from the Vulkan SDK / shaderc) on PATH. Not wired into `zig build`
# per the brief — run it manually whenever the GLSL sources change and
# commit the resulting `.spv` files alongside.

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
shaders_dir="$repo_root/assets/shaders"

if ! command -v glslc >/dev/null 2>&1; then
    echo "compile-shaders.sh: glslc not found on PATH" >&2
    echo "  Install via the Vulkan SDK (https://vulkan.lunarg.com/) or" >&2
    echo "  'brew install shaderc' on macOS." >&2
    exit 1
fi

cd "$shaders_dir"

echo "compile-shaders.sh: glslc $(glslc --version | head -1)"

for src in triangle.vert.glsl triangle.frag.glsl; do
    case "$src" in
        *.vert.glsl) stage=vert ;;
        *.frag.glsl) stage=frag ;;
        *)
            echo "compile-shaders.sh: cannot derive shader stage from '$src'" >&2
            exit 1
            ;;
    esac
    out="${src%.glsl}.spv"
    glslc -fshader-stage="$stage" "$src" -o "$out"
    bytes=$(wc -c < "$out" | tr -d ' ')
    echo "  $src → $out ($bytes bytes)"
done

echo "compile-shaders.sh: done. Commit the .spv files alongside the .glsl sources."
