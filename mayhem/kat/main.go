// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so verify-repo's sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system executables)
// cannot neuter it — a suite that only runs `go test` would be immune to the
// sabotage check and would NOT prove the oracle is behavioral. This probe is built
// with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, prints nothing, and test.sh's exact string
// assertions fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it asserts VALUES computed by three
// independent CUE subsystems (parser+formatter canonicalization, the compiler+
// evaluator, and the YAML-to-CUE extractor fuzz_yaml exercises) against fixed
// expected strings. A patch that stubs any of these to stop a crash cannot
// reproduce these exact values.
//
// Prints four lines, which test.sh matches EXACTLY:
//
//	KAT_FORMAT=<cue/format.Node output of a hand-written, badly-spaced CUE snippet>
//	KAT_EVAL_X=<evaluated result of 6*7 through cuecontext+compile+evaluate>
//	KAT_EVAL_S=<evaluated result of "foo" + "bar" through the same path>
//	KAT_YAML=<cue/format.Node output of a YAML document extracted via encoding/yaml.Extract>
package main

import (
	"fmt"
	"os"
	"strings"

	"cuelang.org/go/cue"
	"cuelang.org/go/cue/cuecontext"
	"cuelang.org/go/cue/format"
	"cuelang.org/go/cue/parser"
	"cuelang.org/go/encoding/yaml"
)

func main() {
	// ── 1) parser + formatter: format.Node canonicalizes whitespace/spacing ──────
	const src = "package p\n\na:    1+2\nb:\"hello\"\n"
	astFile, err := parser.ParseFile("kat.cue", src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: ParseFile: %v\n", err)
		os.Exit(1)
	}
	out, err := format.Node(astFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: format.Node: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_FORMAT=%s\n", strings.TrimRight(string(out), "\n"))

	// ── 2) compiler + evaluator: a real known-answer computation, not just syntax ─
	ctx := cuecontext.New()
	v := ctx.CompileString(`x: 6*7
s: "foo" + "bar"`)
	if err := v.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "kat: CompileString: %v\n", err)
		os.Exit(1)
	}
	xi, err := v.LookupPath(cue.ParsePath("x")).Int64()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: lookup x: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_EVAL_X=%d\n", xi)
	si, err := v.LookupPath(cue.ParsePath("s")).String()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: lookup s: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_EVAL_S=%s\n", si)

	// ── 3) YAML-to-CUE extraction, the subsystem fuzz_yaml exercises ─────────────
	yamlSrc := "a: 1\nb:\n  - x\n  - y\n"
	yf, err := yaml.Extract("kat.yaml", []byte(yamlSrc))
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: yaml.Extract: %v\n", err)
		os.Exit(1)
	}
	yout, err := format.Node(yf)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: format.Node(yaml): %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_YAML=%s\n", strings.TrimRight(string(yout), "\n"))
}
