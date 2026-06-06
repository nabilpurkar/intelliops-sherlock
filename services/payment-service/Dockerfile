FROM python:3.12-slim
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN useradd -u 1000 -m app
USER 1000
WORKDIR /app
COPY main.py .
EXPOSE 8002
CMD ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8002"]
