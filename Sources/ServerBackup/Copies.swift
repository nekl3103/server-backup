import SwiftUI

struct CopyCommandResult:Identifiable{let id=UUID();let title:String;let output:String}
struct CopiesView:View {
    @EnvironmentObject var m:Model
    @State private var repo=""
    @State private var snapshot=""
    @State private var other=""
    @State private var copies:[[String:Any]]=[]
    @State private var search=""
    @State private var fileQuery=""
    @State private var selectedPaths=""
    @State private var loading=false
    @State private var executing=false
    @State private var loadingRepository=""
    @State private var pendingOperation:String?
    @State private var operationTitle=""
    @State private var error:String?
    @State private var generation=UUID()
    @State private var advanced=false
    @State private var comparingServer=false
    @State private var tools=false
    @State private var finder=false
    @State private var command="check"
    @State private var args="[]"
    @State private var confirm=false
    @State private var result:CopyCommandResult?
    let commands=["check","forget","prune","copy","key","unlock","repair","migrate","tag","cat","dump","list","mount","help","version","cache","generate","backup"]
    var visible:[[String:Any]]{copies.filter{search.isEmpty || ([$0["id"] as? String ?? "",$0["hostname"] as? String ?? "",$0["time"] as? String ?? ""]+($0["paths"] as? [String] ?? [])+($0["tags"] as? [String] ?? [])).joined(separator:" ").localizedCaseInsensitiveContains(search)}}
    var selected:[String:Any]?{copies.first{$0["id"] as? String==snapshot}}
    func label(_ copy:[String:Any])->String{backupTime(copy["time"] as? String)+" · "+String((copy["short_id"] as? String ?? copy["id"] as? String ?? "").prefix(8))}
    func size(_ copy:[String:Any])->String{if let value=(copy["summary"] as? [String:Any])?["total_bytes_processed"] as? NSNumber{return ByteCountFormatter.string(fromByteCount:value.int64Value,countStyle:.binary)};if let page=m.snapshotPages.first(where:{$0.key.server==m.selectedID && $0.key.repository==repo && $0.key.snapshot==copy["id"] as? String})?.value{return ByteCountFormatter.string(fromByteCount:page.size,countStyle:.binary)};return "Размер появится после просмотра файлов"}
    var body:some View{let filtered=visible;return VStack(alignment:.leading,spacing:18){WorkspaceIntro(title:"Резервные копии",detail:"Выберите версию, просмотрите файлы или сравните изменения",icon:"clock.arrow.circlepath")
        HStack{Picker("Хранилище",selection:$repo){if m.repositories.isEmpty{Text("Нет хранилищ").tag("")};ForEach(m.repositories.indices,id:\.self){i in let r=m.repositories[i];Text(r["name"] as? String ?? r["id"] as? String ?? "").tag(r["id"] as? String ?? "")}};Button("Обновить копии"){load()}.disabled(loading || repo.isEmpty);if loading{ProgressView().controlSize(.small)};Spacer();Button("Статистика"){run("stats",["--json"],"Статистика хранилища")}.disabled(executing || repo.isEmpty);Button("Проверка структуры"){run("check",[],"Проверка структуры")}.disabled(executing || repo.isEmpty)}
        if let error{Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
        if executing{HStack{ProgressView().controlSize(.small);Text(operationTitle+"…").font(.caption).foregroundStyle(BackupTheme.muted)}}
        HStack(alignment:.top,spacing:16){
            BackupPanel(title:"Версии · "+String(copies.count),icon:"square.stack.3d.up"){
                TextField("Поиск: дата, ID, сервер, путь",text:$search)
                ScrollView{LazyVStack(alignment:.leading,spacing:8){ForEach(filtered.indices,id:\.self){i in let copy=filtered[i];Button{snapshot=copy["id"] as? String ?? "";selectedPaths="";m.selectedSnapshot=snapshot;m.preferredRepository=repo}label:{VStack(alignment:.leading,spacing:7){HStack{Image(systemName:"archivebox").foregroundStyle(BackupTheme.blue);Text(backupTime(copy["time"] as? String)).font(.callout.weight(.semibold));Spacer();if snapshot==copy["id"] as? String{Image(systemName:"checkmark.circle.fill").foregroundStyle(BackupTheme.blue)}};Text((copy["hostname"] as? String ?? "")+" · "+String((copy["short_id"] as? String ?? copy["id"] as? String ?? "").prefix(8))).font(.caption).foregroundStyle(BackupTheme.muted);Text(size(copy)).font(.caption).foregroundStyle(BackupTheme.muted)}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(snapshot==copy["id"] as? String ? BackupTheme.blue.opacity(0.14):BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())}.buttonStyle(.plain)};if filtered.isEmpty && !loading{Text(copies.isEmpty ? "Копий пока нет":"Ничего не найдено").font(.caption).foregroundStyle(BackupTheme.muted)}}}.frame(height:260)
                Text("Время показано в часовом поясе Mac.").font(.caption).foregroundStyle(BackupTheme.muted)
            }.frame(width:280)
            VStack(alignment:.leading,spacing:14){if let selected{
                BackupPanel(title:label(selected),icon:"archivebox"){
                    Text("Сервер: "+(selected["hostname"] as? String ?? "Не указан")).font(.callout)
                    Text((selected["paths"] as? [String] ?? []).joined(separator:" · ")).font(.caption).foregroundStyle(BackupTheme.muted).textSelection(.enabled)
                    if let tags=selected["tags"] as? [String],!tags.isEmpty{Text("Метки: "+tags.joined(separator:", ")).font(.caption).foregroundStyle(BackupTheme.muted)}
                    HStack{Button("Восстановить всю копию"){restore(all:true)}.buttonStyle(.borderedProminent);Button("Проверить восстановление"){m.selectedSnapshot=snapshot;m.preferredRepository=repo;m.section="Проверка копий"}}
                }

            }else{BackupPanel(title:"Выберите копию",icon:"archivebox"){Text("После выбора версии слева здесь появятся её сведения и файлы.").foregroundStyle(BackupTheme.muted)}}}
        }
        if selected != nil{BackupPanel(title:"Файлы выбранной копии",icon:"folder"){
            SnapshotDetailsBrowser(repository:repo,snapshot:snapshot,includes:$selectedPaths)
            Button("Восстановить выбранные данные"){restore(all:false)}.disabled(lines(selectedPaths).isEmpty)
        }}
        BackupPanel(title:"Сравнить выбранную копию",subtitle:"Узнайте, что изменилось между версиями или на сервере",icon:"arrow.left.arrow.right"){
            Button("С текущими файлами сервера"){comparingServer=true}.disabled(snapshot.isEmpty)
            HStack{Picker("Сравнить выбранную с",selection:$other){Text("Выберите вторую копию").tag("");ForEach(copies.indices,id:\.self){i in Text(label(copies[i])).tag(copies[i]["id"] as? String ?? "")}};Button("Показать изменения"){run("diff",["--json",snapshot,other],"Изменения между копиями")}.disabled(snapshot.isEmpty || other.isEmpty || snapshot==other || executing)}
        }
        ClickableDisclosure(title:"Найти файл во всех копиях",isExpanded:$finder){
            HStack{TextField("Название файла, например nginx.conf",text:$fileQuery);Button("Найти"){run("find",["--json",fileQuery],"Поиск файлов")}.disabled(fileQuery.isEmpty || executing || repo.isEmpty)}
            Text("Для поиска части названия можно использовать *: например *.conf.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
        ClickableDisclosure(title:"Обслуживание хранилища",isExpanded:$tools){
            Text("Копирование в другое хранилище и дополнительный пароль доступа.").font(.caption).foregroundStyle(BackupTheme.muted)
            CopyRepositoryView(destination:repo)
        }
        ClickableDisclosure(title:"Технические команды Restic",isExpanded:$advanced){VStack(alignment:.leading,spacing:12){
            Picker("Команда",selection:$command){ForEach(Array(Set(commands+(m.probe["restic_commands"] as? [String] ?? []).filter{$0 != "init" && $0 != "restore"})).sorted(),id:\.self){Text($0).tag($0)}}
            Text("Аргументы — JSON-массив строк. Возможности зависят от версии Restic; mount требует FUSE.").font(.caption).foregroundStyle(BackupTheme.muted)
            TextEditor(text:$args).font(.caption.monospaced()).frame(height:80).border(.quaternary);Button("Выполнить"){confirm=true}.disabled(repo.isEmpty || m.busy)
        }}
        ResultView()
    }.onAppear{if repo.isEmpty{repo=m.preferredRepository.isEmpty ? m.repositories.first?["id"] as? String ?? "":m.preferredRepository};if snapshot.isEmpty{snapshot=m.selectedSnapshot};if !repo.isEmpty && copies.isEmpty{load()}}.onChange(of:repo){_,_ in copies=[];snapshot="";other="";selectedPaths="";load()}.onChange(of:m.operationState["status"] as? String){_,value in
            if let pending=pendingOperation,m.operationState["id"] as? String==pending,["success","failed","incomplete","cancelled"].contains(value ?? ""){
                pendingOperation=nil;executing=false
                if value=="success"{result=CopyCommandResult(title:operationTitle,output:m.operationState["output"] as? String ?? "")}
                else{error=m.operationState["error"] as? String ?? "Проверка не завершена"}
            }
        }.onDisappear{generation=UUID()}.sheet(item:$result){CopyCommandResultView(result:$0)}.sheet(isPresented:$comparingServer){SnapshotCompareView(repository:repo,snapshot:snapshot,roots:selected?["paths"] as? [String] ?? []).environmentObject(m)}
        .confirmationDialog("Выполнить операцию? Очистка, ремонт и изменение ключей могут необратимо изменить репозиторий.",isPresented:$confirm){Button("Выполнить"){do{guard let values=try JSONSerialization.jsonObject(with:Data(args.utf8)) as? [String] else{throw AppFailure(message:"Нужен массив строк")};m.perform(["action":"command","repository_id":repo,"command":command,"args":values,"confirmed":true])}catch{m.error=error.localizedDescription}}}
    }
    func restore(all:Bool){m.selectedSnapshot=snapshot;m.preferredRepository=repo;m.restoreIncludes=all ? []:lines(selectedPaths);m.section="Восстановление"}
    func load(){guard let server=m.current,!repo.isEmpty,!(loading && loadingRepository==repo) else{return};loadingRepository=repo;let token=UUID();generation=token;let repository=repo;loading=true;error=nil;Task{do{let value=try await m.readLive(["action":"command","repository_id":repository,"command":"snapshots","args":["--json"]],server:server) as? [String:Any] ?? [:];guard generation==token else{return};if (value["exit_code"] as? Int ?? 0) != 0{throw AppFailure(message:value["error"] as? String ?? "Не удалось получить копии")};let output=value["output"] as? String ?? "[]";let parsed=try await Task.detached{(try JSONSerialization.jsonObject(with:Data(output.utf8)) as? [[String:Any]] ?? []).sorted{($0["time"] as? String ?? "") > ($1["time"] as? String ?? "")}}.value;guard generation==token else{return};copies=parsed;if !copies.contains(where:{$0["id"] as? String==snapshot}){snapshot=copies.first?["id"] as? String ?? ""};loading=false}catch{guard generation==token else{return};loading=false;self.error=error.localizedDescription}}}
    func run(_ command:String,_ args:[String],_ title:String){guard let server=m.current,!executing else{return};let repository=repo;executing=true;operationTitle=title;error=nil;Task{do{let value=try await m.readLive(["action":"command","repository_id":repository,"command":command,"args":args],server:server) as? [String:Any] ?? [:];guard m.selectedID==server.id,repo==repository else{executing=false;return};if let id=value["operation_id"] as? String{pendingOperation=id;m.trackOperation(id,server:server);m.operationState["operation"]=command;m.tick();return};executing=false;if (value["exit_code"] as? Int ?? 0) != 0{throw AppFailure(message:value["error"] as? String ?? "Операция не выполнена")};result=CopyCommandResult(title:title,output:value["output"] as? String ?? "")}catch{executing=false;self.error=error.localizedDescription}}}
}
struct CopyCommandResultView:View{
    let result:CopyCommandResult
    @Environment(\.dismiss) var dismiss
    @State private var technical=false
    @State private var values:[[String:Any]]=[]
    var changes:[[String:Any]]{values.filter{$0["path"] != nil}}
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Text(result.title).font(.title2);Spacer();Button("Закрыть"){dismiss()}};ScrollView{VStack(alignment:.leading,spacing:12){
        if result.output.isEmpty{Label("Операция завершена без ошибок",systemImage:"checkmark.circle.fill").foregroundStyle(.green)}
        if let stats=values.first,let size=stats["total_size"] as? NSNumber{HStack{MetricCard(title:"Размер данных",value:ByteCountFormatter.string(fromByteCount:size.int64Value,countStyle:.binary));MetricCard(title:"Файлов",value:String((stats["total_file_count"] as? NSNumber)?.intValue ?? 0))}}
        if !changes.isEmpty{Text("Изменений: "+String(changes.count)).font(.headline);ForEach(Array(changes.prefix(500).enumerated()),id:\.offset){_,row in HStack{Text(["+":"Добавлен","-":"Удалён","M":"Изменён"][row["modifier"] as? String ?? ""] ?? "Изменение").font(.caption).frame(width:90,alignment:.leading);Text(row["path"] as? String ?? "").font(.caption.monospaced()).textSelection(.enabled)}.padding(8).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:6))};if changes.count>500{Text("Показаны первые 500 изменений. Полный вывод доступен ниже.").font(.caption)}}
        if changes.isEmpty && !(values.first?["total_size"] is NSNumber){Text(result.output).font(.caption.monospaced()).textSelection(.enabled)}
        ClickableDisclosure(title:"Полный вывод",isExpanded:$technical){Text(result.output).font(.caption.monospaced()).textSelection(.enabled)}
    }}}.padding(24).frame(width:820,height:600).task{let output=result.output;values=await Task.detached{output.split(separator:"\n").compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}}.value}}
}
