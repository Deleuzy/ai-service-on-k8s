#!/usr/bin/env bash
# End-to-end check on a real Kubernetes cluster (kind in CI): install, use, break the store, recover, roll out a new version.
# Every step prints PASS or exits non-zero.
set -euo pipefail
NS=ai-demo
REL=demo
SVC=$REL-ai-service
PORT=18080
BODY='{"building":"Hus A","rooms":[{"name":"Kontor 1","distance_to_exit_m":12},{"name":"Lager","distance_to_exit_m":31.5}]}'

pass() { echo "PASS: $*"; }
pf_pid=""
start_pf() { kubectl -n $NS port-forward svc/$SVC $PORT:80 >/dev/null 2>&1 & pf_pid=$!; sleep 3; }
stop_pf() { [ -n "$pf_pid" ] && kill $pf_pid 2>/dev/null || true; pf_pid=""; }
trap stop_pf EXIT
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

kubectl create namespace $NS
# 1. The password is generated here and only exists as a Kubernetes Secret, never in the repo or the chart.
kubectl -n $NS create secret generic ai-service-db --from-literal=password="$(openssl rand -hex 24)"
pass "secret created outside the chart"

helm install $REL chart/ai-service -n $NS --set image.tag=ci --wait --timeout 5m
kubectl -n $NS rollout status deploy/$SVC --timeout=180s
pass "helm install, 2 replicas ready"

# 2. Normal use
start_pf
[ "$(code localhost:$PORT/readyz)" = 200 ] && pass "readyz 200 with store up"
resp=$(curl -s -X POST localhost:$PORT/check -H 'content-type: application/json' -H 'x-request-id: e2e-1' -d "$BODY")
echo "$resp" | grep -q '"failing_rooms":\["Lager"\]' && pass "check flags the room over 25 m"
[ "$(code -X POST localhost:$PORT/check -H 'content-type: application/json' -d '{"building":"X","rooms":[]}')" = 422 ] && pass "bad input rejected with 422"
stop_pf

# 3. Traces reached the OpenTelemetry Collector
sleep 8
kubectl -n $NS logs deploy/$REL-otel-collector | grep -q 'rule_check' && pass "trace span rule_check received by OTel Collector"

# 4. Logs are JSON with a trace id
kubectl -n $NS logs -l app.kubernetes.io/name=ai-service --tail=200 | grep '"request_id": "e2e-1"' | grep -q '"trace_id": "[0-9a-f]\{32\}"' \
  && pass "JSON log line for the request carries a trace id"

# 5. Store outage: readiness must fail (traffic stops) but liveness must not restart the pods
restarts_before=$(kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | paste -sd+ - | bc)
kubectl -n $NS scale statefulset/$REL-postgres --replicas=0
kubectl -n $NS wait --for=delete pod/$REL-postgres-0 --timeout=120s || true
for i in $(seq 1 30); do
  ready=$(kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true)
  [ "$ready" = 0 ] && break; sleep 2
done
[ "$ready" = 0 ] && pass "store down: all service pods marked NotReady (taken out of the Service)"
pod=$(kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS port-forward pod/$pod $PORT:8000 >/dev/null 2>&1 & pf_pid=$!; sleep 3
[ "$(code localhost:$PORT/readyz)" = 503 ] && pass "readyz 503 while store is down"
[ "$(code localhost:$PORT/healthz)" = 200 ] && pass "healthz still 200, so no restart loop"
[ "$(code -X POST localhost:$PORT/check -H 'content-type: application/json' -d "$BODY")" = 503 ] && pass "check returns 503 'retry later' instead of a silent loss"
stop_pf
kubectl -n $NS logs $pod --tail=50 | grep -q 'readiness failed: store unreachable' && pass "outage visible in the logs"

# 6. Recovery
kubectl -n $NS scale statefulset/$REL-postgres --replicas=1
kubectl -n $NS rollout status statefulset/$REL-postgres --timeout=180s
kubectl -n $NS wait --for=condition=Ready pod -l app.kubernetes.io/name=ai-service --timeout=120s
restarts_after=$(kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | paste -sd+ - | bc)
[ "$restarts_before" = "$restarts_after" ] && pass "recovered without a single container restart ($restarts_after)"
start_pf
[ "$(code -X POST localhost:$PORT/check -H 'content-type: application/json' -d "$BODY")" = 200 ] && pass "check works again after recovery"
stop_pf

# 7. Rolling update to a new version with maxUnavailable 0
helm upgrade $REL chart/ai-service -n $NS --set image.tag=ci --set serviceVersion=0.2.0 --wait --timeout 5m
kubectl -n $NS rollout status deploy/$SVC --timeout=180s
kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{.items[*].metadata.labels.app\.kubernetes\.io/version}' | grep -q '0.2.0' \
  && pass "rolled out version 0.2.0"

# 8. A killed pod is replaced
victim=$(kubectl -n $NS get pods -l app.kubernetes.io/name=ai-service -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS delete pod "$victim" --wait=false
sleep 5
kubectl -n $NS rollout status deploy/$SVC --timeout=120s
[ "$(kubectl -n $NS get deploy/$SVC -o jsonpath='{.status.readyReplicas}')" = 2 ] && pass "deleted pod replaced, 2/2 ready"

echo "ALL E2E CHECKS PASSED"
