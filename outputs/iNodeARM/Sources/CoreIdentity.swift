import Foundation
import Security
import Darwin

func verifyCorePeer(_ fd:Int32,expectedUID:uid_t)throws {
    var uid:uid_t=0;var gid:gid_t=0
    guard getpeereid(fd,&uid,&gid)==0,uid==expectedUID else {
        throw NSError(domain:"IPC",code:1,userInfo:[NSLocalizedDescriptionKey:"VPN 核心用户身份不匹配"])
    }
    var pid:pid_t=0;var count=socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&count)==0,pid>0 else {
        throw NSError(domain:"IPC",code:2,userInfo:[NSLocalizedDescriptionKey:"无法确认 VPN 核心进程"])
    }
    var code:SecCode?;var requirement:SecRequirement?
    let attributes=[kSecGuestAttributePid as String:pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&code)==errSecSuccess,
          SecRequirementCreateWithString("cdhash H\"\(trustedCoreCDHash)\"" as CFString,[],&requirement)==errSecSuccess,
          let code,let requirement,
          SecCodeCheckValidity(code,[],requirement)==errSecSuccess else {
        throw NSError(domain:"IPC",code:3,userInfo:[NSLocalizedDescriptionKey:"VPN 核心签名不匹配，请使用同一完整应用包"])
    }
}
