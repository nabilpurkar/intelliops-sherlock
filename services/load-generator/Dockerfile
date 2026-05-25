FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY locustfile.py .

EXPOSE 8089

# Default: headless mode, 20 users, ramp 2/s, run forever
# Override with env vars: LOCUST_USERS, LOCUST_SPAWN_RATE
CMD ["locust", \
     "--headless", \
     "--users",       "20", \
     "--spawn-rate",  "2", \
     "--host",        "http://order-service:8000"]
