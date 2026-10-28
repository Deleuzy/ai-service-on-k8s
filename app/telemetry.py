"""OpenTelemetry setup. Traces go to an OTLP endpoint (an OTel Collector in the cluster) when one is configured;
without one, spans still exist so trace ids appear in the logs, they are just not exported."""
import os
from contextlib import contextmanager

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

_provider = TracerProvider(resource=Resource.create({
    "service.name": "ai-service",
    "service.version": os.getenv("SERVICE_VERSION", "dev"),
}))
if endpoint := os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    _provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint.rstrip('/')}/v1/traces")))
trace.set_tracer_provider(_provider)
tracer = trace.get_tracer("ai-service")


def instrument(app):
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")


@contextmanager
def span(name, attributes=None):
    with tracer.start_as_current_span(name, attributes=attributes or {}) as s:
        yield s


def current_trace_id() -> str | None:
    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x") if ctx.is_valid else None
