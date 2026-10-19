#!/usr/bin/env bash
# The local PostgreSQL topology for the Workers' Miniflare suites: one container
# on 127.0.0.1 (Podman first; Docker through OPENCAST_CONTAINER_RUNTIME, whose
# daemon path is unverified here), production's single-runtime-role install order
# applied from the unmodified postgres/ files into a connection-free template,
# and opencast_dev cloned from it. Runs under macOS's /bin/bash 3.2 and Linux bash 5.
#
#   up | install | down | reset | status | provenance | runtime | sql <database> [role] | prune
#
# OPENCAST_PG_CONTAINER      container name (opencast-postgres-local); the volume is <name>-data
# OPENCAST_PG_PORT           published on 127.0.0.1 only (55432)
# OPENCAST_PG_HOST           the host transport's server (127.0.0.1); the container
#                            transport publishes on loopback and refuses any other
# OPENCAST_PG_IMAGE          PostgreSQL 18.6's multi-platform index by default; the marker
#                            records the platform image the runtime runs
# OPENCAST_PG_PSQL           container: psql in the container over its Unix socket as postgres;
#                            host: the host's psql over TCP to OPENCAST_PG_HOST:OPENCAST_PG_PORT (CI)
# OPENCAST_CONTAINER_RUNTIME podman or docker; unset, podman when on PATH, else docker
# OPENCAST_PG_SOURCE         the postgres/ directory to install (this script's ../)
#
# The passwords are fixed local constants, never secrets: postgres is
# opencast-local-postgres and opencast_local_<role> is opencast-local-<role>.
# The superuser is orchestration only; tests, proxies and Workers never hold it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
container=${OPENCAST_PG_CONTAINER:-opencast-postgres-local}
port=${OPENCAST_PG_PORT:-55432}
# PostgreSQL 18.6's index: each runtime selects its own platform's image from it.
index_digest=sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336
image=${OPENCAST_PG_IMAGE:-docker.io/library/postgres@$index_digest}
pg_host=${OPENCAST_PG_HOST:-127.0.0.1}
transport=${OPENCAST_PG_PSQL:-container}
container_runtime=${OPENCAST_CONTAINER_RUNTIME:-}
source_dir=$(cd "${OPENCAST_PG_SOURCE:-$here/..}" && pwd)
volume=$container-data
owner=opencast_local_owner
runtime=opencast_local_runtime
reader=opencast_local_reader
# Production's single-runtime-role order (postgres/README.md), reader-grants.sql
# last; these twelve are the marker's inputs. reader-stats-grant.sql is a
# superuser role grant, outside the template.
files='migrations/0001_slice_a.sql runtime-grants.sql migrations/0002_slice_b.sql
runtime-grants-slice-b.sql migrations/0003_delivery_member.sql
migrations/0004_identity_delivery_support.sql runtime-grants-slice-c.sql
runtime-grants-slice-d.sql runtime-grants-slice-e.sql runtime-grants-slice-f.sql
runtime-grants-integration.sql reader-grants.sql'

say() { printf 'local-postgres: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
usage() { say "usage: local-postgres.sh up|install|down|reset|status|provenance|runtime|sql <database> [role]|prune"; exit 2; }

case $port in '' | *[!0-9]*) die "OPENCAST_PG_PORT must be a port number, not $port" ;; esac
case $transport in
  container)
    [ "$pg_host" = 127.0.0.1 ] ||
      die "OPENCAST_PG_HOST=$pg_host needs OPENCAST_PG_PSQL=host: the container publishes on 127.0.0.1 only" ;;
  host)
    command -v psql >/dev/null 2>&1 && command -v pg_isready >/dev/null 2>&1 ||
      die "OPENCAST_PG_PSQL=host needs psql and pg_isready on PATH"
    # One endpoint, this script's own: an inherited libpq setting never redirects
    # it, and each one replaced is named. The read-backs must see the role
    # defaults, never a caller's session options.
    for name in PGHOST PGHOSTADDR PGPORT PGSERVICE PGSERVICEFILE PGSSLMODE PGOPTIONS PGUSER PGDATABASE; do
      if eval "[ -n \"\${$name+set}\" ]"; then say "overriding inherited $name"; unset "$name"; fi
    done
    export PGHOST=$pg_host PGPORT=$port PGSSLMODE=disable ;;
  *) die "OPENCAST_PG_PSQL must be container or host, not $transport" ;;
esac

password_for() {
  case $1 in
    postgres) printf '%s' opencast-local-postgres ;;
    "$owner") printf '%s' opencast-local-owner ;;
    "$runtime") printf '%s' opencast-local-runtime ;;
    "$reader") printf '%s' opencast-local-reader ;;
    *) return 1 ;;
  esac
}

where() { if [ "$transport" = host ]; then printf '%s' "$PGHOST:$PGPORT"; else printf '%s' "container $container"; fi; }

# The container CLI, resolved only where a container is touched: never by the
# host transport's install, status or sql (CI).
ctr() { "$container_runtime" "$@"; }
use_runtime() {
  [ -z "${runtime_kind:-}" ] || return 0
  if [ -z "$container_runtime" ]; then
    if command -v podman >/dev/null 2>&1; then container_runtime=podman
    elif command -v docker >/dev/null 2>&1; then container_runtime=docker; fi
  fi
  [ -n "$container_runtime" ] && command -v "$container_runtime" >/dev/null 2>&1 ||
    die "install Podman (or Docker) or set OPENCAST_CONTAINER_RUNTIME"
  case ${container_runtime##*/} in
    podman) runtime_kind=podman ;;
    docker) runtime_kind=docker ;;
    *) die "OPENCAST_CONTAINER_RUNTIME must name podman or docker, not $container_runtime" ;;
  esac
}

# exists container|volume <name>: 0 present, 1 absent. Any other failure (a
# daemon or CLI error) dies with its message; it never reads as absence.
exists() {
  local err code=0
  err=$(ctr "$1" inspect --format '{{.Name}}' "$2" </dev/null 2>&1 >/dev/null) || code=$?
  [ "$code" -ne 0 ] || return 0
  case $(printf '%s' "$err" | tr '[:upper:]' '[:lower:]') in *'no such '*) return 1 ;; esac
  die "$container_runtime $1 inspect $2 failed: ${err:-exit $code}"
}

# pg <database> <role> [psql options]: one psql session whose input is stdin.
# container: the Unix socket (local trust, orchestration only); host: TCP, SCRAM.
pg() {
  local database=$1 role=$2
  shift 2
  if [ "$transport" = host ]; then
    PGPASSWORD=$(password_for "$role" || printf '%s' "${PGPASSWORD:-}") \
      psql -X -w -v ON_ERROR_STOP=1 -U "$role" -d "$database" "$@"
  else
    ctr exec -i --user postgres "$container" psql -X -v ON_ERROR_STOP=1 -U "$role" -d "$database" "$@"
  fi
}

# quiet <database> <role> [psql options]: pg with stdout dropped; on failure the
# first server ERROR (or psql's whole stderr) becomes this script's message.
quiet() {
  local err message code=0
  err=$(mktemp "${TMPDIR:-/tmp}/local-postgres.XXXXXX")
  pg "$@" -q >/dev/null 2>"$err" || code=$?
  if [ "$code" -ne 0 ]; then
    message=$(sed -n 's/^.*ERROR:  //p' "$err" | head -n 1)
    [ -n "$message" ] || message=$(cat "$err")
    rm -f "$err"
    die "${message:-psql exited $code}"
  fi
  rm -f "$err"
}

# ready <attempts>: over TCP, not the socket, because the image's init-time
# server listens on the socket alone; one exec for the whole wait, since every
# podman exec holds a conmon for 300 s.
ready() {
  if [ "$transport" = host ]; then
    local i=1
    until pg_isready -q -h "$PGHOST" -p "$PGPORT" -U postgres -d postgres; do
      [ "$i" -lt "$1" ] || return 1
      i=$((i + 1))
      sleep 0.5
    done
  else
    ctr exec "$container" sh -c 'i=1; until pg_isready -q -h 127.0.0.1 -p 5432 -U postgres -d postgres; do
      [ "$i" -lt "$1" ] || exit 1; i=$((i + 1)); sleep 0.5; done' sh "$1" </dev/null 2>/dev/null
  fi
}

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

# The SHA-256 of the twelve files concatenated in install order.
files_hash() {
  local f
  for f in $files; do [ -f "$source_dir/$f" ] || die "missing $source_dir/$f"; done
  for f in $files; do cat "$source_dir/$f"; done | sha256
}

# The platform image a runtime runs, as one manifest digest: the image's
# RepoDigests without their repository prefix, plus the container's ImageDigest
# (Podman records it; Docker has none), less the known index digest. The
# container's own digest wins when it remains; otherwise exactly one remaining
# digest resolves, and none or several stay unresolved (empty, index-not-child,
# multiple). An image-config ID is a handle here, never a recorded digest.
resolve() { # resolve <image id> [container ImageDigest]
  local listed candidates rest
  listed=$(ctr image inspect --format '{{json .RepoDigests}}' "$1" </dev/null) ||
    die "image provenance error: no metadata for image $1"
  candidates=$({ printf '%s\n' "$listed" | tr -d '[]" ' | tr ',' '\n' | sed 's/^.*@//'
    [ -z "${2:-}" ] || printf '%s\n' "$2"; } | grep -E '^sha256:[0-9a-f]{64}$' | sort -u) || true
  rest=$(printf '%s\n' "$candidates" | grep -v -x -F "$index_digest" | grep .) || true
  if [ -n "${2:-}" ] && printf '%s\n' "$rest" | grep -q -x -F "$2"; then printf '%s\n' "$2"
  elif [ -z "$rest" ] && [ -n "$candidates" ]; then echo 'unresolved: index-not-child'
  elif [ -z "$rest" ]; then echo 'unresolved: empty'
  elif [ "$(printf '%s\n' "$rest" | wc -l | tr -d ' ')" = 1 ]; then printf '%s\n' "$rest"
  else echo 'unresolved: multiple'; fi
}

platform_of() {
  ctr image inspect --format '{{.Os}}/{{.Architecture}}' "$1" </dev/null ||
    die "image provenance error: no metadata for image $1"
}

# requested|resolved|platform of the container.
container_provenance() {
  local id digest='' resolved platform
  id=$(ctr container inspect --format '{{.Image}}' "$container" </dev/null) ||
    die "image provenance error: cannot inspect $container"
  if [ "$runtime_kind" = podman ]; then
    digest=$(ctr container inspect --format '{{.ImageDigest}}' "$container" </dev/null) ||
      die "image provenance error: cannot inspect $container"
  fi
  # Callers run this inside $( ), where bash drops errexit: refusals pass on explicitly.
  resolved=$(resolve "$id" "$digest") || exit 1
  platform=$(platform_of "$id") || exit 1
  printf '%s|%s|%s\n' "$image" "$resolved" "$platform"
}

# The resolved digest of $image itself, pulled first when absent.
requested_resolved() {
  local id
  if ! id=$(ctr image inspect --format '{{.Id}}' "$image" </dev/null 2>/dev/null); then
    say "pulling $image"
    ctr image pull "$image" </dev/null >/dev/null || die "cannot pull $image"
    id=$(ctr image inspect --format '{{.Id}}' "$image" </dev/null) || die "image provenance error: no metadata for $image"
  fi
  resolve "$id"
}

# The marker's provenance: what the container runs, or on the host transport,
# which consults no container runtime, the literal unresolved.
provenance() {
  if [ "$transport" = host ]; then printf '%s|unresolved|unresolved\n' "$image"; else container_provenance; fi
}

# marker|datistemplate|datallowconn, '-' for an absent marker or template.
sql_state() {
  cat <<'SQL'
SELECT to_regclass('public.opencast_local_install') IS NOT NULL AS has_marker \gset
\if :has_marker
SELECT coalesce(max(files_sha256), '-') AS marker FROM public.opencast_local_install WHERE template = 'opencast_template' \gset
\else
\set marker '-'
\endif
SELECT :'marker' || '|' || coalesce((SELECT datistemplate::text || '|' || datallowconn::text
  FROM pg_database WHERE datname = 'opencast_template'), '-|-');
SQL
}

# Create an absent role with production's posture (setup-private-fixture.sh:
# runtime and reader LOGIN NOINHERIT with its four settings); refuse an existing
# one whose attributes, settings, password kind or memberships differ. The owner
# carries search_path at ROLE level so every clone inherits it.
sql_roles() {
  cat <<'SQL'
DO $roles$
DECLARE
  settings constant text[] := ARRAY['idle_in_transaction_session_timeout=10s', 'lock_timeout=2s',
    'search_path=opencast, pg_catalog', 'statement_timeout=5s'];
  want record;
  same boolean;
BEGIN
  FOR want IN SELECT * FROM (VALUES
      ('opencast_local_owner', true, ARRAY['search_path=opencast, pg_catalog'], ARRAY[]::text[], 'opencast-local-owner'),
      ('opencast_local_runtime', false, settings, ARRAY[]::text[], 'opencast-local-runtime'),
      ('opencast_local_reader', false, settings, ARRAY['pg_read_all_stats'], 'opencast-local-reader'))
    AS v(name, inherit, config, groups, password)
  LOOP
    SELECT a.rolcanlogin AND NOT a.rolsuper AND NOT a.rolcreatedb AND NOT a.rolcreaterole
        AND NOT a.rolreplication AND NOT a.rolbypassrls AND a.rolinherit = want.inherit
        AND a.rolconnlimit = -1 AND a.rolpassword LIKE 'SCRAM-SHA-256$%'
        AND ARRAY(SELECT c FROM unnest(s.setconfig) AS c ORDER BY c) = want.config
        AND ARRAY(SELECT g.rolname::text FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
          WHERE m.member = a.oid) <@ want.groups
      INTO same
      FROM pg_authid a LEFT JOIN pg_db_role_setting s ON s.setrole = a.oid AND s.setdatabase = 0
      WHERE a.rolname = want.name;
    IF FOUND THEN
      IF same IS NOT TRUE THEN RAISE EXCEPTION 'role % differs: run reset', want.name; END IF;
      CONTINUE;
    END IF;
    EXECUTE format('CREATE ROLE %I LOGIN %s NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
      want.name, CASE WHEN want.inherit THEN 'INHERIT' ELSE 'NOINHERIT' END, want.password);
    EXECUTE format('ALTER ROLE %I SET search_path = opencast, pg_catalog', want.name);
    IF NOT want.inherit THEN
      EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', want.name, '5s');
      EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', want.name, '10s');
      EXECUTE format('ALTER ROLE %I SET lock_timeout = %L', want.name, '2s');
    END IF;
  END LOOP;
END
$roles$;
SQL
}

# An unmarked template is a crashed install's leftover: nothing can be cloned from it.
sql_fresh_template() {
  cat <<'SQL'
SELECT format('ALTER DATABASE %I IS_TEMPLATE false', datname) FROM pg_database
  WHERE datname = 'opencast_template' AND datistemplate \gexec
DROP DATABASE IF EXISTS opencast_template;
CREATE DATABASE opencast_template OWNER opencast_local_owner;
SQL
}

# After the owner sessions end: no session can connect to the template again,
# so a clone never waits on one. The marker lives in the maintenance database.
# image is the legacy install-time string; image_requested, image_resolved and
# platform are the provenance the readers use.
sql_seal() {
  cat <<'SQL'
BEGIN;
ALTER DATABASE opencast_template WITH IS_TEMPLATE true ALLOW_CONNECTIONS false;
CREATE TABLE IF NOT EXISTS public.opencast_local_install(template text PRIMARY KEY, files_sha256 text,
  installed_at timestamptz, server_version text, image text);
ALTER TABLE public.opencast_local_install ADD COLUMN IF NOT EXISTS image_requested text,
  ADD COLUMN IF NOT EXISTS image_resolved text, ADD COLUMN IF NOT EXISTS platform text;
INSERT INTO public.opencast_local_install VALUES ('opencast_template', :'hash', now(), current_setting('server_version'), :'requested',
    :'requested', :'resolved', :'platform')
  ON CONFLICT (template) DO UPDATE SET files_sha256 = excluded.files_sha256, installed_at = excluded.installed_at,
    server_version = excluded.server_version, image = excluded.image, image_requested = excluded.image_requested,
    image_resolved = excluded.image_resolved, platform = excluded.platform;
COMMIT;
SQL
}

# Every install: a marker from before the provenance columns gains them (the DDL
# only then), and a changed runtime image is recorded. installed_at and
# files_sha256 never move; an unchanged provenance updates no row.
sql_upgrade() {
  cat <<'SQL'
SELECT count(*) = 3 AS upgraded FROM information_schema.columns WHERE table_schema = 'public'
  AND table_name = 'opencast_local_install' AND column_name IN ('image_requested', 'image_resolved', 'platform') \gset
\if :upgraded
\else
ALTER TABLE public.opencast_local_install ADD COLUMN IF NOT EXISTS image_requested text,
  ADD COLUMN IF NOT EXISTS image_resolved text, ADD COLUMN IF NOT EXISTS platform text;
\endif
UPDATE public.opencast_local_install SET image_requested = :'requested', image_resolved = :'resolved', platform = :'platform'
  WHERE template = 'opencast_template' AND (image_requested IS DISTINCT FROM :'requested'
    OR image_resolved IS DISTINCT FROM :'resolved' OR platform IS DISTINCT FROM :'platform');
SQL
}

# requested|resolved|platform from the marker; '-|-|-' before the upgrade.
sql_provenance() {
  cat <<'SQL'
SELECT count(*) = 3 AS upgraded FROM information_schema.columns WHERE table_schema = 'public'
  AND table_name = 'opencast_local_install' AND column_name IN ('image_requested', 'image_resolved', 'platform') \gset
\if :upgraded
SELECT coalesce(image_requested, '-') || '|' || coalesce(image_resolved, '-') || '|' || coalesce(platform, '-')
  FROM public.opencast_local_install WHERE template = 'opencast_template';
\else
SELECT '-|-|-';
\endif
SQL
}

sql_dev() {
  cat <<'SQL'
SELECT 'CREATE DATABASE opencast_dev TEMPLATE opencast_template OWNER opencast_local_owner'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'opencast_dev') \gexec
SQL
}

sql_summary() {
  cat <<'SQL'
SELECT current_setting('server_version') || '|' || files_sha256 || '|' || image_requested || '|' || image_resolved
    || '|' || platform
  FROM public.opencast_local_install WHERE template = 'opencast_template';
SQL
}

build() {
  local hash=$1 requested=$2 resolved=$3 platform=$4 f var
  say "building opencast_template from $source_dir"
  sql_fresh_template | quiet postgres postgres
  for f in $files; do
    case $f in reader-grants.sql) var=reader_role=$reader ;; *) var=runtime_role=$runtime ;; esac
    quiet opencast_template "$owner" -v "$var" <"$source_dir/$f"
  done
  # The README's superuser step: the owner cannot grant predefined-role membership.
  quiet postgres postgres -v "reader_role=$reader" <"$source_dir/reader-stats-grant.sql"
  sql_seal | quiet postgres postgres -v "hash=$hash" -v "requested=$requested" -v "resolved=$resolved" \
    -v "platform=$platform"
}

cmd_install() {
  local hash state marker facts requested resolved platform
  ready 120 || die "PostgreSQL is not ready ($(where))"
  [ -f "$source_dir/reader-stats-grant.sql" ] || die "missing $source_dir/reader-stats-grant.sql"
  hash=$(files_hash)
  state=$(sql_state | pg postgres postgres -qAt) || die "cannot read the install state ($(where))"
  marker=${state%%|*}
  # Never a silent rebuild under a running suite.
  if [ "$marker" != - ] && [ "$marker" != "$hash" ]; then die "template is stale: run reset"; fi
  facts=$(provenance)
  IFS='|' read -r requested resolved platform <<EOF
$facts
EOF
  sql_roles | quiet postgres postgres
  if [ "$marker" = - ]; then
    build "$hash" "$requested" "$resolved" "$platform"
  elif [ "${state#*|}" != 'true|false' ]; then
    die "opencast_template does not match its install marker: run reset"
  fi
  sql_upgrade | quiet postgres postgres -v "requested=$requested" -v "resolved=$resolved" -v "platform=$platform"
  sql_dev | quiet postgres postgres
  say "installed: opencast_template sha256 $hash, opencast_dev present"
}

cmd_status() {
  local state hash facts requested resolved platform
  ready 1 || { say "not ready ($(where))"; return 1; }
  state=$(sql_state | pg postgres postgres -qAt) || { say "the install marker is unreadable"; return 1; }
  [ "${state%%|*}" != - ] || { say "no install marker: run install"; return 1; }
  case ${state#*|} in true\|*) ;; *) say "opencast_template is not a template: run reset"; return 1 ;; esac
  hash=$(files_hash 2>/dev/null) || hash=unreadable
  if [ "$hash" = "${state%%|*}" ]; then
    printf 'ready: opencast_template sha256 %s, matching %s\n' "$hash" "$source_dir"
  else
    printf 'ready: opencast_template sha256 %s; %s hashes %s, so install will refuse: run reset\n' \
      "${state%%|*}" "$source_dir" "$hash"
  fi
  facts=$(sql_provenance | pg postgres postgres -qAt) || { say "the install marker is unreadable"; return 1; }
  IFS='|' read -r requested resolved platform <<EOF
$facts
EOF
  printf 'image_requested %s\nimage_resolved %s\nplatform %s\ntransport %s\n' "$requested" "$resolved" "$platform" "$transport"
  # The provenance gate: the container transport must know what it runs. The
  # host transport consults no runtime (CI's service), so it only reports.
  if [ "$transport" = container ]; then
    case $resolved in
      unresolved*) say "image provenance $resolved"; return 1 ;;
      -) say "image provenance unrecorded: run install"; return 1 ;;
    esac
  fi
}

machine_up() {
  local state log i=1
  [ "$runtime_kind" = podman ] && [ "$(uname -s)" = Darwin ] || return 0
  state=$(ctr machine inspect --format '{{.State}}' </dev/null) || die "no Podman machine to start"
  [ "$state" != running ] || return 0
  log=${TMPDIR:-/tmp}/$container-machine-start.log
  say "starting the Podman machine (output: $log)"
  # Detached and never on a captured pipe: the VM's daemons inherit the caller's fds.
  nohup "$container_runtime" machine start </dev/null >"$log" 2>&1 &
  until [ "$(ctr machine inspect --format '{{.State}}' </dev/null 2>/dev/null)" = running ] &&
    ctr info </dev/null >/dev/null 2>&1; do
    [ "$i" -lt 180 ] || die "the Podman machine did not start (output: $log)"
    i=$((i + 1))
    sleep 1
  done
}

# An existing container must run the image $image resolves to; when either side
# is unresolved, the requested references are compared instead, with a warning.
container_up() {
  local facts have want requested published
  if exists container "$container"; then
    facts=$(container_provenance)
    have=$(printf '%s' "$facts" | cut -d'|' -f2)
    want=$(requested_resolved)
    case "$have|$want" in
      unresolved*|*'|unresolved'*)
        case $have in
          unresolved*) say "warning: image provenance $have; comparing requested references" ;;
          *) say "warning: image provenance $want for $image; comparing requested references" ;;
        esac
        requested=$(ctr container inspect --format '{{.Config.Image}}' "$container" </dev/null)
        [ "$requested" = "$image" ] || die "container $container runs $requested, not $image: run reset" ;;
      *) [ "$have" = "$want" ] || die "container $container runs $have, not $want ($image): run reset" ;;
    esac
    if [ "$(ctr container inspect --format '{{.State.Running}}' "$container" </dev/null)" != true ]; then
      ctr start "$container" </dev/null >/dev/null
    fi
  else
    say "creating $container from $image"
    ctr run -d --name "$container" -p "127.0.0.1:$port:5432" \
      -e POSTGRES_PASSWORD=opencast-local-postgres -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
      -v "$volume:/var/lib/postgresql" "$image" </dev/null >/dev/null
  fi
  ready 240 || die "PostgreSQL in $container did not become ready"
  published=$(ctr port "$container" 5432/tcp </dev/null)
  [ "$published" = "127.0.0.1:$port" ] || die "container $container publishes $published, not 127.0.0.1:$port: run reset"
}

cmd_down() {
  if exists container "$container"; then
    ctr stop "$container" </dev/null >/dev/null
    ctr rm "$container" </dev/null >/dev/null
    say "removed $container; kept volume $volume"
  fi
}

summary() {
  local facts version files requested resolved platform
  facts=$(sql_summary | pg postgres postgres -qAt)
  IFS='|' read -r version files requested resolved platform <<EOF
$facts
EOF
  printf '%s is up: PostgreSQL %s on 127.0.0.1:%s (%s)\n' "$container" "$version" "$port" "$container_runtime"
  printf '  image     %s\n' "$requested"
  printf '  runs      %s (%s)\n' "$resolved" "$platform"
  printf '  template  opencast_template (IS_TEMPLATE, ALLOW_CONNECTIONS false), sha256 %s\n' "$files"
  printf '  dev       postgres://%s@127.0.0.1:%s/opencast_dev\n' "$runtime" "$port"
  printf '  roles     %s, %s, %s; postgres for orchestration only\n' "$owner" "$runtime" "$reader"
  printf '  passwords the fixed local constants in local-postgres.sh\n'
}

[ "$transport" = host ] || use_runtime
case ${1:-} in
  up) use_runtime; machine_up; container_up; cmd_install; summary ;;
  install) cmd_install ;;
  down) use_runtime; machine_up; cmd_down ;;
  reset)
    use_runtime
    machine_up
    cmd_down
    if exists volume "$volume"; then ctr volume rm "$volume" </dev/null >/dev/null; say "removed volume $volume"; fi
    container_up; cmd_install; summary ;;
  status) cmd_status ;;
  provenance)
    # Read-only: what the container runs, by the marker's rule; nothing written.
    use_runtime
    exists container "$container" || die "no container $container"
    facts=$(container_provenance)
    IFS='|' read -r requested resolved platform <<EOF
$facts
EOF
    printf 'image_requested %s\nimage_resolved %s\nplatform %s\nruntime %s\n' "$requested" "$resolved" "$platform" "$container_runtime"
    case $resolved in unresolved*) say "image provenance $resolved"; exit 1 ;; esac ;;
  # Read-only: the container CLI this script selects, for a caller that inspects it too.
  runtime) use_runtime; printf '%s\n' "$container_runtime" ;;
  sql) [ $# -ge 2 ] && [ $# -le 3 ] || usage; pg "$2" "${3:-postgres}" -qAt ;;
  prune)
    shift
    # storage.mjs owns the registry and the death rule; it reads this port.
    export OPENCAST_PG_PORT=$port
    exec node "$(cd "$here/../.." && pwd)/tests/storage.mjs" prune "$@" ;;
  *) usage ;;
esac
