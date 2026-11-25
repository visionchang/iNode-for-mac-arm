import Foundation
final class MemoryProfiles:ProfileStorage {
    var values:[String:Data]=[:]
    func data(forKey:String)->Data? {values[forKey]}
    func set(_ data:Data,forKey:String){values[forKey]=data}
}
final class MemoryPasswords:PasswordStorage {
    var values:[String:String]=[:]
    var rejectWrites=false
    func read(_ account:String)throws->String? {values[account]}
    func write(_ password:String,account:String)throws {
        if rejectWrites {throw NSError(domain:"test",code:1)}
        values[account]=password
    }
    func delete(_ account:String)throws {values.removeValue(forKey:account)}
}
@main struct CredentialsTest {
    static func main()throws {
        let profiles=MemoryProfiles();let passwords=MemoryPasswords()
        let store=CredentialStore(defaults:profiles,passwords:passwords)
        let secret="test-secret-DO-NOT-PERSIST-IN-SETTINGS"
        var profile=SavedProfile(gateway:"https://vpn.example.com:443",domain:"unit",username:"alice",pin:"pin",trustedPin:"pin",routes:"",remember:true)
        try store.save(profile,password:secret)
        precondition(store.load()==profile)
        let restored=try store.password(for:profile);precondition(restored==secret)
        precondition(!profiles.values.values.contains{String(data:$0,encoding:.utf8)!.contains(secret)})
        print("PASS: settings contain profile only; password is delegated to secret storage")
        let initialKey=profile.accountKey
        profile.gateway="https://other.example.com:443"
        precondition(profile.accountKey != initialKey)
        let otherPassword=try store.password(for:profile);precondition(otherPassword==nil)
        print("PASS: changing the gateway cannot reuse the previous account secret")
        profile.gateway="https://vpn.example.com:443";profile.domain="other"
        precondition(profile.accountKey != initialKey)
        profile.domain="unit";profile.username="bob"
        precondition(profile.accountKey != initialKey)
        try store.save(profile,password:"new-test-secret")
        precondition(passwords.values[initialKey]==nil)
        print("PASS: credentials are scoped by gateway, domain and account; replaced account is forgotten")
        passwords.rejectWrites=true
        var changed=profile;changed.username="charlie"
        do {try store.save(changed,password:"not-saved");preconditionFailure("Expected storage error")}catch{}
        precondition(store.load()==profile)
        print("PASS: storage failure does not report the new account as remembered")
        try store.forget();precondition(passwords.values.isEmpty)
        precondition(store.load()?.remember==false);precondition(store.load()?.username=="")
        print("PASS: forgetting credentials deletes the stored secret")
        passwords.rejectWrites=false
        profile.remember=true
        try store.save(profile,password:"vpn-test-secret")
        var portal=profile;portal.mode="portal";portal.gateway="192.0.2.10";portal.domain=""
        try store.save(portal,password:"portal-test-secret")
        let vpnPassword=try store.password(for:profile);let portalPassword=try store.password(for:portal)
        precondition(vpnPassword=="vpn-test-secret" && portalPassword=="portal-test-secret")
        precondition(store.load(mode:"portal")==portal)
        try store.forget(mode:"portal")
        let kept=try store.password(for:profile);precondition(kept=="vpn-test-secret")
        precondition(store.load()?.remember==true && store.load(mode:"portal")?.remember==false)
        print("PASS: VPN and Portal profiles and passwords remain isolated")
    }
}
