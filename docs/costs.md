# Cost estimate

These are planning estimates, not quotes. Zerops bills by actual allocation/usage and prices can change; recalculate with the current [Zerops pricing page](https://docs.zerops.io/company/pricing) before a long-lived deployment.

Using the July 2026 list prices used for this demonstration—$6 per dedicated CPU, $0.75 per 0.25 GB RAM, $0.05 per 0.5 GB disk, $0.01 per GB object storage, and $10 for a Serious project per 30 days—the fixed node baselines are:

| Profile/group | Per node | Count | Approximate node subtotal / 30 days |
|---|---:|---:|---:|
| `full` control planes: 4 dedicated CPU, 8 GB RAM, 20 GB disk | $50 | 3 | $150 |
| `full` workers: 4 dedicated CPU, 12 GB RAM, 50 GB disk | $65 | 3 | $195 |
| `production` control plane: 4 dedicated CPU, 8 GB RAM, 20 GB disk | $50 | 1 | $50 |
| `production` workers: 4 dedicated CPU, 8 GB RAM, 50 GB disk | $53 | 2 | $106 |
| `staging` nodes: 2 shared CPU, 4 GB RAM, 20 GB disk | usage-based shared CPU plus about $14 RAM/disk | 2 | about $28 plus shared-CPU usage |

The resulting node baseline is about **$345/30 days** for `full`, **$156/30 days** for `production`, and **$28/30 days plus shared-CPU usage** for `staging`. Optional worker four adds about $65 to full. Optional worker three adds about $53 to production.

Outer services change the total:

- `full` adds two small edge containers, Serious Core, 25 GB backup storage, PostgreSQL, Elasticsearch, Prometheus/Grafana and ELK/APM runtimes. A realistic demonstration total remains roughly **$400–$500+ per 30 days**, depending on observability allocation and retained data.
- `production` adds two small edge containers, Serious Core and 25 GB private backup storage, but no dedicated observability/database services. Budget above the $156 node baseline for edge usage and the project core; object storage starts around $0.25/month before transfer/other applicable charges.
- `staging` requests Lightweight Core for a new import and has no edge, object storage or observability orbiting service. In an existing Serious-Core project the core cannot be downgraded, so its current core charge remains.

Horizontal and vertical resize inputs change these numbers directly. Disk can grow but cannot shrink in place. The nested destroy operation clears cluster state, while profile switching or explicit service cleanup determines whether outer Zerops service charges stop. Delete unused recipe-owned runtimes after evaluation, keep staging disposable, and configure a spending warning in Zerops.
