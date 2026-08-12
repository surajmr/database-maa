#!/usr/bin/env bash
set -euo pipefail

: "${PRIMARY_OKE_CLUSTER_OCID:?Set PRIMARY_OKE_CLUSTER_OCID}"
: "${STANDBY_OKE_CLUSTER_OCID:?Set STANDBY_OKE_CLUSTER_OCID}"
PRIMARY_REGION="${ADB_PRIMARY_REGION:-us-ashburn-1}"
STANDBY_REGION="${ADB_STANDBY_REGION:-us-phoenix-1}"
KUBE_CONFIG="${KUBECONFIG:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KUBE_CONFIG")"
tmpdir="$(mktemp -d /tmp/fsdr-kube-contexts.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

oci ce cluster create-kubeconfig --cluster-id "$PRIMARY_OKE_CLUSTER_OCID" \
  --region "$PRIMARY_REGION" --file "$tmpdir/iad" --kube-endpoint PUBLIC_ENDPOINT \
  --token-version 2.0.0 --overwrite >/dev/null
oci ce cluster create-kubeconfig --cluster-id "$STANDBY_OKE_CLUSTER_OCID" \
  --region "$STANDBY_REGION" --file "$tmpdir/phx" --kube-endpoint PUBLIC_ENDPOINT \
  --token-version 2.0.0 --overwrite >/dev/null

for item in iad phx; do
  context="$(KUBECONFIG="$tmpdir/$item" kubectl config get-contexts -o name | head -n 1)"
  [[ -n "$context" ]] || { echo "No context generated for $item" >&2; exit 1; }
  name="fsdr-iad-primary"; [[ "$item" == phx ]] && name="fsdr-phx-standby"
  KUBECONFIG="$tmpdir/$item" kubectl config rename-context "$context" "$name" >/dev/null
done

existing="$KUBE_CONFIG"
[[ -f "$existing" ]] || existing=/dev/null
merged="$tmpdir/merged"
KUBECONFIG="$existing:$tmpdir/iad:$tmpdir/phx" kubectl config view --flatten > "$merged"
install -m 600 "$merged" "$KUBE_CONFIG"
echo "Created contexts: fsdr-iad-primary fsdr-phx-standby"
kubectl config get-contexts fsdr-iad-primary fsdr-phx-standby
