#!/usr/bin/env python3
"""Run one INLINE panelist (Fugu, or any non-agentic OpenAI-compatible endpoint).

Non-agentic models can't read repo files, so we inline everything: the boot context,
the mission, and every file named in the contract's manifest (`context.files`). The
1M-token context windows (Fugu) make this comfortable.

Supports two endpoint shapes:
  --api responses  -> POST /v1/responses   (Fugu; honors --effort via reasoning.effort)
  --api chat       -> POST /v1/chat/completions  (generic OpenAI-compatible inline)

Manifest format (`context.files`), one entry per line:
  path/relative/to/repo/root.sol            # whole file
  reference/big/flattened.sol:2943-3760      # only lines 2943..3760 (1-indexed, inclusive)
  # comment lines and blanks are ignored

Stdlib only. Usage:
  panelist_inline.py --api responses --base-url https://api.sakana.ai/v1 \
    --model fugu-ultra --api-key-env SAKANA_API_KEY --effort max \
    --boot prompts/.../_boot.md --mission prompts/.../1.md \
    --manifest prompts/.../context.files
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))  # adversarial-review/.. = repo root

LANG = {".sol": "solidity", ".md": "markdown", ".py": "python", ".sh": "bash",
        ".toml": "toml", ".json": "json"}


def read_slice(spec):
    """spec is 'path' or 'path:start-end'. Returns (display_path, text)."""
    if ":" in spec and spec.rsplit(":", 1)[1].replace("-", "").isdigit() and "-" in spec.rsplit(":", 1)[1]:
        path, rng = spec.rsplit(":", 1)
        start, end = (int(x) for x in rng.split("-"))
    else:
        path, start, end = spec, None, None
    abspath = path if os.path.isabs(path) else os.path.join(REPO, path)
    with open(abspath, "r") as f:
        lines = f.readlines()
    if start is not None:
        sliced = lines[start - 1:end]
        disp = f"{path} (lines {start}-{end})"
        return disp, "".join(sliced)
    return path, "".join(lines)


def load_manifest(manifest_path):
    files = []
    with open(manifest_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            files.append(line)
    return files


def assemble_input(boot_path, mission_path, manifest_path):
    parts = []
    parts.append(open(boot_path).read())
    parts.append("\n\n===================== YOUR MISSION =====================\n\n")
    parts.append(open(mission_path).read())
    if manifest_path and os.path.exists(manifest_path):
        parts.append("\n\n===================== INLINED CONTEXT =====================\n")
        parts.append("The following files are provided in full (you cannot read the filesystem). "
                     "Treat them as your working set: the contract under review, its tests, and the "
                     "source-of-truth precedent to diff against.\n")
        for spec in load_manifest(manifest_path):
            disp, text = read_slice(spec)
            ext = os.path.splitext(disp.split(" ")[0])[1]
            fence = LANG.get(ext, "")
            parts.append(f"\n### FILE: {disp}\n```{fence}\n{text}\n```\n")
    return "".join(parts)


def extract_responses_text(body):
    if isinstance(body.get("output_text"), str) and body["output_text"]:
        return body["output_text"]
    chunks = []
    for item in body.get("output", []):
        for c in item.get("content", []):
            if c.get("type") in ("output_text", "text") and c.get("text"):
                chunks.append(c["text"])
    return "\n".join(chunks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", choices=["responses", "chat"], default="responses")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key-env", default="SAKANA_API_KEY")
    ap.add_argument("--effort", default=None, help="responses API reasoning.effort, e.g. max")
    ap.add_argument("--boot", required=True)
    ap.add_argument("--mission", required=True)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--max-tokens", type=int, default=32000)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--dump-prompt", action="store_true", help="print assembled input and exit (no API call)")
    args = ap.parse_args()

    text_in = assemble_input(args.boot, args.mission, args.manifest)
    if args.dump_prompt:
        sys.stdout.write(text_in)
        return 0

    key = os.environ.get(args.api_key_env, "")
    if not key:
        sys.stderr.write(f"[panelist_inline] {args.api_key_env} is unset\n")
        return 2

    if args.api == "responses":
        payload = {"model": args.model, "input": text_in, "max_output_tokens": args.max_tokens}
        if args.effort:
            payload["reasoning"] = {"effort": args.effort}
        url = args.base_url.rstrip("/") + "/responses"
    else:
        payload = {"model": args.model, "max_tokens": args.max_tokens, "temperature": 0.2,
                   "messages": [{"role": "user", "content": text_in}]}
        url = args.base_url.rstrip("/") + "/chat/completions"

    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"[panelist_inline] HTTP {e.code}: {e.read().decode('utf-8','replace')[:800]}\n")
        return 2
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"[panelist_inline] request failed: {e}\n")
        return 2

    out = extract_responses_text(body) if args.api == "responses" else \
        body.get("choices", [{}])[0].get("message", {}).get("content", "")
    if not out:
        sys.stderr.write(f"[panelist_inline] empty/unparsed response: {json.dumps(body)[:800]}\n")
        return 3
    sys.stdout.write(out)
    if not out.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
