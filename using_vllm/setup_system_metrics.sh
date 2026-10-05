#!/usr/bin/env bash
# Add CPU/memory (node_exporter) and GPU (nvidia_gpu_exporter) metrics to the existing
# Prometheus + Grafana stack from setup_monitoring.sh. No Docker.
set -euo pipefail

BASE="${BASE:-/workspace/monitoring}"
VLLM_TARGET="${VLLM_TARGET:-localhost:8000}"
NODE_PORT="${NODE_PORT:-9100}"
GPU_PORT="${GPU_PORT:-9835}"
NODE_VER="${NODE_VER:-}"   # empty = latest
GPU_VER="${GPU_VER:-}"     # empty = latest

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$BASE/prometheus/prometheus" ] || die "Prometheus not found in $BASE. Run setup_monitoring.sh first."
command -v nvidia-smi >/dev/null || die "nvidia-smi not found: no GPU visible"
mkdir -p "$BASE/exporters" "$BASE/logs" "$BASE/dashboards"

latest() { curl -s "https://api.github.com/repos/$1/releases/latest" | grep -oP '"tag_name": "v\K[0-9.]+(?=")' | head -1 || true; }

# ---------------- node_exporter (CPU / memory / load) ----------------
if [ ! -x "$BASE/exporters/node_exporter/node_exporter" ]; then
  [ -n "$NODE_VER" ] || NODE_VER="$(latest prometheus/node_exporter)"
  NODE_VER="${NODE_VER:-1.9.1}"
  log "Installing node_exporter $NODE_VER"
  mkdir -p "$BASE/exporters/node_exporter"
  curl -fL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.linux-amd64.tar.gz" \
    | tar xz -C "$BASE/exporters/node_exporter" --strip-components=1
fi

# ---------------- nvidia_gpu_exporter (GPU) ----------------
if [ ! -x "$BASE/exporters/nvidia_gpu_exporter/nvidia_gpu_exporter" ]; then
  [ -n "$GPU_VER" ] || GPU_VER="$(latest utkuozdemir/nvidia_gpu_exporter)"
  GPU_VER="${GPU_VER:-1.3.1}"
  log "Installing nvidia_gpu_exporter $GPU_VER"
  mkdir -p "$BASE/exporters/nvidia_gpu_exporter"
  curl -fL "https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${GPU_VER}/nvidia_gpu_exporter_${GPU_VER}_linux_x86_64.tar.gz" \
    | tar xz -C "$BASE/exporters/nvidia_gpu_exporter"
fi

# ---------------- Start exporters (bound to localhost only) ----------------
pkill -f "exporters/node_exporter/node_exporter" 2>/dev/null || true
pkill -f "exporters/nvidia_gpu_exporter/nvidia_gpu_exporter" 2>/dev/null || true
sleep 1

log "Starting node_exporter on 127.0.0.1:${NODE_PORT}"
nohup "$BASE/exporters/node_exporter/node_exporter" \
  --web.listen-address="127.0.0.1:${NODE_PORT}" \
  > "$BASE/logs/node_exporter.log" 2>&1 &

log "Starting nvidia_gpu_exporter on 127.0.0.1:${GPU_PORT}"
nohup "$BASE/exporters/nvidia_gpu_exporter/nvidia_gpu_exporter" \
  --web.listen-address="127.0.0.1:${GPU_PORT}" \
  > "$BASE/logs/nvidia_gpu_exporter.log" 2>&1 &

# ---------------- Update Prometheus config (keeps the vllm job) ----------------
cat > "$BASE/prometheus/prometheus.yml" << EOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: vllm
    metrics_path: /metrics
    static_configs:
      - targets: ["${VLLM_TARGET}"]
  - job_name: node
    static_configs:
      - targets: ["localhost:${NODE_PORT}"]
  - job_name: gpu
    static_configs:
      - targets: ["localhost:${GPU_PORT}"]
EOF

if pgrep -f "$BASE/prometheus/prometheus" >/dev/null; then
  pkill -HUP -f "$BASE/prometheus/prometheus"   # reload config without restarting
  log "Prometheus config reloaded"
else
  log "WARNING: Prometheus is not running. Start it with setup_monitoring.sh"
fi

# ---------------- Grafana dashboard (auto-detected within ~10s) ----------------
python3 - "$BASE/dashboards/system.json" << 'PYEOF'
import json, sys
DS = {"type": "prometheus", "uid": "prometheus"}
cpu = '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m]))'
panels_def = [
  ("GPU utilization", "percentunit", [("nvidia_smi_utilization_gpu_ratio", "{{name}} GPU")], 1, 0),
  ("GPU memory used", "percentunit", [("nvidia_smi_memory_used_bytes / nvidia_smi_memory_total_bytes", "{{name}}")], 1, 0),
  ("GPU memory used (bytes)", "bytes", [("nvidia_smi_memory_used_bytes", "used"), ("nvidia_smi_memory_total_bytes", "total")], None, None),
  ("GPU temperature", "celsius", [("nvidia_smi_temperature_gpu", "{{name}}")], None, None),
  ("GPU power draw", "watt", [("nvidia_smi_power_draw_watts", "{{name}}")], None, None),
  ("CPU usage", "percentunit", [(cpu, "cpu")], 1, 0),
  ("Memory used", "bytes", [("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "used"), ("node_memory_MemTotal_bytes", "total")], None, None),
  ("Memory used %", "percentunit", [("1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes", "memory")], 1, 0),
  ("Load average", "short", [("node_load1", "1m"), ("node_load5", "5m"), ("node_load15", "15m")], None, None),
]
panels = []
for i, (title, unit, exprs, mx, mn) in enumerate(panels_def):
    defaults = {"unit": unit}
    if mx is not None: defaults["max"] = mx
    if mn is not None: defaults["min"] = mn
    panels.append({
      "id": i + 1, "type": "timeseries", "title": title,
      "gridPos": {"x": (i % 2) * 12, "y": (i // 2) * 8, "w": 12, "h": 8},
      "datasource": DS,
      "fieldConfig": {"defaults": defaults, "overrides": []},
      "targets": [{"expr": e, "legendFormat": l, "refId": chr(65 + j), "datasource": DS} for j, (e, l) in enumerate(exprs)],
    })
dash = {"uid": "system-gpu-cpu", "title": "System: GPU / CPU / Memory", "schemaVersion": 39,
        "refresh": "5s", "time": {"from": "now-15m", "to": "now"}, "panels": panels}
json.dump(dash, open(sys.argv[1], "w"), indent=2)
PYEOF
log "Dashboard written: 'System: GPU / CPU / Memory'"

# ---------------- Verify ----------------
sleep 8
curl -sf "localhost:${NODE_PORT}/metrics" >/dev/null && log "node_exporter OK" || log "node_exporter NOT responding: see $BASE/logs/node_exporter.log"
curl -sf "localhost:${GPU_PORT}/metrics" >/dev/null && log "nvidia_gpu_exporter OK" || log "nvidia_gpu_exporter NOT responding: see $BASE/logs/nvidia_gpu_exporter.log"
log "Prometheus targets:"
curl -s localhost:9090/api/v1/targets | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("  ", t["labels"]["job"], t["health"])'       