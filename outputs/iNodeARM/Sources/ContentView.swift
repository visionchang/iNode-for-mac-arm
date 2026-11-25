import SwiftUI
import AppKit

enum Palette {
    static let ink=Color(red:0.10,green:0.16,blue:0.28)
    static let muted=Color(red:0.46,green:0.52,blue:0.63)
    static let accent=Color(red:0.13,green:0.39,blue:0.92)
    static let canvas=Color(red:0.95,green:0.97,blue:1.00)
    static let wash=Color(red:0.89,green:0.93,blue:1.00)
    static let online=Color(red:0.08,green:0.61,blue:0.41)
    static let danger=Color(red:0.88,green:0.21,blue:0.27)
    static let border=Color(red:0.87,green:0.91,blue:0.97)
}
struct ConnectionsView:View {
    @ObservedObject var connections:ConnectionsModel
    var body:some View {
        ContentView(model:connections.current,connections:connections).id(connections.selectedMode)
    }
}
struct ContentView:View {
    @ObservedObject var model:ConnectionModel
    @ObservedObject var connections:ConnectionsModel
    @State private var settings=false
    @State private var appSettings=false
    @State private var history=false
    @State private var revealPassword=false
    @State private var editingGateway=false
    @State private var gatewayDraft=""
    @State private var gatewayHovered=false
    @FocusState private var codeFocused:Bool
    private var connected:Bool {model.stage=="connected"}
    private var busy:Bool {model.active && !model.awaitingCode && !connected}
    var body:some View {
        VStack(spacing:0) {
            header
            VStack(spacing:12) {
                HStack(spacing:12) {
                    connectionType(connections.portal,icon:"network",mode:"portal")
                    connectionType(connections.vpn,icon:"lock.shield",mode:"vpn")
                }
                if connected {connectionCard}
                else if busy {waitingCard}
                gatewayCard
                if model.active,!connected,model.connectionMode=="vpn" {steps}
                if model.awaitingCode {verificationCard}
                else if !model.active {loginCard}
                if !model.error.isEmpty {errorCard}

            }.padding(.horizontal,24).padding(.bottom,12)
            Spacer(minLength:0)
            actionArea
        }
        .frame(width:410)
        .frame(minHeight:738)
        .fixedSize(horizontal:false,vertical:true)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .sheet(isPresented:$settings){settingsSheet}
        .sheet(isPresented:$appSettings){appSettingsSheet}
        .sheet(isPresented:$history){ConnectionHistoryView(journal:connections.journal)}
        .onChange(of:model.stage){_ in codeFocused=model.awaitingCode}
        .onAppear{model.loadDomains();codeFocused=model.awaitingCode}
    }
    private var header:some View {
        HStack(spacing:11) {
            Image(systemName:"point.3.connected.trianglepath.dotted")
                .font(.system(size:20,weight:.semibold)).foregroundStyle(.white)
                .frame(width:38,height:38).background(Palette.accent.gradient,in:RoundedRectangle(cornerRadius:13))
            VStack(alignment:.leading,spacing:0) {
                Text("iNode").font(.system(size:27,weight:.bold,design:.rounded))
                Text("for Mac · Apple Silicon").font(.system(size:10,weight:.semibold)).tracking(0.3).foregroundStyle(Palette.muted)
            }.accessibilityElement(children:.ignore).accessibilityLabel("iNode for Mac")
            Spacer()
            HStack(spacing:8) {
                Button {history=true} label:{Image(systemName:"clock.arrow.circlepath").font(.system(size:16,weight:.medium)).foregroundStyle(Palette.accent).frame(width:37,height:37).background(.white,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Palette.border,lineWidth:1))}
                    .buttonStyle(.plain).help("在线记录与累计时长").accessibilityLabel("在线记录")
                Button {appSettings=true} label:{Image(systemName:"gearshape").font(.system(size:16,weight:.medium)).foregroundStyle(Palette.accent).frame(width:37,height:37).background(.white,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Palette.border,lineWidth:1))}
                    .buttonStyle(.plain).help("开机启动与自动连接设置").accessibilityLabel("应用设置")
            }
        }.padding(.horizontal,24).padding(.top,20).padding(.bottom,16)
    }
    private func stateTitle(_ connection:ConnectionModel)->String {
        if connection.stage=="connected" {return "在线"}
        if connection.awaitingCode {return "待验证"}
        if connection.active {return "连接中"}
        return connection.error.isEmpty ? "未连接" : "连接失败"
    }
    private func stateColor(_ connection:ConnectionModel)->Color {
        if connection.stage=="connected" {return Palette.online}
        if connection.active {return Palette.accent}
        return connection.error.isEmpty ? Palette.muted : Palette.danger
    }
    private func connectionType(_ connection:ConnectionModel,icon:String,mode:String)->some View {
        let selected=connections.selectedMode==mode
        let online=connection.stage=="connected"
        return Button {connections.selectedMode=mode} label:{
            VStack(alignment:.leading,spacing:10) {
                HStack(spacing:8) {
                    Image(systemName:icon).font(.system(size:18,weight:.medium))
                    Text(connection.modeTitle).font(.system(size:15,weight:.bold))
                    Spacer(minLength:0)
                    if selected {Image(systemName:"checkmark.circle.fill").font(.system(size:12))}
                }.foregroundStyle(selected ? .white : Palette.accent)
                HStack(spacing:6) {
                    Circle().fill(online ? (selected ? Color(red:0.43,green:0.98,blue:0.77) : Palette.online) : (selected ? Color.white.opacity(0.7) : stateColor(connection))).frame(width:7,height:7)
                    Text(stateTitle(connection)).font(.system(size:12,weight:.semibold))
                }.foregroundStyle(selected ? .white : stateColor(connection))
                    .padding(.horizontal,9).padding(.vertical,5)
                    .background(selected ? Color.white.opacity(0.16) : stateColor(connection).opacity(0.09),in:Capsule())
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? Palette.accent : Color.white,in:RoundedRectangle(cornerRadius:20))
                .overlay(RoundedRectangle(cornerRadius:20).stroke(selected ? Palette.accent : Palette.border,lineWidth:1))
                .shadow(color:selected ? Palette.accent.opacity(0.16) : .clear,radius:10,x:0,y:5)
                .contentShape(RoundedRectangle(cornerRadius:20))
        }.buttonStyle(.plain)
            .accessibilityLabel(connection.modeTitle+"，"+stateTitle(connection)+(selected ? "，当前选择" : ""))
            .help("切换到 "+connection.modeTitle+"，保留另一种连接")
    }
    private var gatewayCard:some View {
        VStack(alignment:.leading,spacing:10) {
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Label(model.connectionMode=="portal" ? "Portal 服务器" : "VPN 网关",systemImage:"server.rack").font(.system(size:12,weight:.medium)).foregroundStyle(Palette.muted)
                    Spacer()
                    if model.connectionMode=="vpn" {
                        Button {settings=true} label:{Label("连接设置",systemImage:"slider.horizontal.3").font(.system(size:11,weight:.medium)).foregroundStyle(Palette.accent)}
                            .buttonStyle(.plain).help("设置 SSL VPN 的额外内网网段")
                    }
                }
                HStack(spacing:10) {
                    if editingGateway {
                        TextField(model.connectionMode=="portal" ? "例如 192.0.2.10:50200" : "例如 vpn.example.com:3000",text:$gatewayDraft)
                            .font(.system(size:15,weight:.medium,design:.monospaced)).textFieldStyle(.roundedBorder)
                        Button("取消"){editingGateway=false}.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(Palette.muted)
                        Button("完成"){
                            let address=gatewayDraft.trimmingCharacters(in:.whitespacesAndNewlines)
                            if address != model.gatewayAddress {model.updateGateway(address);model.loadDomains()}
                            editingGateway=false
                        }.buttonStyle(.plain).font(.system(size:12,weight:.semibold)).foregroundStyle(Palette.accent)
                    } else {
                        Text(model.gatewayAddress.isEmpty ? "未设置地址" : model.gatewayAddress)
                            .font(.system(size:16,weight:.medium,design:.monospaced))
                            .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                        Button {gatewayDraft=model.gatewayAddress;editingGateway=true} label:{
                            Image(systemName:"square.and.pencil").font(.system(size:13,weight:.medium))
                                .frame(width:28,height:28)
                                .background(Palette.canvas,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("编辑服务器地址")
                            .accessibilityLabel("编辑服务器地址")
                            .opacity(gatewayHovered ? 1 : 0).allowsHitTesting(gatewayHovered)
                    }
                }.contentShape(Rectangle()).onHover{gatewayHovered=$0}
            }
            Divider().opacity(0.45)
            HStack(spacing:10) {
                Text("域").font(.system(size:12)).foregroundStyle(Palette.muted)
                Picker("域",selection:$model.domain) {
                    Text("默认").tag("")
                    ForEach(model.selectableDomains,id: \.self){id in Text(model.domainNames[id] ?? id).tag(id)}
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth:.infinity,alignment:.leading)
                if model.loadingDomains {ProgressView().controlSize(.small)}
                else {Button{model.loadDomains()}label:{Image(systemName:"arrow.clockwise").font(.system(size:13)).frame(width:24,height:24)}.buttonStyle(.plain).help("从服务器读取域列表")}
            }.disabled(editingGateway)
            if !model.domainError.isEmpty {Text(model.domainError).font(.system(size:11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)}
        }.padding(16).background(.white,in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(Palette.border,lineWidth:1)).disabled(model.active)
    }
    private var stepIndex:Int {model.authenticationStep}
    private var steps:some View {
        HStack(spacing:0) {
            ForEach(Array(["账号登录","图形校验","短信验证"].enumerated()),id:\.offset) { index,label in
                if index>0 {Rectangle().fill(index<=stepIndex ? Palette.accent.opacity(0.35) : Palette.ink.opacity(0.09)).frame(height:1).padding(.horizontal,8)}
                HStack(spacing:5) {
                    ZStack {
                        Circle().fill(index<=stepIndex ? Palette.accent : Palette.ink.opacity(0.08)).frame(width:20,height:20)
                        if index<stepIndex {Image(systemName:"checkmark").font(.system(size:9,weight:.bold)).foregroundStyle(.white)}
                        else {Text("\(index+1)").font(.system(size:10,weight:.semibold)).foregroundStyle(index==stepIndex ? .white : Palette.muted)}
                    }
                    Text(label).font(.system(size:11,weight:index<=stepIndex ? .medium : .regular)).foregroundStyle(index<=stepIndex ? Palette.accent : Palette.muted).fixedSize()
                }
            }
        }.padding(.vertical,2)
    }
    private var loginCard:some View {
        VStack(alignment:.leading,spacing:0) {
            Text("账号信息").font(.system(size:15,weight:.semibold)).padding(.bottom,12)
            fieldRow("person",title:"账号") {
                TextField("账号",text:$model.username)
            }
            Divider().opacity(0.45).padding(.vertical,10)
            fieldRow("key.horizontal",title:"密码") {
                HStack(spacing:6) {
                    Group {if revealPassword {TextField("密码",text:$model.password)} else {SecureField("密码",text:$model.password)}}
                        .onSubmit{if !editingGateway {model.connect()}}
                    Button {revealPassword.toggle()} label:{Image(systemName:revealPassword ? "eye.slash" : "eye").foregroundStyle(Palette.muted).frame(width:24,height:24)}.buttonStyle(.plain).help(revealPassword ? "隐藏密码" : "显示密码")
                }
            }
            Divider().opacity(0.45).padding(.top,11).padding(.bottom,10)
            Toggle(isOn:$model.rememberCredentials){Text("记住账号密码").font(.system(size:12)).foregroundStyle(Palette.muted)}
                .toggleStyle(.switch).controlSize(.mini).tint(Palette.accent).help("账号密码以明文保存在本机，仅当前用户可读写")
                .onChange(of:model.rememberCredentials){_ in model.forgetCredentials()}
        }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(Palette.border,lineWidth:1))
    }
    private func fieldRow<Content:View>(_ icon:String,title:String,@ViewBuilder content:()->Content)->some View {
        HStack(spacing:12) {
            Image(systemName:icon).font(.system(size:17)).foregroundStyle(Palette.accent.opacity(0.8)).frame(width:22)
            VStack(alignment:.leading,spacing:6) {
                Text(title).font(.system(size:11)).foregroundStyle(Palette.muted)
                content().font(.system(size:14)).textFieldStyle(.plain)
            }
        }
    }
    private var verificationCard:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(model.stage=="sms" ? "短信验证码" : "图片验证码").font(.system(size:15,weight:.semibold))
                Spacer()
                if model.stage=="captcha" {Button("换一张"){model.refresh()}.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(Palette.accent)}
            }
            if let image=model.image {
                Image(nsImage:image).resizable().interpolation(.none).scaledToFit().frame(maxWidth:.infinity).frame(height:64).padding(.vertical,4).background(Palette.canvas,in:RoundedRectangle(cornerRadius:12))
            } else {
                Label("短信已发送至你的手机",systemImage:"checkmark.circle.fill").font(.system(size:12)).foregroundStyle(Palette.accent).padding(.vertical,8)
            }
            TextField(model.stage=="sms" ? "输入短信验证码" : "输入图片中的字符",text:$model.code)
                .font(.system(size:19,weight:.medium,design:.rounded)).tracking(3).textFieldStyle(.plain)
                .padding(12).background(Palette.canvas,in:RoundedRectangle(cornerRadius:12))
                .focused($codeFocused).onSubmit{model.submit()}.accessibilityLabel(model.stage=="sms" ? "短信验证码" : "图片验证码")
            Text(model.stage=="sms" ? "验证通过后将自动建立连接" : "验证通过后，系统将发送短信验证码").font(.system(size:11)).foregroundStyle(Palette.muted)
        }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:20))
    }
    private var waitingCard:some View {
        VStack(spacing:12) {
            HStack(spacing:12) {ProgressView().controlSize(.small);Text(model.status).font(.system(size:15,weight:.semibold));Spacer()}
            if !model.detail.isEmpty {Text(model.detail).font(.system(size:12)).foregroundStyle(Palette.muted).frame(maxWidth:.infinity,alignment:.leading)}
        }.padding(18).background(Palette.wash,in:RoundedRectangle(cornerRadius:20))
    }
    private var connectionCard:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                Image(systemName:"checkmark.circle.fill").font(.system(size:26)).foregroundStyle(Palette.online)
                    .frame(width:48,height:48).background(Palette.online.opacity(0.10),in:RoundedRectangle(cornerRadius:15))
                VStack(alignment:.leading,spacing:5) {
                    Text(model.modeTitle+" 已连接").font(.system(size:19,weight:.bold))
                    Text(model.gatewayAddress).font(.system(size:12,design:.monospaced)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength:0)
            }
            Text(model.detail).font(.system(size:12,design:.monospaced)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).background(.white,in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(Palette.online.opacity(0.24),lineWidth:1))
    }
    private var errorCard:some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:"exclamationmark.circle.fill").foregroundStyle(Palette.danger)
            Text(model.error).font(.system(size:12)).foregroundStyle(Palette.ink).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(15).background(Palette.danger.opacity(0.07),in:RoundedRectangle(cornerRadius:15))
    }
    private var actionArea:some View {
        VStack(spacing:10) {
            if !model.active {
                primaryButton(model.connectionMode=="portal" ? "登录 Portal" : "连接 VPN",icon:"arrow.right"){model.connect()}.disabled(editingGateway).opacity(editingGateway ? 0.45 : 1)
            } else if model.awaitingCode {
                primaryButton(model.stage=="sms" ? "验证并连接" : "继续验证",icon:"arrow.right"){model.submit()}.disabled(model.code.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).opacity(model.code.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            } else if connected {
                primaryButton(model.connectionMode=="portal" ? "Portal 下线" : "断开 VPN",icon:"power",color:Palette.danger){model.disconnect()}
            } else {
                Button {model.disconnect()} label:{Text("取消连接").font(.system(size:14,weight:.semibold)).foregroundStyle(Palette.danger).frame(maxWidth:.infinity).frame(height:50).background(Palette.danger.opacity(0.07),in:RoundedRectangle(cornerRadius:16))}.buttonStyle(.plain)
            }
            if model.awaitingCode {Button("取消连接"){model.disconnect()}.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(Palette.danger)}
            ConnectionTimingView(journal:model.journal,mode:model.connectionMode,recordID:model.recordID)
            if !model.awaitingCode {Text("版本 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")").font(.system(size:10,weight:.medium,design:.rounded)).foregroundStyle(Palette.muted.opacity(0.65)).tracking(1)}
        }.padding(.horizontal,24).padding(.top,12).padding(.bottom,18).background(Palette.canvas)
    }
    private func primaryButton(_ title:String,icon:String,color:Color = Palette.accent,action:@escaping()->Void)->some View {
        Button(action:action) {HStack {Spacer();Text(title);Image(systemName:icon).font(.system(size:14,weight:.semibold));Spacer()}.font(.system(size:15,weight:.semibold)).foregroundStyle(.white).frame(height:52).background(color.gradient,in:RoundedRectangle(cornerRadius:16)).shadow(color:color.opacity(0.18),radius:9,x:0,y:4)}
            .buttonStyle(.plain).keyboardShortcut(.defaultAction)
    }
    private var settingsSheet:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text("连接设置").font(.system(size:21,weight:.semibold));Spacer();Button("完成"){settings=false}.buttonStyle(.plain).foregroundStyle(Palette.accent)}
            if model.connectionMode=="vpn" {
                VStack(alignment:.leading,spacing:8) {Text("额外内网网段").font(.caption).foregroundStyle(Palette.muted);TextField("例如 10.20.0.0/16；多个网段用逗号分隔",text:$model.routes)}
                Text("通常留空，仅补充服务器未下发的目标网段。").font(.system(size:12)).foregroundStyle(Palette.muted)
                Label("使用 TLS 加密传输",systemImage:"lock.fill").font(.system(size:12)).foregroundStyle(Palette.accent)
            }else{
                Text("Portal 默认端口为 50200，可在服务器地址后填写 :端口。").font(.system(size:12)).foregroundStyle(Palette.muted)
            }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width:360).background(Palette.canvas).preferredColorScheme(.light)
    }
    private var appSettingsSheet:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("应用设置").font(.system(size:21,weight:.semibold))
                Spacer()
                Button("完成"){appSettings=false}.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            VStack(alignment:.leading,spacing:12) {
                Toggle(isOn:Binding(
                    get:{connections.launchAtLogin},
                    set:{connections.setLaunchAtLogin($0)}
                )) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("开机自动启动").font(.system(size:13,weight:.medium))
                        Text("登录 macOS 时自动启动 iNode for Mac。").font(.system(size:11)).foregroundStyle(Palette.muted)
                    }
                }.toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
                if connections.launchAtLoginRequiresApproval {
                    Text("需要在“系统设置 → 通用 → 登录项与扩展”中允许 iNode for Mac。").font(.system(size:11)).foregroundStyle(Palette.accent)
                }
                if !connections.launchAtLoginError.isEmpty {
                    Text(connections.launchAtLoginError).font(.system(size:11)).foregroundStyle(Palette.danger)
                }
                Divider().opacity(0.45)
                Toggle(isOn:$connections.autoConnectPortal) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("启动时自动连接 Portal").font(.system(size:13,weight:.medium))
                        Text("应用启动后，若已保存 Portal 服务器及账号密码，将自动发起连接。").font(.system(size:11)).foregroundStyle(Palette.muted)
                    }
                }.toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
                if !connections.portal.isConfiguredForAutoConnect {
                    Text("当前尚未保存完整的 Portal 账号密码；请先在 Portal 页面勾选“记住账号密码”并登录成功一次。").font(.system(size:11)).foregroundStyle(Palette.muted)
                }
            }.padding(16).background(.white,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Palette.border,lineWidth:1))
        }.padding(24).frame(width:380).background(Palette.canvas).foregroundStyle(Palette.ink).preferredColorScheme(.light)
            .onAppear{connections.refreshLaunchAtLoginStatus()}
    }
}
