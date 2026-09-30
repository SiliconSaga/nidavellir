#!/usr/bin/env bash
# GIT_ASKPASS helper for puller.sh: git asks "Username for '<url>': " then
# "Password for '<url>': ". The token is read from a file so it is never an
# argument to anything.
case "$1" in
  Username*) printf '%s\n' "$PULLER_USERNAME" ;;
  Password*) cat "$PULLER_TOKEN_FILE" ;;
  *) exit 1 ;;
esac
