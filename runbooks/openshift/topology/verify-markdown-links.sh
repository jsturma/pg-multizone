#!/usr/bin/env bash
# Validate relative markdown links (files + GitHub-style heading anchors).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export ROOT

python3 << 'PY'
import os, re, sys
from pathlib import Path

ROOT = Path(os.environ["ROOT"])

def extract_headings(path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    in_fence = False
    headings = []
    for line in lines:
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r"^(#{1,6})\s+(.+)$", line)
        if m:
            headings.append(m.group(2).strip())
    return headings

def github_slug(text):
    text = re.sub(r"<[^>]+>", "", text)
    text = text.lower()
    text = re.sub(r"[—–:!?.`\'\",()/\\]", "", text)
    text = re.sub(r"\s+", "-", text.strip())
    return text

link_re = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
broken = []

for md in sorted(ROOT.rglob("*.md")):
    for _text, target in link_re.findall(md.read_text(encoding="utf-8", errors="replace")):
        target = target.strip()
        if not target or target.startswith("http"):
            continue
        path_part, _, anchor = target.partition("#")
        if path_part.startswith("/"):
            file_path = (ROOT / path_part.lstrip("/")).resolve()
        elif path_part:
            file_path = (md.parent / path_part).resolve()
        else:
            file_path = md.resolve()
        if path_part and not file_path.exists():
            broken.append(f"FILE  {md.relative_to(ROOT)} -> {target}")
            continue
        if anchor:
            headings = {github_slug(h) for h in extract_headings(file_path if path_part else md)}
            if anchor not in headings:
                broken.append(f"ANCHOR {md.relative_to(ROOT)} -> {target}")

if broken:
    print("❌  Broken markdown links:", file=sys.stderr)
    for b in broken:
        print(b, file=sys.stderr)
    sys.exit(1)
print("✅  All relative markdown links resolve")
PY
