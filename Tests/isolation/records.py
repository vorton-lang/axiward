"""Raw and shareable records for native isolation checks."""
import hashlib
import json
import re
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]


def public(value):
    if isinstance(value, dict):
        return {public(key): public(item) for key, item in value.items()}
    if isinstance(value, list):
        return [public(item) for item in value]
    if isinstance(value, str):
        for root, label in [(PROJECT, "AXIWARD"), (Path.home(), "USER_HOME")]:
            for slash in (1, 2, 4, 8):
                for path in (str(root).replace("\\", "\\" * slash), root.as_posix()):
                    value = re.sub(re.escape(path), lambda _: label, value, flags=re.IGNORECASE)
        return value
    return value


def save(name, result, raw_path):
    raw_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    record = public(result)
    record["rawRecord"] = raw_path.relative_to(PROJECT).as_posix()
    record["rawSha256"] = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    (raw_path.parent / name).write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
