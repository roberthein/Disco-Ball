import Foundation
import Observation

@MainActor
@Observable
final class DiscoBallModel {
    // Geometry and material properties
    var radius: Float = 0.25
    var tileArcSize: Float = 0.018
    var tileGap: Float = 0.0018
    var mirrorRoughness: Float = 0.04
    var jitterAmount: Float = 0.006
    var jitterSeed: UInt64 = 1337

    // Animation properties
    var ballYawSpeed: Float = 12.0
    var lightRigYawSpeed: Float = 4.0
    var rotateRig: Bool = true

    // Camera properties
    var fovDegrees: Float = 45.0
    var cameraDistance: Float = 1.85

    // Performance settings
    var lowQuality: Bool = false

    /// Resets all properties to their default values
    func reset() {
        radius = 0.25
        tileArcSize = 0.018
        tileGap = 0.0018
        mirrorRoughness = 0.04
        jitterAmount = 0.006
        jitterSeed = 1337
        ballYawSpeed = 12.0
        lightRigYawSpeed = 4.0
        rotateRig = true
        fovDegrees = 45.0
        cameraDistance = 1.85
        lowQuality = false
    }
}
