import RealityKit

/// The camera and lights stay on +Z while the turntable turns the icon, so the engraved −Z back
/// faces the camera after a half turn.
enum SettingsAboutHeroScene {
    static func makeStage(holding icon: Entity) -> (stage: Entity, turntable: Entity) {
        let stage = Entity()
        let turntable = Entity()
        turntable.addChild(icon)
        stage.addChild(turntable)
        stage.addChild(makeCamera())
        // The default environment alone leaves the navy back nearly black;
        // a key and a fill keep the engraving legible in light and dark.
        stage.addChild(makeDirectionalLight(intensity: 2500, from: [-1, 1, 2]))
        stage.addChild(makeDirectionalLight(intensity: 900, from: [1, 0, 2]))
        return (stage, turntable)
    }

    /// A 26° field of view from 0.3 m frames the 0.12 m tile at 87% of the
    /// view; mid-turn its near edge reaches 95%.
    private static func makeCamera() -> PerspectiveCamera {
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 26
        camera.look(at: .zero, from: [0, 0, 0.30], relativeTo: nil)
        return camera
    }

    private static func makeDirectionalLight(intensity: Float, from position: SIMD3<Float>) -> DirectionalLight {
        let light = DirectionalLight()
        light.light.intensity = intensity
        light.look(at: .zero, from: position, relativeTo: nil)
        return light
    }
}
