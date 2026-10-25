import json
import re
from pathlib import Path

root = Path(".")
xcstrings_path = root / "ClipHarbor" / "Localizable.xcstrings"
with open(xcstrings_path, "r", encoding="utf-8") as f:
    xcstrings_data = json.load(f)

defined_keys = set(xcstrings_data.get("strings", {}).keys())

# Check blocker rules and metadata
rules_path = root / "ClipHarbor" / "blocker_rules.json"
meta_path = root / "ClipHarbor" / "blocker_metadata.json"

with open(rules_path, "r", encoding="utf-8") as f:
    rules = json.load(f)
print(f"Verified blocker_rules.json: {len(rules)} rules")

with open(meta_path, "r", encoding="utf-8") as f:
    meta = json.load(f)
print(f"Verified blocker_metadata.json: version={meta.get('ruleVersion')}, count={meta.get('ruleCount')}, source_commit={meta.get('sourceCommit')}")

# Regex to find NSLocalizedString keys (handling escaped quotes)
ns_localized_pattern = re.compile(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"')

swift_files = list((root / "ClipHarbor").glob("*.swift"))
missing_keys = {}

for sf in swift_files:
    text = sf.read_text(encoding="utf-8")
    matches = ns_localized_pattern.findall(text)
    for raw_k in matches:
        k = raw_k.replace('\\"', '"')
        if k not in defined_keys:
            missing_keys.setdefault(sf.name, []).append(k)

if missing_keys:
    print(f"MISSING KEYS DETECTED ({len(missing_keys)} files):")
    for fname, keys in missing_keys.items():
        print(f"  {fname}: {keys}")
else:
    print("ALL NSLocalizedString keys are defined in Localizable.xcstrings! (0 missing keys)")

print(f"Verified {len(swift_files)} Swift source files.")
