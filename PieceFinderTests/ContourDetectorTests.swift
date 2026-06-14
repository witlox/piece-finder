import XCTest
import Vision
@testable import PieceFinder

final class ContourDetectorTests: XCTestCase {

    // MARK: - Single-polarity detection

    /// Dark-on-light polarity should find dark blobs against a light field.
    func testDetect_DarkOnLight_FindsDarkBlobOnLight() throws {
        let cg = makeImage(width: 100, height: 100,
                           background: .white,
                           blob: .black,
                           blobRect: CGRect(x: 30, y: 30, width: 40, height: 40))
        let contours = try ContourDetector.detect(
            in: cg, contrastAdjustment: 1.0, maxCount: 10,
            detectsDarkOnLight: true
        )
        XCTAssertFalse(contours.isEmpty,
                       "Dark-on-light should find the black blob")
    }

    /// Light-on-dark polarity should find light blobs against a dark field —
    /// the case that drove the dual-polarity work (tan/cream pieces in a
    /// darker pile previously went undetected).
    func testDetect_LightOnDark_FindsLightBlobOnDark() throws {
        let cg = makeImage(width: 100, height: 100,
                           background: .black,
                           blob: .white,
                           blobRect: CGRect(x: 30, y: 30, width: 40, height: 40))
        let contours = try ContourDetector.detect(
            in: cg, contrastAdjustment: 1.0, maxCount: 10,
            detectsDarkOnLight: false
        )
        XCTAssertFalse(contours.isEmpty,
                       "Light-on-dark should find the white blob")
    }

    /// Dark-on-light polarity should NOT find a light blob against a dark
    /// field — this is the gap that detectBothPolarities is meant to close.
    func testDetect_DarkOnLight_MissesLightBlobOnDark() throws {
        let cg = makeImage(width: 100, height: 100,
                           background: .black,
                           blob: .white,
                           blobRect: CGRect(x: 30, y: 30, width: 40, height: 40))
        let contours = try ContourDetector.detect(
            in: cg, contrastAdjustment: 1.0, maxCount: 10,
            detectsDarkOnLight: true
        )
        // Vision may still return a 0-or-near-0-area frame-level contour;
        // the assertion is that no piece-sized contour is returned.
        let pieceSized = contours.filter { c in
            let a = c.boundingBox.width * c.boundingBox.height
            return a > 0.05 && a < 0.95
        }
        XCTAssertTrue(pieceSized.isEmpty,
                      "Dark-on-light shouldn't find a light blob on dark")
    }

    // MARK: - Both-polarity detection

    /// detectBothPolarities should return at least as many contours as a
    /// single-polarity pass on a realistic mixed-colour image.
    func testDetectBothPolarities_ReturnsAtLeastSinglePolarityCount() throws {
        let cg = loadAndDownsample("manual1a_cutout.jpeg")
        let dark = try ContourDetector.detect(
            in: cg, contrastAdjustment: 2.0, maxCount: 20, detectsDarkOnLight: true
        )
        let both = ContourDetector.detectBothPolarities(
            in: cg, contrastAdjustment: 2.0, maxCountPerPolarity: 20
        )
        XCTAssertGreaterThanOrEqual(
            both.count, dark.count,
            "Both-polarity must return ≥ single-polarity contour count"
        )
    }

    /// detectBothPolarities should find both a light blob AND a dark blob
    /// in an image that contains one of each — neither single polarity
    /// would find both on its own.
    func testDetectBothPolarities_FindsBothLightAndDarkBlobs() {
        let cg = makeImage(width: 200, height: 100,
                           background: .gray,
                           blob: .black,
                           blobRect: CGRect(x: 20, y: 20, width: 50, height: 60),
                           extraBlob: .white,
                           extraBlobRect: CGRect(x: 130, y: 20, width: 50, height: 60))
        let both = ContourDetector.detectBothPolarities(
            in: cg, contrastAdjustment: 2.0, maxCountPerPolarity: 10
        )
        let pieceSized = both.filter { c in
            let a = c.boundingBox.width * c.boundingBox.height
            return a > 0.03 && a < 0.50
        }
        XCTAssertGreaterThanOrEqual(
            pieceSized.count, 2,
            "Should find both the dark and light blobs (got \(pieceSized.count))"
        )
    }

    // MARK: - Helpers

    private func loadAndDownsample(_ name: String) -> CGImage {
        let uiImage = TestImageLoader.loadImage(named: name)
        let normalized = uiImage.normalizedOrientation()
        let rawCG = normalized.cgImage!
        return ContourDetector.downsample(rawCG, maxDimension: 2000)
    }

    private enum Tone {
        case white, black, gray
        var cgColor: CGColor {
            switch self {
            case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            case .black: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            case .gray:  return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            }
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        background: Tone,
        blob: Tone,
        blobRect: CGRect,
        extraBlob: Tone? = nil,
        extraBlobRect: CGRect? = nil
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(blob.cgColor)
        ctx.fill(blobRect)
        if let extra = extraBlob, let rect = extraBlobRect {
            ctx.setFillColor(extra.cgColor)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }
}
