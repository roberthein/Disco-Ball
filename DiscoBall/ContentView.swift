import SwiftUI
import RealityKit
import UIKit

private struct SceneReferences {
    weak var rootEntity: Entity?
    weak var discoBall: Entity?
    weak var lightRig: Entity?
    weak var cameraEntity: Entity?
}

private enum ManualTarget: String, CaseIterable, Identifiable {
    case ball = "Ball"
    case scene = "Scene"
    var id: String { rawValue }
}

struct ContentView: View {
    @State var model: DiscoBallModel

    @State private var sceneReferences = SceneReferences()
    @State private var animationTask: Task<Void, Never>? = nil
    @State private var showControls = true

    // Manual rotation controls
    @State private var manualTarget: ManualTarget = .ball
    @State private var pauseAutoRotationOnDrag = false
    @State private var isDragging = false
    @State private var lastDragTranslation: CGSize = .zero
    private let yawSensitivityDegreesPerPoint: Float = 0.25
    private let pitchSensitivityDegreesPerPoint: Float = 0.25

    var body: some View {
        ZStack {
            RealityView { content in
                let root = Entity(); root.name = "Root"

                // Camera
                let cam = Entity()
                var camComp = PerspectiveCameraComponent()
                camComp.fieldOfViewInDegrees = model.fovDegrees
                cam.components.set(camComp)
                cam.position = SIMD3<Float>(0, 0.05, model.cameraDistance)
                root.addChild(cam)

                // Light rig
                let lightRig = makeProfessionalLightRig()
                root.addChild(lightRig)

                // Disco ball
                let ball = try? DiscoBallBuilder.makeDiscoBall(params: .init(
                    radius: model.radius,
                    tileArc: model.lowQuality ? model.tileArcSize * 1.5 : model.tileArcSize,
                    tileGap: model.tileGap,
                    jitterAmount: model.jitterAmount,
                    jitterSeed: model.jitterSeed,
                    lowQuality: model.lowQuality
                ), mirrorRoughness: model.mirrorRoughness)
                if let ball { root.addChild(ball) }

                content.add(root)
                sceneReferences = .init(rootEntity: root, discoBall: ball, lightRig: lightRig, cameraEntity: cam)
                startAnimationLoopIfNeeded()
            } update: { _ in
                updateCamera()
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { dragValue in
                    let deltaX = dragValue.translation.width - lastDragTranslation.width
                    let deltaY = dragValue.translation.height - lastDragTranslation.height
                    lastDragTranslation = dragValue.translation

                    // Map horizontal drag to yaw (Y axis), vertical drag to pitch (X axis)
                    let deltaYawRadians = Angle(degrees: Double(Float(deltaX) * yawSensitivityDegreesPerPoint)).radians
                    let deltaPitchRadians = Angle(degrees: Double(-Float(deltaY) * pitchSensitivityDegreesPerPoint)).radians

                    let yawQuaternion = simd_quatf(angle: Float(deltaYawRadians), axis: [0, 1, 0])
                    let pitchQuaternion = simd_quatf(angle: Float(deltaPitchRadians), axis: [1, 0, 0])

                    if manualTarget == .ball, let discoBall = sceneReferences.discoBall {
                        // Apply yaw then pitch for intuitive orbit
                        discoBall.orientation = pitchQuaternion * yawQuaternion * discoBall.orientation
                    } else if manualTarget == .scene, let lightRig = sceneReferences.lightRig {
                        lightRig.orientation = pitchQuaternion * yawQuaternion * lightRig.orientation
                    }
                    isDragging = true
                }
                .onEnded { _ in
                    isDragging = false
                    lastDragTranslation = .zero
                }
            )
            .onTapGesture { withAnimation(.snappy) { showControls.toggle() } }

            if showControls {
                controls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.snappy, value: showControls)
            }
        }
        // iOS 17+ onChange
        .onChange(of: model.tileArcSize) { rebuildDiscoBall() }
        .onChange(of: model.tileGap) { rebuildDiscoBall() }
        .onChange(of: model.jitterAmount) { rebuildDiscoBall() }
        .onChange(of: model.jitterSeed) { rebuildDiscoBall() }
        .onChange(of: model.radius) { rebuildDiscoBall() }
        .onChange(of: model.lowQuality) { rebuildDiscoBall() }
        .onChange(of: model.mirrorRoughness) { rebuildMirrorMaterial() }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    // MARK: - Animation Loop

    @MainActor
    private func startAnimationLoopIfNeeded() {
        guard animationTask == nil else { return }
        animationTask = Task { @MainActor in
            let clock = ContinuousClock()
            var lastUpdateTime = clock.now
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(16)) // ~60 FPS

                let currentTime = clock.now
                let deltaTime: Duration = currentTime - lastUpdateTime
                lastUpdateTime = currentTime

                // Convert duration to seconds
                let deltaTimeSeconds = Double(deltaTime.components.seconds) + Double(deltaTime.components.attoseconds) / 1e18
                let shouldSuppressAutoRotation = isDragging && pauseAutoRotationOnDrag

                if !shouldSuppressAutoRotation, let discoBall = sceneReferences.discoBall {
                    let yawRadians = Angle(degrees: Double(model.ballYawSpeed) * deltaTimeSeconds).radians
                    discoBall.orientation *= simd_quatf(angle: Float(yawRadians), axis: [0, 1, 0])

                    // Add subtle wobble for more realistic motion
                    let wobbleRadians = Angle(degrees: 8.594 * deltaTimeSeconds).radians
                    discoBall.orientation *= simd_quatf(angle: Float(wobbleRadians), axis: [1, 0, 0])
                }

                if !shouldSuppressAutoRotation, model.rotateRig, let lightRig = sceneReferences.lightRig {
                    let lightRigYawRadians = Angle(degrees: Double(model.lightRigYawSpeed) * deltaTimeSeconds).radians
                    lightRig.orientation *= simd_quatf(angle: Float(lightRigYawRadians), axis: [0, 1, 0])
                }
            }
        }
    }

    // MARK: - Camera

    @MainActor
    private func updateCamera() {
        guard let cameraEntity = sceneReferences.cameraEntity else { return }
        if var cameraComponent = cameraEntity.components[PerspectiveCameraComponent.self] {
            cameraComponent.fieldOfViewInDegrees = model.fovDegrees
            cameraEntity.components[PerspectiveCameraComponent.self] = cameraComponent
        }
        cameraEntity.position = SIMD3<Float>(0, 0.05, model.cameraDistance)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                // Manual rotation selector
                HStack {
                    Text("Manual Rotate:")
                    Picker("", selection: $manualTarget) {
                        ForEach(ManualTarget.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Pause auto while dragging", isOn: $pauseAutoRotationOnDrag)
                        .font(.caption)
                }

                HStack {
                    Text("Tile Density")
                    Slider(value: Binding(get: { Double(model.tileArcSize) },
                                          set: { model.tileArcSize = Float($0) }),
                           in: 0.010...0.060)
                    Text(String(format: "%.3f m", model.tileArcSize)).monospacedDigit().font(.caption)
                }
                HStack {
                    Text("Tile Gap")
                    Slider(value: Binding(get: { Double(model.tileGap) },
                                          set: { model.tileGap = Float($0) }),
                           in: 0.000...0.010)
                    Text(String(format: "%.3f m", model.tileGap)).monospacedDigit().font(.caption)
                }
                HStack {
                    Text("Mirror Roughness")
                    Slider(value: Binding(get: { Double(model.mirrorRoughness) },
                                          set: { model.mirrorRoughness = Float($0) }),
                           in: 0.00...0.20)
                    Text(String(format: "%.2f", model.mirrorRoughness)).monospacedDigit().font(.caption)
                }
                HStack {
                    Text("Ball Yaw Speed")
                    Slider(value: Binding(get: { Double(model.ballYawSpeed) },
                                          set: { model.ballYawSpeed = Float($0) }),
                           in: 0...30)
                    Text(String(format: "%.0f°/s", model.ballYawSpeed)).monospacedDigit().font(.caption)
                }
                HStack {
                    Toggle("Rotate Light Rig", isOn: $model.rotateRig)
                    Slider(value: Binding(get: { Double(model.lightRigYawSpeed) },
                                          set: { model.lightRigYawSpeed = Float($0) }),
                           in: 0...30)
                    Text(String(format: "%.0f°/s", model.lightRigYawSpeed)).monospacedDigit().font(.caption)
                }
                HStack {
                    Text("FoV")
                    Slider(value: Binding(get: { Double(model.fovDegrees) },
                                          set: { model.fovDegrees = Float($0) }),
                           in: 30...70)
                    Text(String(format: "%.0f°", model.fovDegrees)).monospacedDigit().font(.caption)
                }
                HStack {
                    Text("Quality")
                    Toggle("Low", isOn: $model.lowQuality).toggleStyle(.switch)
                    Spacer()
                    Button("Reset") { model.reset(); rebuildAll() }
                }
                Text("Tip: drag horizontally/vertically to yaw/pitch the \(manualTarget.rawValue.lowercased()).")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .font(.callout)
        .foregroundStyle(.white)
    }

    // MARK: - Rebuilds

    @MainActor
    private func rebuildDiscoBall() {
        guard let rootEntity = sceneReferences.rootEntity else { return }
        sceneReferences.discoBall?.removeFromParent()
        do {
            let ball = try DiscoBallBuilder.makeDiscoBall(params: .init(
                radius: model.radius,
                tileArc: model.lowQuality ? model.tileArcSize * 1.5 : model.tileArcSize,
                tileGap: model.tileGap,
                jitterAmount: model.jitterAmount,
                jitterSeed: model.jitterSeed,
                lowQuality: model.lowQuality
            ), mirrorRoughness: model.mirrorRoughness)
            ball.name = "DiscoBall"
            rootEntity.addChild(ball)
            sceneReferences.discoBall = ball
        } catch {
            print("Rebuild failed: \(error)")
        }
    }

    @MainActor
    private func rebuildMirrorMaterial() {
        guard let discoBall = sceneReferences.discoBall else { return }
        for child in discoBall.children {
            if let mirrorTilesEntity = child as? ModelEntity, mirrorTilesEntity.name == "MirrorTiles" {
                mirrorTilesEntity.model?.materials = [DiscoBallMaterials.mirror(roughness: model.mirrorRoughness)]
            }
        }
    }

    @MainActor
    private func rebuildAll() {
        rebuildDiscoBall()
        updateCamera()
    }
}

// MARK: - Professional Lighting Setup
private func makeProfessionalLightRig() -> Entity {
    let lightRig = Entity()
    lightRig.name = "LightRig"

    func createDirectionalLight(color: UIColor, intensity: Float, position: SIMD3<Float>) -> Entity {
        let directionalLight = DirectionalLight()
        directionalLight.light.color = color
        directionalLight.light.intensity = intensity

        let lightEntity = Entity()
        lightEntity.position = position
        lightEntity.look(at: .zero, from: lightEntity.position, relativeTo: nil)
        lightEntity.addChild(directionalLight)
        return lightEntity
    }

    // Key light (warm)
    lightRig.addChild(createDirectionalLight(color: UIColor(red: 1.00, green: 0.92, blue: 0.85, alpha: 1),
                                           intensity: 120000, position: SIMD3<Float>(0.8, 1.1, 0.6)))
    // Fill light (cool)
    lightRig.addChild(createDirectionalLight(color: UIColor(red: 0.80, green: 0.90, blue: 1.00, alpha: 1),
                                           intensity: 70000, position: SIMD3<Float>(-0.9, 0.4, 0.9)))
    // Rim light (magenta)
    lightRig.addChild(createDirectionalLight(color: UIColor(red: 1.00, green: 0.25, blue: 0.75, alpha: 1),
                                           intensity: 90000, position: SIMD3<Float>(0.0, 0.8, -0.8)))

    func createSpotLight(color: UIColor, position: SIMD3<Float>, intensity: Float, angleDegrees: Float) -> Entity {
        let spotLight = SpotLight()
        var lightComponent = spotLight.light
        lightComponent.color = color
        lightComponent.intensity = intensity
        lightComponent.innerAngleInDegrees = max(5, angleDegrees)
        lightComponent.outerAngleInDegrees = angleDegrees + 20
        spotLight.light = lightComponent

        let spotLightEntity = Entity()
        spotLightEntity.position = position
        spotLightEntity.look(at: .zero, from: spotLightEntity.position, relativeTo: nil)
        spotLightEntity.addChild(spotLight)
        return spotLightEntity
    }

    // Accent colored spot lights
    lightRig.addChild(createSpotLight(color: UIColor(red: 0.6, green: 1.0, blue: 0.7, alpha: 1),
                                    position: SIMD3<Float>(0.6, -0.2, 0.7),
                                    intensity: 9000, angleDegrees: 45))
    lightRig.addChild(createSpotLight(color: UIColor(red: 0.7, green: 0.7, blue: 1.0, alpha: 1),
                                    position: SIMD3<Float>(-0.7, 0.0, 0.3),
                                    intensity: 8000, angleDegrees: 45))
    lightRig.addChild(createSpotLight(color: UIColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1),
                                    position: SIMD3<Float>(0.0, -0.3, -0.7),
                                    intensity: 8500, angleDegrees: 45))

    return lightRig
}
