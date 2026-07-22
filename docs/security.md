# Security model

## Shared baseline

- Node lifecycle endpoints are private, bearer-authenticated, and expose fixed operations rather than a generic shell.
- Kubernetes API access is VPN-only. The recipe does not publicly route the API, Headlamp, or application ingress.
- Kubernetes Secrets use API-server encryption at rest with a 32-byte key generated and stored through Zerops secrets.
- The `workloads` namespace enforces the Restricted Pod Security Standard, least-privilege RBAC, default-deny NetworkPolicies, bounded resources, a `LimitRange`, and a `ResourceQuota`.
- System components receive only documented PSA/privileged exceptions required by Calico, ingress, and profile-enabled storage/telemetry.
- The API audit policy records mutations and metadata access. Live-operation stdout and stderr pass through the redactor before reaching GitHub Actions logs; evidence files are independently sanitized before upload. Both paths redact tokens, authorization headers, cookies, e-mail addresses, and IP addresses.
- Kubescape/CIS findings are reports; they do not automatically block deployment. Functional and profile-appropriate conformance failures do.
- Git stores no token, kubeconfig, password, private key, rendered Kubernetes Secret, or unredacted API response. GitHub secrets authenticate workflows; generated operator credentials stay in sensitive Zerops project variables.
- GitHub deployment remains owner-triggered and manual. All changing workflows use repository-wide concurrency and the Zerops repository/profile lock. GitHub-owned Actions are pinned to full commit SHAs; third-party Actions are prohibited.

## Profile-specific controls

| Control | `full` | `production` | `staging` |
|---|---|---|---|
| Service mesh | Istio ambient with strict mTLS | None | None |
| Durable recovery identity | Age-encrypted etcd/PKI/signing/encryption bundle in `k8sbackups` | Same, for its single-member etcd | None |
| Cluster UI | VPN-only Headlamp with admin/operator/developer/read-only service accounts | None | None |
| Dedicated telemetry | Alloy/Fluent Bit/exporters to Zerops observability services | None; outer runtime platform logs/stats only | None; outer runtime platform logs/stats only |
| Privileged storage exception | Longhorn, 3-replica policy | Longhorn, 2-replica policy | None |

The production and staging names do not alter their availability facts: both have one control plane, and staging also has one worker. Security acceptance reports expected outage boundaries instead of treating them as failover.

## Secret and evidence handling

The full and production recovery workflows create object-storage credentials only at runtime from Zerops environment references. Decrypted recovery bundles, encrypted recovery archives, private age identities, S3 credentials, API tokens, Headlamp tokens, and kubeconfigs never enter artifacts. One-day artifacts contain only the selected profile, its public descriptor, exact service/Kubernetes inventories, statuses, checksums, non-sensitive object keys, redacted functional output, and forbidden-component assertions.

The workflow redaction pipeline runs with Bash `pipefail`, so filtering output
cannot turn a failed operation into a successful job. JSON and YAML evidence is
redacted structurally, including nested and array values. Binary files and
Kubernetes `Secret`/`SecretList` objects are rejected, and artifact upload is
gated on successful sanitization, so a rejected tree cannot be published.
Historical workflow-log payloads and superseded artifacts are removed before
publication; run conclusions and the final sanitized evidence records remain
available.

Staging must start without `k8sbackups_*` variables. Its node image is built locally so adding a backup credential solely for image distribution cannot accidentally create an undeclared durable dependency.

SSH through the Zerops VPN is retained as break-glass access. Normal changes use Kubernetes and the authenticated fixed-operation node agent.
