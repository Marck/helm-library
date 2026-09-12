#!/bin/sh
# Put the WORKING-TREE library into the test chart's charts/ directory.
#
# The test chart deliberately declares no dependency on common. A dependency
# would have to name a repository, and both options are wrong here:
#
#   * the published index (https://Marck.github.io/helm-library) resolves to the
#     LAST RELEASE, so CI would validate the previous version. A regression
#     introduced by the PR under review would pass, and a newly added helper
#     would fail because the published chart does not have it yet. A test
#     harness that cannot see the change it is testing is worse than none.
#   * file:// resolves the working tree correctly but needs a version
#     constraint kept in lockstep with every release, which is friction for a
#     constraint that never selects anything.
#
# Copying it in sidesteps both. Helm loads a library chart that is physically
# present in charts/ without any dependency entry, so there is no repository and
# no version to maintain. tests/**/charts/ is gitignored, so this is a build
# artifact like any other.
#
# Real consumers (charts/servarr, and every chart in helm-charts) use the
# published index and a pinned version, which is the correct thing for them:
# release the library first, then bump the consumer.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CHART="${1:-$ROOT/tests/common-test-chart}"

[ -d "$ROOT/charts/common" ] || { echo "FAIL: $ROOT/charts/common not found" >&2; exit 1; }
rm -rf "$CHART/charts/common" "$CHART/Chart.lock"
mkdir -p "$CHART/charts"
cp -R "$ROOT/charts/common" "$CHART/charts/common"
