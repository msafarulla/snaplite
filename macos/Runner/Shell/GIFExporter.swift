import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a movie into a looping GIF at 10 fps, at most 960 points on the long side.
enum GIFExporter {
    static func export(_ movie: URL, completion: @escaping (URL?) -> Void) {
        let output = Capture.uniqueURL(in: movie.deletingLastPathComponent(), base: movie.deletingPathExtension().lastPathComponent, ext: "gif")
        Task {
            let ok = (try? await write(movie, to: output)) ?? false
            await MainActor.run { completion(ok ? output : nil) }
        }
    }

    private static func write(_ movie: URL, to output: URL) async throws -> Bool {
        let fps = 10.0
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return false }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)   // pixels, so 960 points at 2x
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = (0..<max(1, Int(duration * fps))).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            return false
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        // Every requested time gets a frame (a failed one repeats the previous), so the count matches
        var last: CGImage?
        for await result in generator.images(for: times) {
            if let image = try? result.image { last = image }
            if let frame = last { CGImageDestinationAddImage(destination, frame, frameProperties) }
        }
        return last != nil && CGImageDestinationFinalize(destination)
    }
}
