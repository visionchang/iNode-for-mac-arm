import Foundation
import Security
import Darwin

enum NetworkService {
    static let directory = "/Library/PrivilegedHelperTools/local.vision.inode-arm"
    static let socketPath = "/var/run/local.vision.inode-arm/control.sock"
    static func failure(_ message:String)->NSError {
        NSError(domain:"NetworkService",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
    static func address(_ path:String)throws->sockaddr_un {
        guard path.utf8.count<104 else {throw failure("服务地址过长")}
        var value=sockaddr_un()
        value.sun_family=sa_family_t(AF_UNIX)
        value.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to:&value.sun_path) { pointer in
            pointer.withMemoryRebound(to:CChar.self,capacity:104) { destination in
                path.withCString { _ = strcpy(destination,$0) }
            }
        }
        return value
    }
    static func limits(_ fd:Int32) {
        var timeout=timeval(tv_sec:5,tv_usec:0)
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        var enabled:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,socklen_t(MemoryLayout<Int32>.size))
    }
    // Bind signature validation to the kernel's audit token, including PID version.
    // A numeric PID alone could be reused between peer lookup and signature lookup.
    static func authenticate(_ fd:Int32,uid expectedUID:uid_t? = nil,hash:String)throws->(uid_t,pid_t) {
        var uid:uid_t=0;var gid:gid_t=0
        guard getpeereid(fd,&uid,&gid)==0,expectedUID == nil || uid==expectedUID else {
            throw failure("后台服务通信身份不匹配")
        }
        var token=audit_token_t()
        var size=socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&size)==0,
              size==MemoryLayout<audit_token_t>.size else {throw failure("无法确认后台通信进程")}
        let tokenData=withUnsafeBytes(of:token){Data($0)}
        var code:SecCode?;var requirement:SecRequirement?
        guard hash.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:tokenData] as CFDictionary,[],&code)==errSecSuccess,
              SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString,[],&requirement)==errSecSuccess,
              let code,let requirement,SecCodeCheckValidity(code,[],requirement)==errSecSuccess else {
            throw failure("应用与后台服务版本不匹配，请重新安装同版本安装包")
        }
        var pid:pid_t=0;size=socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size)==0,pid>0 else {throw failure("无法确认应用进程")}
        return (uid,pid)
    }
    static func readLine(_ fd:Int32)throws->Data {
        var result=Data();var byte:UInt8=0
        while result.count<1024 {
            let n=Darwin.read(fd,&byte,1)
            if n<0 && errno==EINTR {continue}
            guard n==1 else {throw failure("后台服务通信超时或已断开")}
            if byte==10 {return result}
            result.append(byte)
        }
        throw failure("后台服务请求过长")
    }
    static func writeLine(_ value:[String:Any],to fd:Int32)throws {
        var data=try JSONSerialization.data(withJSONObject:value);data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset=0
            while offset<bytes.count {
                let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if n<0 && errno==EINTR {continue}
                guard n>0 else {throw failure("无法发送后台服务请求")}
                offset+=n
            }
        }
    }
}
