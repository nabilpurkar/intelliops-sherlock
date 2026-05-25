FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

RUN adduser --disabled-password --gecos "" appuser
USER appuser

EXPOSE 8002

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8002/health')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8002", "--workers", "2"]
