import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConnectionTimingView:View {
    @ObservedObject var journal:ConnectionJournal
    let mode:String
    let recordID:UUID?
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let record=journal.record(recordID) ?? journal.latest(mode:mode)
            let title=(record?.endedAt != nil && record?.connectedAt != nil) ? "上次在线" : "本次在线"
            let total=journal.total(mode:mode,at:context.date)
            if record != nil || total>0 {
                Text(title+" "+OnlineDuration.string(record?.duration(at:context.date) ?? 0)+"  ·  累计 "+OnlineDuration.string(total))
                    .font(.system(size:10)).monospacedDigit().foregroundStyle(Palette.muted.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth:.infinity)
            }
        }
    }
}

struct ConnectionHistoryView:View {
    @ObservedObject var journal:ConnectionJournal
    @Environment(\.dismiss) private var dismiss
    @State private var mode="all"
    @State private var selection:UUID?
    @State private var exportError=""
    @State private var showExportError=false
    private var filtered:[ConnectionRecord] {journal.records.filter{mode=="all" || $0.mode==mode}}
    private var selected:ConnectionRecord? {
        filtered.first{$0.id==selection} ?? filtered.first
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {
                Image(systemName:"clock.arrow.circlepath").font(.system(size:21)).foregroundStyle(Palette.accent)
                Text("在线记录").font(.system(size:22,weight:.bold))
                Spacer()
                Button("导出记录",action:export).disabled(filtered.isEmpty)
                Button("完成"){dismiss()}.keyboardShortcut(.cancelAction)
            }
            Picker("连接类型",selection:$mode) {
                Text("全部").tag("all")
                Text("Portal").tag("portal")
                Text("SSL VPN").tag("vpn")
            }.pickerStyle(.segmented)
            if !journal.storageError.isEmpty {
                Label(journal.storageError,systemImage:"exclamationmark.triangle.fill")
                    .font(.system(size:12)).foregroundStyle(Palette.danger)
            }
            if filtered.isEmpty {
                VStack(spacing:10) {
                    Image(systemName:"clock").font(.system(size:34)).foregroundStyle(Palette.muted)
                    Text("暂无连接记录").font(.system(size:16,weight:.semibold))
                    Text("开始连接后，会在这里记录连接过程和在线时长。")
                        .font(.system(size:12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                HStack(alignment:.top,spacing:16) {
                    List(selection:$selection) {
                        ForEach(filtered) { record in
                            recordRow(record).tag(record.id)
                        }
                    }.listStyle(.inset).frame(width:245)
                        .background(.white,in:RoundedRectangle(cornerRadius:14))
                    if let record=selected {
                        detail(record).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    }
                }.frame(maxHeight:.infinity)
            }
        }.padding(24).frame(width:670,height:590).background(Palette.canvas).foregroundStyle(Palette.ink)
            .tint(Palette.accent).preferredColorScheme(.light)
            .alert("导出失败",isPresented:$showExportError){Button("确定",role:.cancel){}}message:{Text(exportError)}
    }
    private func recordRow(_ record:ConnectionRecord)->some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(record.modeTitle).font(.system(size:13,weight:.semibold))
                Spacer()
                Circle().fill(record.onlineSince != nil ? Palette.online : Palette.muted.opacity(0.5)).frame(width:6,height:6)
            }
            Text(record.gateway).font(.system(size:11,design:.monospaced)).lineLimit(1)
            Text(record.startedAt,format:.dateTime.month().day().hour().minute().second())
                .font(.system(size:11)).foregroundStyle(Palette.muted)
            Text(record.stateTitle).font(.system(size:11)).foregroundStyle(record.onlineSince != nil ? Palette.online : Palette.muted)
        }.padding(.vertical,5)
    }
    private func detail(_ record:ConnectionRecord)->some View {
        ScrollView {
            VStack(alignment:.leading,spacing:13) {
                HStack {
                    Text(record.modeTitle).font(.system(size:17,weight:.bold))
                    Spacer()
                    Text(record.stateTitle).font(.system(size:11,weight:.medium)).foregroundStyle(Palette.accent)
                }
                Text(record.gateway).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                if !record.username.isEmpty {infoRow("账号",value:record.username)}
                if !record.domain.isEmpty {infoRow("域",value:record.domain)}
                infoRow("发起时间",value:record.startedAt.formatted(date:.abbreviated,time:.standard))
                if let connected=record.connectedAt {infoRow("上线时间",value:connected.formatted(date:.abbreviated,time:.standard))}
                if let ended=record.endedAt {infoRow("结束时间",value:ended.formatted(date:.abbreviated,time:.standard))}
                TimelineView(.periodic(from:.now,by:1)) { context in
                    infoRow("在线时长",value:OnlineDuration.string(record.duration(at:context.date)))
                }
                Divider()
                Text("连接日志").font(.system(size:13,weight:.semibold))
                ForEach(record.events) { event in
                    HStack(alignment:.top,spacing:10) {
                        Circle().fill(event.kind == .failed ? Palette.danger : Palette.accent.opacity(0.65)).frame(width:6,height:6).padding(.top,5)
                        VStack(alignment:.leading,spacing:3) {
                            Text(event.kind.title).font(.system(size:12,weight:.medium))
                            if let failure=event.failure {Text(failure.title).font(.system(size:11)).foregroundStyle(Palette.danger)}
                            Text(event.date,format:.dateTime.month().day().hour().minute().second())
                                .font(.system(size:10)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                if record.events.last?.kind == .interrupted {
                    Text("异常结束时间以最后一次保存时间为准，未推算应用关闭后的在线时长。")
                        .font(.system(size:11)).foregroundStyle(Palette.muted)
                }
            }.padding(16)
        }.background(.white,in:RoundedRectangle(cornerRadius:14))
    }
    private func infoRow(_ title:String,value:String)->some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.system(size:10)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size:12)).textSelection(.enabled)
        }
    }
    private func export() {
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.plainText]
        panel.nameFieldStringValue="iNode-for-Mac-在线记录-"+Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))+".txt"
        let selectedMode=mode=="all" ? nil : mode
        panel.begin { result in
            guard result == .OK,let url=panel.url else {return}
            Task { @MainActor in
                do {try journal.exportText(mode:selectedMode).write(to:url,atomically:true,encoding:.utf8)}
                catch {exportError="无法保存到所选位置，请选择可写入的文件夹。";showExportError=true}
            }
        }
    }
}
