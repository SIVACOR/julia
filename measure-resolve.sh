#!/usr/bin/env bash
# Open item 1: what does a cold resolve actually cost?
#
#   ./measure-resolve.sh [image]
#
# The dependency set is the direct dependencies of AEADataEditor/docker-aer-2022-0276,
# a real AEA Julia replication package -- names only, no pins, so Pkg resolves
# current versions. n=1, and the binary-artifact packages (HDF5, Blosc, JLD)
# dominate.
#
# WHERE YOU RUN THIS IS PART OF THE MEASUREMENT. A fast link makes the download
# half disappear and yields a reassuring, useless number. The figure the plan
# wants is from a worker-equivalent JS2 VM.
set -uo pipefail
IMAGE="${1:-sivacor-julia:1.11.9-local}"
WS="$(mktemp -d)"; chmod 777 "$WS"; mkdir -p "$WS/project"; chmod 777 "$WS/project"
cleanup() {
  docker run --rm --user 0:0 -v "$WS:/w" --entrypoint /bin/sh "$IMAGE" \
    -c 'rm -rf /w/.julia /w/project' >/dev/null 2>&1
  rm -rf "$WS"
}
trap cleanup EXIT

cat > "$WS/project/Project.toml" <<'TOML'
[deps]
Blosc = "a74b3585-a348-5f62-a45c-50e91977d574"
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
CategoricalArrays = "324d7699-5711-5eae-9e2f-1d82baa6b597"
Combinatorics = "861a8166-3701-5b0c-9a16-15d98fcdc6aa"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
DataStructures = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
Distributions = "31c24e10-a181-5473-b8eb-7969acd0382f"
FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
FixedEffectModels = "9d5cd8c9-2029-5cab-9928-427838db53e3"
GLM = "38e38edf-8417-5370-95a0-9cbb8c7f171a"
HDF5 = "f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f"
JLD = "4138dd39-2aa7-5051-a626-17a0bb65d9c8"
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
Optim = "429524aa-4258-5aef-a3af-852621145aeb"
PrettyTables = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
ShiftedArrays = "1277b4bf-5013-50f5-be3d-901d8477a67a"
StatsBase = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
StatsModels = "3eaba693-59b7-5ba5-a881-562e759f1c8d"
Vcov = "ec2bfdc2-55df-4fc9-b9ae-4958c2cf2486"
TOML

echo "host: $(uname -srm)  |  image: $IMAGE"
echo "resolving 19 direct dependencies, cold depot..."
start=$(date +%s)
docker run --rm --read-only --user 4242:4242 \
  -e HOME=/workspace -e TMPDIR=/tmp -v "$WS:/workspace" --tmpfs /tmp \
  -w /workspace/project --entrypoint /usr/local/julia/bin/julia \
  "$IMAGE" --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()' \
  > "$WS/resolve.log" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))

echo
echo "exit code            : $rc"
echo "wall clock           : ${elapsed}s"
echo "packages installed   : $(ls "$WS/.julia/packages" 2>/dev/null | wc -l)"
echo "depot size on disk   : $(du -sh "$WS/.julia" 2>/dev/null | cut -f1)"
echo "  of which artifacts : $(du -sh "$WS/.julia/artifacts" 2>/dev/null | cut -f1)"
echo "  of which compiled  : $(du -sh "$WS/.julia/compiled" 2>/dev/null | cut -f1)"
[ $rc -ne 0 ] && { echo; echo "--- last 15 lines ---"; tail -15 "$WS/resolve.log"; }
exit $rc
