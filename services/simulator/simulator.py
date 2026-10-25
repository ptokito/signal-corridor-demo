"""
corridor-simulator: generates realistic, repeatable traffic for the demo.

WHERE IT RUNS
  Kubernetes (k3s), namespace "corridor", one pod. Not instrumented: it plays the
  role of the outside world.

WHAT IT SIMULATES (every second, with some randomness)
  1. Signal controllers: each of the 10 intersections checks in with signal-api
     roughly every 8 seconds (about 75 check-ins per minute in total). This is
     machine-to-machine traffic inside the cluster.
  2. Operations staff: engineers open the corridor overview or an intersection
     page through NGINX on the host tier (about 15 page requests per minute).
     These hit the portal exactly as a person would, minus a real browser, so
     they appear in APM but NOT in Browser monitoring (no JavaScript runs).
  3. Field reports: about one issue report every 1 to 2 minutes, which dispatches
     a crew through crew-dispatch.

Rates are tunable with environment variables in k8s/apps.yaml.
"""
import os
import random
import time

import requests

SIGNAL_API = os.environ.get("SIGNAL_API_URL", "http://signal-api:8000")
PORTAL = os.environ.get("PORTAL_URL", "http://localhost")
CHECKIN_SECONDS = float(os.environ.get("CHECKIN_INTERVAL_SECONDS", "8"))
VIEW_PROB = float(os.environ.get("VIEW_PROBABILITY_PER_SECOND", "0.25"))
REPORT_PROB = float(os.environ.get("REPORT_PROBABILITY_PER_SECOND", "0.012"))
ISSUES = ["Signal on flash", "Signal dark (no power)", "Pedestrian button broken",
          "Detector not triggering", "Other"]

session = requests.Session()
session.headers["User-Agent"] = "corridor-simulator/1.0"


def wait_for_intersections():
    """Block until signal-api is up, then return the list of intersection IDs."""
    while True:
        try:
            r = session.get(f"{SIGNAL_API}/intersections", timeout=5)
            r.raise_for_status()
            return [i["id"] for i in r.json()]
        except requests.RequestException as exc:
            print(f"waiting for signal-api: {exc}", flush=True)
            time.sleep(5)


def controller_checkin(iid):
    # Most controllers are normal; a few report coordination or detector states.
    state = random.choices(["normal", "coordinated", "detector-fault"], weights=[85, 13, 2])[0]
    session.post(f"{SIGNAL_API}/checkins", json={"intersection_id": iid, "state": state}, timeout=10)


def staff_view(ids):
    if random.random() < 0.4:
        session.get(f"{PORTAL}/", timeout=10)
    else:
        session.get(f"{PORTAL}/intersections/{random.choice(ids)}", timeout=10)


def field_report(ids):
    session.post(f"{PORTAL}/intersections/{random.choice(ids)}/report",
                 data={"issue": random.choice(ISSUES), "reporter": "Field supervisor"}, timeout=15)


if __name__ == "__main__":
    ids = wait_for_intersections()
    print(f"simulating {len(ids)} intersections; portal at {PORTAL}", flush=True)
    # Stagger the controllers so check-ins are spread evenly across the interval.
    next_checkin = {iid: time.time() + random.uniform(0, CHECKIN_SECONDS) for iid in ids}
    while True:
        now = time.time()
        for iid in ids:
            if now >= next_checkin[iid]:
                next_checkin[iid] = now + CHECKIN_SECONDS * random.uniform(0.8, 1.2)
                try:
                    controller_checkin(iid)
                except requests.RequestException as exc:
                    print(f"check-in failed intersection={iid}: {exc}", flush=True)
        try:
            if random.random() < VIEW_PROB:
                staff_view(ids)
            if random.random() < REPORT_PROB:
                field_report(ids)
        except requests.RequestException as exc:
            print(f"portal request failed: {exc}", flush=True)
        time.sleep(1)
