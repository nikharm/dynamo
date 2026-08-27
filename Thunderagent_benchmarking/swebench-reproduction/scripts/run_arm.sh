#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( "$1" != "baseline" && "$1" != "thunderagent" ) ]]; then
  echo "Usage: DYNAMO_API_BASE=http://host:port/v1 $0 <baseline|thunderagent> [run-id]" >&2
  exit 64
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

arm=$1
run_id=${2:-run-001}
if [[ -z "${DYNAMO_API_BASE:-}" ]]; then
  echo "ERROR: set DYNAMO_API_BASE to the private OpenAI-compatible /v1 endpoint." >&2
  exit 64
fi

THUNDERAGENT_DIR="$ROOT_DIR/.deps/ThunderAgent"
PROVIDER_DIR="$ROOT_DIR/.deps/pi-dynamo-provider/pi-plugin"
HARBOR="$ROOT_DIR/.venv/bin/harbor"
ARTIFACT_ROOT=${ARTIFACT_ROOT:-$ROOT_DIR/artifacts}
ARTIFACT_DIR="$ARTIFACT_ROOT/$arm/$run_id"
JOB_NAME=${JOB_NAME:-qwen3-coder-next-$arm-$run_id}

if [[ "$arm" == "thunderagent" ]]; then
  session_final=1
else
  session_final=0
fi

"$SCRIPT_DIR/verify_setup.sh" inputs
command -v docker >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null
docker info >/dev/null
curl -fsS "${DYNAMO_API_BASE%/}/models" >/dev/null
[[ -x "$HARBOR" ]] || { echo "ERROR: run scripts/setup_harbor.sh first." >&2; exit 1; }
[[ -d "$PROVIDER_DIR" ]] || { echo "ERROR: Pi Dynamo provider is missing." >&2; exit 1; }

if [[ -n "${START_AT_EPOCH:-}" ]]; then
  [[ "$START_AT_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR: START_AT_EPOCH must be an epoch timestamp." >&2; exit 64; }
  while (( $(date +%s) < START_AT_EPOCH )); do
    sleep 1
  done
fi

mkdir -p "$ARTIFACT_DIR"
export PI_DYNAMO_PROVIDER_PATH="$PROVIDER_DIR"

{
  date -u +%Y-%m-%dT%H:%M:%SZ
  uname -a
  nproc
  free -h
  df -h
  docker version
  docker info
  uv --version
  "$ROOT_DIR/.venv/bin/python" --version
  printf 'ThunderAgent commit: '
  git -C "$THUNDERAGENT_DIR" rev-parse HEAD
  printf 'Pi provider commit: '
  git -C "$ROOT_DIR/.deps/pi-dynamo-provider" rev-parse HEAD
  printf '%s\n' 'Python packages:'
  cat "$ROOT_DIR/.deps/driver-packages.txt"
} > "$ARTIFACT_DIR/driver-host.txt" 2>&1

vmstat_pid=''
cleanup_driver_telemetry() {
  if [[ -n "$vmstat_pid" ]]; then
    kill "$vmstat_pid" 2>/dev/null || true
    wait "$vmstat_pid" 2>/dev/null || true
  fi
}
trap cleanup_driver_telemetry EXIT
trap 'exit 130' INT TERM
if command -v vmstat >/dev/null 2>&1; then
  vmstat 5 -t > "$ARTIFACT_DIR/driver-vmstat.log" &
  vmstat_pid=$!
fi

start_epoch=$(date +%s)

set +e
(
  cd "$THUNDERAGENT_DIR/examples/datagen/harbor"
  "$HARBOR" run \
    --path datasets/swebench \
    --agent pi \
    --model "dynamo/$MODEL_NAME" \
    --ak "api_base=${DYNAMO_API_BASE%/}" \
    --ak "version=$PI_VERSION" \
    --ae "DYN_AGENT_SESSION_FINAL=$session_final" \
    --n-tasks "$HARBOR_TASKS" \
    --n-concurrent "$HARBOR_CONCURRENCY" \
    --network-mode host \
    --override-cpus "$HARBOR_CPUS_PER_TRIAL" \
    --override-memory-mb "$HARBOR_MEMORY_MB_PER_TRIAL" \
    -v "$PI_DYNAMO_PROVIDER_PATH:/opt/pi-dynamo-provider:ro" \
    --jobs-dir "$ARTIFACT_DIR/jobs" \
    --job-name "$JOB_NAME" \
    --quiet
) 2>&1 | tee "$ARTIFACT_DIR/harbor.log"
harbor_status=${PIPESTATUS[0]}
set -e
cleanup_driver_telemetry
vmstat_pid=''

end_epoch=$(date +%s)
jq -n \
  --arg arm "$arm" \
  --arg run_id "$run_id" \
  --arg model "$MODEL_NAME" \
  --arg model_revision "$MODEL_REVISION" \
  --arg dataset_revision "$SWEBENCH_DATASET_REVISION" \
  --arg task_list_sha256 "$SWEBENCH_TASK_LIST_SHA256" \
  --arg pi_version "$PI_VERSION" \
  --argjson start_epoch "$start_epoch" \
  --argjson end_epoch "$end_epoch" \
  --argjson tasks "$HARBOR_TASKS" \
  --argjson concurrency "$HARBOR_CONCURRENCY" \
  --argjson cpus_per_trial "$HARBOR_CPUS_PER_TRIAL" \
  --argjson memory_mb_per_trial "$HARBOR_MEMORY_MB_PER_TRIAL" \
  --argjson timeout_seconds "$HARBOR_TIMEOUT_SECONDS" \
  --argjson session_final "$session_final" \
  --argjson exit_status "$harbor_status" \
  '{arm:$arm,run_id:$run_id,model:$model,model_revision:$model_revision,
    dataset_revision:$dataset_revision,task_list_sha256:$task_list_sha256,
    pi_version:$pi_version,start_epoch:$start_epoch,end_epoch:$end_epoch,
    duration_seconds:($end_epoch-$start_epoch),tasks:$tasks,concurrency:$concurrency,
    cpus_per_trial:$cpus_per_trial,memory_mb_per_trial:$memory_mb_per_trial,
    timeout_seconds:$timeout_seconds,dyn_agent_session_final:$session_final,
    exit_status:$exit_status}' > "$ARTIFACT_DIR/run-metadata.json"

cat "$ARTIFACT_DIR/run-metadata.json"
exit "$harbor_status"
