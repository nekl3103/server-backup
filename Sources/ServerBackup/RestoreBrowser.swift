import SwiftUI

struct SnapshotFileSelection:View {
    let repository:String
    let snapshot:String
    @Binding var includes:String
    var body:some View{SnapshotDetailsBrowser(repository:repository,snapshot:snapshot,includes:$includes,compact:true)}
}
struct RestoreDirectoryPicker:View{
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let server:Server
    @Binding var target:String
    @State private var path="/"
    @State private var entries:[[String:Any]]=[]
    @State private var loading=false
    @State private var error:String?
    @State private var generation=UUID()
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Text("Каталог на сервере "+server.name).font(.title2);Spacer();Button("Закрыть"){dismiss()}};HStack{Button("Выше"){path=URL(fileURLWithPath:path).deletingLastPathComponent().path;load()};TextField("Путь",text:$path).onSubmit{load()};Button("Открыть"){load()}};if loading{ProgressView().controlSize(.small)};if let error{Text(error).foregroundStyle(.orange)};List(entries.indices,id:\.self){i in let entry=entries[i];Button{path=entry["path"] as? String ?? path;load()}label:{Label(entry["name"] as? String ?? "",systemImage:"folder.fill").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)};Text("Будет восстановлена структура путей из копии внутри выбранного каталога. Можно дописать имя нового каталога после выбора.").font(.caption).foregroundStyle(.secondary);HStack{Text(path).font(.caption.monospaced());Spacer();Button("Выбрать этот каталог"){target=path;dismiss()}.buttonStyle(.borderedProminent).disabled(loading || error != nil || path=="/")}}.padding(24).frame(width:680,height:520).onAppear{path=URL(fileURLWithPath:target).deletingLastPathComponent().path;load()}.onDisappear{generation=UUID()}}
    func load(){let token=UUID();generation=token;loading=true;error=nil;Task{do{let result=try await m.readLive(["action":"browse","path":path],server:server);guard generation==token else{return};entries=(result as? [[String:Any]] ?? []).filter{$0["directory"] as? Bool==true};loading=false}catch{guard generation==token else{return};loading=false;self.error=error.localizedDescription}}}
}

struct RestoreDestinationBrowser:View{
    @EnvironmentObject var m:Model
    let server:Server
    @Binding var target:String
    @Binding var targetFile:String?
    @State private var path="/"
    @State private var entries:[[String:Any]]=[]
    @State private var loading=false
    @State private var error:String?
    @State private var generation=UUID()
    @State private var folderName=""
    var body:some View{VStack(alignment:.leading,spacing:10){
        Text(server.name+" · "+server.host).font(.caption).foregroundStyle(BackupTheme.muted)
        HStack{Button("Выше"){path=URL(fileURLWithPath:path).deletingLastPathComponent().path;load()}.disabled(path=="/");Text(path).font(.caption.monospaced()).lineLimit(1);Spacer();Button("Обновить"){load()}.disabled(loading)}
        Toggle("Сохранить в текущую папку",isOn:Binding(get:{target==path && targetFile==nil},set:{if $0{target=path;targetFile=nil}})).font(.caption)
        if let error{Text(error).font(.caption).foregroundStyle(.orange)};if loading{ProgressView().controlSize(.small)}
        ScrollView{LazyVStack(spacing:4){ForEach(entries.indices,id:\.self){i in let entry=entries[i];let item=entry["path"] as? String ?? "";let folder=entry["directory"] as? Bool==true
            HStack(spacing:10){Toggle("Выбрать "+item,isOn:Binding(get:{folder ? target==item && targetFile==nil:targetFile==item},set:{if $0{if folder{target=item;targetFile=nil}else{target=URL(fileURLWithPath:item).deletingLastPathComponent().path;targetFile=item}}})).labelsHidden().toggleStyle(.checkbox)
                Image(systemName:folder ? "folder.fill":"doc").foregroundStyle(folder ? BackupTheme.blue:BackupTheme.muted)
                if folder{Button(entry["name"] as? String ?? ""){path=item;load()}.buttonStyle(.plain).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}else{Text(entry["name"] as? String ?? "").frame(maxWidth:.infinity,alignment:.leading)}
            }.padding(8).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:6))
        }}}.frame(height:220)
        HStack{TextField("Имя новой папки",text:$folderName);Button("Выбрать"){guard !folderName.contains("/"),!folderName.isEmpty,![".",".."].contains(folderName) else{return};target=URL(fileURLWithPath:path).appendingPathComponent(folderName).path;targetFile=nil}.disabled(folderName.isEmpty)}
        Text(targetFile==nil ? "Каталог: "+target:"Заменить файл: "+(targetFile ?? "")).font(.caption.monospaced()).textSelection(.enabled)
    }.onAppear{load()}.onChange(of:server.id){_,_ in path="/";target="/";targetFile=nil;load()}.onDisappear{generation=UUID()}}
    func load(){let token=UUID();generation=token;loading=true;error=nil;Task{do{let value=try await m.readLive(["action":"browse","path":path],server:server);guard generation==token else{return};entries=value as? [[String:Any]] ?? [];loading=false}catch{guard generation==token else{return};loading=false;self.error=error.localizedDescription}}}
}
struct RestoreRuleBuilder:View{
    @Binding var includes:String
    @State private var kind="extension"
    @State private var value=""
    var body:some View{VStack(alignment:.leading,spacing:12){
        Text("Выбор по признаку").font(.headline)
        Text("Например: все фотографии, файлы с определённым именем или расширением. Правило создаётся автоматически.").font(.caption).foregroundStyle(BackupTheme.muted)
        HStack{Picker("Что искать",selection:$kind){Text("Расширение").tag("extension");Text("Имя содержит").tag("contains");Text("Точное имя").tag("name")};TextField(kind=="extension" ? "Например: jpg":"Например: nginx.conf",text:$value);Button("Добавить правило"){add()}.disabled(value.trimmingCharacters(in:.whitespaces).isEmpty || value.contains("/") || value.contains("\n"))}
        HStack{Text("Быстрый выбор:").font(.caption);Button("Фотографии"){append(["**/*.jpg","**/*.jpeg","**/*.png","**/*.webp"])};Button("Документы"){append(["**/*.pdf","**/*.docx","**/*.xlsx"])};Button("Конфигурации"){append(["**/*.conf","**/*.yaml","**/*.yml","**/*.json"])} }
        Text("Правила добавляются к выбранным галочками путям. Будут восстановлены данные, подходящие хотя бы под один выбор.").font(.caption).foregroundStyle(BackupTheme.muted)
    }}
    func append(_ rules:[String]){includes=Array(Set(lines(includes)+rules)).sorted().joined(separator:"\n")}
    func add(){let input=value.trimmingCharacters(in:.whitespacesAndNewlines);let escaped=input.replacingOccurrences(of:"[",with:"[[]").replacingOccurrences(of:"*",with:"[*]").replacingOccurrences(of:"?",with:"[?]");let rule=kind=="extension" ? "**/*."+escaped.trimmingCharacters(in:CharacterSet(charactersIn:".")):kind=="contains" ? "**/*"+escaped+"*":"**/"+escaped;append([rule]);value=""}
}
