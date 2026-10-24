# Images in file tiles — research and release recommendation

Research date: 2026-10-23. Planning only; no product code, build, app launch, or codec probe was performed. Platform floor in `Package.swift` is macOS 14. API availability and actual codec fixtures must therefore be exercised on macOS 14 as well as the current OS before a support claim ships.

## Recommendation

Ship a native, read-only image surface within the existing file tile, with a bounded ImageIO decoding service and explicit capability/failure states. First release: PNG, JPEG, GIF poster frames, TIFF primary/first image, BMP, HEIC/HEIF, WebP, and icon formats where the running system actually decodes the fixture. Make SVG an explicit separately gated slice: source editing remains useful immediately; safe static rendering requires its own prototype and witness. Broader ImageIO formats can work opportunistically without promising every variant. Animated playback, image editing, RAW development, HDR reference fidelity, and layered design-document editing are later work.

“Most images” should mean broad local preview coverage with honest fallbacks, not a filename allowlist that claims success before decoding. UTType identifies content; it is not proof of an installed decoder. Apple provides a runtime list of readable ImageIO type identifiers, and explicitly warns that supported formats differ by platform. [I1, I2]

## Existing code and integration boundaries

- `Sources/ContinuumRevivedCore/FilePreview.swift`: `Presentation` currently has source text and Markdown only. Loading imposes a 1 MiB text budget, rejects NUL/non-UTF8 data, and returns a string/unavailable result. Image decoding must branch before this UTF-8 read, with a separate budget; raising the text cap does not solve binary rendering.
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`: `loadFile()` and `apply(_:)` assume text, recovery drafts, CodeMirror/Markdown, editor state, and language-service lifecycle. Introduce a presentation-level routing boundary rather than pretending an image is an editable text session. Preserve document location, title, move/trash handling, open/reveal routing, focus, hydration, and scene retirement.
- `CanvasBackgroundImageCache.swift` already demonstrates off-main ImageIO thumbnails, bucketed target sizes, counted cache work, generation checks, and deliberately reversed stale completions in QA. Reuse the design, not its four-entry screen-background cache verbatim: a canvas can own many image files.
- `AgentComposer/ComposerImageThumbnailPipeline.swift` already has leases, cancellation-aware awaiters, a decoded-byte cache budget, file signature keys, and transformed ImageIO thumbnails. Composer thumbnails encode PNG for their consumer. A viewer should normally retain a bounded `CGImage` directly rather than encode and decode again. Audit shared extraction only after deciding ownership and residency semantics; no broad refactor is necessary for the first surface.
- File tiles already have a surface-residency protocol and explicit exclusion for WKWebView snapshots. A new image body must connect content revision, zoom/scroll state and retirement to that system. It must not decode from `layout()` or canvas camera callbacks. See `docs/internals/performance.md`.

## Format contract

The support column below is a proposed product contract, not observed runtime results. Actual file decoding is the final authority. Use extension/UTType to choose a likely route, then inspect the ImageIO source type; mismatches and corrupt input need an honest state. [I1, I3]

| Family | Proposed near-release behavior | Qualification / later work |
| --- | --- | --- |
| PNG, JPEG/JPG | Native bounded still preview; transparency for PNG; orientation and embedded profile respected | Baseline fixture-backed commitment; progressive/truncated files must fail safely |
| GIF | Still poster with a visible “Animation not playing” indication when animation metadata is present | Image count alone is insufficient to label animation; multi-page containers also have multiple images |
| APNG | Poster if decoded, same explicit static indication | Animation API documents GIF/APNG, but static loading and animation metadata still require fixtures [I4] |
| TIFF/TIF | First/primary image with visible “Image 1 of N” for multiple pages | Do not imply complete multi-page navigation or scientific/float fidelity |
| HEIC/HEIF | Primary image when the runtime decoder succeeds | Containers may include auxiliary/spatial/alternate representations; not an animation just because count > 1 |
| WebP | Native still when the running ImageIO decoder succeeds | UTType.webP existing does not establish animated WebP playback support [I3] |
| BMP, ICO, ICNS | Native still when the runtime decoder succeeds | Icons have multiple representations; select useful primary/best representation rather than promise animation |
| JPEG2000, TGA, PSD composite, camera RAW/DNG, EXR and other ImageIO-readable content | Best-effort preview or system preview fallback, clearly described | No guaranteed format-wide fidelity; no PSD layer editing, RAW development or high-depth analysis |
| AVIF, JPEG XL and less common modern formats | Attempt only when runtime capability and decoding succeed | Do not infer availability from Safari support; test on minimum/current macOS and publish only verified claims |
| SVG | Retain source editor; separately gate a safe static preview | UTType.svg conforms to image but is not a guarantee that ImageIO rasterizes arbitrary SVG [I3, I5] |
| PDF | Route to a document viewer, not a raster-image special case | Multi-page text/select/search deserves separate PDFKit planning |

## Viewer UX

Use one drawing view inside a scroll/zoom container, bounded controls, and existing Array tokens. Default to aspect-fit without cropping. Include Fit, actual pixel scale, zoom percentage/step controls, pan when enlarged, checkerboard transparency, original dimensions, format and file size. Explain when a bounded preview prevents original-pixel inspection; a 4096-pixel preview enlarged to 100% is not the original. “Open in Default App” and Reveal in Finder remain available for unavailable or unsupported content. Use Array's existing choice components for any dropdown.

Keep canvas zoom and image zoom separate. Scroll/pinch behavior must be deliberate and agree with focus/gesture ownership so exploring an image does not unexpectedly move the whole workspace. Restoring a tile may restore fit/zoom/pan as presentation state; changes to the file reset invalid bounds. Image pixels and metadata are transient cache state and should not be persisted into canvas JSON. Any new user-editable persisted property needs WorkspaceAPIExposure classification.

Do not autoplay many GIFs in a spatial workspace. The first release can ship static with a clear indicator. A later explicit Play command should animate only the focused visible tile, stop on hide/retirement/replacement, honor reduced motion, and bound decoded frames. Apple's convenience animation API documents GIF/APNG and main-queue frame delivery; it does not promise bounded memory or arbitrary animation-format coverage. [I4]

Preserve color spaces into the drawing path. Do not flatten every image to untagged bytes or an opaque background. Verify orientation using transformed thumbnails and fixtures with different corner colors. ImageIO advertises color management, but correct output also depends on the drawing/context/surface-snapshot path. Full HDR/wide-gamut reference fidelity is a separate tested claim; newer HDR/SDR decode keys exist, but their presence in current docs is not a macOS 14 availability guarantee. [I6, I7]

## Proposed resource policy

These are starting engineering budgets, not measured acceptance values. Agree them with the performance owner and tune using a real nine-tile canvas.

1. Inspect file URL/regular-file identity and cheap metadata asynchronously. Avoid `Data(contentsOf:)` for the entire original. Create an ImageIO URL source with decoded-image caching disabled for inspection.
2. Decode a transformed thumbnail to an explicitly bounded pixel dimension, off main. Apple exposes a maximum thumbnail dimension and an orientation/aspect transform option. A thumbnail bound limits output allocation, not an absolute guarantee about the codec's temporary memory. [I8, I9]
3. Initially cap normal previews at 4096 pixels on the long edge and 64 MiB actual decoded byte cost per result (`bytesPerRow × height`, overflow checked). A square 4096 RGBA8 image alone is 64 MiB; high-depth or padded formats need actual-cost admission.
4. Set a global approximately 128 MiB decoded-image LRU budget and one or two simultaneous decode jobs. Account for both cached images and visible tile-owned references; an evicted cache entry is not freed while views retain it. Tier residency: visible/focused preview, tiny poster for distant tiles, no retained full preview for cold tiles.
5. Bucket target resolutions and debounce resize requests. Pure camera pan must decode zero images. Canvas zoom should not cause continuous redecoding: defer resolution upgrades to settled interaction, with at most one queued generation per document. Preserve a lower-resolution ready image while upgrading.
6. Cancellation should revoke delivery immediately; generation/file-signature checks prevent late results from replacing newer content. ImageIO synchronous decoding may not be interruptible mid-call. Queue bounds and avoiding useless jobs are therefore essential. Do not claim a cancellation flag is a hard timeout.
7. Initial preflight policy could reject or request external preview above 256 MiB compressed input or implausibly large dimensions (e.g. 250 MP), but these values must be validated rather than treated as universal safe limits. Compressed size is not decoded size; tiny files can expand enormously. For robust hard deadlines/memory boundaries, an out-of-process decoder is the stronger later architecture.
8. File signature invalidation must handle replacement, rename, deletion, and decode completion after tile removal. Polling inherited from text-only external monitoring must not do repeated I/O for every cold image tile.

Apple's own memory guidance recommends transforming external images to the scale/depth actually displayed with ImageIO. That supports the bounded-preview direction, without proving these particular budgets. [I10]

## SVG decision gate

Do not load arbitrary SVG as a top-level browser document and call it a passive image preview. SVG has processing modes with different script, external-resource, interaction and animation behavior; secure static mode disables all four. [I11]

Time-box a proof-of-concept: first evaluate system-native rasterization/Quick Look output on self-contained SVG fixtures. If WebKit is needed, use a dedicated nonpersistent, script-disabled image-only wrapper with a content policy denying network/local sibling resource access, navigation and popups; disable document animation or snapshot to a bounded static image. Disabling JavaScript alone does not block external images/fonts/styles or CSS/SVG animation. Current WebKit's `allowsContentJavaScript` defaults to true, so disable it explicitly. [I12]

A shipped SVG renderer owes fixture-backed evidence of self-contained vector fidelity plus no script execution, no external requests, no sibling-file reads and no background animation work. If that does not fit the release window, ship editable SVG source plus explicit system preview now and defer embedded SVG rendering. Sanitizing XML with regex is not an acceptable shortcut.

## Quick Look fallback

Use system preview as an explicit fallback for decoder failures/less common formats, with a clear unavailable state when the system cannot preview. A `QLThumbnailGenerator` result is a thumbnail or even a lower-quality representation, not a full interactive image/document viewer. Do not mistake a generic file icon for successful content rendering. Its API can return nil/error. [I13]

For embedded `QLPreviewView`, prototype tile residency, input behavior, extension variability, resource lifetime and failure states before using it as a universal surface. The Apple close documentation specifically warns of leaked memory if the view is not closed when required. Retirement must close and recreate when necessary, rather than assuming hiding a tile releases the preview. [I14] System/third-party preview-provider availability is a runtime capability, so fallback coverage should never be advertised as an unconditional guarantee.

## Offline behavioral witnesses

- Routing: PNG/JPEG correctly named, uppercase, no extension, misleading extension, corrupt files, directories and invalid paths. Assert actual displayed body and unavailable reason; binary content must never enter text recovery/save.
- Pixel output: small deterministic fixtures for transparency, EXIF rotation/mirroring, ICC profile preservation and corner-color orientation; assert decoded dimensions/representative pixels. Appearance snapshots in light/dark ensure checkerboard/chrome legibility, while pixel content stays stable.
- Real format corpus: compact licensed/repository-owned baseline fixtures, plus primary-image HEIC, multi-page TIFF, animated GIF/APNG and icon representation selection. Log runtime ImageIO type inventory. Assert success only for product-guaranteed fixtures on the macOS floor; optional formats should exercise a deterministic simulated unavailable-capability branch too.
- Limits: highly compressed oversized image, absurd/overflow metadata, wide panorama, high depth, truncated source. Assert decode admission/result dimensions/actual byte costs, visible bounded-preview notice and no silent original-resolution claim.
- Lifecycle: intentionally land old completion after new file replacement; close/remove/switch workspace during decode; cancellation drops results and pending requests stay bounded. Drive production workspace mount/open paths for integration rather than constructing a checks-only scene.
- Scaling: repeated pan/layout of 1/9/50 installed image tiles decodes zero unchanged images, adds no views, does no metadata reads, and does not grow cache bytes. Assert counts; report generous timing/RSS diagnostics alongside them. Resize bursts remain within coalesced decode counts.
- Animation later: deterministic frame clock for pause/resume/focus; zero frame work while offscreen/reduced-motion/retired. Do not use wall-clock sleep as the main assertion.
- Register any introduced check flags in the matrix, enumerate flags from source before invoking, and confirm actual final report coverage. Planning has not run these checks.

## Primary references

- I1: [CGImageSourceCopyTypeIdentifiers](https://developer.apple.com/documentation/imageio/cgimagesourcecopytypeidentifiers()) — runtime readable type inventory; consulted 2026-10-23.
- I2: [ImageIO basics](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_basics/ikpg_basics.html) — archived guide; supported formats vary by platform, so runtime query supersedes historic table.
- I3: [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers/) and [system declared types](https://developer.apple.com/documentation/uniformtypeidentifiers/system-declared-uniform-type-identifiers) — classification, including modern type names, not codec guarantees.
- I4: [CGAnimateImageAtURLWithBlock](https://developer.apple.com/documentation/imageio/cganimateimageaturlwithblock(_:_:_:)) — GIF/APNG scope, timing and main-queue delivery.
- I5: [UTType.svg](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/svg) — `public.svg-image` conformance.
- I6: [ImageIO overview](https://developer.apple.com/documentation/imageio) — color-management capability.
- I7: [Decode to HDR](https://developer.apple.com/documentation/imageio/kcgimagesourcedecodetohdr), [Decode to SDR](https://developer.apple.com/documentation/imageio/kcgimagesourcedecodetosdr) — current symbols; deployment availability not established by this research.
- I8: [CGImageSource](https://developer.apple.com/documentation/imageio/cgimagesource) — metadata, primary index, cache options and source APIs.
- I9: [Creating and using image sources](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html) — thumbnail generation and transform options.
- I10: [Making changes to reduce memory use](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use) — appropriately scaled/depth external images.
- I11: [W3C SVG 2 processing modes](https://www.w3.org/TR/SVG2/conform.html#secure-static-mode) — external-resource/script/animation restrictions.
- I12: [WKWebpagePreferences.allowsContentJavaScript](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript) — JavaScript control and default.
- I13: [QLThumbnailGenerator.generateBestRepresentation](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/generatebestrepresentation(for:completion:)) — asynchronous thumbnail/error contract.
- I14: [QLPreviewView.close](https://developer.apple.com/documentation/quicklookui/qlpreviewview/close()) — lifetime and memory-leak warning.
