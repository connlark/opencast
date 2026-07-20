# Pinned base image: the linux/amd64 manifest of
# docker.io/library/python:3.12-slim (pulled 2026-07-16). Cloudflare
# Containers run amd64 only, and pinning a platform manifest (not the
# multi-arch list) means a mis-targeted build fails instead of silently
# packing arm64 binaries under an amd64 label. Build with
# --platform=linux/amd64. ffmpeg comes from the Debian trixie repository at
# build time; the installed version is recorded in SBOM.md and must be
# re-verified when the pin moves.
FROM docker.io/library/python:3.12-slim@sha256:cab2dbf575e971934a81e4622f5aba17aa7929719bd7e31033a3a83b97fd0464

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && ffmpeg -version | head -1

COPY media_server.py /srv/media_server.py

EXPOSE 8080
CMD ["python3", "/srv/media_server.py"]
