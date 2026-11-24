#!/usr/bin/env bash
# The tunnels to a NAT-mode lab server, which nothing outside Erebus reaches otherwise (the lab project forbids proxy
# devices): this host's 127.0.0.1:<port> through incus exec (socat on both ends), and with --mac on to the Mac's own
# 127.0.0.1:<port> through ssh -R (the mac-dev skill, "The server"). They outlive this shell; close them when done.
#
#   lab/immich-server/tunnel.sh open [--mac]     open them, then check /api/server/ping through each
#   lab/immich-server/tunnel.sh check [--mac]    /api/server/ping through them
#   lab/immich-server/tunnel.sh status
#   lab/immich-server/tunnel.sh close            close both
#
# On the Mac the only commands are the forward and the curl that checks it. Env: IMMICH_INSTANCE (default
# ind-immich-show), SHOWCASE_PORT (the port on this host and on the Mac, default 2290; another server needs another
# port), EREBUS_DIR, MAC_HOST (user@address; private, never written into the repository), MAC_SSH_OPTIONS (such as
# "-i ~/.ssh/<key> -o IdentitiesOnly=yes").
set -euo pipefail

EREBUS_DIR=${EREBUS_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/erebus}
NAME=${IMMICH_INSTANCE:-ind-immich-show}
PORT=${SHOWCASE_PORT:-2290}
P=lab
# shellcheck source=/dev/null
. "$EREBUS_DIR/lib/erebus.sh"
RUN=${XDG_RUNTIME_DIR:-/tmp/verso-lab-$(id -u)}/verso-lab-tunnel/$NAME
mkdir -p "$RUN" && chmod 700 "$RUN"

command=${1:-status}
mac=false
[ "${2:-}" = --mac ] && mac=true
# ssh to the Mac; word splitting of MAC_SSH_OPTIONS is wanted.
mac_ssh() { ssh ${MAC_SSH_OPTIONS:-} -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
alive() { [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }
ping_here() { curl -fsS --max-time 10 "http://127.0.0.1:$PORT/api/server/ping" 2>/dev/null | grep -q pong; }
ping_mac() { mac_ssh "$MAC_HOST" "curl -fsS --max-time 10 http://127.0.0.1:$PORT/api/server/ping" </dev/null 2>/dev/null | grep -q pong; }
# until <seconds> <command...>: poll every 2 s.
until_ok() {
  local deadline=$(( SECONDS + $1 )); shift
  until "$@"; do [ "$SECONDS" -lt "$deadline" ] || return 1; sleep 2; done
}
stop() {
  if alive "$1"; then
    kill -- "-$(cat "$RUN/$1.pid")" 2>/dev/null || kill "$(cat "$RUN/$1.pid")" 2>/dev/null || true
    step "closed the $1 tunnel"
  fi
  rm -f "$RUN/$1.pid"
}

case $command in
open)
  [ "$(state "$P" "$NAME")" = RUNNING ] || die "$NAME is not running"
  if ! alive here; then
    if ss -ltn "sport = :$PORT" | grep -q LISTEN; then die "127.0.0.1:$PORT is taken by another process; set SHOWCASE_PORT"; fi
    inc exec --project "$P" "$NAME" -- sh -c \
      'command -v socat >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null' </dev/null
    # One incus exec per connection (about 0.1 s each), so an app's few kept-alive connections cost little.
    setsid socat "TCP-LISTEN:$PORT,bind=127.0.0.1,reuseaddr,fork" \
      "EXEC:$EREBUS_DIR/bin/incus exec --project $P $NAME -- socat STDIO TCP\\:127.0.0.1\\:2283" \
      </dev/null >"$RUN/here.log" 2>&1 &
    echo $! > "$RUN/here.pid"
    until_ok 30 ping_here || die "no answer through 127.0.0.1:$PORT ($RUN/here.log)"
  fi
  step "this host: http://127.0.0.1:$PORT reaches $NAME"
  if $mac; then
    : "${MAC_HOST:?set MAC_HOST to the Mac user@address}"
    if ! alive mac; then
      setsid ssh ${MAC_SSH_OPTIONS:-} -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -R "127.0.0.1:$PORT:127.0.0.1:$PORT" "$MAC_HOST" </dev/null >"$RUN/mac.log" 2>&1 &
      echo $! > "$RUN/mac.pid"
    fi
    until_ok 60 ping_mac || die "the Mac gets no answer through its 127.0.0.1:$PORT ($RUN/mac.log)"
    step "the Mac: http://127.0.0.1:$PORT reaches $NAME (curl on the Mac got pong)"
  fi
  ;;
check)
  ping_here && step "this host: pong through 127.0.0.1:$PORT" || die "this host: no answer through 127.0.0.1:$PORT"
  if $mac; then
    : "${MAC_HOST:?set MAC_HOST to the Mac user@address}"
    ping_mac && step "the Mac: pong through its 127.0.0.1:$PORT" || die "the Mac: no answer through its 127.0.0.1:$PORT"
  fi
  ;;
status)
  for tunnel in here mac; do
    if alive "$tunnel"; then echo "$tunnel: open (pid $(cat "$RUN/$tunnel.pid"), port $PORT)"; else echo "$tunnel: closed"; fi
  done
  ;;
close)
  stop mac
  stop here
  ;;
*) die "usage: $0 open [--mac] | check [--mac] | status | close" ;;
esac
