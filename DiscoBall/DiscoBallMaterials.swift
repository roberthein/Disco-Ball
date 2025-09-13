import RealityKit
import UIKit

enum DiscoBallMaterials {
    /// Creates a simple black material for the inner sphere
    static func innerBlack() -> UnlitMaterial {
        UnlitMaterial(color: .black)
    }

    /// Creates a reflective mirror material with adjustable roughness
    static func mirror(roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white)
        material.metallic = 2.0
        material.roughness = .init(floatLiteral: max(0, min(1, roughness)))
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.05
        return material
    }
}
