import urllib.request
import re
import json
import hashlib
from pathlib import Path

source_url = "https://raw.githubusercontent.com/AdAway/adaway.github.io/master/hosts.txt"
commit_sha = "f39ba0a523564447dfa94e40327c1a14c02304dc"

req = urllib.request.Request(source_url, headers={"User-Agent": "ClipHarbor/1.0"})
with urllib.request.urlopen(req, timeout=20) as resp:
    raw_data = resp.read()

sha256 = hashlib.sha256(raw_data).hexdigest()
text = raw_data.decode("utf-8", errors="replace")

domains = set()
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) >= 2:
        d = parts[1].strip().lower()
        if d not in ("localhost", "localhost.localdomain", "broadcasthost", "local") and not d.startswith("127.") and not d.startswith("::"):
            domains.add(d)

sorted_domains = sorted(list(domains))
rules = []
for d in sorted_domains:
    escaped = re.escape(d)
    rules.append({
        "trigger": {
            "url-filter": f"^https?://([^/]+\\.)?{escaped}[:/]"
        },
        "action": {
            "type": "block"
        }
    })

meta = {
    "schemaVersion": 1,
    "ruleVersion": "adaway-20261026-v1",
    "sourceName": "AdAway Default Blocklist",
    "sourceURL": source_url,
    "sourceCommit": commit_sha,
    "sourceLicense": "CC BY 3.0 (Creative Commons Attribution 3.0)",
    "sourceLicenseURL": "https://creativecommons.org/licenses/by/3.0/",
    "sourceContributors": "Kicelo, Dominik Schuermann",
    "sourceSHA256": sha256,
    "ruleCount": len(rules),
    "adaptationNote": "Converted from hosts format to WebKit Content Blocker url-filter JSON rules."
}

out_dir = Path("ClipHarbor")
rules_path = out_dir / "blocker_rules.json"
meta_path = out_dir / "blocker_metadata.json"

with open(rules_path, "w", encoding="utf-8") as f:
    json.dump(rules, f, separators=(",", ":"))

with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)

print(f"Generated {len(rules)} rules in {rules_path} (size: {rules_path.stat().st_size} bytes)")
print(f"Generated metadata in {meta_path}")
