import Foundation
import Darwin

// Local plaintext storage, explicitly requested by the user. Access is limited
// to the current user; this does not protect against other code running as them.
struct LocalFilePasswords:PasswordStorage {
    let directory:URL
    init(directory:URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("iNode ARM",isDirectory:true)) {
        self.directory=directory
    }
    private func failure(_ operation:String)->NSError {
        NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"本地密码文件\(operation)失败（\(errno)）"])
    }
    private func directoryFD(create:Bool)throws->Int32? {
        if create {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        let fd=Darwin.open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        if fd<0 {if !create && errno==ENOENT{return nil};throw failure("打开目录")}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),fchmod(fd,0o700)==0 else {
            Darwin.close(fd);throw failure("检查目录权限")
        }
        return fd
    }
    private func load(_ directory:Int32)throws->[String:String] {
        let fd=openat(directory,"credentials.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        if fd<0 {if errno==ENOENT{return [:]};throw failure("读取")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer{try? handle.close()}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),(info.st_mode&S_IFMT)==S_IFREG,
              info.st_size<=1_048_576,fchmod(fd,0o600)==0 else {throw failure("检查文件权限")}
        var data=try handle.read(upToCount:1_048_577) ?? Data()
        defer{data.resetBytes(in:0..<data.count)}
        guard data.count<=1_048_576 else {throw NSError(domain:"Credentials",code:1,userInfo:[NSLocalizedDescriptionKey:"本地密码文件过大"])}
        return try JSONDecoder().decode([String:String].self,from:data)
    }
    private func save(_ values:[String:String],to directory:Int32)throws {
        if values.isEmpty {
            if unlinkat(directory,"credentials.json",0) != 0 && errno != ENOENT {throw failure("删除")}
            return
        }
        var bytes=try JSONEncoder().encode(values)
        defer{bytes.resetBytes(in:0..<bytes.count)}
        let temp="credentials-"+UUID().uuidString+".tmp"
        let fd=openat(directory,temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw failure("创建")}
        defer{Darwin.close(fd);unlinkat(directory,temp,0)}
        try bytes.withUnsafeBytes { raw in
            var offset=0
            while offset<raw.count {
                let count=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if count<0 && errno==EINTR{continue}
                guard count>0 else {throw failure("写入")}
                offset+=count
            }
        }
        guard fsync(fd)==0,renameat(directory,temp,directory,"credentials.json")==0 else {throw failure("保存")}
    }
    func read(_ account:String)throws->String? {
        guard let fd=try directoryFD(create:false) else{return nil}
        defer{Darwin.close(fd)}
        return try load(fd)[account]
    }
    func write(_ password:String,account:String)throws {
        let fd=try directoryFD(create:true)!
        defer{Darwin.close(fd)}
        var values=try load(fd);values[account]=password
        try save(values,to:fd)
    }
    func delete(_ account:String)throws {
        guard let fd=try directoryFD(create:false) else{return}
        defer{Darwin.close(fd)}
        var values=try load(fd);values.removeValue(forKey:account)
        try save(values,to:fd)
    }
}
