import AVFoundation
import Foundation
import ImageIO

/// A video Kelp just wrote, opened again and checked against what was asked: its size, its frame rate, its length and
/// its sound. What the page itself gets wrong (a picture or a video that doesn't load, a clip past the end) is said
/// first, as warnings. The verdict shows in Export's recent list, and an agent's export gets it as JSON.
struct MotionVerify: Codable, Equatable {
    var file: String, ok: Bool
    var width: Int, height: Int, fps: Double, duration: Double, audio: Bool
    var problems: [String], warnings: [String]

    /// One line for the recent list: what it is when all is well, else what isn't.
    var summary: String {
        if !ok { return problems.joined(separator: " · ") }
        let head = "✓ \(width)×\(height) · \(Self.number(fps)) fps · \(Self.number(duration)) s"
        return head + (audio ? " · " + String(localized: "sound") : "")
            + (warnings.isEmpty ? "" : " · " + String(localized: "warnings: \(warnings.count)"))
    }

    static func number(_ value: Double) -> String { String(format: "%g", (value * 100).rounded() / 100) }

    /// What a video was asked to be: its size, rate, length in seconds, and whether it has sound.
    struct Asked {
        var width: Int, height: Int, fps: Double, duration: Double, sound = false
    }

    /// Opens `url` and compares it with what was `asked`.
    static func check(_ url: URL, _ asked: Asked, warnings: [String]) async -> MotionVerify {
        let (width, height, fps, duration, sound) = (asked.width, asked.height, asked.fps, asked.duration, asked.sound)
        var out = MotionVerify(
            file: url.lastPathComponent, ok: true, width: 0, height: 0, fps: 0, duration: 0, audio: false, problems: [],
            warnings: warnings)
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return out.failed(String(localized: "The file doesn’t open")) }
            out.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            out.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            out.fps = fps   // a GIF has delays, not a rate: same frames run together into one longer one
            out.duration = (0..<CGImageSourceGetCount(source)).reduce(0) { total, i in
                let frame = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                return total
                    + ((gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime])
                        as? Double ?? 1 / fps)
            }
        } else {
            let asset = AVURLAsset(url: url)
            do {
                let length = try await asset.load(.duration)
                let video = try await asset.loadTracks(withMediaType: .video).first
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard let video else { return out.failed(String(localized: "No picture in the file")) }
                let size = try await video.load(.naturalSize)
                out.width = Int(size.width.rounded())
                out.height = Int(size.height.rounded())
                out.fps = Double(try await video.load(.nominalFrameRate))
                out.duration = length.seconds
                out.audio = !audio.isEmpty
            } catch {
                return out.failed(String(localized: "The file doesn’t open: \(error.localizedDescription)"))
            }
        }
        // H.264 rounds a size down to even numbers: one pixel less is as asked.
        if abs(out.width - width) > 1 || abs(out.height - height) > 1 {
            out.problems.append(String(localized: "\(out.width)×\(out.height) instead of \(width)×\(height)"))
        }
        if abs(out.fps - fps) > 0.01 {
            out.problems.append(String(localized: "\(number(out.fps)) fps instead of \(number(fps))"))
        }
        if abs(out.duration - duration) > 1.5 / fps {
            out.problems.append(String(localized: "\(number(out.duration)) s instead of \(number(duration))"))
        }
        if sound, !out.audio { out.problems.append(String(localized: "No sound, though the page has some")) }
        out.ok = out.problems.isEmpty
        return out
    }

    private func failed(_ why: String) -> MotionVerify {
        var copy = self
        copy.ok = false
        copy.problems = [why]
        return copy
    }
}
