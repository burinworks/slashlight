FROM python:3.13-alpine
WORKDIR /app
COPY collector.py aggregate.py ./
COPY dashboard/ ./dashboard/
RUN adduser -D -H slashlight && mkdir -p /data /public && chown slashlight /data /public
USER slashlight
ENV DATA_DIR=/data PUBLIC_DIR=/public PORT=8080 PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["python", "collector.py"]
