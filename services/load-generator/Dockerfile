FROM python:3.12-slim

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN useradd -u 1000 -m app
USER 1000

WORKDIR /app
COPY locustfile.py .

EXPOSE 8089

CMD ["locust", "--host", "http://order-service.apps.svc.cluster.local:8000", \
     "--web-host", "0.0.0.0", "--web-port", "8089"]
