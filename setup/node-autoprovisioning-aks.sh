#!/usr/bin/env bash
# Turns on AKS Node Auto Provisioning (NAP: Karpenter run by Azure) for the node-autoprovisioning connector.
# Re-runnable. Every cluster change is an "az aks update", so each one needs CONFIRM=1; without it the script
# only reports what it would do.
#   1. checks the prerequisites: Azure CNI overlay with the Cilium dataplane
#   2. NAP and the cluster autoscaler cannot run together: turns the autoscaler off on every node pool, keeping
#      each pool at its current node count (those nodes stay; NAP adds and removes the extra ones)
#   3. sets --node-provisioning-mode Auto; AKS then creates the NodePools "default" and "system-surge" and the
#      AKSNodeClass "default"
# Then enable "Node autoprovisioning" on the Connectors page: it adds the NodePool "aio-spot" (values-aks.yaml).
#
# Turn it off again: disable the connector, then DISABLE=1 CONFIRM=1 bash setup/node-autoprovisioning-aks.sh
# (mode Manual; NAP nodes are drained and removed by AKS). Re-enable the autoscaler on a pool by hand afterwards:
#   az aks nodepool update -g RG --cluster-name AKS -n POOL --enable-cluster-autoscaler --min-count 1 --max-count 2
set -euo pipefail

RG="${RG:-creative}"
AKS="${AKS:-creative}"
CONFIRM="${CONFIRM:-0}"

run() {
  if [ "$CONFIRM" = "1" ]; then echo "+ $*"; "$@" >/dev/null; else echo "would run: $*"; fi
}

if [ "${DISABLE:-0}" = "1" ]; then
  if kubectl get nodepools.karpenter.sh aio-spot >/dev/null 2>&1; then
    echo "NodePool aio-spot still exists: disable the connector on the Connectors page first." >&2
    exit 1
  fi
  run az aks update -g "$RG" -n "$AKS" --node-provisioning-mode Manual
  exit 0
fi

echo "==> AKS $AKS ($RG): network prerequisites"
read -r PLUGIN MODE DATAPLANE < <(az aks show -g "$RG" -n "$AKS" \
  --query "[networkProfile.networkPlugin, networkProfile.networkPluginMode, networkProfile.networkDataplane]" \
  -o tsv | tr '\n' ' ')
if [ "$PLUGIN" != "azure" ] || [ "$MODE" != "overlay" ] || [ "$DATAPLANE" != "cilium" ]; then
  echo "NAP needs Azure CNI overlay with Cilium; this cluster has plugin=$PLUGIN mode=$MODE dataplane=$DATAPLANE." >&2
  echo "Use the spot node pool with the cluster autoscaler instead (docs/architecture/CONNECTORS.md, Cheapest compute)." >&2
  exit 1
fi

CURRENT=$(az aks show -g "$RG" -n "$AKS" --query "nodeProvisioningProfile.mode" -o tsv 2>/dev/null || true)
if [ "$CURRENT" = "Auto" ]; then
  echo "Node Auto Provisioning is already on. Enable the connector on the Connectors page."
  exit 0
fi

echo "==> cluster autoscaler off on every node pool (NAP replaces it)"
while read -r POOL AUTOSCALE COUNT; do
  [ -n "$POOL" ] || continue
  if [ "$AUTOSCALE" = "true" ]; then
    echo "pool $POOL: autoscaler on, $COUNT node(s) now; keeping $COUNT"
    run az aks nodepool update -g "$RG" --cluster-name "$AKS" -n "$POOL" --disable-cluster-autoscaler
  fi
done < <(az aks nodepool list -g "$RG" --cluster-name "$AKS" --query "[].[name, enableAutoScaling, count]" -o tsv)

echo "==> Node Auto Provisioning on"
run az aks update -g "$RG" -n "$AKS" --node-provisioning-mode Auto

if [ "$CONFIRM" != "1" ]; then
  echo "Nothing changed. Re-run with CONFIRM=1 to apply (cluster updates; running pods are not restarted)."
  exit 0
fi
echo "Done. Check: kubectl get nodepools.karpenter.sh,aksnodeclasses.karpenter.azure.com"
echo "Then enable Node autoprovisioning on the Connectors page."
