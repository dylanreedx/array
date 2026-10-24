# FT0 ImageIO platform probe

Run date: 2026-10-24. Probe only, independent of the app and SwiftPM.

## Observed environment and command

- macOS 27.0.1, build 26A434, arm64 (`sw_vers`, `uname -m`).
- Command: `CLANG_MODULE_CACHE_PATH=/tmp/array-image-probe-cache swift scripts/probe-file-tile-images.swift`
- Final run exited **0**. A first compilation failed on a throwing autoclosure and ambiguous color-space interpolation; both script issues were fixed before the reported run. A first successful run used an incorrect JPEG XL identifier; the final script uses the runtime-listed `public.jpeg-xl`.
- No app launch, live project access, Git mutation, SwiftPM build, network access, or tmux access occurred. A unique temporary fixture directory is deleted by the script. Swift's module cache and captured output remain under `/tmp`.
- The process printed `sysctlbyname for kern.hv_vmm_present failed with status -1`; assertions and decoding still completed. Its origin was not investigated, and it is retained in raw output.

## Findings

| Probe | Observed result | What it establishes |
| --- | --- | --- |
| PNG and TIFF generated 8×4 RGBA fixtures | Decode succeeded; every RGBA pixel matched after normalization into sRGB | Small-fixture lossless colors and transparent quadrant survived this encode/decode path |
| GIF, JPEG, BMP generated fixtures | Decode succeeded, dimensions 8×4 | These particular files decode; GIF was single-frame and JPEG is lossy |
| Bounded thumbnail, each successful format | Maximum dimension 2 produced 2×1 | ImageIO thumbnail output honored this small bound; not a measurement of peak codec memory |
| TIFF orientations 1–8 | All dimensions and every RGBA pixel matched explicit EXIF orientation mappings | Rotation and mirroring are applied with `kCGImageSourceCreateThumbnailWithTransform` on these fixtures |
| Clearly corrupt `.png` | No usable thumbnail | A small malformed input is rejected |
| HEIC, AVIF | Destination finalization failed for the 8×4 alpha, 256×256 opaque RGBX, and 512×512 opaque JPEG-derived fixtures (last uses explicit quality 0.8) | Encoding failed across these inputs; **does not establish missing decoder support** |
| ICO, ICNS | Tiny non-square fixture failed to encode; standard 256×256 opaque fixture encoded and decoded, then produced 32×32 thumbnails | Same-runtime generated-file roundtrip succeeds; four interior color/opacity samples match within 32/255 |
| HEIF, WebP, JPEG XL | Runtime advertises reader; no writer for queried type | Type advertised only; **no decode proof**, external fixture required |
| SVG | `public.svg-image` absent from runtime source list | This ImageIO inventory does not advertise SVG decoding; no SVG bytes were probed |

The original 8×4 decoded fixtures each report 128 decoded bytes (`bytesPerRow × height`). The original 8×4 successful outputs reported `kCGColorSpaceSRGB`. The 256×256 icon results each report 262,144 decoded bytes; generated ICO and ICNS files were 1,791 and 1,801 bytes, respectively. That tests a tagged sRGB path, not arbitrary embedded ICC, Display P3, CMYK, HDR or color fidelity through Array's surface snapshots.

## Limits and next evidence

This is useful evidence for a bounded native decoding spike, not a shipped format compatibility table. The machine is newer than the app's macOS 14 floor. Repeat the script on macOS 14 and the current supported release; obtain small legally reusable real HEIC/HEIF, WebP, AVIF, JPEG XL, ICO/ICNS, multi-page TIFF, animated GIF/APNG, wide-gamut and high-depth fixtures. Add misleading-extension and primary-image container tests before publishing support claims.

The tiny non-square image violates some icon encoder constraints in this runtime: a 256×256 opaque replacement succeeds. HEIC/AVIF finalization still fails for larger opaque sources, including a JPEG-decoded 512×512 image with explicit lossy quality 0.8. The cause is undetermined; neither a general codec limitation nor a hardware/sandbox restriction was proven. Do not interpret encoder failures as decoder regressions. Each successful baseline fixture is checked with a 2-pixel thumbnail; there is no large-image, decode-storm, RSS, cancellation, concurrency, residency, Quick Look, SVG, animation, app rendering or security claim here. No full matrix was run; this standalone planning probe is not yet registered as a release gate.

The probe reads `docs/internals/performance.md` requirements into its design: bounded outputs, no AppKit per-pixel views, explicit result sizes, and actual pixel assertions instead of source-string checks. It does not yet establish performance budgets for production.

## Follow-up method

The script retains every original baseline, alpha and orientation assertion. It additionally generates a 256×256 sRGB `noneSkipLast` opaque image with red, green, blue and white quadrants; tries HEIC, AVIF, ICO and ICNS; asserts decoded dimensions; samples RGBA in each quadrant with tolerance for lossy codecs; and requests a 32-pixel bounded thumbnail. It also makes a 512×512 opaque source, encodes/decodes it through JPEG, then retries HEIC/AVIF with quality 0.8 to vary source representation, dimensions and compression options. No tools were installed or fixtures/dependencies downloaded. All optional attempts retain their own failure status rather than silently passing as supported formats.

## Raw final output

```text
sysctlbyname for kern.hv_vmm_present failed with status -1OS: Version 27.0.1 (Build 26A434)
Readable types: com.adobe.photoshop-image, com.adobe.raw-image, com.apple.atx, com.apple.icns, com.apple.pict, com.canon.cr2-raw-image, com.canon.cr3-raw-image, com.canon.crw-raw-image, com.canon.tif-raw-image, com.compuserve.gif, com.dxo.raw-image, com.epson.raw-image, com.fuji.raw-image, com.hasselblad.3fr-raw-image, com.hasselblad.fff-raw-image, com.ilm.openexr-image, com.kodak.raw-image, com.konicaminolta.raw-image, com.leafamerica.raw-image, com.leica.raw-image, com.leica.rwl-raw-image, com.microsoft.bmp, com.microsoft.cur, com.microsoft.dds, com.microsoft.ico, com.nikon.nefx-raw-image, com.nikon.nrw-raw-image, com.nikon.raw-image, com.olympus.or-raw-image, com.olympus.raw-image, com.olympus.sr-raw-image, com.panasonic.raw-image, com.panasonic.rw2-raw-image, com.pentax.raw-image, com.phaseone.raw-image, com.samsung.raw-image, com.sgi.sgi-image, com.sony.arw-raw-image, com.sony.axr-raw-image, com.sony.raw-image, com.sony.sr2-raw-image, com.truevision.tga-image, org.khronos.astc, org.khronos.ktx, org.khronos.ktx2, org.nema.dicom, org.webmproject.webp, public.avci, public.avif, public.avis, public.heic, public.heics, public.heif, public.jpeg, public.jpeg-2000, public.jpeg-xl, public.mpo-image, public.pbm, public.png, public.pvr, public.radiance, public.tiff
Writable types: com.adobe.pdf, com.adobe.photoshop-image, com.apple.atx, com.apple.icns, com.compuserve.gif, com.ilm.openexr-image, com.microsoft.bmp, com.microsoft.dds, com.microsoft.ico, com.truevision.tga-image, org.khronos.astc, org.khronos.ktx, org.khronos.ktx2, public.avif, public.heic, public.heics, public.jpeg, public.jpeg-2000, public.pbm, public.png, public.pvr, public.tiff
DECODED png: detected=public.png; count=1; original=8x4; bounded=2x1; bytes=128; colorSpace=kCGColorSpaceSRGB
DECODED tiff: detected=public.tiff; count=1; original=8x4; bounded=2x1; bytes=128; colorSpace=kCGColorSpaceSRGB
DECODED gif: detected=com.compuserve.gif; count=1; original=8x4; bounded=2x1; bytes=128; colorSpace=kCGColorSpaceSRGB
DECODED jpg: detected=public.jpeg; count=1; original=8x4; bounded=2x1; bytes=128; colorSpace=kCGColorSpaceSRGB
DECODED bmp: detected=com.microsoft.bmp; count=1; original=8x4; bounded=2x1; bytes=128; colorSpace=kCGColorSpaceSRGB
FAILED heic: Finalize failed for public.heic
UNPROVEN heif: advertisedReadable=true; no system writer; external fixture required
UNPROVEN webp: advertisedReadable=true; no system writer; external fixture required
FAILED avif: Finalize failed for public.avif
UNPROVEN jxl: advertisedReadable=true; no system writer; external fixture required
FAILED ico: Finalize failed for com.microsoft.ico
FAILED icns: Finalize failed for com.apple.icns
OPAQUE FAILED heic: Finalize failed for public.heic; no decoder conclusion from writer failure
OPAQUE FAILED avif: Finalize failed for public.avif; no decoder conclusion from writer failure
OPAQUE DECODED ico: same-runtime roundtrip; detected=com.microsoft.ico; count=1; original=256x256; bounded=32x32; decodedBytes=262144; encodedBytes=1791; four interior RGBA samples within 32/255
OPAQUE DECODED icns: same-runtime roundtrip; detected=com.apple.icns; count=1; original=256x256; bounded=32x32; decodedBytes=262144; encodedBytes=1801; four interior RGBA samples within 32/255
JPEG-DERIVED FAILED public.heic: Finalize failed for public.heic; no decoder conclusion from writer failure
JPEG-DERIVED FAILED public.avif: Finalize failed for public.avif; no decoder conclusion from writer failure
PASS orientation 1: 8x4, all RGBA pixels match
PASS orientation 2: 8x4, all RGBA pixels match
PASS orientation 3: 8x4, all RGBA pixels match
PASS orientation 4: 8x4, all RGBA pixels match
PASS orientation 5: 4x8, all RGBA pixels match
PASS orientation 6: 4x8, all RGBA pixels match
PASS orientation 7: 4x8, all RGBA pixels match
PASS orientation 8: 4x8, all RGBA pixels match
PASS corrupt PNG rejected
PASS required probe assertions; optional format failures/UNPROVEN entries retain their stated status

```
