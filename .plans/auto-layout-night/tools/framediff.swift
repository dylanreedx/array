import AVFoundation
import CoreGraphics
import Foundation
// usage: framediff <movie>  -> per-frame time and mean abs luminance change vs previous frame (64x40 grid)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)
let track = asset.tracks(withMediaType: .video)[0]
let reader = try! AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out); reader.startReading()
var prev: [Double]? = nil
while let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var cells = [Double](repeating: 0, count: 64 * 40)
    for gy in 0..<40 { for gx in 0..<64 {
        let x = gx * w / 64 + w / 128, y = gy * h / 40 + h / 80
        let p = base + y * bpr + x * 4
        cells[gy * 64 + gx] = 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
    } }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    if let prev { let d = zip(cells, prev).map { abs($0 - $1) }.reduce(0, +) / Double(cells.count)
        let changed = zip(cells, prev).filter { abs($0 - $1) > 8 }.count
        print(String(format: "%.3f %.2f %d", t, d, changed)) }
    prev = cells
}
