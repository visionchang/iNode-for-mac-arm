import Foundation
import Darwin
@main struct CoreIdentityTest {
    static func main()throws {
        let exe=CommandLine.arguments[1]
        let dir=URL(fileURLWithPath:"/private/tmp/ia-identity-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:dir)}
        let path=dir.appendingPathComponent("control.sock").path
        let p=Process();p.executableURL=URL(fileURLWithPath:exe);p.arguments=[path,String(getuid()),String(getpid())]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.standardError;try p.run()
        defer{if p.isRunning{p.terminate();p.waitUntilExit()}}
        for _ in 0..<100 {if FileManager.default.fileExists(atPath:path){break};usleep(50_000)}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);precondition(fd>=0)
        var addr=sockaddr_un();addr.sun_family=sa_family_t(AF_UNIX);addr.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to:&addr.sun_path){$0.withMemoryRebound(to:CChar.self,capacity:104){dst in path.withCString{_ = strcpy(dst,$0)}}}
        let connected=withUnsafePointer(to:&addr){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        precondition(connected==0)
        let writer=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        try verifyCorePeer(fd,expectedUID:getuid())
        print("PASS: production code verifies the packaged core's UID, PID and exact code signature")
        let ready=DispatchSemaphore(value:0);let ended=DispatchSemaphore(value:0);let readFD=dup(fd)
        DispatchQueue.global().async {
            readSocketEvents(readFD,onEvent:{e in precondition(e["event"] as? String=="ready");ready.signal()},onEnd:{_ in ended.signal()})
        }
        precondition(ready.wait(timeout:.now()+3) == .success)
        try writer.write(contentsOf:Data("{\"op\":\"stop\"}\n".utf8))
        precondition(ended.wait(timeout:.now()+3) == .success)
        p.waitUntilExit();precondition(p.terminationStatus==0);try writer.close()
        print("PASS: authenticated IPC ready and stop round trip completes")
    }
}
