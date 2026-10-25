# signal-api container image (Python 3.12, Flask, New Relic Python agent).
FROM python:3.12-slim
WORKDIR /app

# Install dependencies first so Docker can cache this layer between code changes.
# "newrelic" in requirements.txt is the New Relic Python APM agent.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# The agent needs no config file: NEW_RELIC_LICENSE_KEY, NEW_RELIC_APP_NAME and the
# other settings come from environment variables in k8s/apps.yaml.
# "newrelic-admin run-program" starts the agent first, then runs gunicorn under it,
# so Flask, requests and psycopg2 are instrumented with no code changes.
EXPOSE 8000
CMD ["newrelic-admin", "run-program", "gunicorn", "-w", "2", "--threads", "4", "-b", "0.0.0.0:8000", "app:app"]
