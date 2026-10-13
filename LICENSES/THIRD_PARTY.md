# Third-party notices

Array is distributed under the MIT License in the repository root. The components below keep their own licenses; these notices do not change those terms.

| Component | Version | License | Notice |
| --- | --- | --- | --- |
| GRDB.swift | 7.11.1 | MIT | [GRDB-MIT.txt](GRDB-MIT.txt) |
| Sparkle | 2.9.5 | MIT | [Sparkle-MIT.txt](Sparkle-MIT.txt) |
| CodeMirror and bundled `@codemirror` / `@lezer` packages | bundled in `Sources/ContinuumRevived/Resources/CodeEditor` | MIT | [CodeMirror.txt](CodeMirror.txt), [CodeMirror-Vim.txt](CodeMirror-Vim.txt) |
| SwiftNIO | 2.101.3 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt), [NOTICE-SwiftNIO.txt](NOTICE-SwiftNIO.txt) |
| swift-crypto | 3.15.1 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt), [NOTICE-SwiftCrypto.txt](NOTICE-SwiftCrypto.txt) |
| swift-asn1 | 1.7.1 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt) |
| swift-atomics | 1.3.1 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt) |
| swift-collections | 1.6.0 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt) |
| swift-system | 1.8.1 | Apache-2.0 | [Apache-2.0.txt](Apache-2.0.txt) |
| swift-markdown | 0.8.0 | Apache-2.0 with Runtime Library Exception | [SwiftMarkdown-Apache-2.0-Runtime-Exception.txt](SwiftMarkdown-Apache-2.0-Runtime-Exception.txt) |
| swift-cmark | 0.8.0 | BSD-3-Clause | [swift-cmark-BSD-3-Clause.txt](swift-cmark-BSD-3-Clause.txt) |
| GhosttyKit | supplied separately by a Ghostty source checkout; not tracked in this repository | MIT, plus licenses for components included by that checkout | [Ghostty-MIT.txt](Ghostty-MIT.txt); see the matching Ghostty checkout for its component notices |

Swift package versions are taken from `Package.resolved`. GhosttyKit is linked from a separately supplied source checkout by `scripts/prepare-ghosttykit.sh`; its exact revision and any bundled component notices therefore depend on the checkout used to build Array.
