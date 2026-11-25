import Foundation

final class SessionProfiles:ProfileStorage {
    var values:[String:Data]=[:]
    func data(forKey:String)->Data? {values[forKey]}
    func set(_ data:Data,forKey:String){values[forKey]=data}
}
final class SessionPasswords:PasswordStorage {
    var values:[String:String]=[:]
    func read(_ account:String)throws->String? {values[account]}
    func write(_ password:String,account:String)throws {values[account]=password}
    func delete(_ account:String)throws {values.removeValue(forKey:account)}
}
@main struct ConnectionsTest {
    @MainActor static func main()throws {
        let profiles=SessionProfiles();let passwords=SessionPasswords()
        let store=CredentialStore(defaults:profiles,passwords:passwords)
        let vpn=ConnectionModel(mode:"vpn",credentialStore:store)
        let portal=ConnectionModel(mode:"portal",credentialStore:store)
        let suite="local.vision.inode-arm.tests."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set("portal",forKey:"connectionMode")
        let connections=ConnectionsModel(vpn:vpn,portal:portal,preferences:prefs)
        precondition(connections.current===portal && vpn !== portal)
        precondition(vpn.connectionMode=="vpn" && portal.connectionMode=="portal")
        vpn.gateway="https://vpn.example.test";vpn.domain="duanxin"
        vpn.username="vpn-user";vpn.password="vpn-dummy-password";vpn.rememberCredentials=true
        portal.portalGateway="192.0.2.10";portal.domain="portal"
        portal.username="portal-user";portal.password="portal-dummy-password";portal.rememberCredentials=true
        connections.selectedMode="vpn";connections.selectedMode="portal"
        precondition(vpn.password=="vpn-dummy-password" && portal.password=="portal-dummy-password")
        precondition(vpn.domain=="duanxin" && portal.domain=="portal")
        print("PASS: page selection retains independent drafts and immutable connection modes")

        vpn.receive(["event":"ready"])
        vpn.receive(["event":"sms","message":"test"]);vpn.code="123456"
        portal.receive(["event":"ready"])
        portal.receive(["event":"authenticated"])
        portal.receive(["event":"connected","address":"192.0.2.20"])
        precondition(connections.current===portal && portal.stage=="connected")
        precondition(vpn.awaitingCode && vpn.code=="123456")
        precondition(vpn.navigationTitle.contains("待验证") && portal.navigationTitle.contains("在线"))
        print("PASS: VPN verification remains live while the Portal page connects")

        connections.selectedMode="vpn"
        vpn.receive(["event":"authenticated"])
        vpn.receive(["event":"connected","address":"10.1.2.3","interface":"utun-test"])
        precondition(vpn.stage=="connected" && portal.stage=="connected")
        let vpnProfile=store.load(mode:"vpn")!;let portalProfile=store.load(mode:"portal")!
        let vpnPassword=try store.password(for:vpnProfile)
        let portalPassword=try store.password(for:portalProfile)
        precondition(vpnPassword=="vpn-dummy-password" && portalPassword=="portal-dummy-password")
        precondition(vpnProfile.username=="vpn-user" && portalProfile.username=="portal-user")
        print("PASS: both models connect concurrently and save their own credentials")

        portal.password="retry-dummy-password"
        portal.receive(["event":"error","message":"test Portal failure"])
        precondition(!portal.active && portal.password=="retry-dummy-password")
        precondition(vpn.stage=="connected" && vpn.detail.contains("utun-test"))
        precondition(connections.current===vpn && portal.navigationTitle.contains("失败"))
        print("PASS: a background Portal failure preserves its input and does not alter VPN state")

        portal.receive(["event":"connected","address":"192.0.2.20"])
        connections.selectedMode="portal";portal.disconnect()
        precondition(!portal.active && vpn.stage=="connected")
        portal.receive(["event":"connected","address":"192.0.2.20"])
        vpn.receive(["event":"disconnected"])
        precondition(!vpn.active && portal.stage=="connected")
        print("PASS: disconnecting either model leaves the other session connected")

        vpn.receive(["event":"connected","address":"10.1.2.3"])
        connections.disconnectAll()
        precondition(!vpn.active && !portal.active)
        print("PASS: application shutdown closes both sessions")
    }
}
