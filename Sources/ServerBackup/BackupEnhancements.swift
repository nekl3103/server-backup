import SwiftUI

struct FileHistoryView:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let repository:String
    let path:String
    @State private var rows:[[String:Any]]=[]
    @State private var offset=0
    @State private var total=0
    @State private var loading=false
    @State private var error=""
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Label("Версии файла",systemImage:"clock.arrow.circlepath").font(.title2);Spacer();Button("Закрыть"){dismiss()}};Text(path).font(.caption.monospaced()).textSelection(.enabled);Text("Размер и дата изменения сохранены в каждой копии. Точное сравнение содержимого доступно в разделе сравнения с сервером.").font(.caption).foregroundStyle(BackupTheme.muted)
        if loading{ProgressView("Загружаются версии…")};if !error.isEmpty{Text(error).foregroundStyle(.orange);Button("Повторить"){load()}.disabled(loading)}
        ScrollView{LazyVStack(spacing:8){ForEach(rows.indices,id:\.self){i in let row=rows[i];let node=row["node"] as? [String:Any] ?? [:];HStack{VStack(alignment:.leading,spacing:5){Text(backupTime(row["time"] as? String)).font(.headline);Text(row["present"] as? Bool==true ? "Изменён: "+backupTime(node["mtime"] as? String):"Файл отсутствует").font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();Text(bytes(node["size"])).font(.caption);Button("Восстановить версию"){m.preferredRepository=repository;m.selectedSnapshot=row["snapshot"] as? String ?? "latest";m.restoreIncludes=[path];m.section="Восстановление";dismiss()}.disabled(row["present"] as? Bool != true)}.padding(12).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))}}}
        HStack{Text("Копий: \(total)").font(.caption);Spacer();Button("Назад"){offset=max(0,offset-5);load()}.disabled(offset==0 || loading);Button("Далее"){offset+=5;load()}.disabled(offset+rows.count>=total || loading)}
    }.padding(24).frame(width:820,height:590).task{load()}}
    func load(){guard let server=m.current,!loading else{return};loading=true;error="";Task{defer{loading=false};do{let value=try await m.readLive(["action":"snapshot_file_history","repository_id":repository,"path":path,"offset":offset,"limit":5],server:server) as? [String:Any] ?? [:];rows=value["versions"] as? [[String:Any]] ?? [];total=value["total"] as? Int ?? 0}catch{self.error=error.localizedDescription}}}
}
struct ContentComparisonView:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let repository:String,snapshot:String,path:String,target:String
    @State private var value:[String:Any]=[:]
    @State private var loading=true
    @State private var error=""
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Label("Сравнение содержимого",systemImage:"doc.text.magnifyingglass").font(.title2);Spacer();Button("Закрыть"){dismiss()}};Text(path+" → "+target).font(.caption.monospaced()).textSelection(.enabled)
        if loading{ProgressView()};if !error.isEmpty{Text(error).foregroundStyle(.orange)}
        if !value.isEmpty{StatusBadge(title:value["same"] as? Bool==true ? "Содержимое совпадает":"Содержимое отличается",color:value["same"] as? Bool==true ? .green:.orange);HStack{MetricCard(title:"В копии",value:bytes(value["snapshot_size"]));MetricCard(title:"На сервере",value:bytes(value["server_size"]))}
            if let diff=value["diff"] as? String{ScrollView([.vertical,.horizontal]){VStack(alignment:.leading,spacing:0){ForEach(Array(diff.components(separatedBy:"\n").enumerated()),id:\.offset){_,line in Text(line.isEmpty ? " ":line).font(.system(.caption,design:.monospaced)).foregroundStyle(line.hasPrefix("+") ? Color.green:line.hasPrefix("-") ? Color.orange:Color.primary).frame(maxWidth:.infinity,alignment:.leading)}}.textSelection(.enabled)}.background(BackupTheme.panel)}else{Text("Бинарный файл или текст больше 1 МБ: сравнение по SHA-256.").foregroundStyle(BackupTheme.muted)}
            Text("SHA-256 копии: "+(value["snapshot_sha256"] as? String ?? "")).font(.caption.monospaced()).textSelection(.enabled);Text("SHA-256 сервера: "+(value["server_sha256"] as? String ?? "")).font(.caption.monospaced()).textSelection(.enabled)
        }
    }.padding(24).frame(width:960,height:650).task{guard let server=m.current else{return};defer{loading=false};do{value=try await m.readLive(["action":"snapshot_content","repository_id":repository,"snapshot":snapshot,"path":path,"target":target],server:server) as? [String:Any] ?? [:]}catch{self.error=error.localizedDescription}}}
}
struct JobManagementView:View{
    @EnvironmentObject var m:Model
    let job:[String:Any]
    @State private var history=false
    @State private var duplicate=false
    @State private var name=""
    @State private var response:[String:Any]=[:]
    var id:String{job["id"] as? String ?? ""}
    var body:some View{VStack(alignment:.leading,spacing:8){HStack{Button(job["enabled"] as? Bool==false ? "Включить":"Приостановить"){m.perform(["action":"job_toggle","job_id":id,"enabled":job["enabled"] as? Bool==false]){_ in m.loadProbe()}};Button("Дублировать"){name=(job["name"] as? String ?? id)+" · копия";duplicate=true}};Button("История и следующий запуск"){history=true}}
        .sheet(isPresented:$duplicate){VStack(alignment:.leading,spacing:18){Text("Дублирование задания").font(.title2);TextField("Название",text:$name);Text("Новое задание будет выключено до проверки настроек.").font(.caption);HStack{Button("Отмена"){duplicate=false};Spacer();Button("Создать"){m.perform(["action":"job_duplicate","job_id":id,"new_id":"job-"+String(UUID().uuidString.prefix(8)),"name":name]){_ in duplicate=false;m.loadProbe()}}}}.padding(24).frame(width:500)}
        .sheet(isPresented:$history){VStack(alignment:.leading,spacing:16){HStack{Text("Настройки · "+(job["name"] as? String ?? id)).font(.title2);Spacer();Button("Закрыть"){history=false}};Text("Следующий запуск: "+(response["next_run"] as? String ?? "Недоступен")).font(.callout);ScrollView{ForEach((response["versions"] as? [[String:Any]] ?? []).indices,id:\.self){i in let version=(response["versions"] as? [[String:Any]] ?? [])[i];DisclosureGroup(backupTime(version["changed"] as? String)){JSONOutput(value:version)}}}}.padding(24).frame(width:800,height:550).task{guard let server=m.current else{return};do{response=try await m.readLive(["action":"job_versions","job_id":id],server:server) as? [String:Any] ?? [:]}catch{m.error=error.localizedDescription}}}}
}
struct ErrorCenterView:View{
    @EnvironmentObject var m:Model
    @State private var rows:[[String:Any]]=[]
    @State private var filter="all"
    @State private var loading=false
    @State private var error=""
    @State private var selected:CheckResult?
    @State private var retry:String?
    var visible:[[String:Any]]{Array(rows.filter{filter=="all" || $0["category"] as? String==filter}.prefix(100))}
    var body:some View{VStack(alignment:.leading,spacing:18){WorkspaceIntro(title:"Центр ошибок",detail:"Бэкапы, дополнительные направления, обслуживание и уведомления",icon:"exclamationmark.bubble");HStack{Picker("Категория",selection:$filter){Text("Все").tag("all");Text("Бэкап").tag("backup");Text("Обслуживание").tag("maintenance");Text("Восстановление").tag("verification");Text("Дополнительные копии").tag("replication");Text("Уведомления").tag("notification");Text("Docker").tag("docker")};Spacer();Button("Обновить"){load()}.disabled(loading)};if loading{ProgressView()};if !error.isEmpty{Text(error).foregroundStyle(.orange)};if visible.isEmpty && !loading{Text("Ошибок в доступной истории нет").foregroundStyle(BackupTheme.muted)}
        ForEach(visible.indices,id:\.self){i in let row=visible[i];BackupPanel(title:row["title"] as? String ?? "Ошибка",subtitle:(row["name"] as? String ?? "")+" · "+backupTime(row["time"] as? String),icon:"exclamationmark.triangle"){Text(row["message"] as? String ?? "").textSelection(.enabled);Text(row["hint"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted);HStack{Button("Журнал"){m.section="Журнал"};if row["retry_action"] as? String=="start_job",let id=row["job_id"] as? String{Button("Повторить задание"){retry=id}};if row["category"] as? String=="notification"{Button("Настроить уведомления"){m.section="Уведомления"}};if row["category"] as? String=="replication"{Button("Открыть хранилища"){m.section="Хранилища"}}}}
        }
    }.task{load()}.confirmationDialog("Повторить бэкап? Задание может временно остановить выбранные контейнеры.",isPresented:Binding(get:{retry != nil},set:{if !$0{retry=nil}})){Button("Запустить"){if let id=retry{m.perform(["action":"start_job","job_id":id])};retry=nil}}}
    func load(){guard let server=m.current,!loading else{return};loading=true;Task{defer{loading=false};do{let value=try await m.readLive(["action":"error_center"],server:server) as? [String:Any] ?? [:];rows=value["entries"] as? [[String:Any]] ?? [];error=""}catch{self.error=error.localizedDescription}}}
}
struct FleetTableView:View{
    @EnvironmentObject var m:Model
    let servers:[Server]
    let edit:(Server)->Void
    var body:some View{VStack(spacing:0){HStack{Text("Сервер").frame(maxWidth:.infinity,alignment:.leading);Text("Связь / копии").frame(width:145,alignment:.leading);Text("Последняя копия").frame(width:170,alignment:.leading);Text("Задание / ошибки").frame(maxWidth:.infinity,alignment:.leading);Text("Свободно").frame(width:110,alignment:.trailing);Color.clear.frame(width:26)}.font(.caption).foregroundStyle(BackupTheme.muted).padding(12)
        ForEach(servers){server in let state=m.fleet[server.id];Button{m.openServer(server)}label:{HStack{VStack(alignment:.leading,spacing:4){Text(server.name).font(.headline).lineLimit(1);Text(server.host).font(.caption.monospaced()).foregroundStyle(BackupTheme.muted)}.frame(maxWidth:.infinity,alignment:.leading);VStack(alignment:.leading,spacing:4){Text(state == nil ? "Не проверен":state?.error != nil ? "Нет связи":"Доступен").foregroundStyle(state == nil ? BackupTheme.muted:state?.error != nil ? .orange:.green);Text(state?.title ?? "—").foregroundStyle(state?.attention==true ? .orange:BackupTheme.muted)}.font(.caption).frame(width:145,alignment:.leading);Text(backupTime(state?.jobs.compactMap{$0["last_success"] as? String}.sorted().last)).font(.caption).frame(width:170,alignment:.leading);Text(state?.error ?? state?.jobs.map{($0["name"] as? String ?? $0["id"] as? String ?? "")+" · "+resultTitle($0["current_status"] as? String ?? $0["last_status"] as? String ?? "Нет копий")}.joined(separator:"; ") ?? "—").font(.caption).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading);Text(free(state)).font(.caption).frame(width:110,alignment:.trailing);Image(systemName:"chevron.right").frame(width:26)}.padding(12).contentShape(Rectangle())}.buttonStyle(.plain).contextMenu{Button("Изменить"){edit(server)}};Divider()}
    }.background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:12))}
    func free(_ state:FleetStatus?)->String{guard let disks=(state?.health["metrics"] as? [String:Any])?["physical_disks"] as? [[String:Any]] else{return "—"};let values=disks.compactMap{($0["free_bytes"] as? NSNumber)?.doubleValue};return values.isEmpty ? "—":bytes(values.reduce(0,+))}
}
