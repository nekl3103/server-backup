import SwiftUI

struct SnapshotPageKey:Hashable{
    let server:String,repository:String,snapshot:String,path:String,query:String
    let offset:Int
}
struct SnapshotEntry:Identifiable{
    let value:[String:Any]
    var id:String{value["path"] as? String ?? ""}
    var name:String{URL(fileURLWithPath:id).lastPathComponent}
    var folder:Bool{value["type"] as? String=="dir"}
    var type:String{["dir":"Папка","file":"Файл","symlink":"Ссылка"][value["type"] as? String ?? ""] ?? (value["type"] as? String ?? "—")}
    var size:String{folder ? "—":(value["size"] as? NSNumber).map{ByteCountFormatter.string(fromByteCount:$0.int64Value,countStyle:.binary)} ?? "—"}
    var mode:String{(value["mode"] as? NSNumber).map{String(format:"%04o",$0.intValue & 0o7777)} ?? "—"}
    var owner:String{(value["user"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? (value["uid"] as? NSNumber).map{"UID "+$0.stringValue} ?? "—"}
    var group:String{(value["group"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? (value["gid"] as? NSNumber).map{"GID "+$0.stringValue} ?? "—"}
    var modified:String{(value["mtime"] as? String).map{backupTime($0)} ?? "—"}
}
struct SnapshotPage{
    let entries:[SnapshotEntry]
    let total:Int
    let size:Int64
    let files:Int
    init(_ value:[String:Any]){entries=(value["entries"] as? [[String:Any]] ?? []).map{SnapshotEntry(value:$0)};total=(value["total"] as? NSNumber)?.intValue ?? 0;let summary=value["summary"] as? [String:Any] ?? [:];size=(summary["total_size"] as? NSNumber)?.int64Value ?? 0;files=(summary["total_file_count"] as? NSNumber)?.intValue ?? 0}
}
extension Model{
    func snapshotPage(_ key:SnapshotPageKey,server:Server,refresh:Bool=false)async throws->SnapshotPage{
        if !refresh,let cached=snapshotPages[key]{return cached}
        if let pending=snapshotRequests[key]{return try await pending.value}
        let task=Task{let response=try await readLive(["action":"snapshot_files","repository_id":key.repository,"snapshot":key.snapshot,"path":key.path,"query":key.query,"offset":key.offset,"limit":250],server:server);guard let value=response as? [String:Any] else{throw AppFailure(message:"Некорректный ответ списка файлов")};return SnapshotPage(value)}
        snapshotRequests[key]=task
        do{let page=try await task.value;snapshotRequests[key]=nil;if snapshotPages.count>=32{snapshotPages.removeAll()};snapshotPages[key]=page;return page}catch{snapshotRequests[key]=nil;throw error}
    }
}
struct SnapshotDetailsBrowser:View{
    @EnvironmentObject var m:Model
    let repository:String
    let snapshot:String
    @Binding var includes:String
    var compact=false
    @State private var directory="/"
    @State private var search=""
    @State private var offset=0
    @State private var page:SnapshotPage?
    @State private var loading=false
    @State private var error:String?
    @State private var selectedRow:String?
    @State private var details:SnapshotEntry?
    @State private var versionFile:SnapshotEntry?
    var key:SnapshotPageKey{SnapshotPageKey(server:m.selectedID ?? "",repository:repository,snapshot:snapshot,path:directory,query:search,offset:offset)}
    var chosen:Set<String>{Set(lines(includes))}
    var entries:[SnapshotEntry]{page?.entries ?? []}
    var body:some View{VStack(alignment:.leading,spacing:12){
        HStack{Button("Выше"){directory=URL(fileURLWithPath:directory).deletingLastPathComponent().path;offset=0}.disabled(directory=="/");Text(directory).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled);Spacer();Button("Обновить"){Task{await load(refresh:true)}}.disabled(loading)}
        HStack{TextField("Поиск по имени или пути",text:$search).onChange(of:search){_,_ in offset=0};if directory != "/"{Button("Выбрать папку"){toggle(directory)}}}
        if !search.isEmpty{Text("Поиск во всём содержимом текущей папки.").font(.caption).foregroundStyle(BackupTheme.muted)}
        if loading{HStack{ProgressView().controlSize(.small);Text(page==nil ? "Подготавливаем список файлов…":"Загружаем страницу…").font(.caption).foregroundStyle(BackupTheme.muted)}}
        if let error{Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
        if compact{
            ScrollView{LazyVStack(spacing:4){ForEach(entries){entry in HStack(spacing:9){selection(entry);Image(systemName:entry.folder ? "folder.fill":"doc").foregroundStyle(entry.folder ? BackupTheme.blue:BackupTheme.muted);Button{if entry.folder{open(entry)}else{details=entry}}label:{Text(search.isEmpty ? entry.name:entry.id).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain);Text(entry.folder ? "Папка целиком":entry.size).font(.caption).foregroundStyle(BackupTheme.muted)}.padding(8).background(chosen.contains(entry.id) ? BackupTheme.blue.opacity(0.12):BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:6))}}}.frame(height:220)
        }else{
            Table(entries,selection:$selectedRow){
                TableColumn(""){entry in selection(entry)}.width(26)
                TableColumn("Имя"){entry in Button{if entry.folder{open(entry)}else{details=entry}}label:{Label(search.isEmpty ? entry.name:entry.id,systemImage:entry.folder ? "folder.fill":entry.value["type"] as? String=="symlink" ? "link":"doc").foregroundStyle(entry.folder ? BackupTheme.blue:Color.primary).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)}.width(min:160,ideal:250)
                TableColumn("Размер"){Text($0.size).monospacedDigit()}.width(85)
                TableColumn("Изменён"){Text($0.modified).font(.caption)}.width(min:120,ideal:150)
                TableColumn("Права"){Text($0.mode).font(.caption.monospaced())}.width(52)
                TableColumn("Владелец"){Text($0.owner).font(.caption)}.width(min:75,ideal:100)
            }.frame(height:340)
        }
        if entries.isEmpty && !loading && error==nil{Text(search.isEmpty ? "Папка пуста":"Файлы не найдены").font(.caption).foregroundStyle(BackupTheme.muted)}
        HStack{Text("Объектов: "+String(page?.total ?? 0)).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Button("Назад"){offset=max(0,offset-250)}.disabled(offset==0 || loading);Text(String(offset/250+1)+" / "+String(max(1,((page?.total ?? 0)+249)/250))).font(.caption.monospaced());Button("Далее"){offset+=250}.disabled(offset+entries.count >= (page?.total ?? 0) || loading)}
        if !compact,let page{HStack{Label("Объём файлов: "+ByteCountFormatter.string(fromByteCount:page.size,countStyle:.binary),systemImage:"internaldrive");Text("Файлов в копии: "+String(page.files))}.font(.caption).foregroundStyle(BackupTheme.muted);Text("Это полный объём файлов; дополнительное место в хранилище зависит от сжатия и повторного использования данных.").font(.caption).foregroundStyle(BackupTheme.muted)}
        if !chosen.isEmpty{HStack{Text("Выбрано: "+String(chosen.count)).font(.caption);Spacer();Button("Снять выбор"){includes=""}};ForEach(Array(chosen.sorted().prefix(12)),id:\.self){path in HStack{Text(path).font(.caption).lineLimit(1).textSelection(.enabled);Spacer();Button{toggle(path)}label:{Image(systemName:"xmark.circle")}.buttonStyle(.plain)}};if chosen.count>12{Text("И ещё "+String(chosen.count-12)+". Полный список доступен в ручном выборе.").font(.caption).foregroundStyle(BackupTheme.muted)}}
    }.task(id:key){await load()}.onChange(of:snapshot){_,_ in directory="/";search="";offset=0;page=nil}.onChange(of:repository){_,_ in directory="/";search="";offset=0;page=nil}.sheet(item:$details){entry in VStack{SnapshotEntryDetails(entry:entry);if !entry.folder{Button("История версий"){details=nil;Task{try? await Task.sleep(for:.milliseconds(300));versionFile=entry}}.padding(.bottom,20)}}}.sheet(item:$versionFile){FileHistoryView(repository:repository,path:$0.id)}}
    func selection(_ entry:SnapshotEntry)->some View{Toggle("Выбрать "+entry.id,isOn:Binding(get:{chosen.contains(entry.id)},set:{_ in toggle(entry.id)})).labelsHidden().toggleStyle(.checkbox)}
    func toggle(_ path:String){var selected=chosen;if selected.contains(path){selected.remove(path)}else{selected.insert(path)};includes=selected.sorted().joined(separator:"\n")}
    func open(_ entry:SnapshotEntry){directory=entry.id;search="";offset=0}
    func load(refresh:Bool=false)async{
        guard let server=m.current else{return};let request=key;page=nil;loading=true;error=nil
        do{if !search.isEmpty{try await Task.sleep(for:.milliseconds(250))};let loaded=try await m.snapshotPage(request,server:server,refresh:refresh);guard !Task.isCancelled,request==key else{return};page=loaded;loading=false}catch{guard !Task.isCancelled,request==key else{return};loading=false;self.error=error.localizedDescription}
    }
}
struct SnapshotEntryDetails:View{
    let entry:SnapshotEntry
    @Environment(\.dismiss) var dismiss
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Label(entry.name,systemImage:entry.folder ? "folder":"doc").font(.title2);Spacer();Button("Закрыть"){dismiss()}};Text(entry.id).font(.callout.monospaced()).textSelection(.enabled);Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:12){row("Тип",entry.type);row("Размер",entry.size);row("Изменён",entry.modified);row("Права",entry.mode);row("Владелец",entry.owner);row("Группа",entry.group);if let link=entry.value["linktarget"] as? String{row("Цель ссылки",link)}};Text("Сведения сохранены в выбранной резервной копии.").font(.caption).foregroundStyle(BackupTheme.muted)}.padding(24).frame(width:650)}
    func row(_ name:String,_ value:String)->some View{GridRow{Text(name).foregroundStyle(BackupTheme.muted);Text(value).textSelection(.enabled)}}
}
