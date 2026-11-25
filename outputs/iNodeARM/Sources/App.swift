import SwiftUI
import AppKit
import Darwin

@MainActor final class ConnectionModel: ObservableObject {
    @Published var gateway = GatewayPolicy.defaultGateway
    @Published var portalGateway = GatewayPolicy.defaultPortalGateway
    let connectionMode:String
    @Published var domains:[String] = [GatewayPolicy.defaultDomain]
    @Published var domainNames:[String:String] = [:]
    @Published var loadingDomains = false
    @Published var domainError = ""
    private var domainRequestID=UUID()
    private var domainProcess:Process?
    private var preferPortalClientDomain = false
    @Published var domain = GatewayPolicy.defaultDomain
    @Published var username = ""
    @Published var password = ""
    @Published var rememberCredentials = false
    private let credentialStore:CredentialStore
    let journal:ConnectionJournal
    @Published private(set) var recordID:UUID?
    private var pendingPassword = ""
    // Retained only for compatibility with the saved-profile schema.
    let pin = ""
    @Published var routes = ""
    @Published var code = ""
    @Published var image: NSImage?
    @Published var stage = "idle"
    @Published var authenticationStep = 0
    @Published var status = "准备连接"
    @Published var detail = ""
    @Published var error = ""
    private var channel: FileHandle?
    private var authorization: Process?
    private var directory: URL?
    private var generation = UUID()
    private var timeoutID = UUID()
    var currentGateway:String {connectionMode=="portal" ? portalGateway : gateway}
    var gatewayAddress:String {
        let prefix=connectionMode=="portal" ? "portal://" : "https://"
        let value=currentGateway.trimmingCharacters(in:.whitespacesAndNewlines)
        return value.lowercased().hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }
    var selectableDomains:[String] {domains + (domain.isEmpty || domains.contains(domain) ? [] : [domain])}
    init(mode:String,credentialStore:CredentialStore = CredentialStore(),journal:ConnectionJournal? = nil) {
        precondition(["vpn","portal"].contains(mode))
        connectionMode=mode;self.credentialStore=credentialStore
        self.journal=journal ?? ConnectionJournal()
        restoreProfile()
    }
    var modeTitle:String {connectionMode=="portal" ? "Portal" : "SSL VPN"}
    var navigationTitle:String {
        if stage=="connected" {return modeTitle+" · 在线"}
        if awaitingCode {return modeTitle+" · 待验证"}
        if !active,!error.isEmpty {return modeTitle+" · 失败"}
        return active ? modeTitle+" · 连接中" : modeTitle
    }
    private func restoreProfile() {
        username="";password="";pendingPassword="";rememberCredentials=false
        domain=connectionMode=="portal" ? "" : GatewayPolicy.defaultDomain
        preferPortalClientDomain=connectionMode=="portal"
        if let saved=credentialStore.load(mode:connectionMode) {
            preferPortalClientDomain=false
            if connectionMode=="portal" {portalGateway=saved.gateway}else{gateway=saved.gateway}
            domain=saved.domain;username=saved.username;routes=saved.routes;rememberCredentials=saved.remember
            if saved.remember {
                do {password=try credentialStore.password(for:saved) ?? ""}
                catch {self.error="读取已记住的密码失败，请手动输入。"}
            }
        }
        domains=domain.isEmpty ? [] : [domain];domainNames=[:]
    }
    func updateGateway(_ value:String) {
        let address=value.trimmingCharacters(in:.whitespacesAndNewlines)
        if connectionMode=="portal" {portalGateway=address}
        else if address.isEmpty {gateway=""}
        else if address.lowercased().hasPrefix("https://") {gateway="https://"+String(address.dropFirst(8))}
        else if address.contains("://") {gateway=address}
        else {gateway="https://"+address}
        domainRequestID=UUID();domainProcess?.terminate();domainProcess=nil;loadingDomains=false
        domains=[];domainNames=[:];domainError="";domain=""
        preferPortalClientDomain=connectionMode=="portal"
    }
    func loadDomains() {
        guard !active,!loadingDomains else{return}
        if connectionMode=="vpn",!gateway.contains("://") {gateway="https://"+gateway}
        guard !currentGateway.isEmpty,let exe=Bundle.main.url(forAuxiliaryExecutable:"inode-desktop") else{return}
        let id=UUID();domainRequestID=id;loadingDomains=true;domainError=""
        let requestedMode=connectionMode;let requestedGateway=currentGateway
        let process=Process();process.executableURL=exe;process.arguments=[requestedMode=="portal" ? "--portal-domains" : "--domains",requestedGateway]
        let output=Pipe();let diagnostics=Pipe();process.standardOutput=output;process.standardError=diagnostics
        domainProcess=process
        do {try process.run()}catch{loadingDomains=false;domainError="无法读取域列表";domainProcess=nil;return}
        Task {
            try? await Task.sleep(nanoseconds:30_000_000_000)
            if domainRequestID==id,loadingDomains {process.terminate()}
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let bytes=output.fileHandleForReading.readDataToEndOfFile()
            let diagnostic=diagnostics.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let value=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
            DispatchQueue.main.async {
                guard let self,self.domainRequestID==id,self.currentGateway==requestedGateway else{return}
                self.loadingDomains=false;self.domainProcess=nil
                if process.terminationStatus==0,let names=value?["domains"] as? [String] {
                    self.domains=names.reduce(into:[String]()){if !$0.contains($1){$0.append($1)}}
                    self.domainNames=[:]
                    for option in value?["domainOptions"] as? [[String:String]] ?? [] {
                        if let id=option["id"],let name=option["name"] {self.domainNames[id]=name}
                    }
                    if !self.domain.isEmpty,!self.domains.contains(self.domain) {self.domain=""}
                    if requestedMode=="vpn",self.domain.isEmpty {self.domain=self.domains.first ?? ""}
                    if requestedMode=="portal",self.preferPortalClientDomain,self.domain.isEmpty,
                       let preferred=value?["defaultDomain"] as? String,self.domains.contains(preferred) {self.domain=preferred}
                    self.preferPortalClientDomain=false
                }else{
                    let reason=String(data:diagnostic.prefix(600),encoding:.utf8) ?? ""
                    self.domainError=reason.isEmpty ? "域列表读取失败，可点击刷新重试" : "域列表读取失败："+reason
                }
            }
        }
    }
    func forgetCredentials() {
        guard !rememberCredentials else{return}
        do {try credentialStore.forget(mode:connectionMode)}
        catch {self.error="删除本地保存的账号密码失败，请重试。"}
    }
    private func saveCredentials() {
        let profile=SavedProfile(gateway:currentGateway,domain:domain,username:username,pin:pin,
            trustedPin:nil,routes:routes,remember:rememberCredentials,mode:connectionMode)
        do {try credentialStore.save(profile,password:pendingPassword)}
        catch {self.error="认证成功，但保存账号密码失败："+error.localizedDescription}
        pendingPassword=""
    }
    var active: Bool { stage != "idle" }
    var awaitingCode: Bool { stage == "captcha" || stage == "sms" }
    var isConfiguredForAutoConnect: Bool {
        rememberCredentials
            && !currentGateway.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && error.isEmpty
    }
    func send(_ body: [String:Any]) {
        guard let channel else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: body)
            defer {data.resetBytes(in:0..<data.count)}
            data.append(10)
            try channel.write(contentsOf: data)
        } catch { fail("无法与 VPN 核心通信（\(error.localizedDescription)），请重新连接。") }
    }
    func connect() {
        guard !active else { return }
        error = ""
        if rememberCredentials,password.isEmpty,let saved=credentialStore.load(mode:connectionMode),saved.remember {
            let current=SavedProfile(gateway:currentGateway,domain:domain,username:username,pin:pin,trustedPin:nil,routes:routes,remember:false,mode:connectionMode)
            if saved.accountKey==current.accountKey {
                do {password=try credentialStore.password(for:saved) ?? ""}
                catch {self.error="读取已记住的密码失败，请手动输入。";return}
            }
        }
        guard !username.isEmpty, !password.isEmpty else { error = "请填写账号和密码"; return }
        if connectionMode=="vpn",!gateway.contains("://") {gateway="https://"+gateway}
        guard connectionMode=="portal" || (URL(string:gateway).map{$0.scheme=="https" && $0.host != nil && $0.user==nil && $0.password==nil} ?? false) else {
            error="请填写有效的服务器地址和端口，例如 vpn.example.com:3000"; return
        }
        domainRequestID=UUID()
        domainProcess?.terminate();domainProcess=nil;loadingDomains=false
        let id=UUID(); generation=id
        // Store only the address authority, never pasted user-info or URL query data.
        let journalURL=connectionMode=="portal" ? "portal://"+gatewayAddress : gateway
        let components=URLComponents(string:journalURL)
        let endpoint=components?.host.map { host in
            host+(components?.port.map{":"+String($0)} ?? "")
        } ?? "未识别地址"
        recordID=journal.begin(mode:connectionMode,gateway:endpoint,username:username,domain:domain)
        do {
            let folder=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("inode-arm-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            directory=folder
            let path=folder.appendingPathComponent("control.sock").path
            guard path.utf8.count < 104 else { throw NSError(domain:"IPC",code:1,userInfo:[NSLocalizedDescriptionKey:"临时目录路径过长"]) }
            guard let exe=Bundle.main.url(forAuxiliaryExecutable:"inode-desktop") else { throw NSError(domain:"Core",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 ARM VPN 核心"]) }
            stage="authorizing"
            status=connectionMode=="portal" ? "正在启动 Portal…" : "正在连接 VPN 后台服务…"
            detail=""
            if connectionMode=="portal" {
                let process=Process()
                process.executableURL=exe;process.arguments=[path,String(getuid()),String(getpid())]
                let diagnostics=Pipe()
                process.standardOutput=FileHandle.nullDevice;process.standardError=diagnostics
                process.terminationHandler={ [weak self] p in Task { @MainActor in
                    guard let self,self.generation==id,self.active else {return}
                    let data=diagnostics.fileHandleForReading.readDataToEndOfFile()
                    let reason=String(data:data.prefix(2000),encoding:.utf8) ?? ""
                    self.fail(p.terminationStatus==0 ? "连接已结束" : "Portal 核心启动失败。\n"+reason)
                }}
                authorization=process
                try process.run()
            } else {
                DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                    do {try startVPNService(socketPath:path)}
                    catch {
                        let reason=error.localizedDescription
                        DispatchQueue.main.async {
                            guard let self,self.generation==id,self.active else {return}
                            self.fail(reason)
                        }
                    }
                }
            }
            Task {
                for _ in 0..<150 {
                    guard generation==id,active else { return }
                    if FileManager.default.fileExists(atPath:path) {
                        openChannel(path,id:id); return
                    }
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                if generation==id { fail("启动连接核心超时，请重新安装应用或稍后重试。") }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func openChannel(_ path:String,id:UUID) {
        let fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { fail("无法创建本地通信通道");return }
        var addr=sockaddr_un();addr.sun_family=sa_family_t(AF_UNIX)
        let length=MemoryLayout<sockaddr_un>.size
        withUnsafeMutablePointer(to:&addr.sun_path) { tuple in
            tuple.withMemoryRebound(to:CChar.self,capacity:104) { dst in
                path.withCString { src in _ = strcpy(dst,src) }
            }
        }
        addr.sun_len=UInt8(length)
        let result=withUnsafePointer(to:&addr) { ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(length)) } }
        guard result==0 else { Darwin.close(fd);fail("无法连接 VPN 核心");return }
        do {try verifyCorePeer(fd,expectedUID:getuid())} catch {Darwin.close(fd);fail(error.localizedDescription);return}
        var noSignal:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        let readFD=dup(fd)
        guard readFD >= 0 else {Darwin.close(fd);fail("无法创建核心消息读取通道");return}
        channel=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        status="正在连接核心…";detail=""
        armTimeout(10, message:"连接核心没有及时响应，请重试。")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            readSocketEvents(readFD, onEvent: { event in
                DispatchQueue.main.async {guard let self,self.generation==id else{return};self.receive(event)}
            }, onEnd: { reason in
                DispatchQueue.main.async {guard let self,self.generation==id,self.active else{return};self.fail(reason.map {"核心通信中断："+$0} ?? "VPN 核心已退出，连接已结束。")}
            })
        }
    }
    private func armTimeout(_ seconds:Double, message:String) {
        let timer=UUID();timeoutID=timer
        Task {
            try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))
            guard timeoutID==timer,active else{return}
            fail(message)
        }
    }
    func receive(_ e:[String:Any]) {
        timeoutID=UUID()
        let event=e["event"] as? String ?? ""
        switch event {
        case "ready":
            journal.append(.ready,to:recordID)
            authenticationStep=0
            stage="working";status="正在连接网关…";detail="获取认证参数"
            pendingPassword=password
            send(["op":"start","mode":connectionMode,"gateway":currentGateway,"domain":domain,"user":username,"password":password,
                  "routes":routes.split(whereSeparator:{$0=="," || $0.isWhitespace}).map(String.init)])
            armTimeout(45,message:"获取网关认证参数或验证码超时，请检查网络后重试。")
        case "captcha":
            journal.append(.captcha,to:recordID)
            authenticationStep=1
            guard let s=e["image"] as? String,let data=Data(base64Encoded:s),let pic=NSImage(data:data) else {fail("无法读取验证码图片");return}
            image=pic;code="";stage="captcha";status="请输入图片验证码";detail="提交后，网关可能发送短信"
        case "sms":
            journal.append(.sms,to:recordID)
            authenticationStep=2
            image=nil;code="";stage="sms";status="请输入短信验证码";detail=e["message"] as? String ?? "短信已发送"
        case "authenticated":journal.append(.authenticated,to:recordID);authenticationStep=3;saveCredentials();stage="working";status=connectionMode=="portal" ? "Portal 认证成功" : "认证成功，正在建立隧道…";detail=""
        case "connected":journal.append(.online,to:recordID);authenticationStep=3;stage="connected";status="已连接";detail=connectionMode=="portal" ? "本机地址：\(e["address"] as? String ?? "")" : "虚拟地址：\(e["address"] as? String ?? "") · \(e["interface"] as? String ?? "")"
        case "reconnecting":journal.append(.reconnecting,to:recordID);stage="working";status="连接中断，正在重连…";detail="复用已有会话，不重复发送短信"
        case "disconnected":disconnect(reason:.remoteDisconnected)
        case "error":fail(e["message"] as? String ?? "连接失败")
        default:break
        }
    }
    func submit() {
        guard awaitingCode,!code.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        let op=stage;stage="working";status="正在验证…"
        send(["op":op,"code":code.trimmingCharacters(in:.whitespacesAndNewlines)]);code=""
        armTimeout(45,message:"网关验证超时，请重新连接。")
    }
    func refresh() {guard stage=="captcha" else{return};stage="working";send(["op":"refresh"]);armTimeout(30,message:"读取验证码超时，请重试。")}
    func disconnect(clearPassword:Bool = false,reason:ConnectionEventKind = .disconnected,failure:ConnectionFailure? = nil) {
        let kind=(reason == .disconnected && journal.record(recordID)?.connectedAt==nil) ? ConnectionEventKind.cancelled : reason
        journal.finish(recordID,kind:kind,failure:failure)
        domainRequestID=UUID();domainProcess?.terminate();domainProcess=nil;loadingDomains=false
        if let channel {try? channel.write(contentsOf:Data("{\"op\":\"stop\"}\n".utf8))}
        // Shutdown wakes the core's reader so it can remove routes before exiting.
        if let channel {shutdown(channel.fileDescriptor,SHUT_RDWR);try? channel.close()}
        channel=nil;generation=UUID();timeoutID=UUID();stage="idle";authenticationStep=0;status="未连接";detail="";code="";pendingPassword="";image=nil
        if clearPassword {password=""}
        if let directory {try? FileManager.default.removeItem(at:directory)}
        directory=nil
    }
    private func fail(_ text:String) {disconnect(clearPassword:false,reason:.failed,failure:ConnectionFailure(message:text));error=text;status="连接未完成"}
}
func shellQuote(_ s:String)->String {"'"+s.replacingOccurrences(of:"'",with:"'\\''")+"'"}
func appleQuote(_ s:String)->String {"\""+s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}

