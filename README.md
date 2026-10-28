# ai-service-on-k8s

A small AI-style service, built to be **deployed, watched, broken and recovered on Kubernetes**.

The service checks escape routes: it takes rooms with their distance to the nearest exit and flags those over a limit (25 m by default). The rule is deliberately simple. The point of the repo is everything around it: a Helm chart, probes that mean something, OpenTelemetry traces, JSON logs with trace ids, secrets that never live in the code, and an end-to-end test that runs on a real Kubernetes cluster (kind) in GitHub Actions.

Portfolio project, 2026, by Bogdan Andone. Results below come from the CI run, not from a laptop.

## What the end-to-end test proves

`scripts/e2e.sh` runs in CI on a fresh kind cluster and prints PASS for each step:

1. The database password is generated in the pipeline and only exists as a Kubernetes Secret. The chart has no password in it, and CI fails if one appears in `values.yaml`.
2. `helm install` brings up 2 replicas, Postgres and an OpenTelemetry Collector.
3. A real request is checked, and bad input is rejected with 422.
4. The trace span `rule_check` reaches the OTel Collector.
5. The JSON log line for the request carries its trace id.
6. **Store outage:** Postgres is scaled to 0. Readiness fails, so Kubernetes takes every pod out of the Service; liveness stays green, so nothing restarts in a loop; a check returns 503 "retry later" instead of losing the result silently; the outage is in the logs.
7. **Recovery:** Postgres comes back, pods become Ready again with zero container restarts, and checks work.
8. **Rolling update** to a new version with `maxUnavailable: 0`.
9. A deleted pod is replaced and the Deployment is back to 2/2 ready.

## Why it is built this way

| Decision | Why |
|---|---|
| Liveness never touches the database | A DB outage should stop traffic, not restart healthy pods in a loop. |
| Readiness checks the store | Kubernetes stops routing to a pod that cannot do its job. |
| 503 with "retry later" when a write fails | A lost result that looks like success is the worst failure. |
| Secret created outside the chart, `DB_PASSWORD` has no default | Secrets never sit in git; a missing Secret fails loudly at start. |
| Non-root, read-only root filesystem, all capabilities dropped, no service account token | The service needs none of it, so it gets none of it. |
| NetworkPolicy | Only pods in the namespace can call the service, and only the service can reach Postgres. |
| `maxUnavailable: 0` and a PodDisruptionBudget | Updates and node drains never take the last replica. |
| OTel Collector between the service and the backend | The service only speaks OTLP; switching the exporter to Tempo is a Collector config change. |

## Run it

```bash
python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest -q                      # 14 tests, no cluster needed

# On a local cluster (kind, Docker):
kind create cluster --name ai-demo
docker build -t ai-service:ci . && kind load docker-image ai-service:ci --name ai-demo
bash scripts/e2e.sh
```

## Honest limits

- It runs on kind in CI, not on a production cluster. There is no Ingress, TLS, autoscaling or multi-node scheduling.
- The Collector prints traces (debug exporter). Grafana, Loki and Tempo are not deployed here; logs are read with `kubectl logs`.
- No FluxCD or Terraform: the chart is installed with Helm from the pipeline.
- Postgres is a single StatefulSet replica with no backups, for the demo only.
- The escape-route rule is a stand-in, not a building-regulation implementation.

## Next steps

- Point the Collector at Tempo and ship logs to Loki, with a Grafana dashboard for request rate, errors and store outages.
- Manage the release with FluxCD from a Git repo, and secrets with Vault or OpenBao instead of a hand-made Secret.
