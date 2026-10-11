FROM python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY classroom_web/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home vaachak
COPY classroom_web/server /app/classroom_web/server
COPY tools/backend_admin.py tools/learning_worker.py tools/run_service.py tools/container_entrypoint.py /app/tools/
RUN mkdir -p /data/audio && chown -R vaachak:vaachak /data /app
ENV PYTHONPATH=/app/classroom_web/server VAACHAK_DATA=/data PYTHONUNBUFFERED=1
# The entrypoint fixes ownership of a fresh disk, then execs as UID 10001.
ENTRYPOINT ["python", "tools/container_entrypoint.py"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fsS "http://127.0.0.1:${PORT:-8000}/api/ready" || exit 1
CMD ["python", "tools/run_service.py"]
