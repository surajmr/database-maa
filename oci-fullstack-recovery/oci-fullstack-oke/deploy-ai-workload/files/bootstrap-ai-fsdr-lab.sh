#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }; }
need oci
need jq

prompt_required() {
  local name="$1" prompt="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then
    read -r -p "$prompt: " value
    [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
    printf -v "$name" '%s' "$value"
  fi
  export "$name"
}

prompt_secret() {
  local name="$1" prompt="$2" value
  value="${!name:-}"
  if [[ -z "$value" ]]; then
    read -r -s -p "$prompt: " value
    echo
    [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
    printf -v "$name" '%s' "$value"
  fi
  export "$name"
}

prompt_required ADB_USER "ADB username"
prompt_secret ADB_PASSWORD "ADB password"
prompt_secret ADB_WALLET_PASSWORD "ADB wallet password"
prompt_required ADB_PRIMARY_DATABASE_OCID "Ashburn ATP OCID"

export ADB_PRIMARY_REGION="${ADB_PRIMARY_REGION:-us-ashburn-1}"
export ADB_STANDBY_REGION="${ADB_STANDBY_REGION:-us-phoenix-1}"
export OCI_REGION="${OCI_REGION:-$ADB_PRIMARY_REGION}"

compartment="$(oci db autonomous-database get --autonomous-database-id "$ADB_PRIMARY_DATABASE_OCID" --region "$ADB_PRIMARY_REGION" --query 'data."compartment-id"' --raw-output)"
job_id=""
outputs_file="$(mktemp /tmp/fsdr-rm-outputs.XXXXXX.json)"
trap 'rm -f "$outputs_file"' EXIT
while IFS= read -r candidate; do
  candidate_outputs="$(oci resource-manager job-output-summary list-job-outputs --job-id "$candidate" --region "$ADB_PRIMARY_REGION")"
  candidate_atp="$(jq -r '.data.items[] | select(."output-name" == "primary_adb_ocid") | ."output-value"' <<<"$candidate_outputs" | head -1)"
  if [[ "$candidate_atp" == "$ADB_PRIMARY_DATABASE_OCID" ]]; then
    job_id="$candidate"
    printf '%s' "$candidate_outputs" > "$outputs_file"
    break
  fi
done < <(oci resource-manager job list --compartment-id "$compartment" --lifecycle-state SUCCEEDED --all --region "$ADB_PRIMARY_REGION" | jq -r '[.data[] | select(.operation == "APPLY")] | sort_by(."time-created") | reverse[] | .id')
[[ -n "$job_id" ]] || { echo "No successful Resource Manager APPLY matched the primary ATP OCID" >&2; exit 1; }

output_value() { jq -r --arg name "$1" '.data.items[] | select(."output-name" == $name) | ."output-value"' "$outputs_file" | head -1; }
export ADB_STANDBY_DATABASE_OCID="$(output_value standby_adb_ocid)"
export PRIMARY_OKE_CLUSTER_OCID="$(output_value primary_oke_cluster_ocid)"
export STANDBY_OKE_CLUSTER_OCID="$(output_value standby_oke_cluster_ocid)"
export ADB_PRIMARY_REGION="$(output_value primary_region)"
export ADB_STANDBY_REGION="$(output_value standby_region)"
[[ -n "$ADB_STANDBY_DATABASE_OCID$PRIMARY_OKE_CLUSTER_OCID$STANDBY_OKE_CLUSTER_OCID" ]] || { echo "Matched job is missing required ATP/OKE outputs" >&2; exit 1; }

jq -n --arg compartment "$compartment" --arg job "$job_id" \
  --arg pr "$ADB_PRIMARY_REGION" --arg sr "$ADB_STANDBY_REGION" \
  --arg pa "$ADB_PRIMARY_DATABASE_OCID" --arg sa "$ADB_STANDBY_DATABASE_OCID" \
  --arg po "$PRIMARY_OKE_CLUSTER_OCID" --arg so "$STANDBY_OKE_CLUSTER_OCID" \
  '{compartment_ocid:$compartment,resource_manager_job_ocid:$job,primary_region:$pr,standby_region:$sr,primary_adb_ocid:$pa,standby_adb_ocid:$sa,primary_oke_cluster_ocid:$po,standby_oke_cluster_ocid:$so}' \
  > "$ROOT_DIR/fsdr-oke-deployment.json"

echo "Bootstrapping AI FSDR lab in $ADB_PRIMARY_REGION..."
exec "$ROOT_DIR/deploy.sh"
