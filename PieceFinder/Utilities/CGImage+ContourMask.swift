import CoreGraphics
import Vision

extension CGImage {

    /// Returns a new image with the area outside the contour made transparent.
    /// Used for preview images and color extraction.
    func maskedWithContour(_ contour: VNContour, bbox: CGRect) -> CGImage? {
        maskedWithContour(contour, bbox: bbox, backgroundColor: nil)
    }

    /// Finds the tight bounding box of the opaque (alpha > 0) pixels in this
    /// image. Returns nil if the image is fully transparent or lacks an alpha
    /// channel.
    ///
    /// Useful after `maskedWithContour` to drop the empty padding around the
    /// piece silhouette so the bbox matches the actual content.
    func opaqueContentBounds() -> CGRect? {
        let w = self.width
        let h = self.height
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w {
                if pixels[row + x * 4 + 3] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // CGContext y=0 is the bottom (Quartz) but the pixel buffer y=0 is the
        // top of the image. We return pixel-space (top-left origin) bounds so
        // callers can crop with CGImage.cropping(to:) directly.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Returns a new image with the area outside the contour filled with a solid color.
    /// Pass white for feature print extraction (avoids alpha channel issues with Vision).
    /// Pass nil for transparent background.
    func maskedWithContour(
        _ contour: VNContour,
        bbox: CGRect,
        backgroundColor: CGColor?
    ) -> CGImage? {
        let w = self.width
        let h = self.height
        guard w >= 1, h >= 1 else { return nil }

        let hasAlpha = backgroundColor == nil
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        ) else {
            return nil
        }

        // Fill background (transparent by default, or solid color)
        if let bg = backgroundColor {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Build a path from contour points, clip, then draw the image
        guard let path = buildContourPath(contour, bbox: bbox, pixelWidth: w, pixelHeight: h) else {
            return nil
        }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()

        // Trim contour edges: erase a thin strip along the boundary.
        // This removes border fragments and background artifacts that
        // the contour detection included at the piece edge.
        if hasAlpha {
            let trim = max(2, min(CGFloat(min(w, h)) * 0.015, 4))
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(trim)
            ctx.addPath(path)
            ctx.strokePath()
        }

        return ctx.makeImage()
    }

    /// Builds a preview-quality image:
    ///   - Pixels outside the contour are filled with `background`.
    ///   - Pixels inside the contour whose RGB is within `tolerance` of the
    ///     sampled outside-contour colour (i.e. the original callout/page
    ///     background that leaked inside a loose contour) are also replaced
    ///     with `background`.
    ///   - All other pixels (the piece) are preserved.
    ///
    /// This is the right call when the chosen contour is a few pixels wider
    /// than the actual piece silhouette: chroma-keying removes the leftover
    /// background fringe that a plain contour clip would keep.
    func chromaKeyedPreview(
        contour: VNContour,
        bbox: CGRect,
        background: CGColor,
        tolerance: Int = 35
    ) -> CGImage? {
        let w = self.width
        let h = self.height
        guard w >= 1, h >= 1 else { return nil }

        guard let path = buildContourPath(
            contour, bbox: bbox, pixelWidth: w, pixelHeight: h
        ) else { return nil }

        // Render the source image into an RGBA buffer.
        guard let imgCtx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        imgCtx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let imgData = imgCtx.data else { return nil }
        let img = imgData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Render an alpha mask of the contour: 255 inside, 0 outside.
        guard let maskCtx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        maskCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        maskCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        maskCtx.addPath(path)
        maskCtx.fillPath()
        guard let maskData = maskCtx.data else { return nil }
        let mask = maskData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Sample the actual background colour from pixels that fall *outside*
        // the contour. Skip pixels that are themselves close to the
        // replacement colour (e.g. genuine off-white margins) so we don't
        // anchor the chroma key to off-white.
        let bgComps = background.components ?? [1, 1, 1, 1]
        let br = UInt8((bgComps[0] * 255).rounded())
        let bgU8 = UInt8((bgComps[1] * 255).rounded())
        let bb = UInt8((bgComps[2] * 255).rounded())

        var sumR = 0, sumG = 0, sumB = 0, samples = 0
        for i in 0 ..< (w * h) {
            let off = i * 4
            guard mask[off + 3] == 0 else { continue }
            let r = img[off], g = img[off + 1], b = img[off + 2]
            let dr = Int(r) - Int(br), dg = Int(g) - Int(bgU8), db = Int(b) - Int(bb)
            if dr*dr + dg*dg + db*db < 100 { continue }   // already ~bg
            sumR += Int(r); sumG += Int(g); sumB += Int(b); samples += 1
        }
        var sample: (r: Int, g: Int, b: Int)? = samples > 50
            ? (sumR / samples, sumG / samples, sumB / samples)
            : nil

        // Fallback: when the contour fills the bbox there are no outside-
        // contour pixels to sample. Read a 10×10 window at each of the 4
        // corners — these are very likely to be background even for a loose
        // contour, since the subject usually sits in the centre.
        if sample == nil {
            let win = max(4, min(w, h) / 20)
            var cR = 0, cG = 0, cB = 0, cN = 0
            for (cx, cy) in [(0, 0), (w - win, 0), (0, h - win), (w - win, h - win)] {
                for dy in 0..<win {
                    for dx in 0..<win {
                        let off = ((cy + dy) * w + (cx + dx)) * 4
                        cR += Int(img[off])
                        cG += Int(img[off + 1])
                        cB += Int(img[off + 2])
                        cN += 1
                    }
                }
            }
            if cN > 0 {
                sample = (cR / cN, cG / cN, cB / cN)
            }
        }

        // Compose the output.
        guard let outCtx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        guard let outData = outCtx.data else { return nil }
        let out = outData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let tolSq = tolerance * tolerance
        var pMinX = w, pMinY = h, pMaxX = -1, pMaxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 4
                let inside = mask[off + 3] > 0

                if !inside {
                    out[off] = br; out[off + 1] = bgU8; out[off + 2] = bb; out[off + 3] = 255
                    continue
                }
                if let s = sample {
                    let dr = Int(img[off]) - s.r
                    let dg = Int(img[off + 1]) - s.g
                    let db = Int(img[off + 2]) - s.b
                    if dr*dr + dg*dg + db*db <= tolSq {
                        out[off] = br; out[off + 1] = bgU8; out[off + 2] = bb; out[off + 3] = 255
                        continue
                    }
                }
                out[off] = img[off]
                out[off + 1] = img[off + 1]
                out[off + 2] = img[off + 2]
                out[off + 3] = 255

                if x < pMinX { pMinX = x }
                if x > pMaxX { pMaxX = x }
                if y < pMinY { pMinY = y }
                if y > pMaxY { pMaxY = y }
            }
        }

        guard let composed = outCtx.makeImage() else { return nil }

        // Tight-crop to the kept (piece) pixels. We can't trust the contour's
        // bbox here — the contour may have wrapped the whole frame.
        guard pMaxX >= pMinX, pMaxY >= pMinY else { return composed }
        let pad = max(2, min(w, h) / 100)
        let cropX = max(0, pMinX - pad)
        let cropY = max(0, pMinY - pad)
        let cropW = min(w - cropX, pMaxX - pMinX + 1 + 2 * pad)
        let cropH = min(h - cropY, pMaxY - pMinY + 1 + 2 * pad)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        return composed.cropping(to: cropRect) ?? composed
    }

    // MARK: - Private

    /// Transforms contour normalizedPoints from image-normalized space into
    /// crop-pixel space and returns a closed CGPath.
    ///
    /// Vision contour points are in 0…1 image-normalized coordinates (bottom-left origin).
    /// The bbox defines which sub-region of the full image was cropped. We map each point
    /// relative to the bbox into the pixel dimensions of the crop.
    private func buildContourPath(
        _ contour: VNContour,
        bbox: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGPath? {
        let points = contour.normalizedPoints
        guard points.count >= 3 else { return nil }

        let pw = CGFloat(pixelWidth)
        let ph = CGFloat(pixelHeight)

        let path = CGMutablePath()
        for (i, point) in points.enumerated() {
            // Map from full-image normalized coords to crop-local pixel coords
            let x = (CGFloat(point.x) - bbox.origin.x) / bbox.width * pw
            let y = (CGFloat(point.y) - bbox.origin.y) / bbox.height * ph
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}
