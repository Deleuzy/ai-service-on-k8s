#!/usr/bin/env bash
# End-to-end check on a real Kubernetes cluster (kind in CI): install, use, break the store, recover, roll out a new version.
# Every check either prints PASS or prints FAIL, dumps diagnostics and exits non-zero. Nothing is allowed to fail quietly.
set -euo pipefail
NS=ai-demo
REL=demo
SVC=$REL-ai-service
PORT=18080
BODY='{"building":"Hus A","rooms":[{"name":"Kontor 1","distance_to_exit_m":12},{"name":"Lager","distance_to_exit_m":31.5}]}'
APP=app.kubernetes.io/name=ai-service

diag() {
  echo "----- diagnostics -----"
  kubectl -n $NS get pods,svc,statefulset,deploy -o wide || true
  kubectl -n $NS describe pods -l $APP | tail -60 || true
  kubectl -n $NS logs -l $APP --tail=40 || true
  kubectl -n $NS logs deploy/$REL-otel-collector --tail=40 || true
  kubectl -n $NS get events --sort-by=.lastTimestamp | tail -30 || true
}
check() {  # check "description" command...
  local desc=$1; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; diag; exit 1; fi
}
pf_pid=""
start_pf() { kubectl -n $NS port-forward "$1" $PORT:"$2" >/dev/null 2>&1 & pf_pid=$!; sleep 3; }
stop_pf() { if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; pf_pid=""; fi; }
trap stop_pf EXIT
code_is() { local want=$1; shift; [ "$(curl -s -o /dev/null -w '%{http_code}' "$@")" = "$want" ]; }
restarts() { kubectl -n $NS get pods -l $APP -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END {print s+0}'; }
ready_count() { kubectl -n $NS get pods -l $APP -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true; }

kubectl create namespace $NS
# The password is generated here and only exists as a Kubernetes Secret, never in the repo or the chart.
kubectl -n $NS create secret generic ai-service-db --from-literal=password="$(openssl rand -hex 24)"
echo "PASS: secret created outside the chart"

if ! helm install $REL chart/ai-service -n $NS --set image.tag=ci --wait --timeout 5m; then echo "FAIL: helm install"; diag; exit 1; fi
kubectl -n $NS rollout status deploy/$SVC --timeout=180s
echo "PASS: helm install, 2 replicas ready"

# Normal use
start_pf svc/$SVC 80
check "readyz 200 with store up" code_is 200 localhost:$PORT/readyz
flags_lager() { curl -s -X POST localhost:$PORT/check -H 'content-type: application/json' -H 'x-request-id: e2e-1' -d "$BODY" | tee /dev/stderr | grep -q '"failing_rooms":\["Lager"\]'; }
check "check flags the room over 25 m" flags_lager
check "bad input rejected with 422" code_is 422 -X POST localhost:$PORT/check -H 'content-type: application/json' -d '{"building":"X","rooms":[]}'
stop_pf

# Traces reach the OpenTelemetry Collector (batch export, so allow some seconds)
span_seen() { for _ in $(seq 1 15); do kubectl -n $NS logs deploy/$REL-otel-collector | grep -q 'rule_check' && return 0; sleep 2; done; return 1; }
check "trace span rule_check received by the OTel Collector" span_seen

json_log_with_trace() { kubectl -n $NS logs -l $APP --tail=300 | grep '"msg": "check done"' | grep '"request_id": "e2e-1"' | grep -q '"trace_id": "[0-9a-f]\{32\}"'; }
check "JSON log line 'check done' for the request carries a trace id" json_log_with_trace

# Store outage: readiness must fail (traffic stops) but liveness must not restart the pods
before=$(restarts)
kubectl -n $NS scale statefulset/$REL-postgres --replicas=0
kubectl -n $NS wait --for=delete pod/$REL-postgres-0 --timeout=120s || true
all_not_ready() { for _ in $(seq 1 30); do [ "$(ready_count)" = 0 ] && return 0; sleep 2; done; return 1; }
check "store down: every service pod marked NotReady (out of the Service)" all_not_ready
pod=$(kubectl -n $NS get pods -l $APP -o jsonpath='{.items[0].metadata.name}')
start_pf pod/$pod 8000
check "readyz 503 while the store is down" code_is 503 localhost:$PORT/readyz
check "healthz still 200, so no restart loop" code_is 200 localhost:$PORT/healthz
check "check returns 503 'retry later' instead of a silent loss" code_is 503 -X POST localhost:$PORT/check -H 'content-type: application/json' -d "$BODY"
stop_pf
outage_logged() { kubectl -n $NS logs "$pod" --tail=100 | grep -q 'readiness failed: store unreachable'; }
check "outage visible in the logs" outage_logged

# Recovery
kubectl -n $NS scale statefulset/$REL-postgres --replicas=1
kubectl -n $NS rollout status statefulset/$REL-postgres --timeout=180s
kubectl -n $NS wait --for=condition=Ready pod -l $APP --timeout=180s
after=$(restarts)
same_restarts() { [ "$before" = "$after" ]; }
check "recovered with no container restarts ($before before, $after after)" same_restarts
start_pf svc/$SVC 80
check "check works again after recovery" code_is 200 -X POST localhost:$PORT/check -H 'content-type: application/json' -d "$BODY"
stop_pf

# Rolling update to a new version with maxUnavailable 0
if ! helm upgrade $REL chart/ai-service -n $NS --set image.tag=ci --set serviceVersion=0.2.0 --wait --timeout 5m; then echo "FAIL: helm upgrade"; diag; exit 1; fi
kubectl -n $NS rollout status deploy/$SVC --timeout=180s
on_new_version() { kubectl -n $NS get pods -l $APP,app.kubernetes.io/version=0.2.0 -o name | grep -q pod; }
check "rolled out version 0.2.0" on_new_version

# A killed pod is replaced
victim=$(kubectl -n $NS get pods -l $APP -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS delete pod "$victim" --wait=false
sleep 5
kubectl -n $NS rollout status deploy/$SVC --timeout=180s
two_ready() { for _ in $(seq 1 30); do [ "$(kubectl -n $NS get deploy/$SVC -o jsonpath='{.status.readyReplicas}')" = 2 ] && return 0; sleep 2; done; return 1; }
check "deleted pod replaced, 2/2 ready" two_ready

echo "ALL E2E CHECKS PASSED"
