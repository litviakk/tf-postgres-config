#!/bin/sh
# Runs once after initdb completes (docker-entrypoint-initdb.d).
# Creates conf.d and adds include_dir to postgresql.conf.
set -eu
mkdir -p "$PGDATA/conf.d"
printf "\ninclude_dir = 'conf.d'\n" >> "$PGDATA/postgresql.conf"
