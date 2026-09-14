"""
VSpo Music — audio-resolve server.

A tiny single-endpoint service: given a YouTube video ID, it uses yt-dlp
(server-side, actively maintained, keeps up with YouTube's anti-bot changes
far better than any pure-Dart or pure-JS on-device library) to resolve a
direct, playable audio stream URL, then either:
  - redirects the client straight to that URL (cheap: no bytes flow through
    this server, just a resolve step), or
  - if that URL turns out to be IP-locked to this server's own egress IP
    (some YouTube signed URLs are), proxies/streams the audio bytes through
    instead.

Start with the redirect path (mode=redirect, the default) since it's far
cheaper on Cloud Run's free egress quota. If audio playback fails on the
phone with the redirected URL (commonly a 403), that's a sign of IP-locking
— switch to mode=proxy for that request and compare.

This is for a single personal user. There is no auth here by design (the
video-ID space is effectively private-enough for personal use, and this
was explicitly asked to stay zero-maintenance/zero-cost), but note this
server is unauthenticated and open to whoever has the URL — do not put
anything sensitive behind it.
"""

import os

from flask import Flask, Response, redirect, request, stream_with_context
import requests
import yt_dlp

app = Flask(__name__)


def resolve_audio_url(video_id: str) -> str:
    """Uses yt-dlp to resolve the best available audio-only stream URL for a
    YouTube video ID. Raises if extraction fails (e.g. blocked, private,
    deleted, age-restricted without cookies configured)."""
    ydl_opts = {
        "format": "bestaudio/best",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "skip_download": True,
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={video_id}", download=False
        )
        return info["url"]


@app.route("/audio")
def audio():
    video_id = request.args.get("id")
    if not video_id:
        return {"error": "missing ?id=<youtube video id>"}, 400

    mode = request.args.get("mode", "redirect")

    try:
        stream_url = resolve_audio_url(video_id)
    except Exception as e:  # noqa: BLE001 — surface any extraction failure as JSON
        return {"error": f"extraction failed: {e}"}, 502

    if mode == "proxy":
        # Streams the actual audio bytes through this server. Costs egress
        # bandwidth on this server's side — use only if the redirect mode
        # gets rejected (403) by the phone due to IP-locking.
        upstream = requests.get(stream_url, stream=True, timeout=30)
        return Response(
            stream_with_context(upstream.iter_content(chunk_size=65536)),
            content_type=upstream.headers.get("Content-Type", "audio/webm"),
            status=upstream.status_code,
        )

    # Default: cheap redirect, no bytes through this server at all.
    return redirect(stream_url, code=302)


@app.route("/")
def health():
    return {"status": "ok", "service": "vspo-music audio resolver"}


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
