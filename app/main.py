"""Escape-route check service: a small AI-style service built to be run, watched and recovered on Kubernetes.

The domain logic is deliberately simple (rooms -> distance to nearest exit -> pass/fail against a limit).
The point of the repo is everything around it: probes, structured logs with trace ids, OpenTelemetry,
secrets outside the code, and a store whose outage the service reports instead of hiding.
"""
import json
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Float, Integer, String, create_engine, func, text
from sqlalchemy.orm import declarative_base, sessionmaker

from app import telemetry

MAX_EXIT_DISTANCE_M = float(os.getenv("MAX_EXIT_DISTANCE_M", "25"))
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "dev")


class JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname,
            "msg": record.getMessage(),
            "service": "ai-service",
            "version": SERVICE_VERSION,
            "trace_id": telemetry.current_trace_id(),
        }
        entry.update(getattr(record, "extra_fields", {}))
        return json.dumps(entry)


log = logging.getLogger("ai-service")
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
log.handlers = [_handler]
log.setLevel(logging.INFO)
log.propagate = False


def database_url() -> str:
    """Build the DB URL from the environment. The password only ever comes from a mounted Secret."""
    if url := os.getenv("DATABASE_URL"):
        return url
    host = os.getenv("DB_HOST")
    if not host:
        return "sqlite:///./local.db"
    password = os.environ["DB_PASSWORD"]  # fail loudly if the Secret is missing
    user = os.getenv("DB_USER", "app")
    name = os.getenv("DB_NAME", "app")
    return f"postgresql+psycopg://{user}:{password}@{host}:5432/{name}"


Base = declarative_base()


class CheckRecord(Base):
    __tablename__ = "checks"
    id = Column(Integer, primary_key=True)
    request_id = Column(String(36), nullable=False)
    rooms = Column(Integer, nullable=False)
    failing = Column(Integer, nullable=False)
    worst_distance_m = Column(Float, nullable=False)
    created_at = Column(DateTime, server_default=func.now())


engine = create_engine(database_url(), pool_pre_ping=True, pool_size=5) if not database_url().startswith("sqlite") \
    else create_engine(database_url(), connect_args={"check_same_thread": False})
Session = sessionmaker(bind=engine)


@asynccontextmanager
async def lifespan(_app):
    try:
        Base.metadata.create_all(engine)
    except Exception as exc:  # the store may not be up yet; readiness will report it
        log.warning("schema init deferred", extra={"extra_fields": {"error": type(exc).__name__}})
    log.info("service started", extra={"extra_fields": {"max_exit_distance_m": MAX_EXIT_DISTANCE_M}})
    yield


app = FastAPI(title="ai-service", version=SERVICE_VERSION, lifespan=lifespan)
telemetry.instrument(app)
METRICS = {"checks_total": 0, "checks_failed_rooms_total": 0, "store_errors_total": 0}


class Room(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    distance_to_exit_m: float = Field(ge=0, le=10_000)


class CheckRequest(BaseModel):
    building: str = Field(min_length=1, max_length=200)
    rooms: list[Room] = Field(min_length=1, max_length=5_000)


@app.get("/healthz")
def healthz():
    """Liveness: the process is up. Never touches the database, so a DB outage does not restart pods."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    """Readiness: can we serve real requests? If the store is down, take this pod out of the Service."""
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:
        log.error("readiness failed: store unreachable", extra={"extra_fields": {"error": type(exc).__name__}})
        return JSONResponse(status_code=503, content={"status": "not ready", "reason": "store unreachable"})
    return {"status": "ready"}


@app.post("/check")
def check(req: CheckRequest, request: Request):
    request_id = request.headers.get("x-request-id", str(uuid.uuid4()))
    with telemetry.span("rule_check", {"rooms": len(req.rooms)}):
        failing = [r for r in req.rooms if r.distance_to_exit_m > MAX_EXIT_DISTANCE_M]
        worst = max(r.distance_to_exit_m for r in req.rooms)
    try:
        with telemetry.span("store_result"), Session() as s:
            s.add(CheckRecord(request_id=request_id, rooms=len(req.rooms), failing=len(failing), worst_distance_m=worst))
            s.commit()
    except Exception as exc:
        METRICS["store_errors_total"] += 1
        log.error("store write failed", extra={"extra_fields": {"request_id": request_id, "error": type(exc).__name__}})
        raise HTTPException(status_code=503, detail="result could not be stored; retry later")
    METRICS["checks_total"] += 1
    METRICS["checks_failed_rooms_total"] += len(failing)
    log.info("check done", extra={"extra_fields": {"request_id": request_id, "rooms": len(req.rooms), "failing": len(failing)}})
    return {
        "request_id": request_id,
        "building": req.building,
        "limit_m": MAX_EXIT_DISTANCE_M,
        "passed": not failing,
        "failing_rooms": [r.name for r in failing],
        "worst_distance_m": worst,
    }


@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    lines = []
    for name, value in METRICS.items():
        lines += [f"# TYPE ai_service_{name} counter", f"ai_service_{name} {value}"]
    return "\n".join(lines) + "\n"
