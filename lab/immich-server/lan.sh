#!/usr/bin/env bash
# LAN mode for a warm NAT-mode lab server, for a session with a device that only the LAN reaches (the maintainer's
# iPhone): `on` gives the running server a LAN address from the router's DHCP (the lan profile), `off` puts it back
# on NAT. Its data stays as it is either way.
#
#   lab/immich-server/lan.sh on       stop it, add the lan profile, start it; prints the LAN URL
#   lab/immich-server/lan.sh off      stop it, remove the lan profile, start it: NAT again, reachable only from Erebus
#   lab/immich-server/lan.sh status
#
# While on, the whole LAN reaches the server and its throwaway logins, so never leave it on unattended: `off` at the
# end of the session, or before leaving it. up.sh's restore (the seeded snapshot, taken on NAT) puts it back on NAT
# too, and showcase.sh and seed.sh never take a snapshot in LAN mode. The .incus name does not resolve on the LAN,
# and the tunnels (tunnel.sh) still work, through incus exec.
#
# Env: IMMICH_INSTANCE (default ind-immich-show), EREBUS_DIR.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EREBUS_DIR=${EREBUS_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/erebus}
NAME=${IMMICH_INSTANCE:-ind-immich-show}
P=lab
# shellcheck source=/dev/null
. "$EREBUS_DIR/lib/erebus.sh"
ENV_FILE=$HERE/.env.$NAME.local
[ "$NAME" = ind-immich-srv ] && ENV_FILE=$HERE/.env.local

[ -n "$(state "$P" "$NAME")" ] || die "$NAME does not exist"
on_lan() { inc list --project "$P" "^$NAME\$" -f json </dev/null | jq -e '.[0].profiles | index("lan")' >/dev/null; }
address() {
  inc list --project "$P" "^$NAME\$" -f json </dev/null |
    jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet") | .address' | head -1
}
wait_ping() {
  wait_for "$P" "$NAME" "Immich /api/server/ping" \
    sh -c 'curl -fsS --max-time 3 http://127.0.0.1:2283/api/server/ping | grep -q pong'
}
# Wait for an eth0 address on the network asked for (LAN: outside incusbr0's 10.190.144.0/24).
wait_address() {
  local deadline=$(( SECONDS + 90 )) ip
  while :; do
    ip=$(address || true)
    case "$1/$ip" in */|lan/10.190.144.*) ;; lan/*|nat/10.190.144.*) echo "$ip"; return 0 ;; esac
    [ "$SECONDS" -lt "$deadline" ] || die "no $1 address on $NAME after 90 s"
    sleep 2
  done
}

case ${1:-status} in
on)
  if ! on_lan; then
    step "$NAME: onto the LAN (the lan profile)"
    inc stop --project "$P" "$NAME" </dev/null 2>/dev/null || true   # stopped already is fine
    inc profile add --project "$P" "$NAME" lan </dev/null
    inc start --project "$P" "$NAME" </dev/null
  fi
  ip=$(wait_address lan)
  wait_ping
  sed -i '/^IMMICH_LAN_URL=/d' "$ENV_FILE" 2>/dev/null || true
  [ -f "$ENV_FILE" ] && echo "IMMICH_LAN_URL=http://$ip:2283" >> "$ENV_FILE"
  if curl -fsS --max-time 5 "http://$ip:2283/api/server/ping" | grep -q pong; then
    step "LAN mode: http://$ip:2283 answers from $(hostname). The whole LAN reaches it: run '$0 off' when done."
  else
    step "LAN mode: http://$ip:2283 (not reachable from $(hostname)). Run '$0 off' when done."
  fi
  ;;
off)
  if on_lan; then
    step "$NAME: back on NAT"
    inc stop --project "$P" "$NAME" </dev/null 2>/dev/null || true   # stopped already is fine
    inc profile remove --project "$P" "$NAME" lan </dev/null
    inc start --project "$P" "$NAME" </dev/null
  fi
  ip=$(wait_address nat)
  wait_ping
  if [ -f "$ENV_FILE" ]; then
    sed -i -e '/^IMMICH_LAN_URL=/d' -e "s|^IMMICH_URL=.*|IMMICH_URL=http://$ip:2283|" "$ENV_FILE"
  fi
  step "NAT mode: $NAME at http://$ip:2283, reachable from Erebus and through tunnel.sh"
  ;;
status)
  if on_lan; then echo "LAN mode: http://$(address):2283 (the whole LAN reaches it)"; else echo "NAT mode: http://$(address):2283"; fi
  ;;
*) die "usage: $0 on | off | status" ;;
esac
