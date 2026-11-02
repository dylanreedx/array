#!/usr/bin/env python3
"""Put the pre-archive 0.2.0 item back at the end of the appcast if the
generator dropped it (it has on every release since 0.7.3x). Prints what it did."""
import sys
from pathlib import Path
here = Path(__file__).resolve().parent
feed = Path(sys.argv[1] if len(sys.argv) > 1 else here.parents[1] / "website/public/appcast.xml")
item = (here / "appcast-0.2.0-item.xml").read_text()
text = feed.read_text()
if "<sparkle:shortVersionString>0.2.0<" in text:
    print("0.2.0 already present; nothing to do")
    sys.exit(0)
assert text.count("    </channel>") == 1, "unexpected appcast shape"
feed.write_text(text.replace("    </channel>", item + "    </channel>"))
print(f"re-inserted 0.2.0 into {feed}")
