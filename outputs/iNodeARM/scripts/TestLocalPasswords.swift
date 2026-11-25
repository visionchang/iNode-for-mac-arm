import Foundation
import Darwin
@main struct LocalPasswordsTest {
    static func main()throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let store=LocalFilePasswords(directory:directory)
        defer{try? FileManager.default.removeItem(at:directory)}
        let absent=try store.read("account-A");precondition(absent==nil)
        precondition(!FileManager.default.fileExists(atPath:directory.path))
        print("PASS: reading absent credentials creates no local files")
        let secret="local-test-中文-!&\\\""
        try store.write(secret,account:"account-A")
        let restored=try LocalFilePasswords(directory:directory).read("account-A")
        precondition(restored==secret)
        let file=directory.appendingPathComponent("credentials.json")
        let dirInfo=try FileManager.default.attributesOfItem(atPath:directory.path)
        let fileInfo=try FileManager.default.attributesOfItem(atPath:file.path)
        precondition((dirInfo[.posixPermissions] as! NSNumber).intValue==0o700)
        precondition((fileInfo[.posixPermissions] as! NSNumber).intValue==0o600)
        print("PASS: credentials survive reopening; directory 0700 and file 0600")
        try store.write("test-second",account:"account-B")
        try store.delete("account-A")
        let removed=try store.read("account-A");let remaining=try store.read("account-B")
        precondition(removed==nil && remaining=="test-second")
        print("PASS: deleting one account preserves other records")
        try store.delete("account-B")
        precondition(!FileManager.default.fileExists(atPath:file.path))
        let leftovers=try FileManager.default.contentsOfDirectory(atPath:directory.path);precondition(leftovers.isEmpty)
        print("PASS: forgetting the final account removes the password file and leaves no temporary files")
    }
}
