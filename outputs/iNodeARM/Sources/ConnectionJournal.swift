import Foundation
import Darwin
import Combine

enum ConnectionEventKind:String,Codable {
    case connecting,ready,captcha,sms,authenticated,online,reconnecting,reconnected
    case disconnected,cancelled,remoteDisconnected,failed,applicationQuit,interrupted
    var title:String {
        switch self {
        case .connecting:return "开始连接"
        case .ready:return "连接核心已就绪"
        case .captcha:return "等待图片验证码"
        case .sms:return "等待短信验证码"
        case .authenticated:return "认证成功"
        case .online:return "连接已建立"
        case .reconnecting:return "连接中断，正在重连"
        case .reconnected:return "重新连接成功"
        case .disconnected:return "主动断开"
        case .cancelled:return "取消连接"
        case .remoteDisconnected:return "连接已结束"
        case .failed:return "连接异常结束"
        case .applicationQuit:return "退出应用"
        case .interrupted:return "上次运行异常结束"
        }
    }
}

enum ConnectionFailure:String,Codable {
    case timeout,authentication,service,communication,other
    var title:String {
        switch self {
        case .timeout:return "等待响应超时"
        case .authentication:return "认证未完成"
        case .service:return "后台服务或核心启动异常"
        case .communication:return "通信异常"
        case .other:return "连接未完成"
        }
    }
    init(message:String) {
        if message.contains("超时") {self = .timeout}
        else if message.contains("后台服务") || message.contains("签名") || message.contains("启动") {self = .service}
        else if message.contains("认证") || message.contains("密码") || message.contains("验证码") {self = .authentication}
        else if message.contains("通信") || message.contains("网络") {self = .communication}
        else {self = .other}
    }
}

struct ConnectionEvent:Codable,Identifiable {
    var id=UUID()
    let date:Date
    let kind:ConnectionEventKind
    var failure:ConnectionFailure?
}

struct ConnectionRecord:Codable,Identifiable {
    let id:UUID
    let mode:String
    let gateway:String
    let username:String
    let domain:String
    let startedAt:Date
    var connectedAt:Date?
    var endedAt:Date?
    var onlineSince:Date?
    var onlineSeconds:TimeInterval=0
    var events:[ConnectionEvent]
    var modeTitle:String {mode=="portal" ? "Portal" : "SSL VPN"}
    var stateTitle:String {
        guard let last=events.last else {return "连接中"}
        if endedAt != nil {return last.kind.title}
        if onlineSince != nil {return "在线"}
        if last.kind == .reconnecting {return "重连中"}
        if last.kind == .captcha || last.kind == .sms {return "待验证"}
        return "连接中"
    }
    func duration(at date:Date)->TimeInterval {
        onlineSeconds + (onlineSince.map{max(0,date.timeIntervalSince($0))} ?? 0)
    }
}

private struct JournalDocument:Codable {
    var version=1
    let savedAt:Date
    let totals:[String:TimeInterval]
    let records:[ConnectionRecord]
}

// Keep the existing data directory and bundle identifier across the app rename.
// This file contains connection metadata and fixed event labels, never secrets
// or unfiltered diagnostic/server messages.
@MainActor final class ConnectionJournal:ObservableObject {
    @Published private(set) var records:[ConnectionRecord]=[]
    @Published private(set) var storageError=""
    private var totals:[String:TimeInterval]=[:]
    private var timer:Timer?
    private var canPersist=true
    private let file=JournalFile()
    init() {
        do {
            if let bytes=try file.read() {
                let document=try JSONDecoder().decode(JournalDocument.self,from:bytes)
                guard document.version==1 else {throw NSError(domain:"Journal",code:1)}
                records=document.records;totals=document.totals
                // The process cannot know when an abnormal exit occurred.
                // Stop at the last persisted checkpoint instead of inventing
                // online time between that checkpoint and the next launch.
                let unfinished=records.filter{$0.endedAt==nil}.map(\.id)
                for id in unfinished {finish(id,kind:.interrupted,at:document.savedAt,save:false)}
                if !unfinished.isEmpty {persist()}
            }
        } catch {
            storageError="无法读取已有在线记录；本次记录暂存于内存，原文件不会被覆盖。"
            canPersist=false
        }
        let timer=Timer(timeInterval:15,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.records.contains(where:{$0.endedAt==nil}) else {return}
                self.persist()
            }
        }
        self.timer=timer
        RunLoop.main.add(timer,forMode:.common)
    }
    func record(_ id:UUID?)->ConnectionRecord? {records.first{$0.id==id}}
    func latest(mode:String)->ConnectionRecord? {records.first{$0.mode==mode}}
    func total(mode:String,at date:Date)->TimeInterval {
        (totals[mode] ?? 0)+records.filter{$0.mode==mode && $0.endedAt==nil}.reduce(0){$0+$1.duration(at:date)}
    }
    @discardableResult func begin(mode:String,gateway:String,username:String,domain:String)->UUID {
        let now=Date();let id=UUID()
        records.insert(ConnectionRecord(id:id,mode:mode,gateway:gateway,username:String(username.prefix(128)),domain:String(domain.prefix(128)),startedAt:now,events:[ConnectionEvent(date:now,kind:.connecting)]),at:0)
        persist();return id
    }
    func append(_ kind:ConnectionEventKind,to id:UUID?) {
        guard let index=records.firstIndex(where:{$0.id==id && $0.endedAt==nil}) else {return}
        let now=Date()
        if kind == .online {
            guard records[index].onlineSince==nil else {return}
            let resumed=records[index].connectedAt != nil
            if records[index].connectedAt==nil {records[index].connectedAt=now}
            records[index].onlineSince=now
            addEvent(resumed ? .reconnected : .online,index:index,date:now)
        } else {
            if kind == .reconnecting {
                pause(index:index,at:now)
            }
            addEvent(kind,index:index,date:now)
        }
        persist()
    }
    func finish(_ id:UUID?,kind:ConnectionEventKind,failure:ConnectionFailure?=nil,at date:Date=Date(),save:Bool=true) {
        guard let index=records.firstIndex(where:{$0.id==id && $0.endedAt==nil}) else {return}
        let ended=max(date,records[index].startedAt)
        pause(index:index,at:ended)
        records[index].endedAt=ended
        totals[records[index].mode,default:0]+=records[index].onlineSeconds
        addEvent(kind,index:index,date:ended,failure:failure)
        if save {persist()}
    }
    private func pause(index:Int,at date:Date) {
        if let since=records[index].onlineSince {
            records[index].onlineSeconds+=max(0,date.timeIntervalSince(since))
            records[index].onlineSince=nil
        }
    }
    private func addEvent(_ kind:ConnectionEventKind,index:Int,date:Date,failure:ConnectionFailure?=nil) {
        records[index].events.append(ConnectionEvent(date:date,kind:kind,failure:failure))
        if records[index].events.count>100 {
            records[index].events.removeSubrange(1..<(records[index].events.count-99))
        }
    }
    private func persist() {
        guard canPersist else {return}
        do {
            let document=JournalDocument(savedAt:Date(),totals:totals,records:records)
            try file.write(JSONEncoder().encode(document))
            storageError=""
        } catch {storageError="在线记录保存失败；当前计时仍在继续，请检查本机存储空间与权限。"}
    }
    func exportText(mode:String?)->String {
        let now=Date()
        var lines=["iNode for Mac · Apple Silicon · 在线记录","导出时间：\(now.formatted(date:.abbreviated,time:.standard))",
                   "Portal 累计在线：\(OnlineDuration.string(total(mode:"portal",at:now)))",
                   "SSL VPN 累计在线：\(OnlineDuration.string(total(mode:"vpn",at:now)))",
                   "时长为客户端统计，不作为服务器计费依据。",""]
        for record in records where mode==nil || record.mode==mode {
            lines.append("[\(record.modeTitle)] \(record.gateway) · \(record.stateTitle)")
            lines.append("账号：\(exportField(record.username))　域：\(exportField(record.domain))")
            lines.append("发起：\(record.startedAt.formatted(date:.abbreviated,time:.standard))")
            if let connected=record.connectedAt {lines.append("上线：\(connected.formatted(date:.abbreviated,time:.standard))")}
            if let ended=record.endedAt {lines.append("结束：\(ended.formatted(date:.abbreviated,time:.standard))")}
            lines.append("在线时长：\(OnlineDuration.string(record.duration(at:now)))")
            for event in record.events {
                lines.append("  \(event.date.formatted(date:.abbreviated,time:.standard))  \(event.kind.title)\(event.failure.map{" · "+$0.title} ?? "")")
            }
            lines.append("")
        }
        return lines.joined(separator:"\n")
    }
    private func exportField(_ value:String)->String {
        value.components(separatedBy:.newlines).joined(separator:" ")
    }
}

enum OnlineDuration {
    static func string(_ seconds:TimeInterval)->String {
        let value=Int(max(0,seconds).rounded(.down))
        let days=value/86400
        let hours=(value%86400)/3600
        let minutes=(value%3600)/60
        let secs=value%60
        if days>0 {
            return String(format:"%ld天 %02ld:%02ld:%02ld",days,hours,minutes,secs)
        }
        return String(format:"%02ld:%02ld:%02ld",hours,minutes,secs)
    }
}

private struct JournalFile {
    private let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("iNode ARM",isDirectory:true)
    private let name="connection-history.json"
    private func failure()->NSError {NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    private func openDirectory(create:Bool)throws->Int32? {
        if create {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let fd=Darwin.open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        if fd<0 {if !create && errno==ENOENT {return nil};throw failure()}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),fchmod(fd,0o700)==0 else {Darwin.close(fd);throw failure()}
        return fd
    }
    func read()throws->Data? {
        guard let dir=try openDirectory(create:false) else {return nil}
        defer {Darwin.close(dir)}
        let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        if fd<0 {if errno==ENOENT {return nil};throw failure()}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer {try? handle.close()}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,fchmod(fd,0o600)==0 else {throw failure()}
        return try handle.readToEnd() ?? Data()
    }
    func write(_ data:Data)throws {
        let dir=try openDirectory(create:true)!
        defer {Darwin.close(dir)}
        let temporary="history-"+UUID().uuidString+".tmp"
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw failure()}
        defer {Darwin.close(fd);unlinkat(dir,temporary,0)}
        try data.withUnsafeBytes { bytes in
            var offset=0
            while offset<bytes.count {
                let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count<0 && errno==EINTR {continue}
                guard count>0 else {throw failure()}
                offset+=count
            }
        }
        guard fsync(fd)==0,renameat(dir,temporary,dir,name)==0 else {throw failure()}
    }
}
