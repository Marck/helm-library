#!/usr/bin/env bash
# Negative tests for common.sso.validate (common 0.5.8).
#
# The happy path is covered by `helm template` on the test chart in CI; a
# validator is only worth anything if it also FAILS when it should, and with a
# message that says what to do. Each case renders the test chart with an
# `sso` override and asserts a non-zero exit plus an expected substring.
#
# Usage: tests/sso-negative.sh   (from the helm-library repo root)

set -u
CHART="tests/common-test-chart"
PASS=0
FAIL=0

# expect_fail <name> <expected-substring> <helm --set args...>
expect_fail() {
  local name="$1" want="$2"; shift 2
  local out
  if out=$(helm template test "$CHART" "$@" 2>&1); then
    echo "FAIL $name: render SUCCEEDED but should have been rejected"
    FAIL=$((FAIL + 1))
    return
  fi
  if printf '%s' "$out" | grep -qF "$want"; then
    echo "ok   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name: rejected, but the message did not contain: $want"
    printf '%s\n' "$out" | tail -3
    FAIL=$((FAIL + 1))
  fi
}

# expect_ok <name> <helm --set args...>
expect_ok() {
  local name="$1"; shift
  local out
  if out=$(helm template test "$CHART" "$@" 2>&1); then
    echo "ok   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name: render failed but should have been allowed"
    printf '%s\n' "$out" | tail -3
    FAIL=$((FAIL + 1))
  fi
}

# An ingress-exposing chart that opts in must say how it authenticates.
expect_fail "missing mode" "declares no sso.mode" \
  --set sso.enforce=true --set sso.mode=null

# Typos must not pass silently.
expect_fail "invalid mode" "invalid sso.mode" \
  --set sso.enforce=true --set sso.mode=magic

# Opting out is allowed, but the reason has to be recorded.
expect_fail "mode none without reason" "no sso.reason" \
  --set sso.enforce=true --set sso.mode=none

# Declaration and Ingress must agree when a marker is configured.
expect_fail "forward-auth marker absent" "do not reference" \
  --set sso.enforce=true --set sso.mode=forward-auth \
  --set sso.forwardAuthMarker=not-in-the-annotations

# The check is OPT-IN: a chart that never heard of it renders unchanged.
expect_ok "opt-out renders (enforce false)" \
  --set sso.enforce=false --set sso.mode=null

# mode: none with a reason is a valid, reviewable exemption.
expect_ok "mode none with reason" \
  --set sso.enforce=true --set sso.mode=none \
  --set sso.reason="native auth: mobile clients break behind a login wall"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
