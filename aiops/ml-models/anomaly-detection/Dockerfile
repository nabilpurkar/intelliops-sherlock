FROM python:3.12-slim AS base

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p /models && chown 1000:1000 /models

COPY --chown=1000:1000 . .

USER 1000

EXPOSE 8080

CMD ["python", "predict.py"]
