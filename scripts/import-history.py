"""Import the bounded legacy Axiward workspace into repository history.

Source files and run records are retained. Machine-local paths are anonymized;
both original and archived SHA-256 are recorded. No source directory is deleted.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--legacy", required=True, type=Path)
args = parser.parse_args()
source = args.legacy.resolve()
repo = Path(__file__).resolve().parent.parent
destination = repo / "history/bootstrap"
destination.mkdir(parents=True, exist_ok=False)
allowed = {".md", ".lean", ".py", ".ps1", ".cs", ".toml", ".json", ".jsonl", ".log", ".txt", ".rules", ".svg", ".png"}
skip_dirs = {".lake", ".git", "__pycache__", "node_modules", "lean-4.34.0-windows", "protocol"}
records, omitted = [], []
secret = re.compile(r"\b(?:sk-[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{24,})\b")
aliases = [(str(source), "LEGACY_WORKSPACE"), (str(Path.home()), "USER_HOME")]
for base in ("outputs", "work"):
    for directory, children, files in os.walk(source / base):
        children[:] = sorted(x for x in children if x not in skip_dirs and not x.endswith(".git"))
        for name in sorted(files):
            path = Path(directory) / name
            relative = path.relative_to(source)
            if path.suffix.lower() not in allowed and name != "lean-toolchain":
                continue
            if name.lower() in {"auth.json", "credentials.json"} or "user-config" in name.lower():
                omitted.append({"path": relative.as_posix(), "reason": "host configuration, not project history"})
                continue
            original = path.read_bytes()
            redacted = False
            if path.suffix.lower() == ".png":
                archived = original
            else:
                encoding = "utf-16" if original.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
                text = original.decode(encoding)
                if secret.search(text):
                    raise RuntimeError(f"Credential-shaped value requires review: {relative}")
                for value, replacement in aliases:
                    for variant in [value.replace("\\", "\\\\"), value.replace("\\", "/"), value]:
                        text = re.sub(re.escape(variant), lambda _: replacement, text, flags=re.IGNORECASE)
                text = re.sub(r"yyf-laptop", "HOST", text, flags=re.IGNORECASE)
                archived = text.encode("utf-8")
                redacted = archived != original
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archived)
            records.append({"path": relative.as_posix(), "originalSha256": hashlib.sha256(original).hexdigest(),
                            "archivedSha256": hashlib.sha256(archived).hexdigest(), "normalized": redacted})
manifest = {"importedAt": "2026-09-18", "source": "former local Axiward task workspace", "files": records,
            "omitted": omitted, "excludedGeneratedDirectories": sorted(skip_dirs),
            "note": "Imported now, not retroactively committed on the original run dates. Normalized paths are archival placeholders, not an executable configuration."}
(destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"files": len(records), "bytes": sum((destination / r['path']).stat().st_size for r in records)}))
