//go:build wasip1

// SPDX-License-Identifier: GPL-2.0-or-later
//
// wasip1 entrypoint for the CRE-04 senior-warehouse op producer. The workflow logic lives in workflow.go
// (untagged, so it builds + tests on the host); main() + the wasm runner are wasip1-only because
// cre/wasm.NewRunner is wasip1-bound.
package main

import (
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(initFn)
}
