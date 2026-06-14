import XCTest
import Vision
@testable import PieceFinder

final class ContourMaskTests: XCTestCase {

    // MARK: - Contour masking basics

    /// Masking a cropped piece image with its contour should produce an image
    /// with both transparent and opaque pixels.
    func testMaskedWithContour_ProducesTransparentBackground() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1b_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )
        XCTAssertFalse(contours.isEmpty, "Should detect contours")

        // Find a piece-sized contour (not the box border)
        guard let contour = contours.first(where: {
            let area = $0.boundingBox.width * $0.boundingBox.height
            return area > 0.01 && area < 0.40
        }) else {
            XCTFail("No piece-sized contour found")
            return
        }

        let bbox = contour.boundingBox
        guard let crop = downsampled.cropping(toNormalizedRect: bbox) else {
            XCTFail("Could not crop bounding box")
            return
        }

        // Test transparent background masking
        guard let masked = crop.maskedWithContour(contour, bbox: bbox) else {
            XCTFail("maskedWithContour returned nil")
            return
        }

        XCTAssertEqual(masked.width, crop.width, "Masked image width should match crop")
        XCTAssertEqual(masked.height, crop.height, "Masked image height should match crop")

        // Check alpha info — should have alpha
        let alphaInfo = masked.alphaInfo
        XCTAssertTrue(
            alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst ||
            alphaInfo == .last || alphaInfo == .first,
            "Masked image should have alpha channel (got \(alphaInfo.rawValue))"
        )

        // Verify mix of transparent and opaque pixels
        let (transparent, opaque) = countTransparency(in: masked)
        XCTAssertGreaterThan(transparent, 0,
                             "Should have transparent pixels (background)")
        XCTAssertGreaterThan(opaque, 0,
                             "Should have opaque pixels (piece)")
    }

    /// Masking with a white background should produce no transparent pixels.
    func testMaskedWithContour_WhiteBackground_NoTransparency() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1b_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )

        guard let contour = contours.first(where: {
            let area = $0.boundingBox.width * $0.boundingBox.height
            return area > 0.01 && area < 0.40
        }) else {
            XCTFail("No piece-sized contour found")
            return
        }

        let bbox = contour.boundingBox
        guard let crop = downsampled.cropping(toNormalizedRect: bbox) else {
            XCTFail("Could not crop bounding box")
            return
        }

        let whiteBg = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let masked = crop.maskedWithContour(contour, bbox: bbox, backgroundColor: whiteBg) else {
            XCTFail("maskedWithContour (white bg) returned nil")
            return
        }

        // With a solid background, alphaInfo should be noneSkipLast
        XCTAssertEqual(masked.alphaInfo, .noneSkipLast,
                       "White-bg masked image should not have alpha")
    }

    /// Masking should not crash or return nil for very small contours.
    func testMaskedWithContour_SmallContour_DoesNotCrash() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1a_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )

        // Try masking every contour — none should crash
        for contour in contours {
            let bbox = contour.boundingBox
            guard let crop = downsampled.cropping(toNormalizedRect: bbox) else { continue }
            // This should not crash even for tiny contours
            _ = crop.maskedWithContour(contour, bbox: bbox)
        }
    }

    // MARK: - averageOpaqueColor tests

    /// averageOpaqueColor on a contour-masked image should return a non-white color
    /// for a colored piece (blue piece from manual1b).
    func testAverageOpaqueColor_ReturnsNonWhiteForColoredPiece() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1b_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )

        // Find a dark (piece) contour
        var foundColoredPiece = false
        for contour in contours {
            let bbox = contour.boundingBox
            let area = bbox.width * bbox.height
            guard area > 0.01, area < 0.40 else { continue }

            guard let crop = downsampled.cropping(toNormalizedRect: bbox) else { continue }
            guard let masked = crop.maskedWithContour(contour, bbox: bbox) else { continue }

            if let result = ColorAnalyzer.averageOpaqueColor(of: masked) {
                // For a colored piece, L should not be near-white
                if result.lab.L < 80 {
                    foundColoredPiece = true
                    // Should have reasonable color values
                    XCTAssertGreaterThan(result.lab.L, 0,
                                         "L* should be positive")
                    break
                }
            }
        }
        XCTAssertTrue(foundColoredPiece,
                      "Should find at least one colored piece with L < 80")
    }

    /// averageOpaqueColor on a fully transparent image should return nil.
    func testAverageOpaqueColor_ReturnsNilForFullyTransparent() {
        guard let ctx = CGContext(
            data: nil, width: 10, height: 10,
            bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create context")
            return
        }
        // Context is initialized to all zeros (fully transparent)
        guard let transparent = ctx.makeImage() else {
            XCTFail("Could not make image")
            return
        }

        let result = ColorAnalyzer.averageOpaqueColor(of: transparent)
        XCTAssertNil(result, "Should return nil for fully transparent image")
    }

    /// averageOpaqueColor vs dominantColor on a masked image — averageOpaqueColor
    /// should be less contaminated by white background.
    func testAverageOpaqueColor_LessWhiteThanDominantColor() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1b_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )

        for contour in contours {
            let bbox = contour.boundingBox
            let area = bbox.width * bbox.height
            guard area > 0.01, area < 0.40 else { continue }

            guard let crop = downsampled.cropping(toNormalizedRect: bbox) else { continue }
            guard let masked = crop.maskedWithContour(contour, bbox: bbox) else { continue }
            guard let opaqueColor = ColorAnalyzer.averageOpaqueColor(of: masked) else { continue }

            let fullColor = ColorAnalyzer.dominantColor(of: crop)

            // averageOpaqueColor should give a darker (less white) result
            // than dominantColor on the raw crop which includes white background
            XCTAssertLessThanOrEqual(
                opaqueColor.lab.L, fullColor.lab.L + 5, // small tolerance
                "averageOpaqueColor L*=\(opaqueColor.lab.L) should not be " +
                "lighter than dominantColor L*=\(fullColor.lab.L)"
            )
            return // Just test the first valid contour
        }
    }

    // MARK: - opaqueContentBounds

    /// A fully transparent image should return nil.
    func testOpaqueContentBounds_FullyTransparent_ReturnsNil() {
        let ctx = CGContext(
            data: nil, width: 50, height: 50,
            bitsPerComponent: 8, bytesPerRow: 200,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: 50, height: 50))
        guard let img = ctx.makeImage() else { XCTFail(); return }
        XCTAssertNil(img.opaqueContentBounds())
    }

    /// A solid-opaque rectangle's bounds should match the rectangle size.
    func testOpaqueContentBounds_SmallOpaqueRegion_ReturnsTightBox() {
        // 100×100 transparent canvas with a 20×25 opaque rectangle drawn at
        // Quartz origin (30, 40). We only assert on size — origin depends on
        // pixel-buffer y-axis orientation, which the helper documents.
        let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 40, width: 20, height: 25))
        guard let img = ctx.makeImage(),
              let bounds = img.opaqueContentBounds() else {
            XCTFail("Expected bounds"); return
        }
        XCTAssertEqual(bounds.width,  20, accuracy: 1)
        XCTAssertEqual(bounds.height, 25, accuracy: 1)
    }

    // MARK: - chromaKeyedPreview

    /// chroma-keyed preview should produce a non-empty image whose dimensions
    /// are no larger than the source crop (i.e., it's tight-cropped).
    func testChromaKeyedPreview_ProducesTightCroppedImage() throws {
        let cgImage = TestImageLoader.loadCGImage(named: "manual1b_cutout.jpeg")
        let downsampled = ContourDetector.downsample(cgImage, maxDimension: 2000)

        let contours = try ContourDetector.detect(
            in: downsampled, contrastAdjustment: 3.0, maxCount: 15
        )
        guard let contour = contours.first(where: {
            let a = $0.boundingBox.width * $0.boundingBox.height
            return a > 0.01 && a < 0.40
        }) else {
            XCTFail("No piece-sized contour found"); return
        }
        let bbox = contour.boundingBox
        guard let crop = downsampled.cropping(toNormalizedRect: bbox) else {
            XCTFail("Crop failed"); return
        }

        let offWhite = CGColor(red: 0.94, green: 0.94, blue: 0.93, alpha: 1)
        guard let keyed = crop.chromaKeyedPreview(
            contour: contour, bbox: bbox, background: offWhite, tolerance: 35
        ) else {
            XCTFail("chromaKeyedPreview returned nil"); return
        }

        XCTAssertGreaterThan(keyed.width, 5)
        XCTAssertGreaterThan(keyed.height, 5)
        XCTAssertLessThanOrEqual(keyed.width, crop.width)
        XCTAssertLessThanOrEqual(keyed.height, crop.height)
    }

    /// chromaKeyedPreview should retain piece-coloured pixels and reject
    /// background-coloured pixels even when the contour was too loose.
    /// Built on synthetic data so the expected output is unambiguous.
    func testChromaKeyedPreview_ReplacesBackgroundColour() throws {
        // 100×100 image: pink background, blue piece in the centre.
        let w = 100, h = 100
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1.0, green: 0.5, blue: 0.7, alpha: 1))  // pink
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))  // blue
        ctx.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        guard let synthetic = ctx.makeImage() else { XCTFail(); return }

        // Build a contour that wraps the entire image (intentionally loose):
        // a 4-point rectangle in Vision-normalized coordinates.
        let frameContour = try makeRectangleContour(in: synthetic)
        let bbox = CGRect(x: 0, y: 0, width: 1, height: 1)
        let offWhite = CGColor(red: 0.94, green: 0.94, blue: 0.93, alpha: 1)
        guard let keyed = synthetic.chromaKeyedPreview(
            contour: frameContour, bbox: bbox, background: offWhite, tolerance: 35
        ) else {
            XCTFail("chromaKeyedPreview returned nil"); return
        }

        // Result should be tight-cropped roughly to the 40×40 blue piece.
        XCTAssertLessThan(keyed.width,  w,  "should shrink horizontally")
        XCTAssertLessThan(keyed.height, h,  "should shrink vertically")
        XCTAssertGreaterThan(keyed.width,  20)
        XCTAssertGreaterThan(keyed.height, 20)

        // Sample a centre pixel — it should be close to the blue piece colour,
        // not the pink background.
        let cx = keyed.width / 2, cy = keyed.height / 2
        let pixel = samplePixel(in: keyed, x: cx, y: cy)
        // Blue piece: R≈25, G≈77, B≈230. We just need "blueish" — B > R + 50.
        XCTAssertGreaterThan(
            Int(pixel.b) - Int(pixel.r), 50,
            "centre pixel should remain piece-blue (got r=\(pixel.r) g=\(pixel.g) b=\(pixel.b))"
        )
    }

    // MARK: - Helpers

    private func samplePixel(in cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = cgImage.width, h = cgImage.height
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let off = (y * w + x) * 4
        return (data[off], data[off + 1], data[off + 2])
    }

    /// Returns a VNContour tracing the four corners of the image.
    /// Vision contours use normalised, bottom-left coordinates — (0,0) bottom-
    /// left, (1,1) top-right.
    private func makeRectangleContour(in cgImage: CGImage) throws -> VNContour {
        // Build a 1×1 image with the same rectangle so VNDetectContoursRequest
        // returns a frame-spanning contour we can hand back.
        let w = cgImage.width, h = cgImage.height
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        guard let synth = ctx.makeImage() else {
            throw NSError(domain: "test", code: -1)
        }
        let contours = try ContourDetector.detect(
            in: synth, contrastAdjustment: 1.0, maxCount: 5, detectsDarkOnLight: true
        )
        guard let c = contours.first else {
            throw NSError(domain: "test", code: -2)
        }
        return c
    }

    private func countTransparency(in cgImage: CGImage) -> (transparent: Int, opaque: Int) {
        let w = cgImage.width
        let h = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return (0, 0) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var transparent = 0
        var opaque = 0
        for p in 0..<(w * h) {
            if pixels[p * 4 + 3] == 0 {
                transparent += 1
            } else {
                opaque += 1
            }
        }
        return (transparent, opaque)
    }
}
