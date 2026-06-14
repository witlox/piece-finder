import ARKit
import RealityKit

@MainActor
final class HighlightOverlayManager: ObservableObject {

    private let anchor = AnchorEntity()
    private weak var arView: ARView?

    /// Default distance from camera when no plane is detected.
    private let fallbackDistance: Float = 0.5

    func attach(to arView: ARView) {
        self.arView = arView
        arView.scene.addAnchor(anchor)
    }

    /// Removes all existing highlights and places new ones for the given candidates.
    func update(candidates: [PieceCandidate]) {
        // Remove all existing highlights
        anchor.children.removeAll()

        guard let arView = arView else { return }

        let viewWidth = Float(arView.bounds.width)
        let viewHeight = Float(arView.bounds.height)

        // Camera intrinsics → exact per-axis FOV factors. At distance d, a
        // bbox spanning fraction f of the buffer corresponds to
        //   physical_meters = f * d * (bufferDimension_pixels / focalLength_pixels)
        // Fallback to typical iPhone wide-camera values when no frame is yet
        // available (very first frames or simulator).
        let (widthFactor, heightFactor): (Float, Float)
        if let frame = arView.session.currentFrame {
            let k = frame.camera.intrinsics
            let res = frame.camera.imageResolution
            widthFactor  = Float(res.width)  / k[0][0]   // res.width  / fx
            heightFactor = Float(res.height) / k[1][1]   // res.height / fy
        } else {
            widthFactor  = 1.40   // ~70° horizontal FOV
            heightFactor = 1.04   // ~55° vertical FOV
        }

        for candidate in candidates {
            // Convert Vision normalized rect to screen coordinates
            let bbox = candidate.boundingBox
            let screenCenter = CGPoint(
                x: CGFloat(bbox.midX) * CGFloat(viewWidth),
                y: (1 - CGFloat(bbox.midY)) * CGFloat(viewHeight)
            )

            // Raycast to find surface distance, or use fallback
            let distance: Float
            if let result = arView.raycast(
                from: screenCenter,
                allowing: .estimatedPlane,
                alignment: .horizontal
            ).first {
                let camPos = arView.cameraTransform.translation
                let hitPos = result.worldTransform.columns.3
                distance = simd_distance(
                    SIMD3(camPos.x, camPos.y, camPos.z),
                    SIMD3(hitPos.x, hitPos.y, hitPos.z)
                )
            } else {
                distance = fallbackDistance
            }

            let physicalWidth  = Float(bbox.width)  * distance * widthFactor
            let physicalHeight = Float(bbox.height) * distance * heightFactor

            // Create highlight entity
            let highlight = HighlightEntity.make(
                candidate: candidate,
                width: max(physicalWidth, 0.01),
                height: max(physicalHeight, 0.01)
            )

            // Position via raycast or projection
            if let result = arView.raycast(
                from: screenCenter,
                allowing: .estimatedPlane,
                alignment: .horizontal
            ).first {
                let worldPos = result.worldTransform.columns.3
                highlight.position = SIMD3(worldPos.x, worldPos.y + 0.002, worldPos.z)
            } else {
                // Fallback: place in front of camera
                let camTransform = arView.cameraTransform
                let forward = camTransform.matrix.columns.2
                let camPos = camTransform.translation
                highlight.position = SIMD3(
                    camPos.x - forward.x * fallbackDistance,
                    camPos.y - forward.y * fallbackDistance,
                    camPos.z - forward.z * fallbackDistance
                )
            }

            anchor.addChild(highlight)
        }
    }

    func removeAll() {
        anchor.children.removeAll()
    }
}
