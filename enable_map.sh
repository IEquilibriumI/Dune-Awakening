#!/usr/bin/env bash
set -euo pipefail

NS="${1:-}"

if [[ -z "$NS" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

BG="$(kubectl -n "$NS" get battlegroup -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "$BG" ]]; then
  echo "ERROR: Could not locate BattleGroup in namespace $NS"
  exit 1
fi

TMP="$(mktemp)"
PATCHED="$(mktemp)"
trap 'rm -f "$TMP" "$PATCHED"' EXIT

kubectl -n "$NS" get battlegroup "$BG" -o yaml > "$TMP"

python3 - "$TMP" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()

maps = [
    ("DeepDesert_1", "Deep Desert"),
    ("SH_HarkoVillage", "HarkoVillage"),
    ("SH_Arrakeen", "Arrakeen"),
]

for idx, (section, display) in enumerate(maps, start=1):
    sec_re = re.compile(rf"^\s*\[\s*{re.escape(section)}\s*\]\s*$", re.M)
    m = sec_re.search(text)

    enabled = False

    if m:
        rest = text[m.end():]
        next_section = re.search(r"^\s*\[\s*[^]]+\s*\]\s*$", rest, re.M)
        block = rest[:next_section.start()] if next_section else rest

        min_re = re.search(r"^\s*MinServers?\s*=\s*(\d+)\s*$", block, re.M)

        if min_re:
            enabled = int(min_re.group(1)) >= 1

    mark = "X" if enabled else " "
    print(f"{idx}: [{mark}] {display}")

print("Q: Quit")
PY

echo
read -rp "Select map to toggle (1-3 or Q): " CHOICE

if [[ "$CHOICE" =~ ^[Qq]$ ]]; then
  echo "No changes made."
  exit 0
fi

python3 - "$TMP" "$PATCHED" "$CHOICE" <<'PY'
import re
import sys
import yaml

src = sys.argv[1]
dst = sys.argv[2]
choice = sys.argv[3]

maps = [
    ("DeepDesert_1", "Deep Desert"),
    ("SH_HarkoVillage", "HarkoVillage"),
    ("SH_Arrakeen", "Arrakeen"),
]

if choice not in {"1", "2", "3"}:
    raise SystemExit("ERROR: Invalid selection")

section, display = maps[int(choice) - 1]

with open(src) as f:
    doc = yaml.safe_load(f)

# Remove generated fields
for key in [
    "creationTimestamp",
    "resourceVersion",
    "uid",
    "generation",
    "managedFields",
]:
    doc.get("metadata", {}).pop(key, None)

doc.pop("status", None)

raw = yaml.safe_dump(doc, sort_keys=False)

sec_re = re.compile(rf"^\s*\[\s*{re.escape(section)}\s*\]\s*$", re.M)
m = sec_re.search(raw)

if not m:
    raise SystemExit(f"ERROR: Could not find section {section}")

rest = raw[m.end():]
next_section = re.search(r"^\s*\[\s*[^]]+\s*\]\s*$", rest, re.M)

block_start = m.end()
block_end = block_start + next_section.start() if next_section else len(raw)
block = raw[block_start:block_end]

min_re = re.search(r"^\s*MinServers?\s*=\s*(\d+)\s*$", block, re.M)

current = int(min_re.group(1)) if min_re else 0
new_value = 0 if current >= 1 else 1

if min_re:
    block = re.sub(
        r"^(\s*MinServers?\s*=\s*)\d+",
        rf"\g<1>{new_value}",
        block,
        flags=re.M,
    )
else:
    block += f"\n              MinServers = {new_value}\n"

raw = raw[:block_start] + block + raw[block_end:]

with open(dst, "w") as f:
    f.write(raw)

state = "enabled" if new_value >= 1 else "disabled"
print(f"Success: {display} was {state}")
PY

kubectl replace -f "$PATCHED" >/dev/null

echo "BattleGroup updated successfully."
