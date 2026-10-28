# ai-service-on-k8s

A small AI-style service, built to be **deployed, watched, broken and recovered on Kubernetes**.

The service checks escape routes: it takes rooms with their distance to the nearest exit and flags those over a limit (25 m by default). The rule is deliberately simple. The point of the repo is everything around it: a Helm chart, probes that mean something, OpenTelemetry traces, JSON logs with trace ids, secrets that never live in the code, and an end-to-end test that runs on a real Kubernetes cluster (kind) in GitHub Actions.

Portfolio project, 2026, by Bogdan Andone. Results below come from the CI run, not from a laptop.

## What the end-to-end test proves

`scripts/e2e.sh` runs in GitHub Actions on a fresh kind cluster. Every check prints PASS or FAIL; a FAIL dumps pods, events and logs and stops the job, and CI also requires the final line `ALL E2E CHECKS PASSED`. All 16 checks passed in [run 40684754445](https://github.com/Deleuzy/ai-service-on-k8s/actions/runs/40684754445):

1. The database password is generated in the pipeline and only exists as a Kubernetes Secret. The chart has no password in it, and CI fails if one appears in `values.yaml`.
2. `helm install --wait` brings up 2 replicas of the service, Postgres and Grafana Tempo.
3. Readiness is 200 with the store up; a real request flags the room over 25 m; bad input is rejected with 422.
4. The JSON log line for that request carries a trace id, and **the same trace id, looked up in Tempo, contains the `rule_check` span.**
5. **Store outage:** Postgres is scaled to 0. Every service pod goes NotReady, so Kubernetes stops routing to it; `/healthz` stays 200, so nothing restarts in a loop; a check returns 503 "retry later" instead of losing the result silently; the outage is in the logs.
6. **Recovery:** Postgres comes back, pods become Ready again with **0 container restarts**, and checks work.
7. **Rolling update** to version 0.2.0 with `maxUnavailable: 0`.
8. A deleted pod is replaced and the Deployment is back to 2/2 ready.

### Two bugs the cluster found

- **Pods start before the database.** The first version created the table only at startup, so on a fresh cluster every write failed. The schema is now created the first time the store is reachable, and a unit test covers a store that appears late. Two replicas racing to create the table is handled too.
- **A green CI that was not true.** An early run passed while several checks had silently failed, because the output was piped through `tee` and `[ test ] && echo PASS` does not stop a script. Every check now goes through one `check` function that fails hard, and CI greps for the final line.

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
| OTLP straight to Tempo | The service only speaks OTLP over HTTP, so the backend can change (Collector, Tempo, Jaeger) without touching the code. |

## Run it

```bash
python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest -q                      # 15 tests, no cluster needed

# On a local cluster (kind, Docker):
kind create cluster --name ai-demo
docker build -t ai-service:ci . && kind load docker-image ai-service:ci --name ai-demo
bash scripts/e2e.sh
```

## Honest limits

- It runs on kind in CI, not on a production cluster. There is no Ingress, TLS, autoscaling or multi-node scheduling.
- Tempo runs as a single pod with local storage and no Grafana in front of it; traces are checked through Tempo's API. Loki is not deployed, so logs are read with `kubectl logs`.
- No FluxCD or Terraform: the chart is installed with Helm from the pipeline.
- Postgres is a single StatefulSet replica with no backups, for the demo only.
- The escape-route rule is a stand-in, not a building-regulation implementation.

## Next steps

- Ship logs to Loki and add Grafana with dashboards for request rate, errors and store outages, linked to the Tempo traces.
- Manage the release with FluxCD from a Git repo, and secrets with Vault or OpenBao instead of a hand-made Secret.
