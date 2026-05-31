#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
WORKFLOW_DIR="${COMFYUI_DIR}/user/default/workflows"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3

# Google Drive folder ID for the "loras" folder (public link)
# https://drive.google.com/drive/folders/1MN2sJ0gi_tm6hJFbcQQ17Txosw0xo0VP
GDRIVE_LORAS_FOLDER_ID="1MN2sJ0gi_tm6hJFbcQQ17Txosw0xo0VP"

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
}

# If this script fails we cannot let a serverless worker be marked as ready.
script_error() {
    local exit_code=$?
    local line_number=$1
    echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

main() {
    . /venv/main/bin/activate
    mkdir -p "$HF_SEMAPHORE_DIR"
    download_input
    download_gdrive_loras

    pids=()
    # Download all HuggingFace models in parallel
    for model in "${HF_MODELS[@]}"; do
        url="${model%%|*}"
        output_path="${model##*|}"
        download_hf_file "$url" "$output_path" &
        pids+=($!)
    done
    
    # Wait for each job and check exit status
    for pid in "${pids[@]}"; do
        wait "$pid" || exit 1
    done
}

download_input() {
  wget -O "$COMFYUI_DIR/input/input.jpg" https://raw.githubusercontent.com/Comfy-Org/example_workflows/refs/heads/main/video/wan/2.2/input.jpg
}

# Download the entire "loras" folder from Google Drive preserving subfolder structure.
# Uses gdown (pip install gdown) with --folder --remaining-ok flags.
# The destination is $MODELS_DIR/loras/ and gdown will recreate subfolders
# (e.g. acciones/, extras/, ...) exactly as they are in Google Drive.
download_gdrive_loras() {
  local loras_dir="$MODELS_DIR/loras"

  echo "==> Installing/upgrading gdown..."
  pip install -q --upgrade gdown

  echo "==> Downloading Google Drive loras folder (ID: $GDRIVE_LORAS_FOLDER_ID)..."
  echo "    Destination: $loras_dir"

  mkdir -p "$loras_dir"

  # --folder  : descarga la carpeta de Drive recursivamente
  # --continue: salta archivos ya existentes (idempotente)
  # -O        : apunta a $MODELS_DIR/loras directamente; gdown vuelca
  #             el contenido dentro sin crear subcarpeta extra
  # Si falla (quota de Drive, etc.) registra el aviso pero no aborta
  # el script, para que las descargas de HuggingFace sigan adelante.
  if ! gdown \
    --folder \
    --continue \
    -O "$loras_dir" \
    "https://drive.google.com/drive/folders/$GDRIVE_LORAS_FOLDER_ID"; then
    echo "[WARN] gdown encontro errores descargando la carpeta de Drive. Continuando..."
  else
    echo "✓ Google Drive loras folder downloaded to: $loras_dir"
  fi
}

# HuggingFace download helper
download_hf_file() {
  local url="$1"
  local output_path="$2"
  local lockfile="${output_path}.lock"
  local max_retries=5
  local retry_delay=2
  
  # Acquire slot for parallel download limiting
  local slot=$(acquire_slot)
  
  # Acquire lock for this specific file
  while ! mkdir "$lockfile" 2>/dev/null; do
    echo "Another process is downloading to $output_path (waiting...)"
    sleep 1
  done
  
  # Check if file already exists
  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)"
    rmdir "$lockfile"
    release_slot "$slot"
    return 0
  fi
  
  # Extract repo and file path
  local repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
  local file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')
  
  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    echo "ERROR: Invalid HuggingFace URL: $url"
    rmdir "$lockfile"
    release_slot "$slot"
    return 1
  fi
  
  local temp_dir=$(mktemp -d)
  local attempt=1
  
  # Retry loop for rate limits and transient failures
  while [ $attempt -le $max_retries ]; do
    echo "Downloading $file_path (attempt $attempt/$max_retries)..."
    
    if hf download "$repo" \
      "$file_path" \
      --local-dir "$temp_dir" \
      --cache-dir "$temp_dir/.cache" 2>&1; then
      
      # Success - move file and clean up
      mkdir -p "$(dirname "$output_path")"
      mv "$temp_dir/$file_path" "$output_path"
      rm -rf "$temp_dir"
      rmdir "$lockfile"
      release_slot "$slot"
      echo "✓ Successfully downloaded: $output_path"
      return 0
    else
      echo "✗ Download failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep $retry_delay
      retry_delay=$((retry_delay * 2))  # Exponential backoff
      attempt=$((attempt + 1))
    fi
  done
  
  # All retries failed
  echo "ERROR: Failed to download $output_path after $max_retries attempts"
  rm -rf "$temp_dir"
  rmdir "$lockfile"
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
