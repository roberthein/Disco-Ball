import RealityKit
import simd

struct DiscoBallBuilder {

    struct BuildParameters {
        var radius: Float
        /// Target arc length of a tile edge along the sphere surface (meters)
        var tileArc: Float
        var tileGap: Float
        var jitterAmount: Float
        var jitterSeed: UInt64
        var lowQuality: Bool
    }

    static func makeDiscoBall(params: BuildParameters, mirrorRoughness: Float) throws -> Entity {
        let root = Entity()

        // Create inner black sphere as base
        let innerSphere = ModelEntity(
            mesh: .generateSphere(radius: params.radius),
            materials: [DiscoBallMaterials.innerBlack()]
        )
        innerSphere.name = "InnerSphere"
        root.addChild(innerSphere)

        // Generate mirror tiles mesh
        let mirrorTilesMesh = try generateMirrorTiles(
            radius: params.radius,
            arcSize: params.tileArc,
            gap: params.tileGap,
            jitterAmount: params.jitterAmount,
            jitterSeed: params.jitterSeed,
            lowQuality: params.lowQuality
        )
        let mirrorTiles = ModelEntity(
            mesh: mirrorTilesMesh,
            materials: [DiscoBallMaterials.mirror(roughness: mirrorRoughness)]
        )
        mirrorTiles.name = "MirrorTiles"
        root.addChild(mirrorTiles)

        return root
    }

    // MARK: - Geometry

    /// Generates mirror tiles covering a sphere with square quads in mid-latitudes
    /// and triangular caps at the poles. Includes gap spacing and jitter for realism.
    private static func generateMirrorTiles(
        radius: Float,
        arcSize: Float,
        gap: Float,
        jitterAmount: Float,
        jitterSeed: UInt64,
        lowQuality: Bool
    ) throws -> MeshResource {

        let tileEdgeSize = max(0.004, arcSize)
        let groutWidth = max(0, min(0.02, gap))
        let tileLiftOffset: Float = 0.0008  // Lift tiles off sphere to avoid z-fighting

        // Calculate meridional step size based on tile edge size
        let meridionalStep = max(0.008, tileEdgeSize / radius) * (lowQuality ? 1.8 : 1.0)

        // Define latitude boundaries for different tile regions
        let bottomCapBaseLatitude: Float = -(.pi / 2) + meridionalStep
        let topCapBaseLatitude: Float = (.pi / 2) - meridionalStep

        // Mid-latitude quad region boundaries
        let minQuadLatitude: Float = bottomCapBaseLatitude + meridionalStep
        let maxQuadLatitude: Float = topCapBaseLatitude - meridionalStep

        // Extra quad rings just before triangle caps
        let topExtraQuadLatitude: Float = topCapBaseLatitude - 0.5 * meridionalStep
        let bottomExtraQuadLatitude: Float = bottomCapBaseLatitude + 0.5 * meridionalStep

        var randomNumberGenerator = Hasher64(seed: jitterSeed)

        var vertexPositions: [SIMD3<Float>] = []
        var vertexNormals: [SIMD3<Float>] = []
        var triangleIndices: [UInt32] = []

        // MARK: Helpers

        @inline(__always)
        func addQuadTile(center: SIMD3<Float>,
                        normal: SIMD3<Float>,
                        basisU: SIMD3<Float>,
                        basisV: SIMD3<Float>,
                        edgeSize: Float,
                        groutWidth: Float,
                        rotationJitter: Float)
        {
            // Shrink tile by grout width to create visible gaps
            let halfEdge = max(0.0005, 0.5 * (edgeSize - groutWidth))
            var uVector = simd_normalize(basisU) * halfEdge
            var vVector = simd_normalize(basisV) * halfEdge

            // Apply small rotation jitter for sparkle effect
            if rotationJitter != 0 {
                let sinJitter = sin(rotationJitter)
                let cosJitter = cos(rotationJitter)
                let originalU = uVector
                uVector = cosJitter * originalU + sinJitter * vVector
                vVector = -sinJitter * originalU + cosJitter * vVector
            }

            // Lift tile outward to avoid z-fighting with inner sphere
            let liftOffset = normal * tileLiftOffset

            // Create quad corners (counter-clockwise for outward-facing normal)
            let corner0 = center + (-uVector - vVector) + liftOffset
            let corner1 = center + (uVector - vVector) + liftOffset
            let corner2 = center + (uVector + vVector) + liftOffset
            let corner3 = center + (-uVector + vVector) + liftOffset

            let startIndex = UInt32(vertexPositions.count)
            vertexPositions += [corner0, corner1, corner2, corner3]
            vertexNormals += [normal, normal, normal, normal]
            triangleIndices += [startIndex, startIndex+1, startIndex+2, startIndex, startIndex+2, startIndex+3]
        }

        @inline(__always)
        func addTriangleTile(_ vertexA: SIMD3<Float>, _ vertexB: SIMD3<Float>, _ vertexC: SIMD3<Float>, jitter: Float) {
            // Calculate centroid and shrink triangle based on grout width
            let centroid = (vertexA + vertexB + vertexC) / 3
            let edgeLengthA = simd_length(vertexB - vertexA)
            let edgeLengthB = simd_length(vertexC - vertexB)
            let edgeLengthC = simd_length(vertexA - vertexC)
            let averageEdgeLength = max(1e-4, (edgeLengthA + edgeLengthB + edgeLengthC) / 3)
            let shrinkFactor = min(0.35, groutWidth / averageEdgeLength)

            var shrunkA = centroid + (vertexA - centroid) * (1 - shrinkFactor)
            var shrunkB = centroid + (vertexB - centroid) * (1 - shrinkFactor)
            var shrunkC = centroid + (vertexC - centroid) * (1 - shrinkFactor)

            // Calculate face normal and ensure outward-facing orientation
            var faceNormal = simd_normalize(simd_cross(shrunkB - shrunkA, shrunkC - shrunkA))
            let outwardDirection = simd_normalize(simd_normalize(shrunkA) + simd_normalize(shrunkB) + simd_normalize(shrunkC))
            if simd_dot(faceNormal, outwardDirection) < 0 {
                swap(&shrunkB, &shrunkC)
                faceNormal = simd_normalize(simd_cross(shrunkB - shrunkA, shrunkC - shrunkA))
            }

            // Apply rotation jitter around face normal for sparkle effect
            if jitter != 0 {
                let rotationQuaternion = simd_quatf(angle: jitter, axis: faceNormal)
                shrunkA = centroid + rotationQuaternion.act(shrunkA - centroid)
                shrunkB = centroid + rotationQuaternion.act(shrunkB - centroid)
                shrunkC = centroid + rotationQuaternion.act(shrunkC - centroid)
            }

            // Lift triangle outward to avoid z-fighting
            let liftOffset = faceNormal * tileLiftOffset
            shrunkA += liftOffset
            shrunkB += liftOffset
            shrunkC += liftOffset

            let startIndex = UInt32(vertexPositions.count)
            vertexPositions += [shrunkA, shrunkB, shrunkC]
            vertexNormals += [faceNormal, faceNormal, faceNormal]
            triangleIndices += [startIndex, startIndex+1, startIndex+2]
        }

        @inline(__always)
        func calculateTileCount(atLatitude latitude: Float) -> Int {
            let parallelRadius = cos(latitude)
            let circumference = 2 * .pi * radius * parallelRadius
            let fullTileCount = max(4, Int(round(circumference / tileEdgeSize)))
            return lowQuality ? max(4, Int(Double(fullTileCount) * 0.55)) : fullTileCount
        }

        // Generate a ring of quad tiles at the specified latitude
        func addQuadRing(atLatitude latitude: Float) {
            let tileCount = calculateTileCount(atLatitude: latitude)
            guard tileCount >= 4 else { return }
            let longitudeStep = 2 * Float.pi / Float(tileCount)

            for tileIndex in 0..<tileCount {
                let longitude = Float(tileIndex) * longitudeStep
                let cosLatitude = cos(latitude)
                let sinLatitude = sin(latitude)
                let cosLongitude = cos(longitude)
                let sinLongitude = sin(longitude)

                // Calculate outward normal and center position on sphere
                let outwardNormal = simd_normalize(SIMD3<Float>(cosLatitude * cosLongitude, sinLatitude, cosLatitude * sinLongitude))
                let centerPosition = radius * outwardNormal

                // Calculate tangent basis vectors from spherical coordinates
                let meridianTangent = simd_normalize(SIMD3<Float>(-sinLatitude * cosLongitude, cosLatitude, -sinLatitude * sinLongitude))
                let parallelTangent = simd_normalize(SIMD3<Float>(-cosLatitude * sinLongitude, 0, cosLatitude * cosLongitude))

                // Ensure outward-facing triangle winding
                var uBasis = meridianTangent
                var vBasis = parallelTangent
                let faceNormal = simd_normalize(simd_cross(uBasis, vBasis))
                if simd_dot(faceNormal, outwardNormal) < 0 {
                    swap(&uBasis, &vBasis)
                }

                let rotationJitter = (randomNumberGenerator.nextFloat() - 0.5) * 2 * jitterAmount
                addQuadTile(center: centerPosition,
                           normal: outwardNormal,
                           basisU: uBasis,
                           basisV: vBasis,
                           edgeSize: tileEdgeSize,
                           groutWidth: groutWidth,
                           rotationJitter: rotationJitter)
            }
        }

        // Generate mid-latitude quad tiles
        if minQuadLatitude < maxQuadLatitude {
            var currentLatitude = minQuadLatitude
            while currentLatitude <= maxQuadLatitude {
                addQuadRing(atLatitude: currentLatitude)
                currentLatitude += meridionalStep
            }
        }

        // Add extra quad rings just before triangle caps to close gaps
        addQuadRing(atLatitude: topExtraQuadLatitude)
        addQuadRing(atLatitude: bottomExtraQuadLatitude)

        // Generate triangular tiles at the poles
        func addPolarTriangleRing(poleSign: Float, ringLatitude: Float) {
            let tileCount = calculateTileCount(atLatitude: ringLatitude)
            guard tileCount >= 3 else { return }
            let longitudeStep = 2 * Float.pi / Float(tileCount)

            // Calculate pole position
            let poleNormal = SIMD3<Float>(0, poleSign, 0)
            let polePosition = radius * poleNormal

            for tileIndex in 0..<tileCount {
                // Calculate two neighboring points on the ring
                let longitude0 = Float(tileIndex) * longitudeStep
                let longitude1 = Float(tileIndex + 1) * longitudeStep
                let cosLatitude = cos(ringLatitude)
                let sinLatitude = sin(ringLatitude)

                let cosLongitude0 = cos(longitude0)
                let sinLongitude0 = sin(longitude0)
                let cosLongitude1 = cos(longitude1)
                let sinLongitude1 = sin(longitude1)

                let ringPoint0 = radius * SIMD3<Float>(cosLatitude * cosLongitude0, sinLatitude, cosLatitude * sinLongitude0)
                let ringPoint1 = radius * SIMD3<Float>(cosLatitude * cosLongitude1, sinLatitude, cosLatitude * sinLongitude1)

                // Apply rotation jitter for sparkle effect
                let jitterAngle = (randomNumberGenerator.nextFloat() - 0.5) * 2 * jitterAmount

                addTriangleTile(ringPoint0, ringPoint1, polePosition, jitter: jitterAngle)
            }
        }

        addPolarTriangleRing(poleSign: 1, ringLatitude: topCapBaseLatitude)    // North pole
        addPolarTriangleRing(poleSign: -1, ringLatitude: bottomCapBaseLatitude) // South pole

        // Create mesh from generated geometry
        var meshDescriptor = MeshDescriptor(name: "MirrorTiles")
        meshDescriptor.positions = MeshBuffers.Positions(vertexPositions)
        meshDescriptor.normals = MeshBuffers.Normals(vertexNormals)
        meshDescriptor.primitives = .triangles(triangleIndices)

        return try .generate(from: [meshDescriptor])
    }
}

/// Tiny deterministic RNG for per-tile jitter.
fileprivate struct Hasher64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float {
        let v = next() >> 40
        return Float(v) / Float(1 << 24)
    }
}
