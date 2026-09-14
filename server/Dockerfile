FROM python:3.12-slim

WORKDIR /app

# ffmpeg isn't strictly required for URL resolution (we don't download/
# transcode anything here), but yt-dlp sometimes wants it available for
# format probing on certain videos, and the image cost is small.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Cloud Run sets $PORT; gunicorn binds to it. 1 worker/thread is plenty for
# personal single-user use and keeps memory usage (hence cost risk) minimal.
CMD exec gunicorn --bind 0.0.0.0:${PORT:-8080} --workers 1 --threads 4 --timeout 60 app:app
