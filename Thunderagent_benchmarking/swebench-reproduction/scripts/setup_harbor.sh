#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../experiment.env
source "$ROOT_DIR/experiment.env"

DEPS_DIR="$ROOT_DIR/.deps"
THUNDERAGENT_DIR="$DEPS_DIR/ThunderAgent"
PROVIDER_DIR="$DEPS_DIR/pi-dynamo-provider"
VENV_DIR="$ROOT_DIR/.venv"

command -v git >/dev/null
command -v uv >/dev/null

mkdir -p "$DEPS_DIR"

actual_uv_version=$(uv --version | awk '{print $2}')
[[ "$actual_uv_version" == "$UV_VERSION" ]] || {
  echo "ERROR: expected uv $UV_VERSION, found $actual_uv_version." >&2
  echo "Install the pinned uv release documented in README.md." >&2
  exit 1
}

fetch_pinned_commit() {
  local url=$1
  local commit=$2
  local destination=$3

  if [[ ! -d "$destination/.git" ]]; then
    mkdir -p "$destination"
    git -C "$destination" init --quiet
    git -C "$destination" remote add origin "$url"
  fi
  [[ "$(git -C "$destination" remote get-url origin)" == "$url" ]] || {
    echo "ERROR: unexpected origin in $destination." >&2
    return 1
  }
  git -C "$destination" fetch --depth 1 origin "$commit"
  git -C "$destination" checkout --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || {
    echo "ERROR: failed to check out $commit in $destination." >&2
    return 1
  }
}

fetch_pinned_commit \
  https://github.com/ishandhanani/ThunderAgent.git \
  "$THUNDERAGENT_HARBOR_COMMIT" \
  "$THUNDERAGENT_DIR"

fetch_pinned_commit \
  https://github.com/ai-dynamo/pi-dynamo-provider.git \
  "$PI_DYNAMO_PROVIDER_COMMIT" \
  "$PROVIDER_DIR"

uv python install "$PYTHON_VERSION"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  uv venv --python "$PYTHON_VERSION" "$VENV_DIR"
fi
actual_python_version=$("$VENV_DIR/bin/python" -c 'import platform; print(platform.python_version())')
[[ "$actual_python_version" == "$PYTHON_VERSION" ]] || {
  echo "ERROR: expected Python $PYTHON_VERSION in $VENV_DIR, found $actual_python_version." >&2
  echo "Remove .venv and rerun this script to recreate the driver environment." >&2
  exit 1
}
uv pip install --python "$VENV_DIR/bin/python" \
  -e "$THUNDERAGENT_DIR/examples/datagen/harbor" \
  "swebench==$SWEBENCH_PACKAGE_VERSION"

{
  uv pip freeze --python "$VENV_DIR/bin/python" | \
    sed '/^-e file:.*\/ThunderAgent\/examples\/datagen\/harbor$/d'
  "$VENV_DIR/bin/python" -c \
    'from importlib.metadata import version; print("harbor==" + version("harbor"))'
} | LC_ALL=C sort > "$DEPS_DIR/driver-packages.txt"

"$VENV_DIR/bin/python" "$SCRIPT_DIR/prepare_harbor.py" \
  --harbor-dir "$THUNDERAGENT_DIR/examples/datagen/harbor" \
  --ids "$ROOT_DIR/workload/swebench-90.txt" \
  --dataset-revision "$SWEBENCH_DATASET_REVISION" \
  --timeout-seconds "$HARBOR_TIMEOUT_SECONDS"

"$SCRIPT_DIR/verify_setup.sh" inputs

printf 'Harbor environment: %s\n' "$THUNDERAGENT_DIR/examples/datagen/harbor"
printf 'Pi provider:       %s\n' "$PROVIDER_DIR/pi-plugin"
printf 'Python:            %s\n' "$VENV_DIR/bin/python"
printf 'Package snapshot:   %s\n' "$DEPS_DIR/driver-packages.txt"
