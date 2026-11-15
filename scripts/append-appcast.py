#!/usr/bin/env python3
"""Append one signed release item to the Sparkle appcast as a pure text splice.

Regenerating the whole feed from releases/ dropped the 0.2.0 item (its DMG is
not archived) and rewrote old pubDates from DMG mtimes. This script never
re-serializes the feed: every existing byte stays as it is, and the new item is
inserted before the first <item> line in the layout the newest items use.
"""
import argparse
import base64
import email.utils
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASES = "https://github.com/dylanreedx/array-releases/releases"
DEFAULT_SIGN = Path(__file__).resolve().parent.parent / ".build/artifacts/sparkle/Sparkle/bin/sign_update"


def refuse(reason):
    print(f"append-appcast: refused: {reason}", file=sys.stderr)
    raise SystemExit(2)


def build_of(item):
    value = item.findtext(SPARKLE + "version")
    if value is None and item.find("enclosure") is not None:
        value = item.find("enclosure").get(SPARKLE + "version")
    return value


def sign(dmg):
    tool = os.environ.get("SPARKLE_SIGN_UPDATE", str(DEFAULT_SIGN))
    result = subprocess.run([tool, str(dmg)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        refuse(f"sign_update exited {result.returncode}: {result.stderr.strip() or result.stdout.strip()}")
    match = re.fullmatch(r'sparkle:edSignature="([A-Za-z0-9+/]+={0,2})" length="(\d+)"', result.stdout.strip())
    if not match:
        refuse(f"sign_update printed no signature and length: {result.stdout.strip()!r}")
    signature, length = match.groups()
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError
    except ValueError:
        refuse("sign_update signature is not a 64-byte Ed25519 signature")
    # A length that is not this file's means the signature is not for this file.
    if int(length) != dmg.stat().st_size:
        refuse(f"sign_update length {length} != {dmg.name} size {dmg.stat().st_size}")
    return signature, length


def item_text(indent, args, signature, length):
    child = indent + "    "
    version = args.version
    fields = [
        ("title", f"Array {version}" if args.channel == "tip" else version),
        ("pubDate", args.pub_date or email.utils.formatdate(localtime=True)),
        ("link", "https://arrayapp.dev"),
        ("sparkle:version", str(args.build)),
        ("sparkle:shortVersionString", version),
    ]
    if args.channel == "tip":
        fields.append(("sparkle:channel", "tip"))
    fields += [("sparkle:minimumSystemVersion", args.min_system),
               ("sparkle:hardwareRequirements", "arm64")]
    lines = [f"{indent}<item>"]
    lines += [f"{child}<{name}>{escape(value)}</{name}>" for name, value in fields]
    url = f"{RELEASES}/download/v{version}/Array-{version}.dmg"
    lines.append(f"{child}<enclosure url={quoteattr(url)} length={quoteattr(length)} "
                 f"type=\"application/octet-stream\" sparkle:edSignature={quoteattr(signature)} />")
    if args.channel != "tip":
        lines.append(f"{child}<sparkle:phasedRolloutInterval>{args.rollout_seconds}</sparkle:phasedRolloutInterval>")
    lines.append(f"{child}<sparkle:releaseNotesLink>{escape(f'{RELEASES}/tag/v{version}')}</sparkle:releaseNotesLink>")
    lines.append(f"{indent}</item>")
    return ("\n".join(lines) + "\n").encode("utf-8"), url


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", required=True, type=Path)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--channel", choices=["tip"])
    parser.add_argument("--rollout-seconds", type=int)
    parser.add_argument("--pub-date")
    parser.add_argument("--min-system", default="14.0")
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+[0-9A-Za-z.+-]*", args.version):
        refuse(f"version {args.version!r} is not X.Y.Z[suffix]")
    if args.channel == "tip" and args.rollout_seconds is not None:
        refuse("tip items are never phased")
    if args.channel != "tip":
        args.rollout_seconds = 3600 if args.rollout_seconds is None else args.rollout_seconds
        if args.rollout_seconds <= 0:
            refuse("--rollout-seconds must be positive")
    if args.dmg.name != f"Array-{args.version}.dmg" or not args.dmg.is_file():
        refuse(f"--dmg must be an existing Array-{args.version}.dmg, got {args.dmg}")

    before = args.feed.read_bytes()
    try:
        old_items = ET.fromstring(before).findall("./channel/item")
    except ET.ParseError as error:
        refuse(f"{args.feed} does not parse: {error}")
    builds = [build_of(item) for item in old_items]
    if any(b is None or not b.isdigit() for b in builds):
        refuse("an existing item has no numeric sparkle:version")
    if str(args.build) in builds:
        refuse(f"build {args.build} is already in the feed")
    if old_items and args.build <= max(map(int, builds)):
        refuse(f"build {args.build} is not above the feed's newest build {max(map(int, builds))}")
    if args.version in [item.findtext(SPARKLE + "shortVersionString") for item in old_items]:
        refuse(f"version {args.version} is already in the feed")
    first = re.search(rb"^([ \t]*)<item>", before, re.M)
    if not first:
        refuse("the feed has no <item> line to insert before")

    signature, length = sign(args.dmg)
    block, url = item_text(first.group(1).decode(), args, signature, length)
    after = before[:first.start()] + block + before[first.start():]

    # The splice must leave every old item exactly as it parsed before.
    new_items = ET.fromstring(after).findall("./channel/item")
    assert len(new_items) == len(old_items) + 1, "item count did not grow by one"
    assert [ET.tostring(i) for i in new_items[1:]] == [ET.tostring(i) for i in old_items], "an old item changed"
    head = new_items[0]
    enclosure = head.find("enclosure")
    assert (build_of(head), head.findtext(SPARKLE + "shortVersionString"), head.findtext(SPARKLE + "channel"),
            enclosure.get("url"), enclosure.get("length"), enclosure.get(SPARKLE + "edSignature")) == \
        (str(args.build), args.version, args.channel, url, length, signature), "new item did not round-trip"

    fd, temp = tempfile.mkstemp(dir=args.feed.parent, prefix=".appcast-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(after)
        os.chmod(temp, args.feed.stat().st_mode & 0o7777)
        os.replace(temp, args.feed)
    except BaseException:
        os.unlink(temp)
        raise
    print(f"appended {args.channel or 'stable'} {args.version} (build {args.build}) to {args.feed}; "
          f"{len(old_items)} existing item(s) untouched")


if __name__ == "__main__":
    main()
