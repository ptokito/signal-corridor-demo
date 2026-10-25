# crew-dispatch container image (Python 3.12, Flask, OpenTelemetry only).
FROM python:3.12-slim
WORKDIR /app

# opentelemetry-distro: the OpenTelemetry SDK plus the `opentelemetry-instrument` launcher.
# opentelemetry-exporter-otlp-proto-http: sends data to New Relic over OTLP/HTTP.
# `opentelemetry-bootstrap -a install` detects Flask and installs its instrumentation.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && opentelemetry-bootstrap -a install
COPY app.py .

# waitress instead of gunicorn: waitress does not fork worker processes, and
# OpenTelemetry's background export threads do not survive a fork.
# Exporter settings (endpoint, api-key header, service name) come from OTEL_*
# environment variables in k8s/apps.yaml.
EXPOSE 8080
CMD ["opentelemetry-instrument", "waitress-serve", "--port=8080", "--threads=8", "app:app"]
