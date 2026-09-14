import json
import os
from datetime import datetime, timezone
from pathlib import Path


def load_state(path):
    p = Path(path)
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def save_state(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(p, 0o600)


def assert_owned(found_uuid, state, key, label):
    owned = state.get("objects", {}).get(key)
    if not owned:
        raise RuntimeError(f"{label}: existing object is not owned by this tool")
    if str(found_uuid) != str(owned):
        raise RuntimeError(f"{label}: UUID differs from saved state")


def make_backup(root_dir, payloads):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = Path(root_dir) / stamp
    root.mkdir(parents=True, exist_ok=False)
    os.chmod(root, 0o700)
    for name, data in payloads.items():
        (root / name).write_text(
            json.dumps(data, ensure_ascii=False, indent=2, default=str) + "\n",
            encoding="utf-8",
        )
    return root
