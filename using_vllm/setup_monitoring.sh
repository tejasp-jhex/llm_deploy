#!/usr/bin/env bash
# Install and start Prometheus + Grafana (no Docker) to monitor a local vLLM server on RunPod.
set -euo pipefail

BASE="${BASE:-/workspace/monitoring}"
VLLM_TARGET="${VLLM_TARGET:-localhost:8000}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROM_VER="${PROM_VER:-}"      # empty = latest
GRAF_VER="${GRAF_VER:-}"      # empty = latest

# Public hostname Grafana is reached at through the RunPod proxy.
# RunPod sets RUNPOD_POD_ID automatically; override with PUBLIC_HOST if needed.
if [ -z "${PUBLIC_HOST:-}" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
  PUBLIC_HOST="${RUNPOD_POD_ID}-${GRAFANA_PORT}.proxy.runpod.net"
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$GRAFANA_PASSWORD" ] || die "Set GRAFANA_PASSWORD, e.g. GRAFANA_PASSWORD='...' ./setup_monitoring.sh"
[ -n "${PUBLIC_HOST:-}" ] || die "Could not detect pod ID. Set PUBLIC_HOST, e.g. PUBLIC_HOST=abc123-3000.proxy.runpod.net"
log "Grafana public host: $PUBLIC_HOST"

mkdir -p "$BASE"/{prometheus-data,grafana-data,grafana-logs,logs} \
         "$BASE"/grafana-provisioning/{datasources,dashboards} "$BASE"/dashboards

latest() { curl -s "https://api.github.com/repos/$1/releases/latest" | grep -oP '"tag_name": "v\K[0-9.]+(?=")' | head -1 || true; }

# ---------------- Prometheus ----------------
if [ ! -x "$BASE/prometheus/prometheus" ]; then
  [ -n "$PROM_VER" ] || PROM_VER="$(latest prometheus/prometheus)"
  PROM_VER="${PROM_VER:-3.5.0}"
  log "Installing Prometheus $PROM_VER"
  mkdir -p "$BASE/prometheus"
  curl -fL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-amd64.tar.gz" \
    | tar xz -C "$BASE/prometheus" --strip-components=1
fi

cat > "$BASE/prometheus/prometheus.yml" << EOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: vllm
    metrics_path: /metrics
    static_configs:
      - targets: ["${VLLM_TARGET}"]
EOF

# ---------------- Grafana ----------------
if [ ! -x "$BASE/grafana/bin/grafana" ]; then
  [ -n "$GRAF_VER" ] || GRAF_VER="$(latest grafana/grafana)"
  GRAF_VER="${GRAF_VER:-12.0.0}"
  log "Installing Grafana $GRAF_VER"
  mkdir -p "$BASE/grafana"
  curl -fL "https://dl.grafana.com/oss/release/grafana-${GRAF_VER}.linux-amd64.tar.gz" \
    | tar xz -C "$BASE/grafana" --strip-components=1
fi

cat > "$BASE/grafana-provisioning/datasources/prometheus.yml" << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
EOF

cat > "$BASE/grafana-provisioning/dashboards/vllm.yml" << EOF
apiVersion: 1
providers:
  - name: vllm
    type: file
    options:
      path: $BASE/dashboards
EOF

python3 - "$BASE/dashboards/vllm.json" << 'PYEOF'
import json, sys
q = lambda p, m: f'histogram_quantile({p}, sum by (le) (rate({m}_bucket[1m])))'
panels_def = [
  ("Requests running / waiting", "short", [("vllm:num_requests_running", "running"), ("vllm:num_requests_waiting", "waiting")]),
  ("KV cache usage", "percentunit", [("vllm:kv_cache_usage_perc", "kv cache")]),
  ("Time to first token", "s", [(q(0.5, "vllm:time_to_first_token_seconds"), "p50"), (q(0.95, "vllm:time_to_first_token_seconds"), "p95")]),
  ("End-to-end latency", "s", [(q(0.5, "vllm:e2e_request_latency_seconds"), "p50"), (q(0.95, "vllm:e2e_request_latency_seconds"), "p95")]),
  ("Inter-token latency", "s", [(q(0.5, "vllm:inter_token_latency_seconds"), "p50"), (q(0.95, "vllm:inter_token_latency_seconds"), "p95")]),
  ("Token throughput (tokens/s)", "short", [("sum(rate(vllm:prompt_tokens_total[1m]))", "prompt"), ("sum(rate(vllm:generation_tokens_total[1m]))", "generation")]),
  ("Successful requests/s", "reqps", [("sum(rate(vllm:request_success_total[1m]))", "requests/s")]),
]
panels = []
for i, (title, unit, exprs) in enumerate(panels_def):
    panels.append({
      "id": i + 1, "type": "timeseries", "title": title,
      "gridPos": {"x": (i % 2) * 12, "y": (i // 2) * 8, "w": 12, "h": 8},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
      "targets": [{"expr": e, "legendFormat": l, "refId": chr(65 + j)} for j, (e, l) in enumerate(exprs)],
    })
dash = {"uid": "vllm-overview", "title": "vLLM Overview", "schemaVersion": 39,
        "refresh": "5s", "time": {"from": "now-15m", "to": "now"}, "panels": panels}
json.dump(dash, open(sys.argv[1], "w"), indent=2)
PYEOF

# ---------------- Grafana environment (includes the proxy/CSRF fix) ----------------
export GF_PATHS_DATA="$BASE/grafana-data"
export GF_PATHS_LOGS="$BASE/grafana-logs"
export GF_PATHS_PROVISIONING="$BASE/grafana-provisioning"
export GF_SERVER_HTTP_ADDR=0.0.0.0
export GF_SERVER_HTTP_PORT="$GRAFANA_PORT"
export GF_SERVER_DOMAIN="$PUBLIC_HOST"
export GF_SERVER_ROOT_URL="https://${PUBLIC_HOST}/"
export GF_SECURITY_CSRF_TRUSTED_ORIGINS="$PUBLIC_HOST"
export GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_PASSWORD"

# ---------------- Restart both ----------------
pkill -f "$BASE/prometheus/prometheus" 2>/dev/null || true
pkill -f "grafana server" 2>/dev/null || true
sleep 2

# The admin password env var only applies on first DB creation; reset it if the DB already exists
if [ -f "$BASE/grafana-data/grafana.db" ]; then
  "$BASE/grafana/bin/grafana" cli --homepath "$BASE/grafana" admin reset-admin-password "$GRAFANA_PASSWORD" >/dev/null 2>&1 \
    && log "Admin password set" || log "Could not reset admin password (continuing)"
fi

log "Starting Prometheus (127.0.0.1:9090)"
nohup "$BASE/prometheus/prometheus" \
  --config.file="$BASE/prometheus/prometheus.yml" \
  --storage.tsdb.path="$BASE/prometheus-data" \
  --storage.tsdb.retention.time=7d \
  --web.listen-address=127.0.0.1:9090 \
  > "$BASE/logs/prometheus.log" 2>&1 &

log "Starting Grafana (0.0.0.0:${GRAFANA_PORT})"
nohup "$BASE/grafana/bin/grafana" server --homepath "$BASE/grafana" \
  > "$BASE/logs/grafana.log" 2>&1 &

# ---------------- Verify ----------------
for i in $(seq 1 30); do
  curl -sf localhost:9090/-/healthy >/dev/null && curl -sf "localhost:${GRAFANA_PORT}/api/health" >/dev/null && break
  sleep 2
done
curl -sf localhost:9090/-/healthy >/dev/null && log "Prometheus OK" || log "Prometheus NOT healthy: see $BASE/logs/prometheus.log"
curl -sf "localhost:${GRAFANA_PORT}/api/health" >/dev/null && log "Grafana OK" || log "Grafana NOT healthy: see $BASE/logs/grafana.log"

log "Checking Grafana -> Prometheus data source..."
sleep 3
curl -s -u "admin:${GRAFANA_PASSWORD}" "localhost:${GRAFANA_PORT}/api/datasources/uid/prometheus/health" || true
echo
log "Open: https://${PUBLIC_HOST}  (login: admin / your GRAFANA_PASSWORD) -> Dashboards -> vLLM Overview"