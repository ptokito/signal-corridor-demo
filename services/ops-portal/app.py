"""
ops-portal: the Operations Portal traffic engineers use to watch the corridor.

WHERE IT RUNS
  The host tier: a regular Ubuntu virtual machine (EC2 on AWS, or your local VM),
  run by gunicorn on 127.0.0.1:8000 behind NGINX on port 80. It is the only
  part of the system a person's web browser talks to.

WHAT IT DOES
  /                          corridor overview: all 10 intersections, latest status
  /intersections/<id>        one intersection: live timing plan, recent check-ins,
                             and a form to report a field issue
  /intersections/<id>/report submits that form, which dispatches a crew

  It holds no data itself. Every page calls signal-api (on Kubernetes) over HTTP.

HOW IT IS MONITORED
  New Relic Python APM agent, started by `newrelic-admin run-program` in the
  systemd unit (see scripts/host-bootstrap.sh and scripts/local-setup.sh).
  The agent also INJECTS THE BROWSER AGENT automatically into every HTML page it
  serves, so real users' page loads, JavaScript errors and Core Web Vitals are
  captured without editing the templates.
"""
import logging
import os

import newrelic.agent
import requests
from flask import Flask, redirect, render_template, request, url_for

SIGNAL_API_URL = os.environ.get("SIGNAL_API_URL", "http://localhost:30081")
MIN_YELLOW_SECONDS = 3.0
ISSUES = ["Signal on flash", "Signal dark (no power)", "Yellow seems too short",
          "Pedestrian button broken", "Detector not triggering", "Other"]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s ops-portal %(message)s")
log = logging.getLogger("ops-portal")
app = Flask(__name__)


def api_get(path):
    """GET from signal-api and return parsed JSON (raises on failure)."""
    resp = requests.get(f"{SIGNAL_API_URL}{path}", timeout=8)
    resp.raise_for_status()
    return resp.json()


@app.context_processor
def constants():
    # Makes the 3-second rule available to every template for red/green styling.
    return {"min_yellow": MIN_YELLOW_SECONDS}


@app.get("/")
def overview():
    try:
        intersections = api_get("/intersections")
    except requests.RequestException as exc:
        log.error("signal-api unavailable: %s", exc)
        return render_template("error.html", message="Corridor data is unavailable right now."), 502
    flagged = sum(1 for i in intersections if i["compliant"] is False)
    newrelic.agent.add_custom_attribute("intersectionsFlagged", flagged)
    return render_template("overview.html", intersections=intersections, flagged=flagged)


@app.get("/intersections/<int:iid>")
def intersection(iid):
    newrelic.agent.add_custom_attribute("intersectionId", iid)
    try:
        detail = api_get(f"/intersections/{iid}")
    except requests.HTTPError as exc:
        if exc.response is not None and exc.response.status_code == 404:
            return render_template("error.html", message=f"No intersection with ID {iid}."), 404
        raise
    return render_template("intersection.html", i=detail, issues=ISSUES, submitted=request.args.get("report"))


@app.post("/intersections/<int:iid>/report")
def report(iid):
    issue = request.form.get("issue", "Other")
    newrelic.agent.add_custom_attribute("intersectionId", iid)
    newrelic.agent.add_custom_attribute("issueType", issue)
    try:
        resp = requests.post(f"{SIGNAL_API_URL}/reports", json={
            "intersection_id": iid, "issue": issue, "reporter": request.form.get("reporter", "TOC operator")},
            timeout=10)
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("report submission failed intersection=%s: %s", iid, exc)
        return render_template("error.html", message="The report could not be submitted. Please try again."), 502
    result = resp.json()
    log.info("field report submitted id=%s intersection=%s issue=%s", result["id"], iid, issue)
    return redirect(url_for("intersection", iid=iid, report=result["id"]))


@app.get("/healthz")
def healthz():
    newrelic.agent.ignore_transaction()
    return {"status": "ok"}
