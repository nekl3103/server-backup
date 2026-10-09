import SwiftUI

struct ServerLogsView:View {
    @EnvironmentObject var m:Model
    @State private var files:[[String:Any]]=[]
    @State private var selected="journal"
    @State private var fileSearch=""
    @State private var search=""
    @State private var text=""
    @State private var updated=""
    @State private var issues:[String]=[]
    @State private var auto=true
    @State private var loading=false
    @State private var loadError:String?
    @State private var follow=true
    @State private var truncated=false
    @StateObject private var stream=SSHStream()
    var filtered:[[String:Any]]{files.filter{fileSearch.isEmpty || ($0["path"] as? String ?? "").localizedCaseInsensitiveContains(fileSearch)}}
    var output:String{search.isEmpty ? text:text.components(separatedBy:"\n").filter{$0.localizedCaseInsensitiveContains(search)}.joined(separator:"\n")}
    var body:some View{BackupPanel(title:"Логи сервера",subtitle:"Файлы /var/log и системный журнал · последние 500 строк",icon:"doc.text"){
        HStack{Toggle("Онлайн · поток",isOn:$auto);Toggle("Следить за концом",isOn:$follow);if loading{ProgressView().controlSize(.small)};Text(auto ? stream.state:"Пауза").font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Button("Обновить список"){list()}.disabled(m.busy);Button("Обновить лог"){load()}.disabled(m.busy)}
        HStack(alignment:.top,spacing:18){
            VStack(alignment:.leading){TextField("Поиск файла",text:$fileSearch);ScrollView{LazyVStack(alignment:.leading,spacing:6){fileButton("journal","Системный журнал");ForEach(filtered.indices,id:\.self){i in let path=filtered[i]["path"] as? String ?? "";fileButton(path,path)}}}.frame(height:420)}.frame(width:280)
            VStack(alignment:.leading,spacing:10){Text(selected=="journal" ? "journalctl":selected).font(.system(.callout,design:.monospaced)).textSelection(.enabled);TextField("Поиск в строках",text:$search);ScrollViewReader{proxy in ScrollView([.horizontal,.vertical]){VStack(alignment:.leading,spacing:0){Text(output.isEmpty ? "Нет строк для отображения":output).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12);Color.clear.frame(height:1).id("log-end")}}.onChange(of:text){_,_ in if follow{proxy.scrollTo("log-end",anchor:.bottom)}}}.frame(height:360).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8));HStack{Text(updated.isEmpty ? "Не загружено":"Обновлено: "+updated).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Button("Скопировать"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(output,forType:.string)};Button("Сохранить…"){export()}};if truncated{Text("Показан конец файла, объём ограничен 500 строками / 512 КБ.").font(.caption).foregroundStyle(BackupTheme.muted)}}
        }
        if let loadError=stream.error ?? loadError{Text("Последние данные сохранены. "+loadError).font(.caption).foregroundStyle(.orange)}
        ForEach(issues,id:\.self){Text($0).font(.caption).foregroundStyle(.orange)}
    }.textFieldStyle(.roundedBorder).onAppear{list()}.onDisappear{stream.stop()}.onChange(of:auto){_,enabled in if enabled{start()}else{stream.stop()}}}
    func fileButton(_ path:String,_ title:String)->some View{Button{selected=path;text="";updated="";load()}label:{HStack{Image(systemName:path=="journal" ? "terminal":"doc.text");Text(title).font(.caption).lineLimit(2);Spacer()}.padding(8).background(selected==path ? BackupTheme.blue.opacity(0.2):Color.clear).clipShape(RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain).disabled(m.busy)}
    func export(){let panel=NSSavePanel();panel.nameFieldStringValue="server-log.txt";if panel.runModal() == .OK,let url=panel.url{do{try output.write(to:url,atomically:true,encoding:.utf8)}catch{m.error=error.localizedDescription}}}
    func list(){m.perform(["action":"log_files"]){r in let value=r as? [String:Any] ?? [:];files=value["files"] as? [[String:Any]] ?? [];issues=value["issues"] as? [String] ?? [];m.result="";load()}}
    func start(){stream.start(model:m,request:["action":"stream","kind":"logs","source":selected=="journal" ? "journal":"file","path":selected]){event in guard event["event"] as? String=="logs",let r=event["result"] as? [String:Any] else{return};let incoming=r["text"] as? String ?? "";text=event["mode"] as? String=="replace" ? LogBuffer.append("",incoming):LogBuffer.append(text,incoming);updated=String((r["updated"] as? String ?? "").prefix(19)).replacingOccurrences(of:"T",with:" ");truncated=r["truncated"] as? Bool ?? truncated;loadError=nil}}
    func load(){if auto{start();return};guard let server=m.current,!loading else{return};let path=selected;loading=true
        Task{do{let r=try await m.readLive(["action":"server_log","source":path=="journal" ? "journal":"file","path":path],server:server);guard path==selected,m.selectedID==server.id else{loading=false;return};let value=r as? [String:Any] ?? [:];text=value["text"] as? String ?? "";updated=String((value["updated"] as? String ?? "").prefix(19)).replacingOccurrences(of:"T",with:" ");truncated=value["truncated"] as? Bool ?? false;loadError=nil}catch{if path==selected,m.selectedID==server.id{loadError=error.localizedDescription}};loading=false}}
}
