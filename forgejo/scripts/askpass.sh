#!/usr/bin/env bash
# GIT_ASKPASS helper for puller.sh: git asks "Username for '<url>': " then
# "Password for '<url>': ". The token is read from a file so it is never an
# argument to anything — and it is offered ONLY to the Forgejo host. GitHub
# also prompts (a missing or private upstream looks the same to it), and the
# first live run answered that prompt with the Forgejo token; now any other
# host gets no answer and the fetch fails as it should.
case "$1" in
  *"'${FORGEJO_URL}'"*) ;;
  *) exit 1 ;;
esac
case "$1" in
  Username*) printf '%s\n' "$PULLER_USERNAME" ;;
  Password*) cat "$PULLER_TOKEN_FILE" ;;
  *) exit 1 ;;
esac
