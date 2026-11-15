#!/usr/bin/env python3
"""Drive the production appcast append on a copy of the real feed; no network, no Keychain."""
import base64
import email.utils
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parent
APPEND = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else SCRIPTS / "append-appcast.py"
REAL_FEED = SCRIPTS.parent / "website/public/appcast.xml"
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
FAKE_SIGN = f'''#!{sys.executable}
import os, sys
mode = os.environ.get("FAKE_SIGN_MODE", "ok")
size = os.path.getsize(sys.argv[1])
if mode == "garbage": print("Error: no private key in Keychain? signature=")
else: print('sparkle:edSignature="{SIGNATURE}" length="%d"' % (size + (mode == "wrong-length")))
'''
ORIGINAL = REAL_FEED.read_bytes()
ITEMS = ET.fromstring(ORIGINAL).findall("./channel/item")
NEXT = max(int(i.findtext(SP + "version")) for i in ITEMS) + 1
SCRATCH = tempfile.TemporaryDirectory(prefix="array-appcast-append-")


def run(temp, command, mode="ok"):
    env = dict(os.environ, SPARKLE_SIGN_UPDATE=str(temp / "sign_update"), FAKE_SIGN_MODE=mode)
    return subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)


def setup(version):
    temp = Path(tempfile.mkdtemp(dir=SCRATCH.name))
    (temp / "appcast.xml").write_bytes(ORIGINAL)
    (temp / "sign_update").write_text(FAKE_SIGN)
    (temp / "sign_update").chmod(0o755)
    dmg = temp / f"Array-{version}.dmg"
    dmg.write_bytes(b"not really a disk image\n" * 1000)
    return temp, dmg


def append(version, build, *extra, mode="ok"):
    temp, dmg = setup(version)
    result = run(temp, [sys.executable, str(APPEND), "--feed", str(temp / "appcast.xml"), "--dmg", str(dmg),
                        "--version", version, "--build", str(build), *extra], mode)
    return temp, dmg, result


def assert_appended(temp, dmg, result, version, build, tip):
    assert result.returncode == 0, f"exit {result.returncode}: {result.stdout}"
    new = (temp / "appcast.xml").read_bytes()
    first = re.search(rb"^[ \t]*<item>", ORIGINAL, re.M).start()
    grown = len(new) - len(ORIGINAL)
    block = new[first:first + grown]
    assert grown > 0 and new[:first] == ORIGINAL[:first] and new[first + grown:] == ORIGINAL[first:], \
        "existing bytes changed outside one inserted block"
    lines = block.decode().splitlines()
    assert lines[0] == "        <item>" and lines[-1] == "        </item>" and block.count(b"<item>") == 1, block
    assert all(line.startswith(" " * 12 + "<") for line in lines[1:-1]), "child lines not 12-space indented"
    items = ET.fromstring(new).findall("./channel/item")
    assert len(items) == len(ITEMS) + 1
    assert [i.findtext("pubDate") for i in items[1:]] == [i.findtext("pubDate") for i in ITEMS], "old pubDates moved"
    assert any(i.findtext("title") == "0.2.0" and i.findtext(SP + "version") == "2" for i in items), "0.2.0 item lost"
    head, enclosure = items[0], items[0].find("enclosure")
    url = f"https://github.com/dylanreedx/array-releases/releases/download/v{version}/Array-{version}.dmg"
    assert head.findtext("title") == (f"Array {version}" if tip else version)
    assert head.findtext(SP + "version") == str(build) and head.findtext(SP + "shortVersionString") == version
    assert enclosure.get("url") == url and enclosure.get("length") == str(dmg.stat().st_size)
    assert enclosure.get(SP + "edSignature") == SIGNATURE and enclosure.get("type") == "application/octet-stream"
    assert head.findtext(SP + "minimumSystemVersion") == "14.0" and head.findtext(SP + "hardwareRequirements") == "arm64"
    assert head.findtext(SP + "releaseNotesLink").endswith(f"/releases/tag/v{version}")
    assert email.utils.parsedate_to_datetime(head.findtext("pubDate")) is not None
    if tip:
        assert head.findtext(SP + "channel") == "tip" and head.find(SP + "phasedRolloutInterval") is None
    else:
        assert head.find(SP + "channel") is None and head.findtext(SP + "phasedRolloutInterval") == "3600"


def assert_refused(temp, result, why):
    assert result.returncode == 2, f"expected exit 2 ({why}), got {result.returncode}: {result.stdout}"
    assert (temp / "appcast.xml").read_bytes() == ORIGINAL, "refused run changed the feed"
    assert "refused" in result.stdout and why in result.stdout, result.stdout


def stable():
    assert_appended(*append("99.0.0", NEXT), "99.0.0", NEXT, tip=False)


def tip():
    version = "99.0.0-tip.0123456789ab"
    assert_appended(*append(version, NEXT, "--channel", "tip"), version, NEXT, tip=True)


def wrapper():
    temp, dmg = setup("99.0.0")
    (temp / "scripts").mkdir()
    shutil.copy(SCRIPTS / "generate-appcast.sh", temp / "scripts")
    shutil.copy(APPEND, temp / "scripts/append-appcast.py")
    result = run(temp, ["/bin/bash", str(temp / "scripts/generate-appcast.sh"), "--dmg", str(dmg),
                        "--version", "99.0.0", "--build", str(NEXT), "--feed", str(temp / "appcast.xml")])
    assert_appended(temp, dmg, result, "99.0.0", NEXT, tip=False)


def refusals():
    newest = ITEMS[0].findtext(SP + "version")
    temp, _, result = append("99.0.0", newest)
    assert_refused(temp, result, f"build {newest} is already in the feed")
    lower = min(int(i.findtext(SP + "version")) for i in ITEMS) - 1
    temp, _, result = append("99.0.0", lower)
    assert_refused(temp, result, "is not above the feed's newest build")
    temp, _, result = append(ITEMS[0].findtext(SP + "shortVersionString"), NEXT)
    assert_refused(temp, result, "is already in the feed")
    temp, _, result = append("99.0.0", NEXT, mode="garbage")
    assert_refused(temp, result, "sign_update printed no signature")
    temp, _, result = append("99.0.0", NEXT, mode="wrong-length")
    assert_refused(temp, result, "sign_update length")


def broken_feed():
    temp, dmg = setup("99.0.0")
    broken = ORIGINAL[:-40]
    (temp / "appcast.xml").write_bytes(broken)
    result = run(temp, [sys.executable, str(APPEND), "--feed", str(temp / "appcast.xml"), "--dmg", str(dmg),
                        "--version", "99.0.0", "--build", str(NEXT)])
    assert result.returncode == 2 and "does not parse" in result.stdout, result.stdout
    assert (temp / "appcast.xml").read_bytes() == broken


failures = []
for case in (stable, tip, wrapper, refusals, broken_feed):
    try:
        case()
        print("PASS", case.__name__)
    except AssertionError as error:
        failures.append(case.__name__)
        print("FAIL", case.__name__, error)
if failures:
    raise SystemExit(1)
print(f"PASS append-only appcast on the real feed ({len(ITEMS)} items, next build {NEXT})")
