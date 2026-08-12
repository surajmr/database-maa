#!/usr/bin/env bash
set -Eeuo pipefail

# Prepares the Ollama PVC Volume Group replication after the RAG application
# has been deployed to the primary OKE cluster.
# It derives the Resource Manager apply job by matching the primary ATP OCID,
# creates the replicated Ollama volume group, and waits until the Phoenix
# replica is ready. It deliberately does not create FSDR DR protection groups
# or plans.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_PATH="${MANIFEST_PATH:-$ROOT_DIR/fsdr-oke-deployment.json}"
PRIMARY_REGION="${ADB_PRIMARY_REGION:-us-ashburn-1}"
STANDBY_REGION="${ADB_STANDBY_REGION:-us-phoenix-1}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need oci
need jq

if [[ -z "${ADB_PRIMARY_DATABASE_OCID:-}" && -f "$MANIFEST_PATH" ]]; then
  ADB_PRIMARY_DATABASE_OCID="$(jq -r '.primary_adb_ocid // empty' "$MANIFEST_PATH")"
  export ADB_PRIMARY_DATABASE_OCID
fi
: "${ADB_PRIMARY_DATABASE_OCID:?ADB_PRIMARY_DATABASE_OCID is required so the Resource Manager deployment can be identified}"

COMPARTMENT_ID="$(oci db autonomous-database get \
  --autonomous-database-id "$ADB_PRIMARY_DATABASE_OCID" \
  --region "$PRIMARY_REGION" --query 'data."compartment-id"' --raw-output)"
[[ "$COMPARTMENT_ID" == ocid1.compartment.* ]] || die "Could not determine the primary ATP compartment"

# Select the completed APPLY whose primary ATP output matches this application's
# primary ATP. This is safer than assuming the newest job in the compartment.
JOB_ID=""
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  outputs="$(oci resource-manager job-output-summary list-job-outputs \
    --job-id "$candidate" --region "$PRIMARY_REGION")"
  candidate_atp="$(jq -r '.data.items[] | select(."output-name" == "primary_adb_ocid") | ."output-value"' <<<"$outputs" | head -1)"
  if [[ "$candidate_atp" == "$ADB_PRIMARY_DATABASE_OCID" ]]; then
    JOB_ID="$candidate"
    break
  fi
done < <(oci resource-manager job list --compartment-id "$COMPARTMENT_ID" \
  --lifecycle-state SUCCEEDED --all --region "$PRIMARY_REGION" | \
  jq -r '[.data[] | select(.operation == "APPLY")] | sort_by(."time-created") | reverse[] | .id')

[[ -n "$JOB_ID" ]] || die "No successful Resource Manager APPLY job matched the primary ATP OCID"

# Terraform pins the one-node standby pool to this AD. The replicated RWO
# volume must be created in the same AD or Kubernetes cannot schedule Ollama.
TARGET_AD="$(jq -r '.data.items[] | select(."output-name" == "standby_oke_node_availability_domain") | ."output-value"' <<<"$outputs" | head -1)"
[[ -n "$TARGET_AD" && "$TARGET_AD" != "null" && "$TARGET_AD" != "OKE cluster creation disabled" ]] \
  || die "The matched APPLY job does not export standby_oke_node_availability_domain; re-apply the updated Terraform first"

PRIMARY_ATP="$(jq -r '.primary_adb_ocid // empty' "$MANIFEST_PATH" 2>/dev/null || true)"
STANDBY_ATP="$(jq -r '.standby_adb_ocid // empty' "$MANIFEST_PATH" 2>/dev/null || true)"
PRIMARY_OKE="$(jq -r '.primary_oke_cluster_ocid // empty' "$MANIFEST_PATH" 2>/dev/null || true)"
STANDBY_OKE="$(jq -r '.standby_oke_cluster_ocid // empty' "$MANIFEST_PATH" 2>/dev/null || true)"

jq -n \
  --arg compartment "$COMPARTMENT_ID" \
  --arg job "$JOB_ID" \
  --arg primary_region "$PRIMARY_REGION" \
  --arg standby_region "$STANDBY_REGION" \
  --arg target_ad "$TARGET_AD" --arg primary_atp "$PRIMARY_ATP" --arg standby_atp "$STANDBY_ATP" \
  --arg primary_oke "$PRIMARY_OKE" --arg standby_oke "$STANDBY_OKE" \
  '{compartment_ocid: $compartment, resource_manager_job_ocid: $job,
    primary_region: $primary_region, standby_region: $standby_region,
    primary_adb_ocid: $primary_atp, standby_adb_ocid: $standby_atp,
    primary_oke_cluster_ocid: $primary_oke, standby_oke_cluster_ocid: $standby_oke,
    standby_oke_node_availability_domain: $target_ad}' > "$MANIFEST_PATH"

echo "Matched Resource Manager apply job: $JOB_ID"
export COMPARTMENT_ID PRIMARY_REGION STANDBY_REGION TARGET_AD
export SOURCE_REGION="$PRIMARY_REGION" TARGET_REGION="$STANDBY_REGION"
export MANIFEST_PATH
"$ROOT_DIR/scripts/postdeployment-enable-volume-replication.sh"

echo
echo "Volume Group replication is ready. Start FSDR configuration with:"
echo "  python3 scripts/configure-fsdr-snapshot-standby.py"
