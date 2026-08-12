#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="ai-fsdr-lab"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_DIR=""

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

on_error() {
  echo >&2
  echo "Deployment failed. Current workload state:" >&2
  kubectl -n "$NAMESPACE" get pods,svc,pvc 2>/dev/null || true
  echo >&2
  echo "Recent events:" >&2
  kubectl -n "$NAMESPACE" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -25 || true
  echo >&2
  echo "Recent backend logs:" >&2
  kubectl -n "$NAMESPACE" logs deployment/ai-backend --tail=100 2>/dev/null || true
}
trap on_error ERR

cleanup() {
  if [[ -n "$MERGE_DIR" && -d "$MERGE_DIR" ]]; then
    rm -rf "$MERGE_DIR"
  fi
}
trap cleanup EXIT

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v unzip >/dev/null 2>&1 || fail "unzip is required"

if [[ -n "${PRIMARY_OKE_CLUSTER_OCID:-}" || -n "${STANDBY_OKE_CLUSTER_OCID:-}" ]]; then
  [[ -n "${PRIMARY_OKE_CLUSTER_OCID:-}" && -n "${STANDBY_OKE_CLUSTER_OCID:-}" ]] || \
    fail "Set PRIMARY_OKE_CLUSTER_OCID and STANDBY_OKE_CLUSTER_OCID together"
  command -v oci >/dev/null 2>&1 || fail "OCI CLI is required to create OKE contexts"
  chmod +x "$ROOT_DIR/scripts/setup-kube-contexts.sh"
  "$ROOT_DIR/scripts/setup-kube-contexts.sh"
  kubectl config use-context fsdr-iad-primary >/dev/null
fi

kubectl cluster-info >/dev/null 2>&1 || fail "kubectl is not connected to a cluster"

: "${ADB_USER:?Set ADB_USER, for example ADMIN}"
: "${ADB_PASSWORD:?Set ADB_PASSWORD}"
: "${ADB_WALLET_PASSWORD:?Set ADB_WALLET_PASSWORD}"

create_merge_dir() {
  if [[ -z "$MERGE_DIR" ]]; then
    MERGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-fsdr-wallet.XXXXXX")"
  fi
}

download_wallet() {
  local database_ocid="$1"
  local region="$2"
  local output_file="$3"

  oci db autonomous-database generate-wallet \
    --autonomous-database-id "$database_ocid" \
    --file "$output_file" \
    --password "$ADB_WALLET_PASSWORD" \
    --region "$region"
}

download_wallets_if_requested() {
  local primary_ocid="${ADB_PRIMARY_DATABASE_OCID:-}"
  local standby_ocid="${ADB_STANDBY_DATABASE_OCID:-}"
  local primary_region="${ADB_PRIMARY_REGION:-}"
  local standby_region="${ADB_STANDBY_REGION:-}"

  if [[ -z "$primary_ocid$standby_ocid$primary_region$standby_region" ]]; then
    return
  fi

  [[ -n "$primary_ocid" && -n "$standby_ocid" && -n "$primary_region" && -n "$standby_region" ]] || \
    fail "Set ADB_PRIMARY_DATABASE_OCID, ADB_STANDBY_DATABASE_OCID, ADB_PRIMARY_REGION, and ADB_STANDBY_REGION together"
  command -v oci >/dev/null 2>&1 || fail "OCI CLI is required to download wallets"

  create_merge_dir
  ADB_PRIMARY_WALLET_ZIP="$MERGE_DIR/Wallet_primary.zip"
  ADB_STANDBY_WALLET_ZIP="$MERGE_DIR/Wallet_standby.zip"

  echo "Downloading primary wallet from $primary_region..."
  download_wallet "$primary_ocid" "$primary_region" "$ADB_PRIMARY_WALLET_ZIP"
  echo "Downloading standby wallet from $standby_region..."
  download_wallet "$standby_ocid" "$standby_region" "$ADB_STANDBY_WALLET_ZIP"
}

find_wallet() {
  if [[ -n "${ADB_WALLET_ZIP:-}" ]]; then
    local expanded
    expanded="${ADB_WALLET_ZIP/#\~/$HOME}"
    [[ -f "$expanded" ]] || fail "Wallet not found: $expanded"
    printf '%s\n' "$expanded"
    return
  fi

  local candidates=()
  while IFS= read -r file; do candidates+=("$file"); done < <(
    find "$ROOT_DIR" "$HOME" -maxdepth 2 -type f -name 'Wallet*.zip' 2>/dev/null | sort -u
  )

  [[ ${#candidates[@]} -gt 0 ]] || fail "No Wallet*.zip found. Set ADB_WALLET_ZIP explicitly."
  [[ ${#candidates[@]} -eq 1 ]] || {
    printf 'Multiple wallet files found:\n' >&2
    printf '  %s\n' "${candidates[@]}" >&2
    fail "Set ADB_WALLET_ZIP to the wallet you want to use"
  }
  printf '%s\n' "${candidates[0]}"
}

validate_wallet() {
  local wallet_zip="$1"
  [[ -f "$wallet_zip" ]] || fail "Wallet not found: $wallet_zip"
  unzip -tq "$wallet_zip" >/dev/null || fail "Wallet ZIP is invalid: $wallet_zip"
  for required in tnsnames.ora ewallet.pem; do
    unzip -Z1 "$wallet_zip" | grep -qx "$required" || fail "Wallet is missing $required: $wallet_zip"
  done
}

wallet_tns_aliases() {
  local tns_file="$1"
  awk 'match($0,/^[[:alnum:]_.-]+[[:space:]]*=/){name=substr($0,RSTART,RLENGTH); sub(/[[:space:]]*=.*/,"",name); print tolower(name)}' "$tns_file"
}

wallet_tns_descriptor() {
  local tns_file="$1"
  local alias="$2"
  awk -v wanted="$alias" '
    function update_depth(value, position, character) {
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        if (character == "(") depth++
        if (character == ")") depth--
      }
    }
    {
      line = $0
      if (!capturing) {
        pattern = "^[[:space:]]*" wanted "[[:space:]]*="
        if (line !~ pattern) next
        sub(/^[^=]*=[[:space:]]*/, "", line)
        capturing = 1
      }
      descriptor = descriptor line "\n"
      update_depth(line)
      if (index(line, "(")) saw_parenthesis = 1
      if (saw_parenthesis && depth == 0) {
        printf "%s", descriptor
        exit
      }
    }
  ' "$tns_file"
}

failover_tns_descriptor() {
  local descriptor="$1"

  # Prevent an unavailable first region from delaying the fallback region for minutes.
  # The source wallet values are retained in the original wallet files; these values apply
  # only to the generated, temporary failover descriptor.
  descriptor="$(printf '%s' "$descriptor" | sed -E 's/\([[:space:]]*(retry_count|retry_delay|connect_timeout|transport_connect_timeout)[[:space:]]*=[^)]*\)//g')"
  descriptor="${descriptor/(description=/(description=(CONNECT_TIMEOUT=10)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=1)(RETRY_DELAY=1)}"
  printf '%s' "$descriptor"
}

merge_wallets() {
  local primary_wallet="$1"
  local standby_wallet="$2"
  local wallet_dir primary_tns standby_tns merged_tns alias primary_descriptor standby_descriptor
  local aliases=()

  command -v zip >/dev/null 2>&1 || fail "zip is required to merge wallets"
  validate_wallet "$primary_wallet"
  validate_wallet "$standby_wallet"

  create_merge_dir
  wallet_dir="$MERGE_DIR/wallet"
  primary_tns="$MERGE_DIR/primary-tnsnames.ora"
  standby_tns="$MERGE_DIR/standby-tnsnames.ora"
  merged_tns="$wallet_dir/tnsnames.ora"
  mkdir -p "$wallet_dir"

  # Retain the primary wallet's credential files; only its connection aliases are merged.
  unzip -q "$primary_wallet" -d "$wallet_dir"
  unzip -p "$primary_wallet" tnsnames.ora > "$primary_tns"
  unzip -p "$standby_wallet" tnsnames.ora > "$standby_tns"

  while IFS= read -r alias; do
    [[ -n "$alias" ]] && aliases+=("$alias")
  done < <(wallet_tns_aliases "$primary_tns")
  [[ ${#aliases[@]} -gt 0 ]] || fail "Could not find connection aliases in primary wallet"

  : > "$merged_tns"
  for alias in "${aliases[@]}"; do
    primary_descriptor="$(wallet_tns_descriptor "$primary_tns" "$alias")"
    standby_descriptor="$(wallet_tns_descriptor "$standby_tns" "$alias")"
    [[ -n "$primary_descriptor" ]] || fail "Could not read primary descriptor for $alias"
    [[ -n "$standby_descriptor" ]] || fail "Standby wallet is missing descriptor for $alias"
    primary_descriptor="$(failover_tns_descriptor "$primary_descriptor")"
    standby_descriptor="$(failover_tns_descriptor "$standby_descriptor")"
    printf '%s =\n  (DESCRIPTION_LIST =\n    (FAILOVER = on)\n    (LOAD_BALANCE = off)\n%s%s  )\n\n' \
      "$alias" "$primary_descriptor" "$standby_descriptor" >> "$merged_tns"
  done

  MERGED_WALLET_ZIP="$MERGE_DIR/Wallet_merged.zip"
  (
    cd "$wallet_dir"
    zip -q -r "$MERGED_WALLET_ZIP" . -x '__MACOSX/*' '.DS_Store'
  )
  validate_wallet "$MERGED_WALLET_ZIP"
}

download_wallets_if_requested

if [[ -n "${ADB_STANDBY_WALLET_ZIP:-}" ]]; then
  [[ -n "${ADB_PRIMARY_WALLET_ZIP:-}" ]] || fail "Set ADB_PRIMARY_WALLET_ZIP when ADB_STANDBY_WALLET_ZIP is set"
  primary_wallet="${ADB_PRIMARY_WALLET_ZIP/#\~/$HOME}"
  standby_wallet="${ADB_STANDBY_WALLET_ZIP/#\~/$HOME}"
  merge_wallets "$primary_wallet" "$standby_wallet"
  WALLET_ZIP="$MERGED_WALLET_ZIP"
  echo "Created a temporary primary-first failover wallet from the supplied primary and standby wallets."
else
  [[ -z "${ADB_PRIMARY_WALLET_ZIP:-}" ]] || fail "Set ADB_STANDBY_WALLET_ZIP as well, or use ADB_WALLET_ZIP for one wallet"
  WALLET_ZIP="$(find_wallet)"
  validate_wallet "$WALLET_ZIP"
fi

if [[ -n "${ADB_DSN:-}" ]]; then
  DSN="$ADB_DSN"
else
  aliases=()
  while IFS= read -r alias; do
    [[ -n "$alias" ]] && aliases+=("$alias")
  done < <(
    unzip -p "$WALLET_ZIP" tnsnames.ora |
      awk 'match($0,/^[[:alnum:]_.-]+[[:space:]]*=/){name=substr($0,RSTART,RLENGTH); sub(/[[:space:]]*=.*/,"",name); print tolower(name)}'
  )
  [[ ${#aliases[@]} -gt 0 ]] || fail "Could not find service aliases in tnsnames.ora"
  DSN=""
  for suffix in _high _medium _low _tpurgent _tp; do
    for alias in "${aliases[@]}"; do
      if [[ "$alias" == *"$suffix" ]]; then DSN="$alias"; break 2; fi
    done
  done
  [[ -n "$DSN" ]] || DSN="${aliases[0]}"
fi

OCI_REGION_VALUE="${OCI_REGION:-${OCI_CLI_REGION:-unknown-region}}"

echo "Using wallet: $WALLET_ZIP"
echo "Using DSN alias: $DSN"
echo "Using region label: $OCI_REGION_VALUE"

echo "Validating manifests..."
kubectl apply --dry-run=client -f "$ROOT_DIR/k8s" >/dev/null
echo "Manifest validation passed."

kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"

kubectl -n "$NAMESPACE" create secret generic adb-wallet \
  --from-file=wallet.zip="$WALLET_ZIP" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic adb-config \
  --from-literal=ADB_USER="$ADB_USER" \
  --from-literal=ADB_PASSWORD="$ADB_PASSWORD" \
  --from-literal=ADB_DSN="$DSN" \
  --from-literal=ADB_WALLET_PASSWORD="$ADB_WALLET_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap lab-config \
  --from-literal=OCI_REGION="$OCI_REGION_VALUE" \
  --from-literal=ADB_PRIMARY_REGION="${ADB_PRIMARY_REGION:-$OCI_REGION_VALUE}" \
  --from-literal=ADB_STANDBY_REGION="${ADB_STANDBY_REGION:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap ai-backend-source \
  --from-file=app.py="$ROOT_DIR/backend/app.py" \
  --from-file=requirements.txt="$ROOT_DIR/backend/requirements.txt" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap ai-frontend-source \
  --from-file=index.html="$ROOT_DIR/frontend/index.html" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap ai-frontend-config \
  --from-file=nginx.conf="$ROOT_DIR/frontend/nginx.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$ROOT_DIR/k8s/ollama.yaml"
kubectl apply -f "$ROOT_DIR/k8s/backend.yaml"
kubectl apply -f "$ROOT_DIR/k8s/frontend.yaml"

# ConfigMap updates do not change pod templates, so restart app deployments on reruns.
kubectl -n "$NAMESPACE" rollout restart deployment/ai-backend deployment/ai-frontend >/dev/null

echo "Waiting for Ollama and model download..."
kubectl -n "$NAMESPACE" rollout status deployment/ollama --timeout=15m

echo "Waiting for backend..."
kubectl -n "$NAMESPACE" rollout status deployment/ai-backend --timeout=10m

echo "Waiting for frontend..."
kubectl -n "$NAMESPACE" rollout status deployment/ai-frontend --timeout=5m

echo "Running end-to-end smoke test..."
kubectl -n "$NAMESPACE" exec -i deployment/ai-backend -- /tmp/venv/bin/python - <<'PY'
import httpx
from pathlib import Path

health = httpx.get("http://127.0.0.1:8000/health", timeout=15).json()
if health.get("database") != "up" or health.get("ollama") != "up":
    raise SystemExit(f"Health check failed: {health}")

sample = Path("/tmp/smoke-test-doc.txt")
sample.write_text(
    "Smoke test document for OCI AI FSDR Lab. "
    "This document confirms upload, indexing, and ADB storage.",
    encoding="utf-8",
)
with sample.open("rb") as fh:
    upload = httpx.post(
        "http://127.0.0.1:8000/upload",
        files={"file": (sample.name, fh, "text/plain")},
        timeout=60,
    )
if upload.status_code >= 400:
    raise SystemExit(f"Upload failed with HTTP {upload.status_code}: {upload.text}")
up = upload.json()
if up.get("chunks_created", 0) < 1:
    raise SystemExit(f"Upload smoke test created no chunks: {up}")

documents = httpx.get("http://127.0.0.1:8000/documents", timeout=30).json()
if not any(item.get("filename") == sample.name for item in documents):
    raise SystemExit(f"Uploaded document not found in ADB: {documents}")

response = httpx.post(
    "http://127.0.0.1:8000/chat",
    json={"question": "What does the smoke test document confirm?"},
    timeout=180,
)
response.raise_for_status()
body = response.json()
if not body.get("answer"):
    raise SystemExit(f"Chat smoke test returned no answer: {body}")
print("Smoke test passed:", body["answer"].strip()[:120])
PY

LB_ADDRESS=""
for _ in $(seq 1 60); do
  LB_ADDRESS="$(kubectl -n "$NAMESPACE" get svc ai-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$LB_ADDRESS" ]] || LB_ADDRESS="$(kubectl -n "$NAMESPACE" get svc ai-frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$LB_ADDRESS" ]] && break
  sleep 10
done

echo
echo "Deployment complete."
kubectl -n "$NAMESPACE" get pods,svc,pvc
if [[ -n "$LB_ADDRESS" ]]; then
  echo "Application URL: http://$LB_ADDRESS"
else
  echo "Load Balancer is still provisioning. Run:"
  echo "kubectl -n $NAMESPACE get svc ai-frontend -w"
fi
