"""
crew-dispatch: assigns a field maintenance crew to a reported signal issue.

WHERE IT RUNS
  Kubernetes (k3s), namespace "corridor", internal service on port 8080.

HOW IT IS MONITORED: OPENTELEMETRY ONLY
  This service deliberately has NO New Relic agent. It is started with
  `opentelemetry-instrument` (see Dockerfile), which auto-instruments Flask and
  exports traces, metrics and logs over OTLP (the OpenTelemetry protocol)
  straight to New Relic's endpoint. All exporter settings are OTEL_* environment
  variables in k8s/apps.yaml.

  The code below also uses the OpenTelemetry API directly:
    - span attributes on the incoming request (report ID, issue type)
    - two custom spans, "assign_crew" and "notify.sms", with their own attributes
    - an error status on notify.sms when the (simulated) SMS gateway times out

  Because the upstream New Relic agent sends the W3C `traceparent` header, these
  spans join the same distributed trace as the agent-instrumented services.
"""
import logging
import random
import time

from flask import Flask, jsonify, request
from opentelemetry import trace

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s crew-dispatch %(message)s")
log = logging.getLogger("crew-dispatch")

# A tracer is the OpenTelemetry object that creates spans for this service.
tracer = trace.get_tracer("crew-dispatch")
app = Flask(__name__)

# Maintenance crews and the intersections (by ID) each one covers.
CREWS = {
    "Crew 12 (North)": range(1, 5),
    "Crew 7 (Central)": range(5, 8),
    "Crew 3 (South)": range(8, 11),
}


@app.post("/dispatch")
def dispatch():
    body = request.get_json(force=True)
    iid = int(body.get("intersection_id", 0))

    # Add attributes to the span OpenTelemetry already created for this request.
    span = trace.get_current_span()
    span.set_attribute("corridor.report_id", body.get("report_id"))
    span.set_attribute("corridor.intersection_id", iid)
    span.set_attribute("corridor.issue", body.get("issue", "Other"))

    # Custom span 1: choose the crew responsible for this intersection.
    with tracer.start_as_current_span("assign_crew") as s:
        crew = next((name for name, ids in CREWS.items() if iid in ids), "Crew 3 (South)")
        s.set_attribute("corridor.crew", crew)
        time.sleep(random.uniform(0.005, 0.02))

    # Custom span 2: text the crew lead (simulated). Fails about 3% of the time.
    with tracer.start_as_current_span("notify.sms") as s:
        s.set_attribute("messaging.system", "sms-gateway-simulated")
        s.set_attribute("corridor.crew", crew)
        time.sleep(random.uniform(0.03, 0.09))
        if random.random() < 0.03:
            s.set_status(trace.Status(trace.StatusCode.ERROR, "SMS gateway timeout"))
            log.error("crew notification failed report=%s crew=%s", body.get("report_id"), crew)
            return jsonify({"crew": crew, "notified": False}), 503

    log.info("crew dispatched report=%s intersection=%s crew=%s issue=%s",
             body.get("report_id"), iid, crew, body.get("issue"))
    return jsonify({"crew": crew, "notified": True})


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
