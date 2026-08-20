FROM python:3.13-slim

# ffmpeg powers video thumbnails. HEIC needs no system packages: the pillow-heif
# manylinux wheel bundles its own libheif.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MEDIAVAULT_MEDIA_ROOT=/media \
    MEDIAVAULT_THUMB_CACHE=/cache/thumbs

# Port uvicorn binds inside the container. Only worth changing under host
# networking, where there is no port mapping to remap a conflict away and
# something else on the NAS may already be holding 8000.
ENV MEDIAVAULT_BIND_PORT=8000

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Runs unprivileged. The media volume must be readable (and writable, for deletes)
# by this uid — see the PUID note in the README if your NAS uses a different one.
RUN useradd --create-home --uid 1000 mediavault \
    && mkdir -p /cache/thumbs \
    && chown -R mediavault:mediavault /cache
USER mediavault

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import os,urllib.request,sys; p=os.environ.get('MEDIAVAULT_BIND_PORT','8000'); sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{p}/', timeout=4).status == 200 else 1)"

# Shell form so MEDIAVAULT_BIND_PORT is expanded at runtime; `exec` keeps uvicorn
# as PID 1 so it still receives SIGTERM and shuts down cleanly.
#
# --factory: the app reads its config from the environment at call time, so nothing
# is constructed at import and the module stays importable in tests.
CMD ["sh", "-c", "exec uvicorn app.main:create_app --factory --host 0.0.0.0 --port \"${MEDIAVAULT_BIND_PORT:-8000}\" --proxy-headers --forwarded-allow-ips '*'"]
