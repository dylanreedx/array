#!/usr/bin/env python3
"""Wait until a release is really live: the deployed appcast serves it and both DMG assets download."""
import argparse
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
NO_CACHE = {"Cache-Control": "no-cache", "Pragma": "no-cache"}


class KeepHead(urllib.request.HTTPRedirectHandler):
    # Python 3.9 turns a redirected HEAD into a GET, which would download the whole DMG.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and req.get_method() == "HEAD":
            new.method = "HEAD"
        return new


OPENER = urllib.request.build_opener(KeepHead)


def fetch_feed(url, timeout):
    busted = f"{url}{'&' if '?' in url else '?'}nocache={time.time_ns()}"
    with OPENER.open(urllib.request.Request(busted, headers=NO_CACHE), timeout=timeout) as response:
        return response.read()


def head_status(url, timeout):
    try:
        with OPENER.open(urllib.request.Request(url, method="HEAD", headers=NO_CACHE), timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except (urllib.error.URLError, OSError) as error:
        return f"unreachable ({error})"


def not_live_reason(args, base, timeout):
    """None when live, otherwise one plain sentence saying what is still missing."""
    try:
        items = ET.fromstring(fetch_feed(args.feed_url, timeout)).findall("./channel/item")
    except (urllib.error.URLError, OSError) as error:
        return f"feed {args.feed_url} unreachable ({error})"
    except ET.ParseError as error:
        return f"feed {args.feed_url} does not parse ({error})"
    builds = [i.findtext(SP + "version") or "" for i in items]
    if str(args.build) not in builds:
        newest = max((int(b) for b in builds if b.isdigit()), default="none")
        return f"feed still serves build {newest}; Vercel has not deployed build {args.build} yet"
    item = items[builds.index(str(args.build))]
    expected = f"{base}Array-{args.version}.dmg"
    served = item.find("enclosure").get("url") if item.find("enclosure") is not None else None
    if served != expected or item.findtext(SP + "shortVersionString") != args.version:
        return (f"feed build {args.build} is {item.findtext(SP + 'shortVersionString')} at {served}; "
                f"expected {args.version} at {expected}")
    for name in ("Array.dmg", f"Array-{args.version}.dmg"):
        status = head_status(base + name, timeout)
        if status != 200:
            return f"feed has build {args.build}, but {name} returns {status} at {base + name}"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--version", required=True)
    parser.add_argument("--feed-url", default="https://arrayapp.dev/appcast.xml")
    parser.add_argument("--download-base")
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--interval", type=float, default=15)
    args = parser.parse_args()
    base = args.download_base or f"https://github.com/dylanreedx/array-releases/releases/download/v{args.version}/"
    base = base if base.endswith("/") else base + "/"

    start = time.monotonic()
    deadline = start + args.timeout
    last, polls = None, 0
    while True:
        polls += 1
        reason = not_live_reason(args, base, max(1.0, min(30.0, deadline - time.monotonic())))
        elapsed = int(time.monotonic() - start)
        if reason is None:
            print(f"live after {elapsed}s ({polls} poll(s)): feed serves build {args.build} ({args.version}); "
                  f"Array.dmg and Array-{args.version}.dmg download", flush=True)
            return 0
        # Say it when it changes, and about once a minute otherwise.
        if reason != last or polls % max(1, int(60 / max(args.interval, 1))) == 0:
            print(f"waiting ({elapsed}s): {reason}", flush=True)
        last = reason
        if time.monotonic() + args.interval > deadline:
            print(f"NOT LIVE after {args.timeout:g}s: {reason}", file=sys.stderr, flush=True)
            return 1
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
