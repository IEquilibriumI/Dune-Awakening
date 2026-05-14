#!/usr/bin/env bash
set -euo pipefail

NS="${1:-}"
ACTION="${2:-}"
PARTITION_ID="${3:-}"

MAP_NAME="DeepDesert_1"

if [[ -z "$NS" || -z "$ACTION" || -z "$PARTITION_ID" ]]; then
  echo "Usage: $0 <namespace> add|delete <partition_id>"
  exit 1
fi

if [[ "$ACTION" != "add" && "$ACTION" != "delete" ]]; then
  echo "ERROR: action must be add or delete"
  exit 1
fi

BG="$(kubectl -n "$NS" get battlegroup -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "$BG" ]]; then
  echo "ERROR: Could not locate BattleGroup in namespace $NS"
  exit 1
fi

TMP="$(mktemp)"
PATCHED="$(mktemp)"
BACKUP="/root/${BG}-before-${ACTION}-${MAP_NAME}-${PARTITION_ID}-$(date +%Y%m%d-%H%M%S).yaml"

trap 'rm -f "$TMP" "$PATCHED"' EXIT

kubectl -n "$NS" get battlegroup "$BG" -o yaml > "$TMP"
cp "$TMP" "$BACKUP"

python3 - "$ACTION" "$PARTITION_ID" "$TMP" "$PATCHED" <<'PY'
import sys
import re
import yaml

action = sys.argv[1]
partition_id = int(sys.argv[2])
src = sys.argv[3]
dst = sys.argv[4]

MAP_NAME = "DeepDesert_1"

with open(src) as f:
    doc = yaml.safe_load(f)

for key in [
    "creationTimestamp",
    "resourceVersion",
    "uid",
    "generation",
    "managedFields",
]:
    doc.get("metadata", {}).pop(key, None)

doc.pop("status", None)

spec = doc["spec"]

world_partitions = spec["database"]["template"]["spec"]["deployment"]["spec"]["worldPartitions"]

target_world = None
for item in world_partitions:
    if item.get("map") == MAP_NAME:
        target_world = item
        break

if target_world is None:
    raise SystemExit(f"ERROR: Could not find worldPartitions map: {MAP_NAME}")

parts = target_world.setdefault("partitions", [])
existing_ids = {int(p["id"]) for p in parts if "id" in p}

if action == "add" and 1 <= partition_id <= 28:
    raise SystemExit("ERROR: partition/index ids 1-28 are reserved and cannot be added")

if action == "delete" and partition_id not in existing_ids:
    raise SystemExit(f"ERROR: partition/index id {partition_id} does not exist in {MAP_NAME}")

if action == "add" and partition_id in existing_ids:
    raise SystemExit(f"ERROR: partition/index id {partition_id} is already used in {MAP_NAME}")

if action == "delete" and 1 <= partition_id <= 28:
    raise SystemExit("ERROR: partition/index ids 1-28 are protected and cannot be deleted")

if action == "add":
    existing_dimensions = [
        int(p.get("dimension", 0))
        for p in parts
        if isinstance(p, dict)
    ]
    next_dimension = max(existing_dimensions, default=-1) + 1

    parts.append({
        "dimension": next_dimension,
        "disable": False,
        "id": partition_id,
        "maxX": 1,
        "maxY": 1,
        "minX": 0,
        "minY": 0,
    })

elif action == "delete":
    target_world["partitions"] = [
        p for p in parts if int(p.get("id", -1)) != partition_id
    ]

active_ids = sorted(int(p["id"]) for p in target_world["partitions"] if "id" in p)
active_count = len(active_ids)

# If DeepDesert_1 exists as a normal serverGroup set, update it.
# Some builds appear to manage Deep Desert through Director instead, so absence is not fatal.
sets = spec.get("serverGroup", {}).get("template", {}).get("spec", {}).get("sets", [])
target_set = None

for item in sets:
    if item.get("map") == MAP_NAME:
        target_set = item
        break

if target_set is not None:
    target_set["partitions"] = active_ids
    target_set["replicas"] = active_count

# Update director.ini if present.
director_files = (
    spec.get("utilities", {})
        .get("director", {})
        .get("spec", {})
        .get("configFiles", {})
        .get("files", {})
)

director_ini = director_files.get("director.ini")

if director_ini:
    # Ensure section exists
    section_pattern = rf"(?m)^\[ {re.escape(MAP_NAME)} \]\n"
    if not re.search(section_pattern, director_ini):
        director_ini += f"\n[ {MAP_NAME} ]\nNumExtraServers = 0\nMinServers = 1\n"

    # Replace inside section only
    def update_section(match):
        section = match.group(0)

        min_servers = active_count
        num_extra = max(0, active_count - 1)

        if re.search(r"(?m)^MinServers\s*=", section):
            section = re.sub(r"(?m)^MinServers\s*=.*$", f"MinServers = {min_servers}", section)
        else:
            section += f"MinServers = {min_servers}\n"

        if re.search(r"(?m)^NumExtraServers\s*=", section):
            section = re.sub(r"(?m)^NumExtraServers\s*=.*$", f"NumExtraServers = {num_extra}", section)
        else:
            section += f"NumExtraServers = {num_extra}\n"

        return section

    director_ini = re.sub(
        rf"(?ms)^\[ {re.escape(MAP_NAME)} \]\n.*?(?=^\[ |\Z)",
        update_section,
        director_ini,
        count=1,
    )

    director_files["director.ini"] = director_ini

with open(dst, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PY

kubectl replace -f "$PATCHED"

if [[ "$ACTION" == "add" ]]; then
  echo "Success: $MAP_NAME was added with ID $PARTITION_ID"
else
  echo "Success: $MAP_NAME was deleted with ID $PARTITION_ID"
fi

echo "Backup saved to: $BACKUP"