import json
import logging

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{tmp_path}/test.db")
    import importlib
    import app.main as main
    importlib.reload(main)
    with TestClient(main.app) as c:
        yield c, main


BUILDING = {"building": "Hus A", "rooms": [
    {"name": "Kontor 1", "distance_to_exit_m": 12.0},
    {"name": "Lager", "distance_to_exit_m": 31.5},
]}


def test_liveness_never_touches_store(client):
    c, main = client
    main.engine.dispose()
    assert c.get("/healthz").json() == {"status": "ok"}


def test_ready_when_store_reachable(client):
    c, _ = client
    r = c.get("/readyz")
    assert r.status_code == 200 and r.json()["status"] == "ready"


def test_not_ready_when_store_down(client, monkeypatch):
    c, main = client
    def boom(*a, **k):
        raise ConnectionError("db down")
    monkeypatch.setattr(main.engine, "connect", boom)
    r = c.get("/readyz")
    assert r.status_code == 503
    assert r.json()["reason"] == "store unreachable"


def test_check_flags_rooms_over_limit(client):
    c, _ = client
    r = c.post("/check", json=BUILDING)
    body = r.json()
    assert r.status_code == 200
    assert body["passed"] is False
    assert body["failing_rooms"] == ["Lager"]
    assert body["worst_distance_m"] == 31.5


def test_check_passes_when_all_within_limit(client):
    c, _ = client
    r = c.post("/check", json={"building": "Hus B", "rooms": [{"name": "Rum", "distance_to_exit_m": 5}]})
    assert r.json()["passed"] is True


def test_request_id_is_kept(client):
    c, _ = client
    r = c.post("/check", json=BUILDING, headers={"x-request-id": "abc-123"})
    assert r.json()["request_id"] == "abc-123"


@pytest.mark.parametrize("payload", [
    {"building": "X", "rooms": []},
    {"building": "", "rooms": [{"name": "R", "distance_to_exit_m": 1}]},
    {"building": "X", "rooms": [{"name": "R", "distance_to_exit_m": -1}]},
    {"building": "X"},
])
def test_bad_input_rejected(client, payload):
    c, _ = client
    assert c.post("/check", json=payload).status_code == 422


def test_store_failure_is_reported_not_hidden(client, monkeypatch):
    c, main = client
    class Broken:
        def __enter__(self):
            raise ConnectionError("db down")
        def __exit__(self, *a):
            return False
    monkeypatch.setattr(main, "Session", lambda: Broken())
    r = c.post("/check", json=BUILDING)
    assert r.status_code == 503
    assert "retry" in r.json()["detail"]
    assert main.METRICS["store_errors_total"] == 1


def test_metrics_count_checks(client):
    c, _ = client
    c.post("/check", json=BUILDING)
    text = c.get("/metrics").text
    assert "ai_service_checks_total 1" in text
    assert "ai_service_checks_failed_rooms_total 1" in text


def test_logs_are_json_with_trace_id(client):
    import io
    c, main = client
    buf = io.StringIO()
    h = logging.StreamHandler(buf)
    h.setFormatter(main.JsonFormatter())
    main.log.addHandler(h)
    try:
        c.post("/check", json=BUILDING)
    finally:
        main.log.removeHandler(h)
    lines = [json.loads(l) for l in buf.getvalue().splitlines()]
    done = [l for l in lines if l["msg"] == "check done"]
    assert done, lines
    assert done[0]["trace_id"] and len(done[0]["trace_id"]) == 32
    assert done[0]["rooms"] == 2


def test_password_never_has_a_default(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("DB_HOST", "db")
    monkeypatch.delenv("DB_PASSWORD", raising=False)
    import app.main as main
    with pytest.raises(KeyError):
        main.database_url()
