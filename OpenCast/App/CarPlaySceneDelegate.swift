import CarPlay

final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayInterfaceCoordinator?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let runtime = OpenCastAppRuntime.shared
        let coordinator = CarPlayInterfaceCoordinator(
            appModel: runtime.appModel,
            modelContext: runtime.modelContainer.mainContext
        )
        self.coordinator = coordinator
        coordinator.start(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}
