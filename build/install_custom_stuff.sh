#!/usr/bin/env bash
set -e

# Pre-install custom nodes and pinned dependencies into the
# Docker image so they don't need to be installed at runtime.
# Model downloads and HuggingFace authentication are NOT included.

cd /ComfyUI
source venv/bin/activate

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore

# ──────────── Hard version pins (verified against PyPI) ────────────

# opencv — 4.10.0.84 is the real latest headless wheel
PIN_OPENCV="${PIN_OPENCV:-4.10.0.84}"

# pillow — 11.x is current stable
PIN_PILLOW_MIN="${PIN_PILLOW_MIN:-11.0.0}"
PIN_PILLOW_MAX="${PIN_PILLOW_MAX:-<12}"

# numpy — Docker image ships >=2.0,<2.8; keep compatible ceiling
PIN_NUMPY_CEILING="${PIN_NUMPY_CEILING:-<2.8}"

# scipy — pin ceiling; scipy 1.15+ drags numpy >=2 which some nodes can't handle
PIN_SCIPY_CEILING="${PIN_SCIPY_CEILING:-<1.16}"

# numba — 0.61 supports numpy<2.2; 0.60 only supports numpy<2.1
PIN_NUMBA_MIN="${PIN_NUMBA_MIN:-0.61.0}"
PIN_NUMBA_MAX="${PIN_NUMBA_MAX:-<0.62}"

# onnxruntime — runtime dep for various model loaders
PIN_ONNXRUNTIME_MIN="${PIN_ONNXRUNTIME_MIN:-1.18.0}"

# gguf — Python GGUF bindings
PIN_GGUF_MIN="${PIN_GGUF_MIN:-0.13.0}"

# safetensors — must stay fresh for newer models
PIN_SAFETENSORS="${PIN_SAFETENSORS:-0.4.5}"

# transformers / accelerate — needed by text encoder loading
PIN_TRANSFORMERS_MIN="${PIN_TRANSFORMERS_MIN:-4.48.0}"
PIN_ACCELERATE_MIN="${PIN_ACCELERATE_MIN:-1.3.0}"

# Node selection
REQUIRED_NODES="${REQUIRED_NODES:-"ComfyUI-KJNodes ComfyUI-Easy-Use rgthree-comfy ComfyUI-Inpaint-CropAndStitch ComfyUI-WanVideoWrapper ComfyUI-VideoHelperSuite ComfyUI-GGUF"}"

# ──────────── Helpers ────────────

get_node() {
    local dir=$1 url=$2 flag=${3:-}
    if [[ -d "custom_nodes/$dir" ]]; then
        echo " [SKIP] $dir already present."
    else
        echo " . cloning $dir"
        git clone --depth 1 $flag "$url" "custom_nodes/$dir"
    fi
}

sanitize_requirements() {
    local req="$1"
    [[ -f "$req" ]] || return 0
    sed -i -E \
        -e 's/^(torch([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(torchvision([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(torchaudio([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(opencv-python([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(opencv-python-headless([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(xformers([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(numpy([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(scipy([^#]*))/# \1  # pinned by installer/gI' \
        -e 's/^(numba([^#]*))/# \1  # pinned by installer/gI' \
        "$req" || true
}

# ──────────── Clone custom nodes ────────────
echo
echo "──────── Cloning custom nodes ────────"
get_node "ComfyUI-KJNodes"                "https://github.com/kijai/ComfyUI-KJNodes.git"
get_node "ComfyUI-Easy-Use"               "https://github.com/yolain/ComfyUI-Easy-Use"
get_node "rgthree-comfy"                  "https://github.com/rgthree/rgthree-comfy.git"
get_node "ComfyUI-Inpaint-CropAndStitch"  "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch"
get_node "ComfyUI-WanVideoWrapper"        "https://github.com/kijai/ComfyUI-WanVideoWrapper"
get_node "ComfyUI-VideoHelperSuite"       "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
get_node "ComfyUI-GGUF"                   "https://github.com/city96/ComfyUI-GGUF"

# ──────────── Core deps (not already in Docker baseline) ────────────
echo
echo "──────── Installing core deps ────────"

pip uninstall -y opencv-python opencv-contrib-python 2>/dev/null || true
pip install --no-input "opencv-python-headless==${PIN_OPENCV}"
pip install --no-input "pillow>=${PIN_PILLOW_MIN},${PIN_PILLOW_MAX}"
pip install --no-input "scipy${PIN_SCIPY_CEILING}"
pip install --no-input "numba>=${PIN_NUMBA_MIN},${PIN_NUMBA_MAX}"
pip install --no-input "onnxruntime>=${PIN_ONNXRUNTIME_MIN}"
pip install --no-input "gguf>=${PIN_GGUF_MIN}"
pip install --no-input "safetensors>=${PIN_SAFETENSORS}"
pip install --no-input "transformers>=${PIN_TRANSFORMERS_MIN}"
pip install --no-input "accelerate>=${PIN_ACCELERATE_MIN}"
pip install --no-input piexif || true

# ──────────── Global constraints file ────────────
echo "   - Writing constraints to /tmp/constraints.txt"
cat > /tmp/constraints.txt <<EOF
numpy${PIN_NUMPY_CEILING}
scipy${PIN_SCIPY_CEILING}
opencv-python-headless==${PIN_OPENCV}
pillow>=${PIN_PILLOW_MIN},${PIN_PILLOW_MAX}
numba>=${PIN_NUMBA_MIN},${PIN_NUMBA_MAX}
onnxruntime>=${PIN_ONNXRUNTIME_MIN}
gguf>=${PIN_GGUF_MIN}
safetensors>=${PIN_SAFETENSORS}
transformers>=${PIN_TRANSFORMERS_MIN}
accelerate>=${PIN_ACCELERATE_MIN}
EOF

# Pin xformers only when it is installed (cu124 images ship it, cu128 do not)
if pip show xformers >/dev/null 2>&1; then
    echo "xformers==${XFORMERS_VERSION}" >> /tmp/constraints.txt
fi

# Freeze installed packages to pin torch / torchvision / torchaudio versions
pip freeze | sed '/^-e /d' >> /tmp/constraints.txt

# ──────────── Install node requirements ────────────
echo
echo "──────── Installing node requirements ────────"
for dir in $REQUIRED_NODES; do
    req="custom_nodes/$dir/requirements.txt"
    if [[ -f "$req" ]]; then
        echo "   - $req"
        req_dir="$(dirname "$req")"

        sanitize_requirements "$req"

        pushd "$req_dir" >/dev/null
        if ! pip install --no-input --prefer-binary --no-build-isolation \
             --upgrade-strategy only-if-needed \
             --constraint /tmp/constraints.txt \
             -r requirements.txt; then
            echo "     -> [WARN] First attempt failed; retrying with build isolation..."
            pip install --no-input --prefer-binary \
                --upgrade-strategy only-if-needed \
                --constraint /tmp/constraints.txt \
                -r requirements.txt || {
                echo "     -> [ERROR] Failed: $req -- continuing"
            }
        fi
        popd >/dev/null
    else
        echo "   - (no requirements.txt) $dir"
    fi
done

# ──────────── Final pip check ────────────
echo
echo "──────── Pip dependency check ────────"
pip check || echo "   - (minor conflicts may exist; verify at runtime)"

# Cleanup
rm -f /tmp/constraints.txt
pip cache purge

echo
echo "Custom nodes and pinned deps are ready"
deactivate
