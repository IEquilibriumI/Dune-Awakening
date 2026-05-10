#!/usr/bin/env bash
set -euo pipefail

NS="${1:-}"
ACTION="${2:-}"
PARTITION_ID="${3:-}"

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
trap 'rm -f "$TMP" "$PATCHED"' EXIT

kubectl -n "$NS" get battlegroup "$BG" -o yaml > "$TMP"

python3 - "$ACTION" "$PARTITION_ID" "$TMP" "$PATCHED" <<'PY'
import sys
import yaml

action = sys.argv[1]
partition_id = int(sys.argv[2])
src = sys.argv[3]
dst = sys.argv[4]

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

survival_world = None
for item in world_partitions:
    if item.get("map") == "Survival_1":
        survival_world = item
        break

if survival_world is None:
    raise SystemExit("ERROR: Could not find worldPartitions map: Survival_1")

parts = survival_world.setdefault("partitions", [])

existing_ids = {int(p["id"]) for p in parts if "id" in p}

if action == "add" and 1 <= partition_id <= 28:
    raise SystemExit(
        f"ERROR: partition/index ids 1-28 are reserved and cannot be added"
    )

if action == "delete" and partition_id not in existing_ids:
    raise SystemExit(
        f"ERROR: partition/index id {partition_id} does not exist in Survival_1"
    )

if action == "add" and partition_id in existing_ids:
    raise SystemExit(
        f"ERROR: partition/index id {partition_id} is already used in Survival_1"
    )

if action == "delete" and 1 <= partition_id <= 28:
    raise SystemExit(
        f"ERROR: partition/index ids 1-28 are protected and cannot be deleted"
    )

if action == "add":
    if partition_id not in existing_ids:
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
    survival_world["partitions"] = [
        p for p in parts if int(p.get("id", -1)) != partition_id
    ]

sets = spec["serverGroup"]["template"]["spec"]["sets"]

survival_set = None
for item in sets:
    if item.get("map") == "Survival_1":
        survival_set = item
        break

if survival_set is None:
    raise SystemExit("ERROR: Could not find serverGroup set map: Survival_1")

active = [int(x) for x in survival_set.get("partitions", [])]

if action == "add":
    if partition_id not in active:
        active.append(partition_id)

elif action == "delete":
    active = [x for x in active if x != partition_id]

active = sorted(active)

survival_set["partitions"] = active
survival_set["replicas"] = len(active)

with open(dst, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PY

kubectl replace -f "$PATCHED"

kubectl replace -f "$PATCHED" >/dev/null 2>&1

if [[ "$ACTION" == "add" ]]; then
  echo "Success survival_1 was added with ID $PARTITION_ID"
else
  echo "Success survival_1 was deleted with ID $PARTITION_ID"
fi
