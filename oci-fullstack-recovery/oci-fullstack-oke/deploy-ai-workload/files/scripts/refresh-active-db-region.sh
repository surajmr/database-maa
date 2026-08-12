#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${FSDR_MANIFEST:-$ROOT_DIR/fsdr-oke-deployment.json}"
NAMESPACE="${NAMESPACE:-ai-fsdr-lab}"
DRILL_REGION=""
command -v oci >/dev/null 2>&1 || { echo "oci is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drill-region)
      [[ $# -ge 2 ]] || { echo "--drill-region requires a region" >&2; exit 1; }
      DRILL_REGION="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--drill-region us-phoenix-1]" >&2
      exit 1
      ;;
  esac
done

read_manifest_value() {
  [[ -f "$MANIFEST_PATH" ]] || return 0
  python3 - "$MANIFEST_PATH" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data.get(sys.argv[2], "")
print(value if isinstance(value, str) else "")
PY
}

PRIMARY_OCID="${ADB_PRIMARY_DATABASE_OCID:-$(read_manifest_value primary_adb_ocid)}"
STANDBY_OCID="${ADB_STANDBY_DATABASE_OCID:-$(read_manifest_value standby_adb_ocid)}"
PRIMARY_REGION="${ADB_PRIMARY_REGION:-$(read_manifest_value primary_region)}"
STANDBY_REGION="${ADB_STANDBY_REGION:-$(read_manifest_value standby_region)}"

if [[ -z "$PRIMARY_OCID" || -z "$STANDBY_OCID" ]]; then
  job_id="$(read_manifest_value resource_manager_job_ocid)"
  if [[ -z "$job_id" && -z "$PRIMARY_OCID" ]]; then
    read -r -p "Ashburn ATP OCID: " PRIMARY_OCID
  fi
  if [[ -z "$job_id" && -n "$PRIMARY_OCID" ]]; then
    compartment="$(oci db autonomous-database get --autonomous-database-id "$PRIMARY_OCID" --region "${PRIMARY_REGION:-us-ashburn-1}" --query 'data."compartment-id"' --raw-output)"
    while IFS= read -r candidate; do
      candidate_outputs="$(oci resource-manager job-output-summary list-job-outputs --job-id "$candidate" --region "${PRIMARY_REGION:-us-ashburn-1}")"
      candidate_atp="$(jq -r '.data.items[] | select(."output-name" == "primary_adb_ocid") | ."output-value"' <<<"$candidate_outputs" | head -1)"
      if [[ "$candidate_atp" == "$PRIMARY_OCID" ]]; then
        job_id="$candidate"
        outputs="$candidate_outputs"
        break
      fi
    done < <(oci resource-manager job list --compartment-id "$compartment" --lifecycle-state SUCCEEDED --all --region "${PRIMARY_REGION:-us-ashburn-1}" | jq -r '[.data[] | select(.operation == "APPLY")] | sort_by(."time-created") | reverse[] | .id')
  fi
  if [[ -n "$job_id" ]]; then
    outputs="${outputs:-$(oci resource-manager job-output-summary list-job-outputs --job-id "$job_id" --region "${PRIMARY_REGION:-us-ashburn-1}")}"
    output_value() { jq -r --arg name "$1" '.data.items[] | select(."output-name" == $name) | ."output-value"' <<<"$outputs" | head -1; }
    PRIMARY_OCID="${PRIMARY_OCID:-$(output_value primary_adb_ocid)}"
    STANDBY_OCID="${STANDBY_OCID:-$(output_value standby_adb_ocid)}"
    PRIMARY_REGION="${PRIMARY_REGION:-$(output_value primary_region)}"
    STANDBY_REGION="${STANDBY_REGION:-$(output_value standby_region)}"
  fi
fi

[[ -n "$PRIMARY_OCID" && -n "$STANDBY_OCID" && -n "$PRIMARY_REGION" && -n "$STANDBY_REGION" ]] || {
  echo "Missing ATP OCIDs or regions in environment/manifest" >&2
  exit 1
}

if [[ ! -f "$MANIFEST_PATH" && -n "${job_id:-}" ]]; then
  jq -n --arg job "$job_id" --arg pr "$PRIMARY_REGION" --arg sr "$STANDBY_REGION" \
    --arg pa "$PRIMARY_OCID" --arg sa "$STANDBY_OCID" \
    '{resource_manager_job_ocid:$job,primary_region:$pr,standby_region:$sr,primary_adb_ocid:$pa,standby_adb_ocid:$sa}' \
    > "$MANIFEST_PATH"
  echo "Recreated deployment manifest: $MANIFEST_PATH"
fi

role_for() {
  oci db autonomous-database get \
    --autonomous-database-id "$1" --region "$2" \
    --query 'data.role' --raw-output
}

primary_role="$(role_for "$PRIMARY_OCID" "$PRIMARY_REGION")"
standby_role="$(role_for "$STANDBY_OCID" "$STANDBY_REGION")"

if [[ "$primary_role" == "PRIMARY" ]]; then
  active_region="$PRIMARY_REGION"
elif [[ "$standby_role" == "PRIMARY" ]]; then
  active_region="$STANDBY_REGION"
else
  echo "Could not identify a PRIMARY ATP: $PRIMARY_REGION=$primary_role, $STANDBY_REGION=$standby_role" >&2
  exit 1
fi

echo "Control-plane roles: $PRIMARY_REGION=$primary_role, $STANDBY_REGION=$standby_role"
display_region="${DRILL_REGION:-$active_region}"
if [[ -n "$DRILL_REGION" ]]; then
  echo "Control-plane primary region: $active_region"
  echo "Active drill region: $display_region"
else
  echo "Active DB region: $display_region"
fi

kubectl -n "$NAMESPACE" patch configmap lab-config \
  --type merge -p "{\"data\":{\"ACTIVE_DB_REGION\":\"$display_region\",\"CONTROL_PLANE_PRIMARY_REGION\":\"$active_region\"}}" >/dev/null
kubectl -n "$NAMESPACE" set env deployment/ai-backend ACTIVE_DB_REGION="$display_region" CONTROL_PLANE_PRIMARY_REGION="$active_region" >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/ai-backend --timeout=5m
echo "Updated $NAMESPACE on kubectl context: $(kubectl config current-context)"
