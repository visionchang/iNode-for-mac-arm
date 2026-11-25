import Foundation
import Combine
import ServiceManagement

@MainActor final class ConnectionsModel:ObservableObject {
    let vpn:ConnectionModel
    let portal:ConnectionModel
    let journal:ConnectionJournal
    private let preferences:UserDefaults
    private var observations:Set<AnyCancellable> = []
    private var hasAttemptedStartupAutoConnect = false
    @Published var selectedMode:String {
        didSet {
            guard ["vpn","portal"].contains(selectedMode) else {selectedMode=oldValue;return}
            preferences.set(selectedMode,forKey:"connectionMode")
        }
    }
    @Published var autoConnectPortal:Bool {
        didSet {
            preferences.set(autoConnectPortal,forKey:"autoConnectPortal")
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginError = ""
    var current:ConnectionModel {selectedMode=="portal" ? portal : vpn}
    init(vpn:ConnectionModel? = nil,portal:ConnectionModel? = nil,preferences:UserDefaults = .standard) {
        let journal=vpn?.journal ?? portal?.journal ?? ConnectionJournal()
        self.journal=journal
        self.vpn=vpn ?? ConnectionModel(mode:"vpn",journal:journal)
        self.portal=portal ?? ConnectionModel(mode:"portal",journal:journal)
        self.preferences=preferences
        let saved=preferences.string(forKey:"connectionMode") ?? "vpn"
        selectedMode=["vpn","portal"].contains(saved) ? saved : "vpn"
        autoConnectPortal=(preferences.object(forKey:"autoConnectPortal") as? Bool) ?? true
        // Selection changes only which model is displayed. Each process and
        // callback retains its own model regardless of the selected page.
        self.vpn.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        self.portal.objectWillChange.sink {[weak self] _ in self?.objectWillChange.send()}.store(in:&observations)
        refreshLaunchAtLoginStatus()
    }
    func refreshLaunchAtLoginStatus() {
        let status=SMAppService.mainApp.status
        launchAtLogin=(status == .enabled || status == .requiresApproval)
        launchAtLoginRequiresApproval=(status == .requiresApproval)
    }
    func setLaunchAtLogin(_ enabled:Bool) {
        launchAtLoginError=""
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError=(enabled ? "开启开机启动失败：" : "关闭开机启动失败：")+error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }
    func autoConnectPortalIfNeeded() {
        guard !hasAttemptedStartupAutoConnect else {return}
        hasAttemptedStartupAutoConnect=true
        guard autoConnectPortal,!portal.active,portal.isConfiguredForAutoConnect else {return}
        portal.connect()
    }
    func disconnectAll() {vpn.disconnect(clearPassword:true,reason:.applicationQuit);portal.disconnect(clearPassword:true,reason:.applicationQuit)}
}
