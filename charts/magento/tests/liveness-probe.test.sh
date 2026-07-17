#!/usr/bin/env bash
# Checks the rendered livenessProbe's static-content clause.
#
# The clause decides whether an empty pub/static/ means "a rebuild is running,
# leave the pod alone" or "the rebuild died, restart me". Getting the flock
# polarity backwards either crashloops every rebuild or disables the self-heal
# entirely, and neither shows up in `helm lint`.
#
# The expression under test is extracted from `helm template` rather than
# retyped here, so a change to the probe fails this test instead of drifting.
set -euo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

MARKER="$ROOT/pub/static/deployed_version.txt"
LOCK="$ROOT/var/.static-rebuild.lock"
mkdir -p "$ROOT/pub/static" "$ROOT/var"

# Pull the probe command out of the rendered Deployment, then neutralise the
# curl half (no Apache here — this test is about the static-content clause)
# and point the absolute paths at our sandbox.
probe="$(helm template t "$CHART" \
  --set staticContentDeploy.enabled=true \
  --set magento.mode=production \
  | yq eval-all 'select(.kind == "Deployment")
      | .spec.template.spec.containers[]
      | select(.name == "magento")
      | .livenessProbe.exec.command[2]' - \
  | sed -e 's|^curl .*\\$|true \\|' -e "s|/var/www/html|$ROOT|g")"

if [[ "$probe" != *flock* || "$probe" != *deployed_version.txt* ]]; then
  echo "FAIL: could not extract the probe clause; did the probe change shape?"
  echo "$probe"
  exit 1
fi

probe() { bash -c "$probe"; }

# 1. Steady state: static content deployed, nothing rebuilding.
echo "v1" > "$MARKER"
probe || { echo "FAIL: healthy pod with deployed static content was killed"; exit 1; }

# 2. Rebuild in flight: -f purged pub/static and holds the lock. Killing the
#    pod here is what wedged magento-dev — the rebuild never got to finish, so
#    the git-sync marker never advanced and the next poll restarted it forever.
: > "$MARKER"
flock "$LOCK" -c 'sleep 5' &
sleep 0.5
probe || { echo "FAIL: pod killed while a rebuild legitimately held the lock"; exit 1; }
wait

# 3. Rebuild died and released the lock, marker still empty: genuine breakage,
#    so the probe must fail and let postStart re-run static-content:deploy.
if probe; then echo "FAIL: empty static content with no rebuild should restart"; exit 1; fi

# 4. Never-deployed marker file behaves the same as an empty one.
rm -f "$MARKER"
if probe; then echo "FAIL: missing marker with no rebuild should restart"; exit 1; fi

echo "PASS: liveness probe tolerates in-flight rebuilds and still self-heals"
