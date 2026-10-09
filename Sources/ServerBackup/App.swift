import SwiftUI
import Combine
import AppKit

@main struct Launcher {
    static func main() {
        if CommandLine.arguments.contains("--askpass") {
            let id=ProcessInfo.processInfo.environment["SERVER_BACKUP_SECRET_ID"] ?? ""
            guard let secret=Vault.get("ssh-"+id) else {exit(1)}
            FileHandle.standardOutput.write(secret);FileHandle.standardOutput.write(Data("\n".utf8));exit(0)
        }
        if CommandLine.arguments.contains("--history-ssh-test") {Task{do{try await SelfTests.historySSH();print("HISTORY SSH TEST PASSED");exit(0)}catch{fputs("\(error)\n",stderr);exit(1)}};dispatchMain()}
        if CommandLine.arguments.contains("--ssh-test") { Task { do {try await SelfTests.ssh();print("SSH TESTS PASSED");exit(0)}catch{fputs("\(error)\n",stderr);exit(1)} };dispatchMain() }
        if CommandLine.arguments.contains("--terminal-test") {do{try TerminalPTYTest.run();print("TERMINAL PTY TEST PASSED");exit(0)}catch{fputs("\(error)\n",stderr);exit(1)}}
        if CommandLine.arguments.contains("--self-test") { do {try SelfTests.run();print("SELF TESTS PASSED");exit(0)}catch{fputs("\(error)\n",stderr);exit(1)} }
        ServerBackupApp.main()
    }
}
struct ServerBackupApp: App {
    @StateObject private var model=Model()
    var body:some Scene {WindowGroup("Server Backup"){MainView().environmentObject(model).preferredColorScheme(.dark).tint(BackupTheme.blue).accentColor(BackupTheme.blue).toggleStyle(BackupCheckboxStyle()).frame(minWidth:1050,minHeight:720)}.defaultSize(width:1250,height:850)}
}
let sections=["Обзор","Хранилища","Задания","Базы данных","Docker","Терминал","Файлы","Программы","Cron","Копии","Календарь","Проверка копий","Ёмкость","Внешний контроль","Восстановление","Мониторинг","Уведомления","Центр ошибок","Журнал"]
struct MainView:View {
    @EnvironmentObject var m:Model
    @State var editServer:Server?
    @State var showExport=false
    let timer=Timer.publish(every:10,on:.main,in:.common).autoconnect()
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:12){Image(systemName:"externaldrive.fill.badge.timemachine").font(.title2).foregroundStyle(BackupTheme.blue);VStack(alignment:.leading,spacing:3){Text("Server Backup").font(.headline);Text(m.current==nil ? "Серверы и резервное копирование":"SSH · Restic · резервное копирование").font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();if m.isDesignPreview{StatusBadge(title:"Демонстрационные данные",color:.orange)};if m.current==nil{Button("Экспорт / импорт"){showExport=true}}}.padding(.horizontal,24).padding(.vertical,15).background(BackupTheme.sidebar)
            Rectangle().fill(BackupTheme.border).frame(height:1)
            if let server=m.current{
                HStack(spacing:0){ServerSidebar(server:server,onEdit:{editServer=server});Rectangle().fill(BackupTheme.border).frame(width:1)
                    VStack(alignment:.leading,spacing:16){WorkspaceHeader(server:server)
                        if let error=m.error{message(error,"exclamationmark.triangle.fill",.red){m.error=nil}}
                        if let notice=m.notice{message(notice,"checkmark.circle.fill",.green){m.notice=nil}}
                        ScrollView{workspace.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,8)}.id(m.section)
                        if !m.operationState.isEmpty && !m.operationDismissed{OperationView()}
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).background(BackupTheme.background)
                }
            }else{ServerHomeView(onAdd:{editServer=Server()},onEdit:{editServer=$0}).environmentObject(m)}
        }.background(BackupTheme.background)
        .sheet(item:$editServer){s in ServerEditor(server:s)}
        .sheet(isPresented:$showExport){ExportView()}
        .sheet(isPresented:Binding(get:{m.pendingTrust != nil},set:{if !$0{m.pendingTrust=nil}})){VStack(alignment:.leading,spacing:18){Text("Подтвердите ключ SSH").font(.title2);Text("Сверьте отпечаток с сервером. Изменившийся ключ требует повторной проверки.");Text(m.pendingTrust?.2 ?? "").font(.system(.body,design:.monospaced)).textSelection(.enabled);HStack{Button("Отмена"){m.pendingTrust=nil};Spacer();Button("Доверять этому ключу"){m.trust()}.buttonStyle(BackupPrimaryButtonStyle())}}.padding(24).frame(width:620)}
        .onChange(of:m.selectedID){_,new in m.reset();if new != nil{m.connect()}}
        .onChange(of:m.section){_,_ in m.error=nil;m.notice=nil;m.result=""}
        .onReceive(timer){_ in m.tick()}.onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in m.transfer.cancel();m.closeTerminals();SSHSessionPool.shared.closeAll()}
    }
    @ViewBuilder var workspace:some View{switch m.section{case "Обзор":OverviewView();case "Хранилища":StorageView();case "Задания":JobsView();case "Базы данных":DatabasesView();case "Docker":DockerView();case "Терминал":if let server=m.current{RemoteTerminalView(server:server,session:m.terminalSession(for:server))};case "Файлы":RemoteFilesView();case "Программы":ProgramsView();case "Cron":CronView();case "Копии":CopiesView();case "Календарь":CalendarBackupView();case "Проверка копий":VerificationView();case "Ёмкость":CapacityView();case "Внешний контроль":ExternalMonitorView();case "Восстановление":RestoreView();case "Мониторинг":MonitorView();case "Уведомления":NotificationsView();case "Центр ошибок":ErrorCenterView();default:LogView()}}
    func message(_ text:String,_ icon:String,_ color:Color,_ close:@escaping()->Void)->some View{HStack(alignment:.top){Image(systemName:icon).foregroundStyle(color);Text(text).font(.callout).textSelection(.enabled);Spacer();Button(action:close){Image(systemName:"xmark")}.buttonStyle(.plain)}.padding(12).background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:10))}
}
struct ServerEditor:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    @State var server:Server
    @State private var useKey:Bool
    @State private var secret=""
    @State private var localError:String?
    init(server:Server){_server=State(initialValue:server);_useKey=State(initialValue:!server.keyPath.isEmpty)}
    var body:some View{VStack(alignment:.leading,spacing:20){
        WorkspaceIntro(title:"SSH-подключение",detail:"Добавьте сервер Ubuntu или Debian",icon:"server.rack")
        if let localError{Text(localError).font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
        BackupPanel(title:""){
            FieldLabel(title:"Название сервера"){TextField("Production",text:$server.name)}
            FieldLabel(title:"Группа серверов"){TextField("Production / Staging",text:Binding(get:{server.group ?? ""},set:{server.group=$0}))}
            FieldLabel(title:"Адрес сервера"){TextField("IP-адрес или домен",text:$server.host)}
            HStack{FieldLabel(title:"Пользователь"){TextField("root",text:$server.user)};FieldLabel(title:"SSH-порт"){TextField("22",value:$server.port,format:.number)}.frame(width:100)}
            Picker("Аутентификация",selection:$useKey){Text("Пароль").tag(false);Text("SSH-ключ").tag(true)}.pickerStyle(.segmented)
            if useKey{FieldLabel(title:"Файл приватного SSH-ключа"){HStack{TextField("/Users/…/.ssh/id_ed25519",text:$server.keyPath);Button{let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;if panel.runModal() == .OK,let url=panel.url{server.keyPath=url.path}}label:{Image(systemName:"folder")}}}}
            FieldLabel(title:useKey ? "Парольная фраза ключа · если задана":"Пароль SSH"){SecureField(useKey ? "Парольная фраза":"Пароль",text:$secret)}
            Toggle("Использовать sudo без пароля",isOn:$server.useSudo)
        }
        Text("Для настройки нужны root или sudo без пароля. Доступы сохраняются в macOS Keychain. При подключении приложение запросит подтверждение ключа сервера.").font(.caption).foregroundStyle(BackupTheme.muted)
        HStack{Button("Отмена"){dismiss()};Spacer();Button("Сохранить и открыть"){
            do{if useKey && server.keyPath.isEmpty{throw AppFailure(message:"Выберите файл SSH-ключа")};if !useKey{server.keyPath=""};try SSH.validate(server);try m.save(server,secret:secret);m.openServer(server);dismiss()}catch{localError=error.localizedDescription}
        }.buttonStyle(BackupPrimaryButtonStyle())}
    }.padding(24).frame(width:540).textFieldStyle(.roundedBorder).background(BackupTheme.background)
        .onAppear{secret=Vault.get("ssh-"+server.id).map{String(decoding:$0,as:UTF8.self)} ?? ""}
        .onChange(of:useKey){_,_ in secret=""}
    }
}
struct JSONOutput:View {let value:Any;var body:some View{Text(Model.pretty(value)).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius:8))}}
struct ResultView:View {@EnvironmentObject var m:Model;@State private var expanded=false;var body:some View{if !m.result.isEmpty{ClickableDisclosure(title:"Технические подробности операции",isExpanded:$expanded){Text(m.result).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(BackupTheme.panel)}}}}
struct OperationView:View {
    @EnvironmentObject var m:Model
    @State private var details=false
    var status:String{m.operationState["status"] as? String ?? "running"}
    var finished:Bool{["success","failed","incomplete","cancelled"].contains(status)}
    var color:Color{status=="success" && m.operationState["replication_errors"] != nil ? .orange:status=="success" ? .green:status=="failed" ? .red:finished ? .orange:BackupTheme.blue}
    var title:String{if status=="success",m.operationState["replication_errors"] != nil{return "Основная копия готова · есть ошибки дополнительных направлений"};return ["success":"Завершено успешно","failed":"Ошибка выполнения","incomplete":"Копия неполная","cancelled":"Операция отменена","queued":"Ожидает запуска","waiting":"Ожидает запуска","running":"Выполняется на сервере"][status] ?? status}
    var operationLabel:String{["backup":"Резервное копирование","external-test":"Внешний контроль","check":"Проверка структуры хранилища","restore":"Восстановление","database-import":"Импорт базы","docker-import":"Восстановление Docker"][m.operationState["operation"] as? String ?? ""] ?? "Операция"}
    var stages:[[String:Any]]{m.operationState["stages"] as? [[String:Any]] ?? []}
    var progress:[String:Any]{m.operationState["progress"] as? [String:Any] ?? [:]}
    func bytes(_ key:String)->String{ByteCountFormatter.string(fromByteCount:(progress[key] as? NSNumber)?.int64Value ?? 0,countStyle:.binary)}
    var body:some View{VStack(alignment:.leading,spacing:12){
        HStack(spacing:12){Image(systemName:status=="success" ? "checkmark.circle.fill":finished ? "exclamationmark.circle.fill":"arrow.triangle.2.circlepath").font(.title2).foregroundStyle(color);VStack(alignment:.leading,spacing:4){Text(title).font(.headline);Text((m.operationState["dry_run"] as? Bool==true ? "Пробный запуск":operationLabel)+" · "+(m.operationState["id"] as? String ?? "")).font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();if !finished,let id=m.operationID{Button("Остановить"){m.perform(["action":"cancel","id":id])}};Button{m.operationDismissed=true}label:{Image(systemName:"xmark")}.buttonStyle(.plain).help("Скрыть панель; операция продолжает работу")}
        if !stages.isEmpty{ForEach(stages.indices,id:\.self){i in let step=stages[i];let stepStatus=step["status"] as? String ?? "running"
            HStack(alignment:.top,spacing:10){
                Image(systemName:stepStatus=="done" ? "checkmark.circle.fill":stepStatus=="failed" ? "exclamationmark.circle.fill":"circle.dotted").foregroundStyle(stepStatus=="done" ? Color.green:stepStatus=="failed" ? Color.orange:BackupTheme.blue)
                VStack(alignment:.leading,spacing:3){Text(String(i+1)+". "+(step["title"] as? String ?? "")).font(.caption).fontWeight(stepStatus=="running" ? .semibold:.regular)
                    if stepStatus=="running",let detail=step["detail"] as? String,!detail.isEmpty{Text(detail).font(.caption).foregroundStyle(BackupTheme.muted)}
                };Spacer();Text(stepStatus=="done" ? "Готово":stepStatus=="failed" ? "Ошибка":"Выполняется").font(.caption).foregroundStyle(BackupTheme.muted)
            }
        }}
        if !finished{
            if let percent=progress["percent_done"] as? Double{ProgressView(value:min(1,max(0,percent)));Text("Копирование: "+String(format:"%.0f%%",percent*100)+" · "+bytes("bytes_done")+" / "+bytes("total_bytes")+" · файлов: "+String((progress["files_done"] as? NSNumber)?.intValue ?? 0)+" / "+String((progress["total_files"] as? NSNumber)?.intValue ?? 0)).font(.caption)
            }else{HStack{ProgressView().controlSize(.small);Text("Ожидание отчёта текущего этапа…").font(.caption).foregroundStyle(BackupTheme.muted)}}
            if let files=progress["current_files"] as? [String],!files.isEmpty{Text(files.joined(separator:" · ")).font(.caption).foregroundStyle(BackupTheme.muted).lineLimit(1).truncationMode(.middle).help(files.joined(separator:"\n"))}
        }
        if let summary=m.operationState["summary"] as? [String:Any]{Text("Добавлено: "+ByteCountFormatter.string(fromByteCount:(summary["data_added_packed"] as? NSNumber)?.int64Value ?? 0,countStyle:.binary)+" · "+String(format:"%.1f с",(summary["total_duration"] as? NSNumber)?.doubleValue ?? 0)).font(.caption)}
        if let summary=m.operationState["summary"] as? [String:Any],!finished{Text("Копирование завершено. Выполняются завершающие этапы.").font(.caption).foregroundStyle(BackupTheme.muted);Text("Обработано: "+ByteCountFormatter.string(fromByteCount:(summary["total_bytes_processed"] as? NSNumber)?.int64Value ?? 0,countStyle:.binary)).font(.caption)}
        ForEach((m.operationState["destinations"] as? [[String:Any]] ?? []).indices,id:\.self){i in let direction=(m.operationState["destinations"] as? [[String:Any]] ?? [])[i];HStack{Label(direction["repository_id"] as? String ?? "",systemImage:"externaldrive");Spacer();StatusBadge(title:resultTitle(direction["status"] as? String ?? ""),color:direction["status"] as? String=="success" ? .green:.orange)}.font(.caption)}
        if let error=m.operationState["error"] as? String,!error.isEmpty{Text(error).font(.caption).foregroundStyle(color).textSelection(.enabled).lineLimit(4)}
        ForEach(m.operationState["warnings"] as? [String] ?? [],id:\.self){Text($0).font(.caption).foregroundStyle(.orange)}
        HStack{Button("Подробности"){details=true};if finished{Text("Панель скроется через 30 секунд. Результат сохранён в журнале.").font(.caption).foregroundStyle(BackupTheme.muted)}}
    }.padding(16).background(color.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(color.opacity(0.3))).sheet(isPresented:$details){OperationDetails(value:m.operationState)} }
}
struct OperationDetails:View {
    let value:[String:Any]
    @Environment(\.dismiss) var dismiss
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Text(operationHistoryTitle(value)).font(.title2);Spacer();Button("Закрыть"){dismiss()}};Text(operationHistoryContext(value)).foregroundStyle(BackupTheme.muted);ScrollView{JSONOutput(value:value)}}.padding(24).frame(width:800,height:600)}
}
