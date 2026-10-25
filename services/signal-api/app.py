"""
signal-api: the system of record for the Smart Signal Corridor.

WHERE IT RUNS
  Kubernetes (k3s), namespace "corridor". Two replicas behind a NodePort (30081)
  so the Operations Portal on the host tier can reach it.

WHAT IT DOES
  1. Receives check-ins from the 10 traffic signal controllers on the corridor
     (simulated by corridor-simulator). For every check-in it asks timing-engine
     for the timing plan that controller should be running, records whether that
     plan is safe, and returns the plan to the controller.
  2. Serves intersection data to the Operations Portal.
  3. Accepts field issue reports ("signal stuck on flash") and hands them to
     crew-dispatch so a maintenance crew is sent.

HOW IT IS MONITORED
  New Relic Python APM agent, loaded by `newrelic-admin run-program` in the
  Dockerfile and configured only through environment variables. The code below
  uses the agent API in three places:
    - add_custom_attribute(): adds business context (intersection, plan version,
      yellow interval) to each transaction and its spans, so traces are searchable
      by those values.
    - record_custom_event("SignalCheckin"): writes one event per check-in. This is
      the data behind the timing-compliance chart and alert. It is the only signal
      that catches the demo incident, because every HTTP call still returns 200.
    - ignore_transaction(): keeps Kubernetes health checks out of the APM data.

SAFETY RULE USED IN THE DEMO
  A yellow (change) interval shorter than 3.0 seconds is non-compliant. Federal
  signal guidance (the MUTCD) generally calls for 3 to 6 seconds of yellow.
"""
import logging
import os
import time

import newrelic.agent
import psycopg2
import psycopg2.pool
import requests
from flask import Flask, jsonify, request

# ---------------------------------------------------------------- configuration
# All settings come from environment variables set in k8s/apps.yaml.
PG_DSN = (
    f"host={os.environ['PG_HOST']} port={os.environ.get('PG_PORT', '5432')} "
    f"dbname={os.environ.get('PG_DB', 'corridor')} user={os.environ.get('PG_USER', 'corridor')} "
    f"password={os.environ['PG_PASSWORD']} connect_timeout=5"
)
TIMING_URL = os.environ.get("TIMING_URL", "http://timing-engine:3000")
DISPATCH_URL = os.environ.get("DISPATCH_URL", "http://crew-dispatch:8080")
CORRIDOR = "US-41/70S Murfreesboro Pike"
MIN_YELLOW_SECONDS = 3.0

# Plain Python logging. The New Relic agent captures these lines automatically
# and forwards them with the trace ID attached ("logs in context").
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s signal-api %(message)s")
log = logging.getLogger("signal-api")

app = Flask(__name__)
pool = psycopg2.pool.ThreadedConnectionPool(1, 10, PG_DSN)

# ---------------------------------------------------------------- database setup
# The 10 pilot intersections. Cross streets are real Murfreesboro Pike
# intersections in Nashville (Davidson County); speed limits are illustrative.
INTERSECTIONS = [
    (1, "Murfreesboro Pk & Fesslers Ln", 40),
    (2, "Murfreesboro Pk & Thompson Ln", 45),
    (3, "Murfreesboro Pk & Briley Pkwy Ramps", 45),
    (4, "Murfreesboro Pk & Donelson Pk", 45),
    (5, "Murfreesboro Pk & Harding Pl", 45),
    (6, "Murfreesboro Pk & Haywood Ln", 45),
    (7, "Murfreesboro Pk & Nashboro Blvd", 40),
    (8, "Murfreesboro Pk & Bell Rd", 45),
    (9, "Murfreesboro Pk & Old Hickory Blvd", 50),
    (10, "Murfreesboro Pk & Hobson Pk", 50),
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS intersections (
  id INT PRIMARY KEY,
  name TEXT NOT NULL,
  corridor TEXT NOT NULL,
  county TEXT NOT NULL,
  speed_mph INT NOT NULL
);
CREATE TABLE IF NOT EXISTS checkins (
  id BIGSERIAL PRIMARY KEY,
  intersection_id INT REFERENCES intersections(id),
  controller_state TEXT,
  plan_version TEXT,
  yellow_s NUMERIC(4,2),
  compliant BOOLEAN,
  at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS checkins_by_intersection ON checkins (intersection_id, at DESC);
CREATE TABLE IF NOT EXISTS reports (
  id SERIAL PRIMARY KEY,
  intersection_id INT REFERENCES intersections(id),
  issue TEXT,
  reporter TEXT,
  crew TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
"""


def init_db():
    """Create tables and seed the intersections. Retries while PostgreSQL starts."""
    for attempt in range(15):
        try:
            conn = pool.getconn()
            with conn, conn.cursor() as cur:
                cur.execute(SCHEMA)
                for iid, name, mph in INTERSECTIONS:
                    cur.execute(
                        "INSERT INTO intersections (id, name, corridor, county, speed_mph) "
                        "VALUES (%s, %s, %s, 'Davidson', %s) ON CONFLICT (id) DO NOTHING",
                        (iid, name, CORRIDOR, mph))
            pool.putconn(conn)
            log.info("database ready, %s intersections seeded", len(INTERSECTIONS))
            return
        except psycopg2.Error as exc:
            log.warning("database not ready (attempt %s): %s", attempt + 1, exc)
            time.sleep(3)
    raise RuntimeError("database unavailable")


init_db()


def query(sql, params=(), one=False):
    """Run a read query and return rows as dictionaries."""
    conn = pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [c[0] for c in cur.description]
            rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        conn.rollback()
    finally:
        pool.putconn(conn)
    return (rows[0] if rows else None) if one else rows


def get_plan(intersection_id):
    """Ask timing-engine for the timing plan this intersection should run."""
    resp = requests.get(f"{TIMING_URL}/plans/{intersection_id}", timeout=5)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------- endpoints
@app.post("/checkins")
def checkin():
    """A signal controller reports in and receives its current timing plan."""
    body = request.get_json(force=True)
    iid = int(body["intersection_id"])
    state = body.get("state", "normal")

    plan = get_plan(iid)
    yellow = float(plan["yellow_s"])
    compliant = yellow >= MIN_YELLOW_SECONDS

    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO checkins (intersection_id, controller_state, plan_version, yellow_s, compliant) "
                "VALUES (%s, %s, %s, %s, %s)",
                (iid, state, plan["plan_version"], yellow, compliant))
    finally:
        pool.putconn(conn)

    # Business context on the transaction (shows on traces, transaction events, spans).
    newrelic.agent.add_custom_attribute("intersectionId", iid)
    newrelic.agent.add_custom_attribute("planVersion", plan["plan_version"])
    newrelic.agent.add_custom_attribute("yellowSeconds", yellow)
    newrelic.agent.add_custom_attribute("timingCompliant", compliant)

    # One SignalCheckin event per controller check-in. Queried with NRQL, e.g.
    #   FROM SignalCheckin SELECT percentage(count(*), WHERE compliant IS true)
    newrelic.agent.record_custom_event("SignalCheckin", {
        "intersectionId": iid,
        "intersectionName": plan["intersection_name"],
        "corridor": CORRIDOR,
        "controllerState": state,
        "planVersion": plan["plan_version"],
        "yellowSeconds": yellow,
        "speedMph": plan["speed_mph"],
        "compliant": compliant,
    })

    if not compliant:
        # Logged as a WARNING, not an error: the service itself is working fine.
        log.warning("non-compliant timing pushed intersection=%s plan=%s yellow_s=%.2f",
                    iid, plan["plan_version"], yellow)
    return jsonify({"accepted": True, "plan": plan})


@app.get("/intersections")
def list_intersections():
    """Corridor overview: every intersection with its most recent check-in."""
    rows = query("""
        SELECT i.id, i.name, i.speed_mph, c.plan_version, c.yellow_s, c.compliant,
               c.controller_state, c.at AS last_checkin
        FROM intersections i
        LEFT JOIN LATERAL (
            SELECT * FROM checkins WHERE intersection_id = i.id ORDER BY at DESC LIMIT 1
        ) c ON true
        ORDER BY i.id
    """)
    for r in rows:
        r["yellow_s"] = float(r["yellow_s"]) if r["yellow_s"] is not None else None
        r["last_checkin"] = r["last_checkin"].isoformat(timespec="seconds") if r["last_checkin"] else None
    return jsonify(rows)


@app.get("/intersections/<int:iid>")
def intersection_detail(iid):
    """One intersection: live timing plan plus the last 10 check-ins."""
    row = query("SELECT id, name, corridor, county, speed_mph FROM intersections WHERE id = %s", (iid,), one=True)
    if not row:
        return jsonify({"error": "not found"}), 404
    newrelic.agent.add_custom_attribute("intersectionId", iid)
    row["plan"] = get_plan(iid)
    history = query("SELECT plan_version, yellow_s, compliant, controller_state, at FROM checkins "
                    "WHERE intersection_id = %s ORDER BY at DESC LIMIT 10", (iid,))
    row["history"] = [{**h, "yellow_s": float(h["yellow_s"]), "at": h["at"].isoformat(timespec="seconds")}
                      for h in history]
    return jsonify(row)


@app.post("/reports")
def create_report():
    """A field issue report. Attaches the current plan and dispatches a crew."""
    body = request.get_json(force=True)
    iid = int(body["intersection_id"])
    issue = body.get("issue", "Other")
    plan = get_plan(iid)
    newrelic.agent.add_custom_attribute("intersectionId", iid)
    newrelic.agent.add_custom_attribute("issueType", issue)

    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("INSERT INTO reports (intersection_id, issue, reporter) VALUES (%s, %s, %s) RETURNING id",
                        (iid, issue, body.get("reporter", "unknown")))
            report_id = cur.fetchone()[0]
    finally:
        pool.putconn(conn)

    crew = None
    try:
        # crew-dispatch is instrumented with OpenTelemetry only. The New Relic agent
        # adds a W3C traceparent header to this call, so both sides join one trace.
        resp = requests.post(f"{DISPATCH_URL}/dispatch", json={
            "report_id": report_id, "intersection_id": iid, "intersection_name": plan["intersection_name"],
            "issue": issue, "yellow_s": plan["yellow_s"]}, timeout=5)
        if resp.ok:
            crew = resp.json().get("crew")
    except requests.RequestException as exc:
        log.error("crew dispatch failed report=%s: %s", report_id, exc)

    log.info("field report created id=%s intersection=%s issue=%s crew=%s", report_id, iid, issue, crew)
    return jsonify({"id": report_id, "crew": crew}), 201


@app.get("/healthz")
def healthz():
    newrelic.agent.ignore_transaction()
    return {"status": "ok"}
