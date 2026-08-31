#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
export PYTHONPYCACHEPREFIX="$root/.pycache"

bash -n run.sh scripts/validate-repository.sh
shasum -a 256 -c CHECKSUMS.sha256
python3 -m compileall -q scripts tests
python3 -m unittest discover -s tests -v
jq empty results/reference-results.json

ruby -e '
  require "yaml"
  files = Dir["deploy/*.yaml"] + Dir["benchmark/*.yaml"] + Dir["model-cache/*.yaml"]
  abort "no manifests found" if files.empty?
  files.each { |path| YAML.load_file(path) }
  abort "expected four direct DGD manifests" unless Dir["deploy/*.yaml"].length == 4
'

if rg --files -g '*.in' | grep -q .; then
  echo "template .in files are not allowed" >&2
  exit 1
fi
if rg -n '@@[A-Z0-9_]+@@' .; then
  echo "unresolved custom template syntax found" >&2
  exit 1
fi

python3 - <<'PY'
import gzip, hashlib, json
from pathlib import Path

path = Path('data/toolagent-shape-trace.jsonl.gz')
compressed = path.read_bytes()
raw = gzip.decompress(compressed)
assert hashlib.sha256(compressed).hexdigest() == 'f081d6352e0f02862fb242146372b47ececc6f661e92935c528dcceefbdfcb20'
assert hashlib.sha256(raw).hexdigest() == 'ce4308b6f19d10fdaf79f10179b04dcb652f4fcc4cf26e5c1388f6e575fc37b2'
rows = [json.loads(line) for line in raw.splitlines()]
assert len(rows) == 5775
assert all(set(row) == {'timestamp', 'input_length', 'output_length', 'hash_ids'} for row in rows)
assert rows[0]['timestamp'] == 0 and rows[-1]['timestamp'] == 1196248
print('shape-only trace validation passed')
PY

ruby -e '
  failures = []
  Dir["**/*.md"].each do |document|
    File.read(document).scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |link|
      next if link.match?(%r{^(https?://|#)})
      path = link.split("#", 2).first
      next if path.empty?
      target = File.expand_path(path, File.dirname(document))
      failures << "#{document}: #{link}" unless File.exist?(target)
    end
  end
  abort failures.join("\n") unless failures.empty?
'

if rg -n -i \
  '(nikharm|dynamo-bench|aks-h100pool|azmk8s|b3f8b3e8|qwen32b-kv-router|/Users/[^/]+/)' \
  . --glob '!scripts/validate-repository.sh'; then
  echo "environment-specific material found" >&2
  exit 1
fi

if rg -n -i \
  '(api[_-]?key|access[_-]?token|bearer |password|client[_-]?secret|private[_-]?key|subscription[_-]?id|hf_[a-z0-9]{20,}|gh[opsu]_[a-z0-9]{20,})' \
  . --glob '!scripts/validate-repository.sh'; then
  echo "potential secret-like material found" >&2
  exit 1
fi

echo "repository validation passed"
