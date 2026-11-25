import Foundation
import Darwin

// No shell, user-selected executable, credentials or network parsing in this daemon.
@main struct ServiceMain {
    static func main()throws {
        guard geteuid()==0 else {throw NetworkService.failure("后台服务必须由系统启动")}
        let hashFile=NetworkService.directory+"/client.cdhash"
        let clientHash=try String(contentsOfFile:hashFile,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard clientHash.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else {
            throw NetworkService.failure("Invalid installed client identity")
        }
        let runtime=(NetworkService.socketPath as NSString).deletingLastPathComponent
        // /var/run is root-controlled; installer creates our private service directory.
        guard mkdir(runtime,0o755)==0 || errno==EEXIST else {
            throw NetworkService.failure("Cannot create service directory")
        }
        var metadata=stat()
        guard lstat(runtime,&metadata)==0,metadata.st_uid==0,
              metadata.st_mode & S_IFMT == S_IFDIR,metadata.st_mode & 0o022 == 0 else {
            throw NetworkService.failure("Unsafe service directory")
        }
        unlink(NetworkService.socketPath)
        let listener=socket(AF_UNIX,SOCK_STREAM,0)
        guard listener>=0 else {throw NetworkService.failure("Cannot create service socket")}
        defer {Darwin.close(listener);unlink(NetworkService.socketPath)}
        var address=try NetworkService.address(NetworkService.socketPath)
        let bound=withUnsafePointer(to:&address) {
            $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
                Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound==0,chmod(NetworkService.socketPath,0o666)==0,listen(listener,8)==0 else {
            throw NetworkService.failure("Cannot bind service socket")
        }
        let slots=DispatchSemaphore(value:8)
        let sessions=Sessions()
        while true {
            let fd=accept(listener,nil,nil)
            if fd<0 {if errno==EINTR {continue};throw NetworkService.failure("Service accept failed")}
            guard slots.wait(timeout:.now()) == .success else {Darwin.close(fd);continue}
            DispatchQueue.global().async {
                defer {Darwin.close(fd);slots.signal()}
                NetworkService.limits(fd)
                do {
                    let (uid,pid)=try NetworkService.authenticate(fd,hash:clientHash)
                    guard uid>0 else {throw NetworkService.failure("Invalid desktop user")}
                    let request=try JSONSerialization.jsonObject(with:NetworkService.readLine(fd)) as? [String:Any]
                    guard request?["op"] as? String == "start",let path=request?["socket"] as? String else {
                        throw NetworkService.failure("Invalid service request")
                    }
                    try validateSessionPath(path)
                    try sessions.start(uid:uid,pid:pid,path:path)
                    try NetworkService.writeLine(["ok":true],to:fd)
                } catch {
                    try? NetworkService.writeLine(["ok":false,"error":error.localizedDescription],to:fd)
                }
            }
        }
    }
}

