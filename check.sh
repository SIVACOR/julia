#!/usr/bin/env bash
# 10-P0's check: does this image behave under every constraint a SIVACOR worker
# imposes? Three legs, run against a locally built image.
#
#   ./check.sh [image]      default: sivacor-julia:1.11.9-local
#
# The constraints reproduced here are the real ones, from girder-sivacor
# lib.py:1562-1591: an arbitrary uid present in no /etc/passwd, a read-only
# rootfs, HOME on the workspace bind mount, and -- for the analysis container
# only -- no network.
set -uo pipefail

IMAGE="${1:-sivacor-julia:1.11.9-local}"
WS="$(mktemp -d)"
FAILED=0

# The workspace is world-writable here only because this script invents a uid.
# A real run has worker uid == container uid, so the bind mount is already owned
# correctly; nothing in the image depends on the difference.
# The container writes its depot as uid 4242, so the host user cannot unlink it
# afterwards -- the containing directories are 0755 and owned by 4242. Reset
# through a root container instead. Nothing about the image depends on this; it
# is an artefact of this script inventing a uid that does not own the mount.
reset_ws() {
  docker run --rm --user 0:0 -v "$WS:/w" --entrypoint /bin/sh "$IMAGE" \
    -c 'rm -rf /w/.julia /w/project && mkdir -p /w/project && chmod -R 777 /w' \
    >/dev/null 2>&1
}
trap 'reset_ws; rm -rf "$WS"' EXIT

chmod 777 "$WS"
reset_ws

run() {  # run <network-arg> <julia args...>
  local net="$1"; shift
  docker run --rm --read-only \
    --user 4242:4242 \
    $net \
    -e HOME=/workspace -e TMPDIR=/tmp \
    -v "$WS:/workspace" \
    --tmpfs /tmp \
    -w /workspace/project \
    --entrypoint /usr/local/julia/bin/julia \
    "$IMAGE" --startup-file=no "$@"
}

ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; FAILED=1; }

echo "== leg 1: the image runs, as an unknown uid on a read-only rootfs =="
printf 'println(1 + 1)\n' > "$WS/project/main.jl"
# Deliberately loads no package: with no Project.toml and nothing baked,
# LOAD_PATH has nothing to resolve against, so a `using` here would fail for
# reasons that say nothing about the image.
out="$(run '--network none' --project=. main.jl 2>&1)"
[ "$(echo "$out" | tail -1)" = "2" ] && ok "julia starts and runs a script" \
  || bad "expected '2', got: $out"

echo
echo "== leg 2: the resolve phase (10-D1) =="
reset_ws
cat > "$WS/project/Project.toml" <<'TOML'
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
TOML
printf 'using CSV\nprintln("CSV loaded")\n' > "$WS/project/main.jl"

start=$(date +%s)
resolve_out="$(run '' --project=. -e 'using Pkg; Pkg.instantiate()' 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - start ))
[ $rc -eq 0 ] && ok "phase 1 (networked instantiate) exited 0" \
  || bad "phase 1 exited $rc: $resolve_out"

[ -f "$WS/project/Manifest.toml" ] \
  && ok "phase 1 wrote Manifest.toml into project/ (the artifact 10-D4 accounts for)" \
  || bad "no Manifest.toml in project/"

# If the baked snapshot is found, Pkg does not fetch General. If this trips, the
# cost is paid by every run, silently, for as long as nobody looks.
if echo "$resolve_out" | grep -qiE 'installing known registries|added .*General.* registry'; then
  bad "phase 1 cloned the General registry -- the baked snapshot was not used"
  echo "$resolve_out" | grep -iE 'registr' | sed 's/^/        /'
else
  ok "phase 1 did not clone the General registry"
fi

out="$(run '--network none' --project=. main.jl 2>&1)"
[ "$(echo "$out" | tail -1)" = "CSV loaded" ] \
  && ok "phase 2 loaded the package offline" \
  || bad "phase 2 failed offline: $out"

echo "  TIME  phase 1 resolve: ${elapsed}s (open item 1 wants this for a realistic set)"

echo
echo "== leg 3: an unsatisfiable environment must fail in phase 1 =="
reset_ws
cat > "$WS/project/Project.toml" <<'TOML'
[deps]
SivacorNoSuchPackage = "d7a1b2c3-0000-4000-8000-000000000001"
TOML
printf 'println("unreachable")\n' > "$WS/project/main.jl"
if run '' --project=. -e 'using Pkg; Pkg.instantiate()' >"$WS/leg3.log" 2>&1; then
  bad "phase 1 succeeded on an unregistered package; it must not"
else
  ok "phase 1 failed, as DEPENDENCY_RESOLUTION_FAILED requires"
  echo "        researcher-facing message, first line:"
  grep -m1 -iE 'error|not found|expected' "$WS/leg3.log" | sed 's/^/        /'
fi

echo
[ $FAILED -eq 0 ] && echo "ALL LEGS PASSED ($IMAGE)" || echo "FAILURES ($IMAGE)"
exit $FAILED
