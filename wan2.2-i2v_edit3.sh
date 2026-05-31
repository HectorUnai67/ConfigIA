#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"

# Google Drive
GDRIVE_LORAS_FOLDER_ID="1MN2sJ0gi_tm6hJFbcQQ17Txosw0xo0VP"
GDRIVE_API_KEY="AIzaSyC3paQZt0IzWNUY5sYcHtW9Vt1uM-ODktg"

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors|$MODELS_DIR/text_encoders/umt5_xxl_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors|$MODELS_DIR/vae/wan_2.1_vae.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors|$MODELS_DIR/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors|$MODELS_DIR/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors|$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors|$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_v1030_rank_64_bf16.safetensors|$MODELS_DIR/loras/extras/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_v1030_rank_64_bf16.safetensors"
  "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors|$MODELS_DIR/loras/extras/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"
)
### End Configuration ###

PROGRESS_PID=""

script_cleanup() {
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
    find "$MODELS_DIR" -name "*.safetensors" 2>/dev/null | while read -r f; do
      size=$(du -sh "$f" 2>/dev/null | cut -f1)
      echo "  Completado:  $(basename "$f")  ($size)"
    done
  done
}

main() {
    . /venv/main/bin/activate

    progress_monitor &
    PROGRESS_PID=$!

    download_input
    download_gdrive_folder "$GDRIVE_LORAS_FOLDER_ID" "$MODELS_DIR/loras"

    for model in "${HF_MODELS[@]}"; do
        local url="${model%%|*}"
        local output_path="${model##*|}"
        download_hf_file "$url" "$output_path"
    done

    echo "==> Todas las descargas completadas."
}

download_input() {
  wget -O "$COMFYUI_DIR/input/input.jpg" \
    https://raw.githubusercontent.com/Comfy-Org/example_workflows/refs/heads/main/video/wan/2.2/input.jpg
}

# Lista los elementos de una carpeta de Drive y devuelve líneas "id|name|mimeType"
gdrive_list_folder() {
  local folder_id="$1"
  local api="https://www.googleapis.com/drive/v3"
  local page_token=""
  local all_items=""

  while true; do
    local url="${api}/files?q=%27${folder_id}%27+in+parents+and+trashed%3Dfalse&fields=nextPageToken,files(id,name,mimeType)&key=${GDRIVE_API_KEY}&pageSize=1000"
    [ -n "$page_token" ] && url="${url}&pageToken=${page_token}"

    local response
    response=$(curl -sf "$url")

    # Extraer id|name|mimeType con python3
    local items
    items=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('files', []):
    print(f['id'] + '|' + f['name'] + '|' + f['mimeType'])
")
    all_items="${all_items}${items}"$'\n'

    page_token=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('nextPageToken', ''))
" 2>/dev/null || true)
    [ -z "$page_token" ] && break
  done

  echo "$all_items"
}

# Descarga recursiva de una carpeta de Google Drive usando la API v3 + curl
download_gdrive_folder() {
  local folder_id="$1"
  local dest_dir="$2"
  local api="https://www.googleapis.com/drive/v3"

  mkdir -p "$dest_dir"
  echo "==> Listando carpeta Drive: $dest_dir"

  local items
  items=$(gdrive_list_folder "$folder_id")

  while IFS='|' read -r id name mime; do
    [ -z "$id" ] && continue

    if [ "$mime" = "application/vnd.google-apps.folder" ]; then
      echo "  -> Subcarpeta: $name"
      download_gdrive_folder "$id" "$dest_dir/$name"
    else
      local dest_file="$dest_dir/$name"
      if [ -f "$dest_file" ]; then
        echo "  Ya existe, saltando: $name"
        continue
      fi

      echo "  Descargando: $name"
      # acknowledgeAbuse=true evita la pantalla de confirmación de Drive
      # para archivos grandes; -L sigue redirecciones
      curl -L \
        --progress-bar \
        -o "$dest_file" \
        "${api}/files/${id}?alt=media&key=${GDRIVE_API_KEY}&acknowledgeAbuse=true"

      # Verificar tamaño: si < 10KB probablemente es un JSON de error
      local size
      size=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
      if [ "$size" -lt 10240 ]; then
        echo "[WARN] $name descargado con solo ${size} bytes — posible error de API:"
        cat "$dest_file"
        rm -f "$dest_file"
      else
        echo "  ✓ $name ($(du -sh "$dest_file" | cut -f1))"
      fi
    fi
  done <<< "$items"

  echo "✓ Carpeta descargada: $dest_dir"
}

download_hf_file() {
  local url="$1"
  local output_path="$2"
  local max_retries=5
  local retry_delay=2

  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)"
    return 0
  fi

  local repo
  repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
  local file_path
  file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')

  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    echo "ERROR: Invalid HuggingFace URL: $url"
    return 1
  fi

  local temp_dir
  temp_dir=$(mktemp -d)
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
      echo "✓ Successfully downloaded: $(basename "$output_path")"
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
  return 1
}

main
