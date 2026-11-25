import Foundation
import Darwin

struct SavedProfile: Codable, Equatable {
    var gateway: String
    var domain: String
    var username: String
    // Legacy saved fields; desktop TLS policy no longer reads these values.
    var pin: String
    var trustedPin: String?
    var routes: String
    var remember: Bool
    var mode: String? = nil
    var accountKey: String {
        let url=URL(string:gateway)
        let endpoint="https://\(url?.host?.lowercased() ?? gateway):\(url?.port ?? 443)"
        let parts=mode=="portal" ? ["portal",gateway,domain,username] : [endpoint,domain,username]
        return (try! JSONEncoder().encode(parts)).base64EncodedString()
    }
}
protocol PasswordStorage {
    func read(_ account: String) throws -> String?
    func write(_ password: String, account: String) throws
    func delete(_ account: String) throws
}
protocol ProfileStorage {
    func data(forKey:String)->Data?
    func set(_ data:Data,forKey:String)
}
struct DefaultsProfileStorage:ProfileStorage {
    func data(forKey:String)->Data? {UserDefaults.standard.data(forKey:forKey)}
    func set(_ data:Data,forKey:String) {UserDefaults.standard.set(data,forKey:forKey)}
}
final class CredentialStore {
    private let defaults:ProfileStorage
    private let passwords:PasswordStorage
    private let key="savedProfile.v1"
    init(defaults:ProfileStorage = DefaultsProfileStorage(),passwords:PasswordStorage = LocalFilePasswords()) {
        self.defaults=defaults;self.passwords=passwords
    }
    func load(mode:String = "vpn")->SavedProfile? {defaults.data(forKey:mode=="portal" ? key+".portal" : key).flatMap{try? JSONDecoder().decode(SavedProfile.self,from:$0)}}
    func password(for profile:SavedProfile)throws->String? {try passwords.read(profile.accountKey)}
    func save(_ profile:SavedProfile,password:String)throws {
        let previous=load(mode:profile.mode ?? "vpn")
        if let previous,previous.remember,(!profile.remember || previous.accountKey != profile.accountKey) {
            try passwords.delete(previous.accountKey)
        }
        if profile.remember {try passwords.write(password,account:profile.accountKey)}
        var saved=profile
        if !saved.remember {saved.username=""}
        defaults.set(try JSONEncoder().encode(saved),forKey:profile.mode=="portal" ? key+".portal" : key)
    }
    func forget(mode:String = "vpn")throws {
        guard var profile=load(mode:mode) else{return}
        try passwords.delete(profile.accountKey);profile.remember=false;profile.username=""
        defaults.set(try JSONEncoder().encode(profile),forKey:mode=="portal" ? key+".portal" : key)
    }
}
