# Disaster recovery

## One worker lost

Longhorn retains three replicas and Kubernetes reschedules workloads. Repair or recreate the affected Zerops service, deploy the node agent, and join it again. Verify Longhorn replica rebuilding before another disruption.

## One control plane lost

The edge proxy removes failed TCP backends naturally. Two etcd members retain quorum. Repair the service and rejoin it as a control plane before taking another member down.

## Two control planes lost

Do not reset the surviving member. Recover at least one failed member if possible. If quorum cannot be recovered, create clean control-plane state and restore a recent etcd snapshot with the same Kubernetes version and PKI, then join the remaining nodes.

## Whole nested cluster lost

1. Preserve application backups and the current Zerops secret variables.
2. Run the destroy workflow until the Zerops-side state is `destroyed`.
3. Run the deploy workflow to recreate the cluster.
4. Restore application data into Longhorn-backed PVCs from application-aware backups.
5. Rotate Headlamp tokens and review audit logs.

The repository and Zerops secrets are the configuration source of truth. Prometheus data is demonstrational and only retained for four hours; it should not be treated as recovery-critical.
