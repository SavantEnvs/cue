#!/usr/bin/env bash
#
# cue/mayhem/test.sh — RUN the project's own Go test suite and a known-answer probe,
# and emit a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test ./...` — cuelang.org/go's own suite: thousands of table-driven and
#     txtar-golden tests across cue/, cue/parser, cue/format, encoding/yaml,
#     internal/core/{compile,eval}, cmd/cue, etc. It asserts exact parsed ASTs,
#     formatted output, and evaluated values via txtar golden files and
#     reflect.DeepEqual/cmp.Diff — real behavioral assertions, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the
#     verify-repo sabotage check (LD_PRELOAD a shim whose constructor _exit(0)s
#     every non-system executable) CANNOT neuter it. A `go test`-only oracle
#     therefore survives sabotage while proving nothing, which is exactly the
#     reward-hackable case the spec forbids. /mayhem/kat is built with cgo =>
#     DYNAMICALLY linked, so the shim DOES neuter it; it then prints nothing and
#     the exact-match assertions below fail. The probe asserts four VALUES computed
#     by three independent CUE subsystems (parser+formatter canonicalization, the
#     compiler+evaluator, and the YAML-to-CUE extractor), so a patch that stubs any
#     of them to stop a crash cannot satisfy it either.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite ────────────────────────────────────────────────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
tail -30 "$SRC/mayhem-build/gotest.err" 2>/dev/null || true

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A
# `[ -f ... ]` guard here is how a probe silently stops running and the oracle
# quietly degrades to the go-test-only (reward-hackable) case.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed/evaluated VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values — computed once from a clean build (docker run --rm <img> /mayhem/kat)
# and pinned here verbatim (including the tab cue/format.Node uses to indent a
# multi-element list); see mayhem/kat/main.go for how each is derived.
#   KAT_FORMAT   cue/format.Node canonicalization of a badly-spaced snippet
#   KAT_EVAL_X   6*7 evaluated through cuecontext+compile+evaluate
#   KAT_EVAL_S   "foo"+"bar" evaluated the same way
#   KAT_YAML     cue/format.Node of a YAML doc extracted via encoding/yaml.Extract
#
# kat_expect does a LITERAL, CONTIGUOUS substring match of the whole (possibly
# multi-line) expected block against $KAT_OUT via bash's `case`/glob (the `*`s are
# the only wildcard chars; $expect itself is quoted so it is matched verbatim,
# newlines and all). Do NOT reimplement this with `grep -F` on a multi-line
# pattern: GNU grep treats a newline-separated -F pattern as MULTIPLE alternative
# single-line patterns, so `grep -qxF "$multiline"` only proves that ONE line of
# the block appears somewhere in the output — not that the whole block is
# present and correct. That bug is exactly the kind of falsely-green oracle this
# probe exists to avoid.
kat_expect() {
  local label="$1" expect="$2"
  case "$KAT_OUT" in
    *"$expect"*)
      echo "KAT PASS: $label"
      PASSED=$(( PASSED + 1 ))
      ;;
    *)
      echo "KAT FAIL: $label — expected to find this exact block in the output:" >&2
      printf '%s\n' "$expect" | sed 's/^/        /' >&2
      FAILED=$(( FAILED + 1 ))
      ;;
  esac
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or a subsystem broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
TAB="$(printf '\t')"
kat_expect "parser+formatter canonicalization" 'KAT_FORMAT=package p

a: 1 + 2
b: "hello"'
kat_expect "evaluator: 6*7"                     'KAT_EVAL_X=42'
kat_expect "evaluator: string concat"           'KAT_EVAL_S=foobar'
kat_expect "YAML-to-CUE extraction + format"    "KAT_YAML=a: 1
b: [
${TAB}\"x\",
${TAB}\"y\",
]"

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
