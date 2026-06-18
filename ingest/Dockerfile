FROM python:3.11-slim

WORKDIR /app

# System deps for lxml (needed by ebooklib)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2 \
    libxslt1.1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PORT=8080

# Single worker process; uvicorn handles async concurrency natively.
CMD exec uvicorn main:app --host 0.0.0.0 --port ${PORT} --workers 1
