#!/usr/bin/env bash
# Install Verso's rpm and deb packages on several distributions at once, each in a throwaway container on Erebus, and
# print one row per distribution (install-test.sh decides what fits where and what is checked).
#
#   lab/packaging/matrix.sh [TAG] [DISTRO ...]               a release's packages (default: the latest release)
#   lab/packaging/matrix.sh --packages DIR [DISTRO ...]      packages built here (linux/packaging/verso-packages.sh)
#
# Distributions: Fedora 44 and 43 and Debian 14 (forky) for the packages, Ubuntu 26.04 LTS where the deb is built, and
# Ubuntu 24.04 LTS, too old, where the deb must be refused and its launcher say why. Instances are named
# ind-pkg-<distribution><LAB_SUFFIX>, in the lab project, ephemeral, with a user.expires, and stopped (so deleted) at
# the end. With a lab server's credentials (IMMICH_ENV, default lab/immich-server/.env.local), each also mounts it with
# its read-only key and checks originals against Immich's checksums; the key goes to the containers only, in a 0600
# file, and is never printed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
EREBUS_DIR=${EREBUS_DIR:-$(cd "$here/../../.." && pwd)/erebus}
[ -f "$EREBUS_DIR/lib/erebus.sh" ] || { echo "no lib/erebus.sh in EREBUS_DIR=$EREBUS_DIR" >&2; exit 1; }
. "$EREBUS_DIR/lib/erebus.sh"
P=lab
WARM_HOURS=${WARM_HOURS:-3}
. "$here/../warm.sh"

packages=$(mktemp -d /tmp/verso-packages.XXXX)
server_env=
# The packages and the key go; the logs in $out stay for reading.
trap 'rm -rf "$packages" ${server_env:+"$server_env"}' EXIT
if [ "${1:-}" = --packages ]; then
  source_dir=${2:?usage: lab/packaging/matrix.sh --packages DIR [DISTRO ...]}
  shift 2
  cp "$source_dir"/verso-*.x86_64.rpm "$source_dir"/verso_*_amd64.deb "$packages/" 2>/dev/null || true
  what="the packages in $source_dir"
else
  tag=${1:-$(gh release view -R jakobhviid/verso --json tagName -q .tagName </dev/null)}
  shift || true
  step "downloading $tag"
  # gh can hang after the last asset; the files are complete by then, so a timeout is safe.
  (cd "$packages" && timeout 120 gh release download "$tag" -R jakobhviid/verso --pattern 'verso-*.x86_64.rpm' \
    --pattern 'verso_*_amd64.deb' </dev/null) || true
  what=$tag
fi
# A system without its package makes a failed row; the others are checked all the same.
ls "$packages"/verso-*.x86_64.rpm "$packages"/verso_*_amd64.deb >/dev/null 2>&1 ||
  ls "$packages"/verso* >/dev/null 2>&1 || die "no rpm or deb in $what"
distros=("$@")
[ ${#distros[@]} -gt 0 ] || distros=(fedora/44 fedora/43 ubuntu/26.04 debian/14 ubuntu/24.04)

IMMICH_ENV=${IMMICH_ENV:-$here/../immich-server/.env.local}
if [ -f "$IMMICH_ENV" ]; then
  server_env=$(mktemp /tmp/verso-server.XXXX)
  ( . "$IMMICH_ENV"; printf 'IMMICH_URL=%s\nIMMICH_KEY=%s\n' "$IMMICH_URL" "$IMMICH_API_KEY_READONLY" ) >"$server_env"
  step "with the server in $(basename "$IMMICH_ENV")"
fi
out=$(mktemp -d /tmp/verso-matrix.XXXX)

# Runs in the background, so errexit is off here: a failing step must still stop the instance and leave a row.
run_one() {
  set +e
  local distro=$1 name log verdict launched=
  name="ind-pkg-$(tr '/.' '--' <<<"$distro")${LAB_SUFFIX:-}"; log="$out/$name.log"
  {
    # Images downloaded for the first time at once can fail one launch: it is tried twice.
    for attempt in 1 2; do
      if inc launch "images:$distro" "$name" --project "$P" --ephemeral -c user.expires="$(expires_at)" -q </dev/null; then
        launched=yes
        break
      fi
      sleep 5
    done
    if [ -n "$launched" ]; then
      if wait_for "$P" "$name" "network" sh -c 'getent hosts github.com >/dev/null' >/dev/null 2>&1; then
        for package in "$packages"/*; do
          inc file push --project "$P" --create-dirs "$package" "$name/root/packages/$(basename "$package")" </dev/null
        done
        inc file push --project "$P" "$here/install-test.sh" "$name/root/install-test.sh" --mode 0755 </dev/null
        [ -z "$server_env" ] || inc file push --project "$P" "$server_env" "$name/root/server.env" --mode 0600 </dev/null
        inc exec --project "$P" "$name" -- /root/install-test.sh </dev/null
      else
        echo "FAIL: no network"
      fi
      inc stop --project "$P" "$name" -q </dev/null
    else
      echo "FAIL: launch"
    fi
  } >"$log" 2>&1
  verdict=$(tail -1 "$log")
  case $verdict in
    ok:*) ;;
    FAIL:*) verdict="$verdict (log: $log)" ;;
    *) verdict="FAIL: ${verdict:-no verdict} (log: $log)" ;;
  esac
  printf '%-14s %s\n' "$distro" "$verdict" >"$out/$name.row"
}
step "testing $what on ${distros[*]}"
for distro in "${distros[@]}"; do run_one "$distro" & done
wait
cat "$out"/*.row
rows=$(ls "$out"/*.row 2>/dev/null | wc -l)
[ "$rows" -eq ${#distros[@]} ] || die "$rows rows for ${#distros[@]} distributions"
! grep -q "FAIL" "$out"/*.row
