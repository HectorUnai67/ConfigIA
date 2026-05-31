#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3

# Google Drive ZIP file ID (carpeta loras comprimida)
# ZIPs de loras alojados en HuggingFace — añadir más URLs según se necesite
HF_LORAS_ZIPS=(
  "https://huggingface.co/HectorUnai/test/resolve/main/acciones.zip"
)

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors
  |$MODELS_DIR/text_encoders/umt5_xxl_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors
  |$MODELS_DIR/vae/wan_2.1_vae.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors
  |$MODELS_DIR/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors
  |$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors
  |$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_v1030_rank_64_bf16.safetensors
  |$MODELS_DIR/loras/extras/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_v1030_rank_64_bf16.safetensors"
  "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors
  |$MODELS_DIR/loras/extras/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"
)
### End Configuration ###

script_cleanup() {
   rm -rf "$HF_SEMAPHORE_DIR"
   kill "$PROGRESS_PID" 2>/dev/null || true
}

script_error() {
    local exit_code=$?
    local line_number=$1
    echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

progress_monitor() {
  while true; do
    sleep 30
    echo "--- [PROGRESO $(date '+%H:%M:%S')] ---"
    find /tmp -name "*.incomplete" 2>/dev/null | while read f; do
      size=$(du -sh "$f" 2>/dev/null | cut -f1)
      name=$(basename "$f" | sed 's/=.*$//')
      echo "  Descargando: $name  ->  $size"
    done
    find "$MODELS_DIR" -name "*.safetensors" 2>/dev/null | while read f; do
      size=$(du -sh "$f" 2>/dev/null | cut -f1)
      echo "  Completado:  $(basename $f)  ($size)"
    done
  done
}

main() {
    . /venv/main/bin/activate
    mkdir -p "$HF_SEMAPHORE_DIR"

    progress_monitor &
    PROGRESS_PID=$!

    download_input
    download_hf_loras_zips

    pids=()
    for model in "${HF_MODELS[@]}"; do
        url="${model%%|*}"
        output_path="${model##*|}"
        download_hf_file "$url" "$output_path" &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" || exit 1
    done

    echo "==> Todas las descargas completadas."
}

download_input() {
  wget -O "$COMFYUI_DIR/input/input.jpg" https://raw.githubusercontent.com/Comfy-Org/example_workflows/refs/heads/main/video/wan/2.2/input.jpg
}

download_hf_loras_zips() {
  local loras_dir="$MODELS_DIR/loras"
  mkdir -p "$loras_dir"

  for zip_url in "${HF_LORAS_ZIPS[@]}"; do
    local zip_name
    zip_name=$(basename "$zip_url" | cut -d'?' -f1)
    local zip_path="/tmp/$zip_name"

    if [ -f "$zip_path" ]; then
      echo "==> ZIP ya descargado, reutilizando: $zip_path"
    else
      echo "==> Descargando $zip_name desde HuggingFace..."
      if ! wget -q --show-progress -O "$zip_path" "$zip_url"; then
        echo "[WARN] No se pudo descargar $zip_url. Continuando..."
        rm -f "$zip_path"
        continue
      fi
      echo "✓ ZIP descargado: $zip_path"
    fi

    echo "==> Descomprimiendo $zip_name en $loras_dir ..."
    unzip -o "$zip_path" -d "$loras_dir"
    rm -f "$zip_path"
    echo "✓ $zip_name descomprimido en: $loras_dir"
  done
}

download_hf_file() {
  local url="$1"
  local output_path="$2"
  local max_retries=5
  local retry_delay=2

  local slot=$(acquire_slot)

  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)"
    release_slot "$slot"
    return 0
  fi

  local repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
  local file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')

  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    echo "ERROR: Invalid HuggingFace URL: $url"
    release_slot "$slot"
    return 1
  fi

  local temp_dir=$(mktemp -d)
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    echo "Downloading $file_path (attempt $attempt/$max_retries)..."

    if hf download "$repo" \
      "$file_path" \
      --local-dir "$temp_dir" \
      --cache-dir "$temp_dir/.cache" 2>&1; then

      mkdir -p "$(dirname "$output_path")"
      mv "$temp_dir/$file_path" "$output_path"
      rm -rf "$temp_dir"
      release_slot "$slot"
      echo "✓ Successfully downloaded: $(basename $output_path)"
      return 0
    else
      echo "✗ Download failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep $retry_delay
      retry_delay=$((retry_delay * 2))
      attempt=$((attempt + 1))
    fi
  done

  echo "ERROR: Failed to download $output_path after $max_retries attempts"
  rm -rf "$temp_dir"
  release_slot "$slot"
  return 1
}

acquire_slot() {
  while true; do
    local count=$(find "$HF_SEMAPHORE_DIR" -name "slot_*" 2>/dev/null | wc -l)
    if [ $count -lt $HF_MAX_PARALLEL ]; then
      local slot="$HF_SEMAPHORE_DIR/slot_$$_$RANDOM"
      touch "$slot"
      echo "$slot"
      return 0
    fi
    sleep 0.5
  done
}

release_slot() {
  rm -f "$1"
}

main
