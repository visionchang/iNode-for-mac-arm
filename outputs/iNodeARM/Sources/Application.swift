import SwiftUI
import AppKit

final class AppDelegate:NSObject,NSApplicationDelegate {
    var connections:ConnectionsModel?
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        MainActor.assumeIsolated {connections?.disconnectAll()}
        return .terminateNow
    }
    // Closing the last window leaves the app and its connection models running.
    // Only an explicit application quit takes the disconnectAll() path above.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}
@main struct InodeApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var connections=ConnectionsModel()
    var body:some Scene {
        Window("iNode for Mac", id:"main") {
            ConnectionsView(connections:connections)
                .onAppear {
                    delegate.connections=connections
                    NSApp.setActivationPolicy(.regular)
                    connections.refreshLaunchAtLoginStatus()
                    connections.autoConnectPortalIfNeeded()
                }
        }.windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        MenuBarExtra {
            ConnectionMenu(connections:connections)
        } label: {
            Image(systemName:connections.vpn.stage == "connected" || connections.portal.stage == "connected" ? "network.badge.shield.half.filled" : "network")
        }
    }
}

struct ConnectionMenu:View {
    @ObservedObject var connections:ConnectionsModel
    @Environment(\.openWindow) private var openWindow

    private func showWindow(_ mode:String? = nil) {
        if let mode {connections.selectedMode=mode}
        openWindow(id:"main")
        NSApp.activate(ignoringOtherApps:true)
    }
    private func state(_ connection:ConnectionModel)->String {
        if connection.stage == "connected" {return "在线"}
        if connection.awaitingCode {return "待验证"}
        if connection.active {return "连接中"}
        return connection.error.isEmpty ? "未连接" : "连接失败"
    }
    @ViewBuilder private func connectionItems(_ connection:ConnectionModel) -> some View {
        Text(connection.modeTitle+"："+state(connection))
        if connection.awaitingCode {
            Button("完成"+connection.modeTitle+"验证") {showWindow(connection.connectionMode)}
        }
        if connection.active {
            Button(connection.stage == "connected" ? "断开"+connection.modeTitle : "取消"+connection.modeTitle+"连接") {
                connection.disconnect()
            }
        } else {
            Button("连接"+connection.modeTitle) {
                showWindow(connection.connectionMode)
                connection.connect()
            }
        }
    }
    var body:some View {
        connectionItems(connections.portal)
        Divider()
        connectionItems(connections.vpn)
        Divider()
        Toggle("开机自动启动", isOn:Binding(
            get:{connections.launchAtLogin},
            set:{connections.setLaunchAtLogin($0)}
        ))
        Toggle("启动时自动连接 Portal", isOn:$connections.autoConnectPortal)
        Divider()
        Button("打开 iNode for Mac") {showWindow()}
        Button("退出 iNode for Mac") {NSApp.terminate(nil)}
    }
}
