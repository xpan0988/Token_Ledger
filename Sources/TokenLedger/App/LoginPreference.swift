import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginPreference {
    private(set) var enabled = false
    private(set) var requiresApproval = false
    private(set) var failed = false

    init() { self.refresh() }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.failed = false
        } catch {
            self.failed = true
        }
        self.refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        self.enabled = status == .enabled || status == .requiresApproval
        self.requiresApproval = status == .requiresApproval
    }
}
