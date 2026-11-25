import Foundation
import Darwin

@main struct ServiceProtocolTest {
    static func main()throws {
        if CommandLine.arguments.count>1 {
            let fd=socket(AF_UNIX,SOCK_STREAM,0)
            defer {Darwin.close(fd)}
            var address=try NetworkService.address(CommandLine.arguments[1])
            let result=withUnsafePointer(to:&address) {
                $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
                    Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(result==0)
            try NetworkService.writeLine(["op":"test"],to:fd)
            let reply=try NetworkService.readLine(fd)
            precondition(reply==Data("ok".utf8))
            return
        }
        try validateSessionPath("/private/tmp/inode-arm-"+UUID().uuidString+"/control.sock")
        for invalid in ["/tmp/inode-arm-"+UUID().uuidString+"/control.sock","/private/tmp/inode-arm-../control.sock","/private/tmp/inode-arm-"+UUID().uuidString+"/../../control.sock"] {
            do {try validateSessionPath(invalid);fatalError("Accepted unsafe session path")}
            catch { }
        }
        print("PASS: session socket path validation rejects traversal and noncanonical paths")
        let folder="/private/tmp/ia-service-test-"+UUID().uuidString
        try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(atPath:folder)}
        let path=folder+"/test.sock"
        let server=socket(AF_UNIX,SOCK_STREAM,0)
        defer {Darwin.close(server)}
        var address=try NetworkService.address(path)
        let bound=withUnsafePointer(to:&address) {
            $0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}
        }
        precondition(bound==0 && listen(server,1)==0)
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let signer=Process();signer.executableURL=URL(fileURLWithPath:"/usr/bin/codesign");signer.arguments=["-dv","--verbose=4",executable.path]
        let pipe=Pipe();signer.standardError=pipe;try signer.run()
        let listing=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)!
        signer.waitUntilExit();precondition(signer.terminationStatus==0)
        let hash=String(listing.split(separator:"\n").first{$0.hasPrefix("CDHash=")}!.dropFirst(7))
        let child=Process();child.executableURL=executable;child.arguments=[path];try child.run()
        let fd=accept(server,nil,nil);precondition(fd>=0)
        defer {Darwin.close(fd)}
        NetworkService.limits(fd)
        do {_ = try NetworkService.authenticate(fd,uid:getuid()+1,hash:hash);fatalError("Accepted wrong UID")}
        catch { }
        do {_ = try NetworkService.authenticate(fd,uid:getuid(),hash:String(repeating:"0",count:40));fatalError("Accepted wrong signature")}
        catch { }
        let (uid,pid)=try NetworkService.authenticate(fd,uid:getuid(),hash:hash)
        precondition(uid==getuid() && pid==child.processIdentifier)
        print("PASS: kernel audit-token signature validation accepts the signed peer and rejects wrong UID/hash")
        let value=try JSONSerialization.jsonObject(with:NetworkService.readLine(fd)) as! [String:String]
        precondition(value["op"]=="test")
        _ = "ok\n".withCString {Darwin.write(fd,$0,3)}
        child.waitUntilExit();precondition(child.terminationStatus==0)
        print("PASS: production service protocol completes an authenticated cross-process request/response")
        var pair:[Int32]=[0,0]
        precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0)
        defer {Darwin.close(pair[0]);Darwin.close(pair[1])}
        let oversized=Data(repeating:65,count:1024)
        _ = oversized.withUnsafeBytes {Darwin.write(pair[0],$0.baseAddress!,1024)}
        do {_ = try NetworkService.readLine(pair[1]);fatalError("Accepted oversized request")}
        catch { }
        print("PASS: oversized service frames are rejected before JSON parsing")
    }
}
