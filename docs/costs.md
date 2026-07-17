# Cost estimate

This demonstration is intentionally large. Using Zerops' July 2026 list prices—$6 per dedicated CPU, $0.75 per 0.25 GB RAM, $0.05 per 0.5 GB disk, and $10 for a Serious project per 30 days—the six fixed node services alone estimate as:

| Group | Per node | Count | Estimate / 30 days |
|---|---:|---:|---:|
| Control planes: 4 dedicated CPU, 8 GB RAM, 20 GB disk | $50 | 3 | $150 |
| Workers: 4 dedicated CPU, 12 GB RAM, 50 GB disk | $65 | 3 | $195 |

The node subtotal is about **$345/30 days**. The two small edge replicas, Serious core, object storage, PostgreSQL, Elasticsearch, and the Prometheus/Grafana/ELK runtimes bring a realistic demonstration total to roughly **$400–$500+ per 30 days**, depending on the observability services' actual scaling and disk use.

Billing is minute-based, so destroy the nested cluster or stop/delete unneeded outer services after evaluation. Object storage is inexpensive, but Elasticsearch disk and RAM can grow. Set a daily spending warning in Zerops.

Always recalculate using the current [Zerops pricing page](https://docs.zerops.io/company/pricing); this document is an estimate, not a quote.
