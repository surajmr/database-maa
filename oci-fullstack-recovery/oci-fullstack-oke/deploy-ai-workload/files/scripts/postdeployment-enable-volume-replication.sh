#!/usr/bin/env bash
set -Eeuo pipefail

# Configure cross-region replication for the OCI block volume backing the
# application's Ollama PVC. Run after oke-ai-fsdr-lab-docs-v3/deploy.sh.

NAMESPACE="${NAMESPACE:-ai-fsdr-lab}"
PVC_NAME="${PVC_NAME:-ollama-data}"
SOURCE_REGION="${SOURCE_REGION:-us-ashburn-1}"
TARGET_REGION="${TARGET_REGION:-us-phoenix-1}"
SOURCE_PROFILE="${SOURCE_PROFILE:-}"
TARGET_PROFILE="${TARGET_PROFILE:-}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"
VOLUME_GROUP_NAME="${VOLUME_GROUP_NAME:-fsr-rag-ollama-vg}"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"
POLL_SECONDS="${POLL_SECONDS:-30}"
MANIFEST_PATH="${MANIFEST_PATH:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need kubectl
need oci
need jq

[[ -n "$COMPARTMENT_ID" ]] || die "Set COMPARTMENT_ID to the OCI compartment OCID"

profile_args() {
  local profile="$1"
  if [[ -n "$profile" ]]; then
    printf '%s\n' --profile "$profile"
  fi
}

mapfile -t SOURCE_PROFILE_ARGS < <(profile_args "$SOURCE_PROFILE")
mapfile -t TARGET_PROFILE_ARGS < <(profile_args "$TARGET_PROFILE")

echo "Waiting for PVC $NAMESPACE/$PVC_NAME to become Bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  "pvc/$PVC_NAME" -n "$NAMESPACE" --timeout=30m

PV_NAME="$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
[[ -n "$PV_NAME" ]] || die "PVC did not provide a persistent volume name"

VOLUME_OCID="$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ "$VOLUME_OCID" == ocid1.volume.* ]] || die "Unexpected CSI volume handle: $VOLUME_OCID"

echo "PV: $PV_NAME"
echo "OCI volume: $VOLUME_OCID"

VOLUME_JSON="$(oci bv volume get --volume-id "$VOLUME_OCID" \
  --region "$SOURCE_REGION" "${SOURCE_PROFILE_ARGS[@]}")"
VOLUME_STATE="$(jq -r '.data."lifecycle-state"' <<<"$VOLUME_JSON")"
SOURCE_AD="$(jq -r '.data."availability-domain"' <<<"$VOLUME_JSON")"
[[ "$VOLUME_STATE" == "AVAILABLE" ]] || die "Volume state is $VOLUME_STATE; it must be AVAILABLE"

# The target AD must match the standby OKE node pool. Do not infer it from the
# first AD in the region: a one-node pool may otherwise land elsewhere.
if [[ -z "${TARGET_AD:-}" && -n "$MANIFEST_PATH" && -f "$MANIFEST_PATH" ]]; then
  TARGET_AD="$(jq -r '.standby_oke_node_availability_domain // empty' "$MANIFEST_PATH")"
fi
[[ -n "${TARGET_AD:-}" && "$TARGET_AD" != "null" ]] \
  || die "Set TARGET_AD to the standby OKE node pool Availability Domain"

REPLICA_DETAILS="$(jq -cn --arg ad "$TARGET_AD" --arg name "$VOLUME_GROUP_NAME-replica" \
  '[{availabilityDomain:$ad, displayName:$name}]')"
SOURCE_DETAILS="$(jq -cn --arg id "$VOLUME_OCID" \
  '{type:"volumeIds", volumeIds:[$id]}')"

echo "Creating a new volume group with cross-region replication: $SOURCE_REGION -> $TARGET_REGION"
VOLUME_GROUP_ID="$(oci bv volume-group create \
  --compartment-id "$COMPARTMENT_ID" \
  --availability-domain "$SOURCE_AD" \
  --display-name "$VOLUME_GROUP_NAME" \
  --source-details "$SOURCE_DETAILS" \
  --volume-group-replicas "$REPLICA_DETAILS" \
  --region "$SOURCE_REGION" "${SOURCE_PROFILE_ARGS[@]}" \
  --query 'data.id' --raw-output)"

echo "Cross-region replication request accepted. OCI will provision the Phoenix replica in the background."
echo "Volume group: $VOLUME_GROUP_ID"
echo "Target: $TARGET_REGION / $TARGET_AD"
echo "SOURCE_VOLUME_OCID=$VOLUME_OCID"
echo "SOURCE_VOLUME_GROUP_OCID=$VOLUME_GROUP_ID"
echo "SOURCE_REGION=$SOURCE_REGION"
echo "TARGET_REGION=$TARGET_REGION"
echo "TARGET_AVAILABILITY_DOMAIN=$TARGET_AD"

if [[ -n "$MANIFEST_PATH" ]]; then
  need jq
  [[ -f "$MANIFEST_PATH" ]] || die "Deployment manifest was not found: $MANIFEST_PATH"
  manifest_tmp="$(mktemp "${MANIFEST_PATH}.XXXXXX")"
  jq --arg volume_group "$VOLUME_GROUP_ID" \
     --arg source_region "$SOURCE_REGION" \
     --arg standby_region "$TARGET_REGION" \
     '.ollama_volume_group_ocid = $volume_group
      | .primary_region = (.primary_region // $source_region)
      | .standby_region = (.standby_region // $standby_region)' \
     "$MANIFEST_PATH" > "$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST_PATH"
  echo "Updated deployment manifest: $MANIFEST_PATH"
fi
