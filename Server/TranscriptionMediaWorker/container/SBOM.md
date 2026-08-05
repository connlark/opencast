# Media Container SBOM

Generated 2026-08-04 from a linux/amd64 image using Alpine and hand-compiled
ffmpeg 9.0 (a 574 MB → 55 MB hardening/size revision). `media_server.py` is
unchanged from the previous image revision.

- Image: registry.cloudflare.com/REPLACE_WITH_ACCOUNT_HASH/your-transcription-media-container:REPLACE_WITH_TAG@sha256:REPLACE_WITH_IMAGE_DIGEST
- Base (both stages): docker.io/library/python:3.12-alpine@sha256:aa679aa4eed6eb56c1dc6ad3f1b98b7d2d788fd961596779d188fdedad97fb38
  (linux/amd64 manifest; Alpine 3.24.1, Python 3.12.13)
- Image build: `podman build --format=docker --platform=linux/amd64 container`
- ffmpeg: 9.0 "Lei", compiled from source in the builder stage (gcc 15.2.0,
  nasm; static ffmpeg libs, `-static-libgcc`). Only ffmpeg + ffprobe ship
  (2,132,080 / 1,910,832 bytes stripped); linked libraries are
  avutil/avcodec/avformat/avfilter/swresample only — no avdevice, no
  swscale, no postproc (removed upstream in 9.0), no ffplay.
- libmp3lame: lame 3.100, compiled static in the builder stage — the same
  upstream version as the Debian `libmp3lame0` the previous image shipped, so
  the normalize path's encoder behavior does not drift.

## Source provenance (vendored in `vendor/`, tracked in git)

| Source | sha256 | Verification |
|---|---|---|
| `ffmpeg-9.0.tar.xz` | `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52` | GPG signature verified 2026-08-04 against the FFmpeg release signing key `FCF986EA15E6E293A5644F10B4322F04D67658D8` (detached sig vendored as `vendor/ffmpeg-9.0.tar.xz.asc`) |
| `lame-3.100.tar.gz` | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` | sha512 cross-checked byte-identical against the Alpine aports `main/lame` pin 2026-08-04 |

Both sha256s are re-verified inside the image build (`sha256sum -c`), so a
swapped vendor file fails the build.

## ffmpeg configure line (canonical copy; must stay derived from media_server.py)

```
./configure \
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
  --extra-cflags=-I/usr/local/include \
  --extra-ldflags='-L/usr/local/lib -static-libgcc'
```

Enabled components map 1:1 to what `media_server.py` invokes: mp3
demux/parse/decode for probe + packet-sum measurement, mp3 mux + stream copy
for chunking, libmp3lame + aresample/aformat/anull (abuffer/abuffersink are
linked unconditionally by configure) for the `-ac 1 -ar 44100` normalize
path, and the `file` protocol only. Everything else — every other codec,
demuxer, protocol, filter, device, and all network code — is compiled out,
not flagged off. (`test_media_server.py` runs on the HOST's ffmpeg and may
use lavfi there; the container binary deliberately has no lavfi.)

## Security updates require active tracking

The previous image took ffmpeg from Debian trixie, which backported security
fixes. This image compiles a pinned upstream release, so its maintainer must
track and apply updates. Watch:

- https://ffmpeg.org/security.html — per-release CVE fix lists (the 9.0.x
  point releases land there and on https://ffmpeg.org/download.html)
- https://ffmpeg.org/releases/ — new 9.0.x tarballs (verify the `.asc`
  against key `FCF986EA15E6E293A5644F10B4322F04D67658D8`, update
  `vendor/` + the Dockerfile sha256, roll a new container image)
- Alpine/python base CVEs ride the `python:3.12-alpine` digest — bump the
  pinned digest and rebuild to pick them up.
- lame 3.100 (2017) is the long-frozen upstream final; Debian carries it
  unpatched too. Mitigation if that changes: it only touches the normalize
  path, after ffmpeg has already demuxed/decoded the input.

The exposure is narrow by construction — the only bytes that reach these
binaries are R2-staged job audio via the `file` protocol on a no-internet
container — but a demuxer/decoder CVE in the mp3 path is still reachable by
untrusted media, so point releases should be adopted promptly.

## apk packages (runtime stage, `apk list --installed`)

```
.python-rundeps-20260616.002526
alpine-baselayout-3.7.2-r1
alpine-baselayout-data-3.7.2-r1
alpine-keys-2.6-r0
alpine-release-3.24.1-r0
apk-tools-3.0.6-r0
busybox-1.37.0-r31
busybox-binsh-1.37.0-r31
ca-certificates-20260611-r0
ca-certificates-bundle-20260611-r0
gdbm-1.26-r0
keyutils-libs-1.6.3-r4
krb5-conf-1.0-r2
krb5-libs-1.22.2-r1
libapk-3.0.6-r0
libbz2-1.0.8-r6
libcom_err-1.47.4-r0
libcrypto3-3.5.7-r0
libffi-3.5.2-r1
libintl-1.0-r0
libncursesw-6.6_p20260516-r0
libnsl-2.0.1-r2
libpanelw-6.6_p20260516-r0
libssl3-3.5.7-r0
libtirpc-1.3.5-r1
libtirpc-conf-1.3.5-r1
libuuid-2.42-r0
libverto-0.3.2-r2
musl-1.2.6-r2
musl-utils-1.2.6-r2
ncurses-terminfo-base-6.6_p20260516-r0
readline-8.3.3-r1
scanelf-1.3.9-r1
sqlite-libs-3.53.2-r0
ssl_client-1.37.0-r31
tzdata-2026b-r0
xz-libs-5.8.3-r0
zlib-1.3.2-r0
```
