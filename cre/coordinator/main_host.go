//go:build !wasip1

// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host-build stub for `main`. The real entrypoint (main.go) is wasip1-only, because cre/wasm.NewRunner is
// wasip1-bound; without this stub a host `go build ./...` of the `package main` would fail to link with
// "function main is undeclared". The workflow is never RUN on the host — it is tested via workflow.go's
// untagged handlers under the sim harness (workflow_test.go) — so this stub is intentionally a no-op.
package main

func main() {}
