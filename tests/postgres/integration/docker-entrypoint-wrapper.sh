#!/bin/sh
# Wrapper entrypoint: starts sshd, then hands off to the official postgres entrypoint.
set -e

# Start sshd in the background.
/usr/sbin/sshd

# Exec the official postgres entrypoint (passes through all arguments).
exec docker-entrypoint.sh "$@"
