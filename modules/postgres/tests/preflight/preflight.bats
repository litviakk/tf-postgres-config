#!/usr/bin/env bats
# Layer 2 — preflight.sh tests against a live Docker PostgreSQL container.
#
# Prerequisites:
#   docker, terraform >= 1.6, bats-core >= 1.7
#
# Run from repo root:
#   bats modules/postgres/tests/preflight/preflight.bats

CONTAINER="pg_preflight_test"
PG_IMAGE="postgres:17"

# ---------------------------------------------------------------------------
# Suite setup / teardown — runs once per file
# ---------------------------------------------------------------------------

setup_file() {
  # Render both variants of the preflight script via Terraform.
  terraform -chdir="$BATS_TEST_DIRNAME" init -reconfigure >/dev/null 2>&1
  terraform -chdir="$BATS_TEST_DIRNAME" apply -auto-approve >/dev/null 2>&1
  export SCRIPT_AUTO SCRIPT_MISMATCH
  SCRIPT_AUTO=$(terraform -chdir="$BATS_TEST_DIRNAME" output -raw preflight_auto_conf_d)
  SCRIPT_MISMATCH=$(terraform -chdir="$BATS_TEST_DIRNAME" output -raw preflight_mismatched_conf_d)

  # Start a fresh PostgreSQL container.
  # --init: tini is PID 1, so stopping the PG process does not kill the container.
  docker rm -f "$CONTAINER" 2>/dev/null || true
  docker run -d --name "$CONTAINER" --init \
    -e POSTGRES_PASSWORD=test \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$PG_IMAGE"

  # Wait for PostgreSQL to be ready.
  local i=0
  until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -ge 30 ] && { echo "PostgreSQL did not start in time" >&2; exit 1; }
    sleep 1
  done

  # Install sudo; configure passwordless access for all users.
  docker exec "$CONTAINER" apt-get update -qq
  docker exec "$CONTAINER" apt-get install -y -qq sudo
  docker exec "$CONTAINER" sh -c \
    "echo 'ALL ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/bats && chmod 440 /etc/sudoers.d/bats"

  # Discover the real binary paths — used by tests that move binaries.
  export _PG_CTL_PATH _PSQL_PATH
  _PG_CTL_PATH=$(docker exec "$CONTAINER" which pg_ctl)
  _PSQL_PATH=$(docker exec "$CONTAINER" which psql)

  # Discover PGDATA; create conf.d; add include_dir.
  export PGDATA
  PGDATA=$(docker exec "$CONTAINER" printenv PGDATA)
  docker exec "$CONTAINER" mkdir -p "$PGDATA/conf.d"
  docker exec -u postgres "$CONTAINER" sh -c \
    "printf \"\ninclude_dir = 'conf.d'\n\" >> $PGDATA/postgresql.conf"
  docker exec -u postgres "$CONTAINER" pg_ctl reload -D "$PGDATA" >/dev/null 2>&1

  # Snapshot the known-good postgresql.conf for per-test reset.
  docker exec "$CONTAINER" cp "$PGDATA/postgresql.conf" "$PGDATA/postgresql.conf.bak"
}

teardown_file() {
  docker rm -f "$CONTAINER" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
  # Restart the container if it stopped (happens when pg_ctl stop kills the entrypoint PID).
  if ! docker exec "$CONTAINER" true 2>/dev/null; then
    docker start "$CONTAINER" >/dev/null 2>&1 || true
    local i=0
    until docker exec "$CONTAINER" true 2>/dev/null; do
      i=$((i + 1)); [ $i -ge 15 ] && break; sleep 1
    done
  fi

  # Recover from any state left by a previously failed test.
  _restore_state

  # Restore known-good conf files and sudo.
  docker exec "$CONTAINER" cp "$PGDATA/postgresql.conf.bak" "$PGDATA/postgresql.conf"
  docker exec "$CONTAINER" mkdir -p "$PGDATA/conf.d"
  docker exec "$CONTAINER" sh -c ": > $PGDATA/postgresql.auto.conf" 2>/dev/null || true
  docker exec "$CONTAINER" sh -c \
    "echo 'ALL ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/bats && chmod 440 /etc/sudoers.d/bats"

  # Ensure PostgreSQL is running.
  if ! docker exec -u postgres "$CONTAINER" pg_ctl status -D "$PGDATA" >/dev/null 2>&1; then
    docker exec -u postgres "$CONTAINER" pg_ctl start -D "$PGDATA" -w >/dev/null 2>&1
    local i=0
    until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
      i=$((i + 1)); [ $i -ge 15 ] && break; sleep 1
    done
  fi
  docker exec -u postgres "$CONTAINER" pg_ctl reload -D "$PGDATA" >/dev/null 2>&1 || true

  _upload "$SCRIPT_AUTO"
}

teardown() {
  _restore_state
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Undo any binary moves or sudo shadows left by a test (called from both
# setup and teardown so cleanup happens regardless of assertion outcome).
_restore_state() {
  # Restore pg_ctl if it was moved.
  if docker exec "$CONTAINER" test -f "${_PG_CTL_PATH}.bak" 2>/dev/null; then
    docker exec "$CONTAINER" mv "${_PG_CTL_PATH}.bak" "$_PG_CTL_PATH" 2>/dev/null || true
  fi
  # Restore psql if it was moved.
  if docker exec "$CONTAINER" test -f "${_PSQL_PATH}.bak" 2>/dev/null; then
    docker exec "$CONTAINER" mv "${_PSQL_PATH}.bak" "$_PSQL_PATH" 2>/dev/null || true
  fi
  # Remove sudo shadow if present.
  docker exec "$CONTAINER" rm -f /usr/local/bin/sudo 2>/dev/null || true
}

# Upload script content to /tmp/preflight.sh in the container.
_upload() {
  printf '%s' "$1" \
    | docker exec -i "$CONTAINER" \
        sh -c 'cat > /tmp/preflight.sh && chmod +x /tmp/preflight.sh'
}

# Run /tmp/preflight.sh inside the container.
_run_preflight() {
  run docker exec "$CONTAINER" /tmp/preflight.sh
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "healthy cluster with correct include_dir exits 0" {
  _run_preflight
  [ "$status" -eq 0 ]
}

@test "missing pg_ctl binary causes exit non-zero" {
  # Move the real binary so command -v pg_ctl fails.
  docker exec "$CONTAINER" mv "$_PG_CTL_PATH" "${_PG_CTL_PATH}.bak"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "missing psql binary causes exit non-zero" {
  docker exec "$CONTAINER" mv "$_PSQL_PATH" "${_PSQL_PATH}.bak"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "stopped PostgreSQL cluster causes exit non-zero" {
  # pg_ctl stop may kill the container if postgres is the entrypoint PID; || true is intentional.
  docker exec -u postgres "$CONTAINER" pg_ctl stop -D "$PGDATA" -m fast >/dev/null 2>&1 || true

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "missing conf.d directory causes exit non-zero" {
  docker exec "$CONTAINER" rm -rf "$PGDATA/conf.d"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "postgresql.conf with no include_dir causes exit non-zero" {
  docker exec "$CONTAINER" sh -c \
    "sed -i 's/^include_dir/# include_dir/' $PGDATA/postgresql.conf"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "explicit conf_d_dir mismatching include_dir causes exit non-zero" {
  _upload "$SCRIPT_MISMATCH"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "SSH user without sudo causes exit non-zero" {
  # Shadow sudo with a wrapper that always fails — root can always use the
  # real sudo, so we must block it at the binary level.
  docker exec "$CONTAINER" sh -c \
    "printf '#!/bin/sh\necho \"sudo: not allowed\" >&2\nexit 1\n' \
     > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo"

  _run_preflight
  [ "$status" -ne 0 ]
}

@test "active managed param in postgresql.conf exits 0 and emits NOTICE" {
  docker exec "$CONTAINER" sh -c \
    "echo 'shared_buffers = 128MB' >> $PGDATA/postgresql.conf"

  _run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTICE"*"shared_buffers"* ]]
}

@test "managed param in postgresql.auto.conf exits 0 and emits NOTICE" {
  docker exec -u postgres "$CONTAINER" sh -c \
    "echo 'work_mem = 8MB' >> $PGDATA/postgresql.auto.conf"

  _run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTICE"*"work_mem"* ]]
}
