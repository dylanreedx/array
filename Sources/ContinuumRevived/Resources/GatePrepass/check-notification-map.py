#!/usr/bin/env python3
"""Structural sender census. Behavioral confidence belongs to Swift witnesses.

Scans owned source for known notification APIs, including forbidden alternate
senders. This is a tripwire, not a proof against arbitrary dynamically generated
code, new APIs, or agents executing their own shell notification commands.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    "local-banner": r"\b(?:UNNotificationRequest|NSUserNotification)\s*\(",
    "badge": r"\.setBadgeCount\s*\(",
    "dock-badge": r"\.badgeLabel\s*=(?!=)",
    "live-activity": r"\bActivity(?:<[^>]+>)?\s*\.\s*request\s*\(",
    "apns-type": r'''(?:\[\s*["']apns-push-type["']\s*\]\s*=|forHTTPHeaderField:\s*["']apns-push-type["']|["']apns-push-type["']\s*:)''',
    "apns-endpoint": r"\bapi\.(?:sandbox\.)?push\.apple\.com\b",
    "simulator-push": r"\bxcrun\s+simctl\s+push\b",
    "audio": r"\bAVAudioPlayer\s*\(",
    "alternate-sender": r"\b(?:NSUserNotificationCenter|terminal-notifier|requestUserAttention)\b|\bdisplay\s+notification\b",
}


def census(text):
    # Whole-line comments do not create a sender. Keep strings: APNs routing is
    # expressed as literal strings. Diagnostic echo text is excluded separately.
    text = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith(("//", "#", "*", "echo ", "print(")))
    return {kind: len(re.findall(pattern, text)) for kind, pattern in PATTERNS.items()
            if re.search(pattern, text)}


def actual_senders(root):
    result = {}
    for folder in ("Sources", "iOS", "scripts"):
        for path in (root / folder).rglob("*"):
            if not path.is_file() or path.suffix not in {".swift", ".sh", ".ts", ".js", ".cjs", ".m", ".mm", ".py"}:
                continue
            if path.resolve() == Path(__file__).resolve():
                continue  # The scanner's own mutation fixtures are not senders.
            if any(part.endswith(("Checks", "Tests")) for part in path.parts):
                continue
            counts = census(path.read_text())
            if counts:
                result[str(path.relative_to(root))] = counts
    return result


def validate(actual, inventory, documented, decision_ids):
    failures = []
    expected = {}
    for source, kinds in inventory.items():
        expected[source] = {}
        for kind, entry in kinds.items():
            expected[source][kind] = entry["count"]
            if not entry["paths"] or not set(entry["paths"]) <= documented:
                failures.append(f"{source}:{kind}: missing documented path")
    for source in sorted(set(expected) | set(actual)):
        if expected.get(source) != actual.get(source):
            failures.append(f"{source}: mapped={expected.get(source, {})} actual={actual.get(source, {})}")
    for path in sorted(decision_ids - documented):
        failures.append(f"hosted decision {path} is absent from notification-paths.md")
    return failures


def self_test():
    assert census('let headers = ["apns-push-type": "alert"]')["apns-type"] == 1
    # Mutate the scanner's inputs, never the user's workspace.
    known = {"sender.swift": {"local-banner": {"count": 1, "paths": ["MAC-01"]}}}
    baseline = {"sender.swift": census('let request = UNNotificationRequest(identifier: "fixture")')}
    assert not validate(baseline, known, {"MAC-01"}, set())
    added = dict(baseline, **{"new.swift": census("UNNotificationRequest(identifier: unknown)")})
    assert validate(added, known, {"MAC-01"}, set()), "new sender escaped census"
    changed = {"sender.swift": census("UNNotificationRequest(a)\nUNNotificationRequest(b)")}
    assert validate(changed, known, {"MAC-01"}, set()), "additional sender escaped census"
    assert validate(baseline, known, set(), set()), "undocumented path escaped census"
    assert validate(baseline, known, {"MAC-01"}, {"H-99"}), "unmapped policy decision escaped census"
    assert census("// UNNotificationRequest(fake)\n# xcrun simctl push fake") == {}
    for kind, sample in {
        "badge": "center.setBadgeCount(1)", "dock-badge": "dock.badgeLabel = value",
        "live-activity": "Activity.request(attributes: a)",
        "apns-type": 'request.setValue("alert", forHTTPHeaderField: "apns-push-type")',
        "apns-endpoint": 'let host = "api.push.apple.com"',
        "simulator-push": "if xcrun simctl push device bundle file; then",
        "audio": "let player = AVAudioPlayer(contentsOf: url)",
        "alternate-sender": 'osascript -e \'display notification "hello"\'',
    }.items():
        assert census(sample).get(kind) == 1, f"{kind} not detected"
    print("Notification map structural mutation checks passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--report", action="store_true", help="print current census, never change the inventory")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    actual = actual_senders(ROOT)
    if args.report:
        print(json.dumps(actual, indent=2, sort_keys=True))
        return 0
    inventory = json.loads((ROOT / "docs/internals/notification-senders.json").read_text())
    document = (ROOT / "docs/internals/notification-paths.md").read_text()
    documented = set(re.findall(r"^\| ([A-Z]+-\d+) \|", document, re.M))
    source = "\n".join((ROOT / "Sources/ContinuumRevivedRelayCore" / name).read_text()
                       for name in ["RelayNotificationDecision.swift", "RelayNotificationOutbox.swift", "RelayNotificationOwnership.swift"])
    decision_ids = set(re.findall(r'\b\w+ = "([A-Z]+-\d+)"', source))
    failures = validate(actual, inventory, documented, decision_ids)
    if failures:
        print("FAIL notification map census:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print(f"Notification sender census passed: {len(actual)} source files; hosted decision IDs mapped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
