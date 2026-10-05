#!/usr/bin/env bash
# Install vLLM (in a venv, if missing), download a Hugging Face model, and serve it (no Docker).
set -euo pipefail

# ---------------- Config (override via env vars) ----------------
MODEL="${MODEL:-QuantTrio/Qwen3.5-9B-AWQ}"
MODEL_DIR="${MODEL_DIR:-/workspace/models/${MODEL##*/}}"
SERVED_NAME="${SERVED_NAME:-$MODEL}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
MAX_LEN="${MAX_LEN:-16384}"
GPU_UTIL="${GPU_UTIL:-0.90}"
API_KEY="${API_KEY:-}"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
LOG_FILE="${LOG_FILE:-/var/log/vllm.log}"
WAIT_SECS="${WAIT_SECS:-900}"
VLLM_VERSION="${VLLM_VERSION:-}"     # e.g. 0.11.0 (empty = latest)
FORCE_UPGRADE="${FORCE_UPGRADE:-0}"  # 1 = upgrade vLLM even if installed
VENV="${VENV:-/workspace/venv}"
# export HF_TOKEN=hf_xxx  # only for gated/private models

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

activate_venv() { set +u; source "$VENV/bin/activate"; set -u; }
vllm_installed() { python3 -c "import vllm" >/dev/null 2>&1 && command -v vllm >/dev/null; }

# ---------------- Pre-flight checks ----------------
command -v nvidia-smi >/dev/null || die "nvidia-smi not found: no GPU visible"
command -v python3 >/dev/null || die "python3 not found"
log "GPU:"; nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader

# ---------------- Reuse existing venv if present ----------------
[ -f "$VENV/bin/activate" ] && { log "Using existing venv: $VENV"; activate_venv; }

# ---------------- Install vLLM if needed ----------------
if vllm_installed && [ "$FORCE_UPGRADE" != "1" ] && [ -z "$VLLM_VERSION" ]; then
  log "vLLM already installed."
else
  # Create venv if we're not already in one
  if [ -z "${VIRTUAL_ENV:-}" ]; then
    log "Creating venv at $VENV ..."
    if ! python3 -m venv "$VENV" 2>/dev/null; then
      log "python3-venv missing, installing via apt..."
      apt-get update -qq && apt-get install -y -qq python3-venv python3-full
      rm -rf "$VENV"
      python3 -m venv "$VENV"
    fi
    activate_venv
  fi

  python3 -m pip install -q -U pip
  if ! command -v uv >/dev/null; then
    python3 -m pip install -q uv || true
  fi
  if command -v uv >/dev/null; then INSTALL=(uv pip install); else INSTALL=(python3 -m pip install); fi

  SPEC="vllm"; [ -n "$VLLM_VERSION" ] && SPEC="vllm==${VLLM_VERSION}"
  log "Installing $SPEC into $VIRTUAL_ENV (this can take several minutes)..."
  "${INSTALL[@]}" -U "$SPEC" || die "vLLM installation failed"
  hash -r
fi

vllm_installed || die "vLLM still not importable after install"
log "vLLM version: $(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo unknown)"

# ---------------- Stop any running vLLM ----------------
if pgrep -f "vllm serve" >/dev/null || pgrep -f "VLLM::EngineCore" >/dev/null; then
  log "Stopping existing vLLM..."
  pkill -f "vllm serve" || true
  sleep 5
  pkill -9 -f "vllm serve" 2>/dev/null || true
  pkill -9 -f "VLLM::EngineCore" 2>/dev/null || true
  sleep 3
fi

# ---------------- Download model ----------------
if ! command -v hf >/dev/null && ! command -v huggingface-cli >/dev/null; then
  log "Installing huggingface_hub..."
  python3 -m pip install -q -U "huggingface_hub[cli]" hf_transfer
fi
python3 -c "import hf_transfer" 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1

mkdir -p "$MODEL_DIR"
log "Downloading $MODEL -> $MODEL_DIR"
for attempt in 1 2 3 4 5; do
  if command -v hf >/dev/null; then
    hf download "$MODEL" --local-dir "$MODEL_DIR" && break
  else
    huggingface-cli download "$MODEL" --local-dir "$MODEL_DIR" && break
  fi
  log "Download failed (attempt $attempt/5), retrying in 10s..."
  sleep 10
  [ "$attempt" -eq 5 ] && die "Download failed after 5 attempts"
done

[ -f "$MODEL_DIR/config.json" ] || die "config.json missing in $MODEL_DIR: incomplete download"
log "Download complete."

# ---------------- Launch vLLM ----------------
CMD=(vllm serve "$MODEL_DIR"
  --served-model-name "$SERVED_NAME"
  --host "$HOST" --port "$PORT"
  --dtype auto
  --max-model-len "$MAX_LEN"
  --gpu-memory-utilization "$GPU_UTIL"
  --trust-remote-code)
[ -n "$API_KEY" ] && CMD+=(--api-key "$API_KEY")
[ "$ENFORCE_EAGER" = "1" ] && CMD+=(--enforce-eager)
# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && CMD+=($EXTRA_ARGS)

log "Starting: ${CMD[*]}"
nohup "${CMD[@]}" > "$LOG_FILE" 2>&1 &
VLLM_PID=$!
echo "$VLLM_PID" > /tmp/vllm.pid

# ---------------- Wait until healthy ----------------
log "Waiting for server (up to ${WAIT_SECS}s). Logs: tail -f $LOG_FILE"
elapsed=0
until curl -sf "http://localhost:${PORT}/health" >/dev/null; do
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "----- last 40 log lines -----"; tail -n 40 "$LOG_FILE"
    die "vLLM exited during startup"
  fi
  [ "$elapsed" -ge "$WAIT_SECS" ] && die "Timed out waiting for vLLM"
  sleep 5; elapsed=$((elapsed + 5))
done

log "vLLM is up (PID $VLLM_PID)."
curl -s "http://localhost:${PORT}/v1/models" -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool
log "Metrics for Prometheus: http://localhost:${PORT}/metrics"