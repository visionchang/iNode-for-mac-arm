import Foundation
import Darwin

func validateSessionPath(_ path:String)throws {
    let prefix="/private/tmp/inode-arm-"
    guard path.hasPrefix(prefix),path.hasSuffix("/control.sock"),
          UUID(uuidString:String(path.dropFirst(prefix.count).dropLast("/control.sock".count))) != nil else {
        throw NetworkService.failure("Invalid session socket path")
    }
}

final class Sessions {
    private let lock=NSLock()
    private var processes:[uid_t:Process]=[:]
    func start(uid:uid_t,pid:pid_t,path:String)throws {
        lock.lock();defer {lock.unlock()}
        guard processes[uid] == nil,processes.count<16 else {
            throw NetworkService.failure("VPN 核心仍在退出，请稍后重试")
        }
        let process=Process()
        process.executableURL=URL(fileURLWithPath:NetworkService.directory+"/inode-desktop")
        process.arguments=[path,String(uid),String(pid)]
        process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"/var/empty","LANG":"en_US.UTF-8"]
        process.standardInput=FileHandle.nullDevice
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        process.terminationHandler={ [weak self] finished in
            guard let self else {return}
            self.lock.lock();defer {self.lock.unlock()}
            if self.processes[uid] === finished {self.processes.removeValue(forKey:uid)}
        }
        try process.run()
        processes[uid]=process
    }
}
