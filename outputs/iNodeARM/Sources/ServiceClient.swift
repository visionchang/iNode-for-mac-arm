import Foundation
import Darwin

func startVPNService(socketPath:String)throws {
    let fd=socket(AF_UNIX,SOCK_STREAM,0)
    guard fd>=0 else {throw NetworkService.failure("无法创建后台服务连接")}
    defer {Darwin.close(fd)}
    NetworkService.limits(fd)
    var address=try NetworkService.address(NetworkService.socketPath)
    let result=withUnsafePointer(to:&address) {
        $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result==0 else {
        throw NetworkService.failure("VPN 后台服务未启动。请先安装 iNode for Mac 安装包；若已安装，请检查系统设置中的后台项目是否允许运行，或重新安装。")
    }
    _ = try NetworkService.authenticate(fd,uid:0,hash:trustedServiceCDHash)
    try NetworkService.writeLine(["op":"start","socket":socketPath],to:fd)
    let response=try JSONSerialization.jsonObject(with:NetworkService.readLine(fd)) as? [String:Any]
    guard response?["ok"] as? Bool == true else {
        throw NetworkService.failure(response?["error"] as? String ?? "后台服务启动 VPN 失败")
    }
}
