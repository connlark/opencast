# Pinned base image: the linux/amd64 manifest of
# docker.io/library/python:3.12-alpine (resolved 2026-08-04), used for both
# stages. Cloudflare Containers run amd64 only, and pinning a platform
# manifest (not the multi-arch list) means a mis-targeted build fails instead
# of silently packing arm64 binaries under an amd64 label. Build with
# --platform=linux/amd64.
#
# ffmpeg/ffprobe are compiled in the build stage from the pinned, GPG-verified
# ffmpeg 9.0 release tarball with everything disabled except the exact
# components media_server.py invokes. SBOM.md records the configure line and
# the security-update tracking note: upstream ffmpeg releases are now OURS to
# watch — there are no distro backports here.
FROM docker.io/library/python:3.12-alpine@sha256:aa679aa4eed6eb56c1dc6ad3f1b98b7d2d788fd961596779d188fdedad97fb38 AS build

RUN apk add --no-cache build-base nasm tar xz

# Sources are vendored in vendor/ (tracked in git) so the image build never
# depends on upstream hosting. The sha256 pins below still gate the build, so
# a swapped or corrupted vendor file fails loudly instead of building.
#
# lame 3.100 (from downloads.sourceforge.net/project/lame/lame/3.100/): the
# same upstream version as the Debian libmp3lame the previous (pass0-8) image
# shipped, so the normalize path's encoder behavior does not drift. sha256
# cross-checked against the Alpine aports pin 2026-08-04.
COPY vendor/lame-3.100.tar.gz /tmp/lame-3.100.tar.gz
RUN echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  /tmp/lame-3.100.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/lame-3.100.tar.gz -C /tmp \
    && cd /tmp/lame-3.100 \
    && ./configure --prefix=/usr/local --disable-shared --enable-static --disable-frontend \
    && make -j"$(nproc)" \
    && make install

# ffmpeg 9.0 "Lei" (released 2026-08-03, from ffmpeg.org/releases/).
# Signature verified 2026-08-04 against the FFmpeg release signing key
# FCF986EA15E6E293A5644F10B4322F04D67658D8 (detached signature vendored
# alongside as vendor/ffmpeg-9.0.tar.xz.asc for re-verification); the sha256
# below pins that exact verified tarball.
COPY vendor/ffmpeg-9.0.tar.xz /tmp/ffmpeg-9.0.tar.xz
RUN echo "7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52  /tmp/ffmpeg-9.0.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/ffmpeg-9.0.tar.xz -C /tmp

# Minimal configure: start from --disable-everything and enable ONLY what
# media_server.py runs — mp3 demux/mux/parse/decode, libmp3lame encode, the
# file protocol, and the aresample/aformat/anull filters the normalize path's
# `-ac 1 -ar 44100` graph auto-inserts (abuffer/abuffersink are linked
# unconditionally by configure). Attack surface is compiled out, not flagged
# off: no network, no autodetected external libs, no other codecs or
# protocols, no ffplay/avdevice/swscale. This list must stay derived from
# media_server.py; SBOM.md carries the canonical copy of the configure line.
RUN cd /tmp/ffmpeg-9.0 \
    && ./configure \
        --prefix=/opt/ffmpeg \
        --disable-everything \
        --disable-autodetect \
        --disable-network \
        --disable-doc \
        --disable-debug \
        --disable-ffplay \
        --disable-avdevice \
        --disable-swscale \
        --enable-libmp3lame \
        --enable-protocol=file \
        --enable-demuxer=mp3 \
        --enable-muxer=mp3 \
        --enable-decoder=mp3float \
        --enable-parser=mpegaudio \
        --enable-encoder=libmp3lame \
        --enable-filter=aresample \
        --enable-filter=aformat \
        --enable-filter=anull \
        --extra-cflags="-I/usr/local/include" \
        --extra-ldflags="-L/usr/local/lib -static-libgcc" \
    && make -j"$(nproc)" \
    && make install \
    && strip /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe

FROM docker.io/library/python:3.12-alpine@sha256:aa679aa4eed6eb56c1dc6ad3f1b98b7d2d788fd961596779d188fdedad97fb38

COPY --from=build /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /usr/local/bin/
COPY media_server.py /srv/media_server.py

EXPOSE 8080
CMD ["python3", "/srv/media_server.py"]
