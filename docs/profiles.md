# Profiles and recipe publishing

## Choose one topology

The repository publishes three alternative Zerops project imports. They are not three clusters intended to coexist in one project.

| Profile | Import source | Exact recipe-owned inventory |
|---|---|---|
| `full` | [`import.yaml`](../import.yaml) | `k8scp1`–`k8scp3`, `k8sworker1`–`k8sworker3`, `k8sedge`, `k8sbackups`, `grafanadb`, `prometheusbackups`, `grafana`, `prometheus`, `elkstorage`, `kibana`, `logstash`, `apmserver` |
| `production` | [`import.production.yaml`](../import.production.yaml) | `k8scp1`, `k8sworker1`, `k8sworker2`, `k8sedge`, `k8sbackups` |
| `staging` | [`import.staging.yaml`](../import.staging.yaml) | `k8scp1`, `k8sworker1`, `k8sedge` |

Zerops project-core services and a pre-existing `zcp` service are not recipe-owned inventory and are preserved. `production` is compact production, not an HA control plane. `staging` is disposable and intentionally has no object storage; its only non-node runtime is the required redundant VRRP/HAProxy edge.

The machine-readable descriptors in [`profiles/`](../profiles/) are the source of truth for topology, endpoint, resource, feature, capability, and acceptance contracts. `K8S_PROFILE=full` is assumed when the variable is absent.

## Direct import sources

Use one of these version-controlled sources in Zerops' **Import a project** screen:

- Full: `https://raw.githubusercontent.com/Samyazz/zerops-k8s/e36f21d3a8fe9fab306125809c8290a9622edb16/import.yaml`
- Compact production: `https://raw.githubusercontent.com/Samyazz/zerops-k8s/e36f21d3a8fe9fab306125809c8290a9622edb16/import.production.yaml`
- Minimal staging: `https://raw.githubusercontent.com/Samyazz/zerops-k8s/e36f21d3a8fe9fab306125809c8290a9622edb16/import.staging.yaml`

These URLs are pinned to the full immutable commit SHA that passed the recorded
static and live acceptance gates. Release tags remain human-friendly aliases;
only a newly tested full commit SHA may replace these publishing endpoints.
`main` is intentionally not the publishing endpoint.

Equivalent zCLI commands after downloading the selected file are:

```sh
zcli project project-import import.yaml
zcli project project-import import.production.yaml
zcli project project-import import.staging.yaml
```

These commands create separate projects. Run only the command for the desired topology. For the existing project, dispatch **Deploy Zerops Kubernetes** with the desired `profile`; the profile-switch plan owns teardown and reconciliation. Do not use `service-import` to layer another profile over an existing recipe-owned cluster.

## Publishing checklist

Before publishing a release or changing the raw links to a tested commit:

1. Validate all three imports against Zerops' public import schema and ensure each exact service inventory matches its profile descriptor.
2. Render all shared setup references and prove that an import never references a service absent from that profile.
3. Run the repository's workflow/profile contract test and secret scan.
4. Run static clean-room validation for all profiles.
5. Run the live staging and production acceptance sequence when the release is intended to carry live-tested status.
6. Pin catalog links to the tested full 40-character commit SHA, verify all three URLs without authentication and compare their bytes, then optionally add a protected release tag as a human-friendly alias.
7. State explicitly that `production` has a single control plane and `staging` has no durable backup.

The import files may contain Zerops preprocessor expressions that generate secrets during import. They must never contain a rendered token, key, kubeconfig, password, connection string, or encrypted-secret payload copied from a live project.

## Workflow contract

All manual workflows are restricted to the repository owner. Every workflow accepts `profile` and defaults to `full`; scheduled workflows resolve `K8S_PROFILE` from the repository variable, falling back to `full`. All changing operations share the repository-wide concurrency group.

| Workflow file | Full | Compact production | Minimal staging |
|---|---|---|---|
| `deploy.yml` / `reusable-deploy.yml` | Reconcile plus full acceptance | Reconcile plus compact-production acceptance | Reconcile plus staging acceptance |
| `destroy.yml` | Destroy nested state and full-owned services during a switch | Destroy nested state and production-owned services during a switch | Destroy nested state and staging-owned services during a switch |
| `maintenance.yml` | Backup, worker roll, HA control-plane roll, add-ons | Backup, worker roll, sole-control-plane roll with API interruption, add-ons | Restart/recover worker and control plane with expected outage; no backup/storage gate |
| `upgrade.yml` | Controlled serial upgrade; full conformance default | Controlled serial upgrade; sole-control-plane interruption | Controlled two-node upgrade without backup; functional acceptance |
| `resize.yml` | Fixed vertical resize; workers 3–4 | Fixed vertical resize; workers 2–3 | Fixed vertical resize only; desired workers must remain 1 |
| `backup.yml` | Supported | Supported | Rejected before mutation |
| `restore-drill.yml` | Supported | Supported | Rejected before mutation |

Profile selection is an assertion about the live topology, not permission to reinterpret another live topology. A mismatched profile, unknown profile, unsupported capability, invalid worker count, unresolved cleanup lock, or repository-ownership mismatch fails before the requested infrastructure mutation.

## Endpoints

All listed endpoints are private and require an active Zerops VPN unless an operator explicitly adds separate public application routing.

| Endpoint | Full | Compact production | Minimal staging |
|---|---|---|---|
| Kubernetes API | `https://<derived-vrrp-vip>:6443` | `https://<derived-vrrp-vip>:6443` | `https://<derived-vrrp-vip>:6443` |
| Demo/application ingress | `http://<derived-vrrp-vip>:8080` | `http://<derived-vrrp-vip>:8080` | `http://<derived-vrrp-vip>:8080` |
| Edge readiness | `http://<derived-vrrp-vip>:18082/healthz` | `http://<derived-vrrp-vip>:18082/healthz` | `http://<derived-vrrp-vip>:18082/healthz` |
| Headlamp | `http://<derived-vrrp-vip>:18081` | Not installed | Not installed |

`<derived-vrrp-vip>` means host `.222` in the last `/24` of the edge runtime's discovered `/22`. For example, `10.0.68.0/22` produces `10.0.71.222`. The recipe never assumes the edge containers keep their individual addresses.
| Node lifecycle agent | `http://NODE.zerops:18080/healthz` | `http://NODE.zerops:18080/healthz` | `http://NODE.zerops:18080/healthz` |
| Grafana/Kibana | Zerops-assigned service subdomains | Not installed | Not installed |

The lifecycle agent's operational endpoints require the bearer credential held in Zerops secrets; its unauthenticated `/healthz` is only a readiness check. Kubeconfig and any full-profile Headlamp credentials are read from sensitive Zerops project variables created for the successful run, never from GitHub artifacts.
