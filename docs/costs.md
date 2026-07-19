# Cost estimate

This demonstration is intentionally large. Using the Zerops list prices checked in July 2026—$6 per dedicated CPU, $0.75 per 0.25 GB RAM, $0.05 per 0.5 GB disk, $0.01 per GB of object storage, and $10 for a Serious project per 30 days—the default six fixed node services estimate as:

| Group | Per node | Count | Estimate / 30 days |
|---|---:|---:|---:|
| Control planes: 4 dedicated CPU, 8 GB RAM, 20 GB disk | $50 | 3 | $150 |
| Workers: 4 dedicated CPU, 12 GB RAM, 50 GB disk | $65 | 3 | $195 |

The default node subtotal is about **$345/30 days**. Enabling `k8sworker4` adds about **$65/30 days**, making the seven-node subtotal about **$410/30 days**. Different resize inputs change these figures directly.

The two small edge replicas, Serious core, object storage, PostgreSQL, Elasticsearch, and the Prometheus/Grafana/ELK runtimes bring a realistic default demonstration total to roughly **$400–$500+ per 30 days**, depending on the observability services' actual scaling, disk use, and retained backup volume. A four-worker or vertically upsized cluster costs more.

Billing is minute-based, so stop/delete unneeded outer services after evaluation. The nested destroy workflow clears Kubernetes state but intentionally leaves its outer Zerops services, so it does not by itself eliminate their resource charges. Object storage is inexpensive, but etcd objects are not automatically pruned and Elasticsearch disk/RAM can grow. Set a daily spending warning in Zerops.

Always recalculate using the current [Zerops pricing page](https://docs.zerops.io/company/pricing); this document is an estimate, not a quote.
