# corridor-simulator container image. Only needs the requests library.
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir requests==2.32.3
COPY simulator.py .
# -u: unbuffered output, so `kubectl logs` shows lines immediately.
CMD ["python", "-u", "simulator.py"]
