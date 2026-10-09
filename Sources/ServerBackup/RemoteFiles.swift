import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemoteAction:Identifiable{let id:String}
struct RemoteImport:Identifiable{let id=UUID();let urls:[URL];let directory:String}
struct RemoteEntry:Identifiable{let value:[String:Any];var id:String{value["path"] as? String ?? ""};var name:String{value["name"] as? String ?? ""};var directory:Bool{value["directory"] as? Bool ?? false}}
struct RemoteFilesView:View {
    @EnvironmentObject var m:Model
    @State private var path="/"
    @State private var entries:[RemoteEntry]=[]
    @State private var selected=Set<String>()
    @State private var selectionAnchor:String?
    @State private var fileActionRunning=false
    @State private var fileActionFeedback=""
    @State private var search=""
    @State private var sortColumn="name"
    @State private var sortAscending=true
    @State private var hasMore=false
    @State private var editorPath:String?
        @State private var action=""
    @State private var newName=""
    @State private var confirmTrash=false
    @State private var showTrash=false
    @State private var uploadFile:URL?
    @State private var uploadHash="absent"
    @State private var uploadTarget=""
    @State private var confirmUpload=false
    @State private var pendingImport:RemoteImport?
    @State private var replaceImport=false
    @State private var dropTarget=false
    @State private var loading=false
    @State private var readGeneration=UUID()
    @State private var moveTarget=""
    @State private var permissions="644"
    var current:RemoteEntry?{selected.count==1 ? entries.first{selected.contains($0.id)}:nil}
    var shown:[RemoteEntry]{entries.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}.sorted{a,b in
        if a.directory != b.directory{return a.directory}
        if sortColumn=="size"{let x=(a.value["size"] as? NSNumber)?.int64Value ?? 0;let y=(b.value["size"] as? NSNumber)?.int64Value ?? 0;if x != y{return sortAscending ? x<y:x>y}}
        if sortColumn=="modified"{let x=a.value["modified"] as? String ?? "";let y=b.value["modified"] as? String ?? "";if x != y{return sortAscending ? x<y:x>y}}
        let order=a.name.localizedStandardCompare(b.name);return sortAscending ? order == .orderedAscending:order == .orderedDescending
    }}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{Label("Файлы",systemImage:"folder.fill").font(.title2.weight(.semibold));Text(m.current?.host ?? "").font(.callout).foregroundStyle(BackupTheme.muted);Spacer();if loading{ProgressView().controlSize(.small)};TextField("Поиск в папке",text:$search).textFieldStyle(.roundedBorder).frame(width:220)}
        HStack{Button("Выше",systemImage:"arrow.up"){path=URL(fileURLWithPath:path).deletingLastPathComponent().path;refresh()};TextField("Каталог сервера",text:$path).onSubmit{refresh()};Button("Открыть"){refresh()};Button("Обновить",systemImage:"arrow.clockwise"){refresh()}}
        HStack{Button("Новая папка"){action="folder";newName=""};Button("Новый файл"){action="file";newName=""};Button("Загрузить…",systemImage:"square.and.arrow.up"){chooseImport()}.disabled(m.transfer.running);Button("Скачать…",systemImage:"square.and.arrow.down"){download()}.disabled(current==nil || current?.directory==true || m.transfer.running);Spacer();Button("Корзина",systemImage:"trash"){showTrash=true}}
        HStack(spacing:5){Button{path="/";refresh()}label:{Image(systemName:"externaldrive.fill");Text("/")}.buttonStyle(.plain);ForEach(breadcrumbs.indices,id:\.self){i in Image(systemName:"chevron.right").font(.caption2).foregroundStyle(BackupTheme.muted);Button(breadcrumbs[i].name){path=breadcrumbs[i].path;refresh()}.buttonStyle(.plain).lineLimit(1)};Spacer();Button{m.toggleFavourite(path)}label:{Image(systemName:(m.favouriteFolders[m.selectedID ?? ""] ?? []).contains(path) ? "star.fill":"star")}.buttonStyle(.plain).help("Текущая папка в избранном")}.font(.callout).padding(.horizontal,12).padding(.vertical,10).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))
        HStack(alignment:.top,spacing:14){
            filesSidebar

            VStack(alignment:.leading,spacing:10){
                HStack(spacing:10){Button{if selected.count==shown.count{selected=[]}else{selected=Set(shown.map(\.id))}}label:{Image(systemName:selected.isEmpty ? "square":selected.count==shown.count ? "checkmark.square.fill":"minus.square.fill")}.buttonStyle(.plain).frame(width:18);sortHeader("Имя",key:"name").frame(maxWidth:.infinity,alignment:.leading);sortHeader("Размер",key:"size").frame(width:80,alignment:.trailing);Text("Права").frame(width:55);sortHeader("Изменено",key:"modified").frame(width:125,alignment:.leading)}.font(.caption.weight(.medium)).foregroundStyle(BackupTheme.muted).padding(.horizontal,12).padding(.vertical,9).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:7))
                List(selection:$selected){ForEach(shown){entry in fileRow(entry).tag(entry.id).contentShape(Rectangle()).onTapGesture(count:2){open(entry)}.contextMenu{Button("Открыть"){open(entry)};Button("Переименовать"){selected=[entry.id];action="rename";newName=entry.name};Button("Переместить…"){selectForAction(entry);action="move";moveTarget=selected.count>1 ? path:entry.id};Button("Права доступа…"){selectForAction(entry);action="permissions";permissions=entry.value["mode"] as? String ?? "644"};if entry.directory{Button("В избранное"){m.toggleFavourite(entry.id)}};Button("Удалить…"){selectForAction(entry);confirmTrash=true}}}}.disabled(fileActionRunning).listStyle(.plain).scrollContentBackground(.hidden).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(BackupTheme.border)).frame(minHeight:350).contextMenu{Button("Новая папка",systemImage:"folder.badge.plus"){action="folder";newName=""};Button("Новый файл",systemImage:"doc.badge.plus"){action="file";newName=""};Divider();Button("Обновить",systemImage:"arrow.clockwise"){refresh()}}
                HStack{Text("Показано: \(entries.count) · выбрано: \(selected.count)").font(.caption).foregroundStyle(BackupTheme.muted);Button("Выбрать все"){selected=Set(shown.map(\.id))}.disabled(shown.isEmpty);if !selected.isEmpty{Button("Снять выбор"){selected=[]}};if hasMore{Button("Показать ещё"){refresh(more:true)}};Spacer()}
                HStack{Spacer();Button("Открыть"){if let current{open(current)}}.disabled(current==nil);Button("Переименовать"){action="rename";newName=current?.name ?? ""}.disabled(current==nil);Button("Переместить…"){action="move";moveTarget=selected.count>1 ? path:current?.id ?? ""}.disabled(selected.isEmpty || fileActionRunning);Button("Права…"){action="permissions";permissions=current?.value["mode"] as? String ?? "644"}.disabled(selected.isEmpty || fileActionRunning);Button("Удалить",systemImage:"trash"){confirmTrash=true}.disabled(selected.isEmpty || fileActionRunning)}
            }
        }.overlay{if dropTarget{RoundedRectangle(cornerRadius:12).stroke(BackupTheme.blue,lineWidth:3).allowsHitTesting(false)}}
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropTarget){providers in acceptDrop(providers)}
        if !fileActionFeedback.isEmpty{HStack{if fileActionRunning{ProgressView().controlSize(.small)};Text(fileActionFeedback).font(.caption).textSelection(.enabled)}}
        Text("Несколько объектов: галочки или ⌘ + клик. Диапазон: Shift + клик. Открыть папку: двойной клик.").font(.caption).foregroundStyle(BackupTheme.muted)
        FileTransferView(transfer:m.transfer,serverID:m.selectedID ?? "")
        Text("SSH · редактор UTF-8 · передача с проверкой SHA-256 · удаление в корзину").font(.caption).foregroundStyle(BackupTheme.muted)
    }.textFieldStyle(.roundedBorder).onAppear{path=m.filePaths[m.selectedID ?? ""] ?? "/";refresh()}.onDisappear{readGeneration=UUID();loading=false}
    .sheet(isPresented:Binding(get:{editorPath != nil},set:{if !$0{editorPath=nil}})){if let editorPath{RemoteFileEditor(path:editorPath,onSaved:{refresh()})}}
    .sheet(isPresented:$showTrash){RemoteTrashView(onChanged:{refresh()})}
    .sheet(item:Binding(get:{action.isEmpty ? nil:RemoteAction(id:action)},set:{if $0==nil{action=""}})){chosen in VStack(alignment:.leading,spacing:16){Text(["folder":"Новая папка","file":"Новый файл","rename":"Переименовать","move":"Переместить","permissions":"Права доступа"][chosen.id] ?? "Файл").font(.title2);if chosen.id=="move"{Text("Выбрано объектов: "+String(selected.count)).font(.caption);TextField(selected.count>1 ? "Каталог назначения для выбранных объектов":"Полный путь назначения, включая имя",text:$moveTarget);Text("Назначение должно находиться на той же файловой системе. Существующие файлы не заменяются.").font(.caption)}else if chosen.id=="permissions"{TextField("Например 644 или 755",text:$permissions);Text("Права меняются у выбранных объектов, без рекурсии.").font(.caption)}else{TextField("Имя",text:$newName)};HStack{Button("Отмена"){action=""};Spacer();Button("Продолжить"){applyAction()}}}.padding(24).frame(width:520)}
    .sheet(item:$pendingImport){batch in VStack(alignment:.leading,spacing:16){Text("Загрузить на сервер").font(.title2);Text("Каталог назначения: "+batch.directory);ScrollView{VStack(alignment:.leading){ForEach(batch.urls,id:\.self){url in Text(url.lastPathComponent)}}}.frame(maxHeight:160);Toggle("Заменять существующие файлы с сохранением предыдущей версии",isOn:$replaceImport);Text("По умолчанию существующие файлы пропускаются. Папки объединяются. Ссылки не загружаются. Отмена сохраняет уже загруженные файлы.").font(.caption);HStack{Button("Отмена"){pendingImport=nil};Spacer();Button("Загрузить"){pendingImport=nil;guard let server=m.current else{return};m.transfer.uploadItems(server:server,locals:batch.urls,directory:batch.directory,replace:replaceImport){if m.selectedID==server.id{refresh()}}}}}.padding(24).frame(width:600)}
    .confirmationDialog("Перенести выбранные объекты в корзину? Количество: "+String(selected.count),isPresented:$confirmTrash){Button("Перенести в корзину"){runSelected("files_trash")}}
    .confirmationDialog("Перезаписать файл на сервере «"+uploadTarget+"»? Предыдущая версия будет сохранена.",isPresented:$confirmUpload){Button("Загрузить и сохранить предыдущую версию"){startUpload()}}
    }
    var breadcrumbs:[(name:String,path:String)]{let parts=path.split(separator:"/");return parts.indices.map{i in (String(parts[i]),"/"+parts[...i].joined(separator:"/"))}}
    var filesSidebar:some View{VStack(alignment:.leading,spacing:14){
        Text("СЕРВЕР").font(.caption2.weight(.semibold)).foregroundStyle(BackupTheme.muted)
        location("Корень",folder:"/",icon:"externaldrive")
        Divider();Text("ИЗБРАННОЕ").font(.caption2.weight(.semibold)).foregroundStyle(BackupTheme.muted)
        ForEach(m.favouriteFolders[m.selectedID ?? ""] ?? [],id:\.self){folder in HStack(spacing:4){location(URL(fileURLWithPath:folder).lastPathComponent,folder:folder,icon:"folder");Button{m.toggleFavourite(folder)}label:{Image(systemName:"minus.circle")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted).help("Убрать из избранного")}}
        if (m.favouriteFolders[m.selectedID ?? ""] ?? []).isEmpty{Text("Добавляйте папки звездой рядом с путём.").font(.caption).foregroundStyle(BackupTheme.muted)}
        Spacer(minLength:12);Button{m.toggleFavourite(path)}label:{Label("Текущая в избранное",systemImage:"star")}.font(.caption).disabled((m.favouriteFolders[m.selectedID ?? ""] ?? []).contains(path))
    }.padding(12).frame(width:170).frame(minHeight:410,alignment:.topLeading).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:10))}
    func location(_ name:String,folder:String,icon:String)->some View{Button{path=folder;refresh()}label:{Label(name,systemImage:icon).lineLimit(1).font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,7).padding(.horizontal,6).background(path==folder ? BackupTheme.blue.opacity(0.18):Color.clear).clipShape(RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())}.buttonStyle(.plain).help(folder)}
    func sortHeader(_ name:String,key:String)->some View{Button{if sortColumn==key{sortAscending.toggle()}else{sortColumn=key;sortAscending=true}}label:{HStack(spacing:4){Text(name);if sortColumn==key{Image(systemName:sortAscending ? "chevron.up":"chevron.down").font(.caption2)}}}.buttonStyle(.plain)}
    func fileRow(_ entry:RemoteEntry)->some View{HStack(spacing:10){Toggle("Выбрать "+entry.name,isOn:Binding(get:{selected.contains(entry.id)},set:{if $0{selected.insert(entry.id)}else{selected.remove(entry.id)};selectionAnchor=entry.id})).labelsHidden().toggleStyle(.checkbox).frame(width:18)
        Image(systemName:entry.directory ? "folder.fill":entry.value["symlink"] as? Bool==true ? "link":"doc.text").foregroundStyle(entry.directory ? Color(red:0.42,green:0.66,blue:0.94):BackupTheme.muted).frame(width:20)
        Text(entry.name).lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading).help(entry.id)
        Text(entry.directory ? "—":ByteCountFormatter.string(fromByteCount:(entry.value["size"] as? NSNumber)?.int64Value ?? 0,countStyle:.binary)).font(.caption).foregroundStyle(BackupTheme.muted).frame(width:80,alignment:.trailing)
        Text(entry.value["mode"] as? String ?? "").font(.caption.monospaced()).foregroundStyle(BackupTheme.muted).frame(width:55)
        Text(backupTime(entry.value["modified"] as? String)).font(.caption).foregroundStyle(BackupTheme.muted).frame(width:125,alignment:.leading)
    }.padding(.vertical,4)}
    func refresh(more:Bool=false){guard let server=m.current else{return};let requested=path;let offset=more ? entries.count:0;let id=UUID();readGeneration=id;loading=true
        Task{do{let value=try await m.readLive(["action":"files_list","path":requested,"offset":offset],server:server);guard readGeneration==id,m.selectedID==server.id else{return};let r=value as? [String:Any] ?? [:];let rows=(r["entries"] as? [[String:Any]] ?? []).map{RemoteEntry(value:$0)};entries=more ? entries+rows:rows;path=r["path"] as? String ?? requested;m.filePaths[server.id]=path;hasMore=r["has_more"] as? Bool ?? false;if !more{selected=[];selectionAnchor=nil};loading=false}catch{guard readGeneration==id else{return};loading=false;m.error=error.localizedDescription}}
    }
    func select(_ entry:RemoteEntry){let flags=NSEvent.modifierFlags
        if flags.contains(.shift),let anchor=selectionAnchor,let a=shown.firstIndex(where:{$0.id==anchor}),let b=shown.firstIndex(where:{$0.id==entry.id}){selected.formUnion(shown[min(a,b)...max(a,b)].map(\.id))}
        else if flags.contains(.command){if selected.contains(entry.id){selected.remove(entry.id)}else{selected.insert(entry.id)};selectionAnchor=entry.id}
        else{selected=[entry.id];selectionAnchor=entry.id}
    }
    func selectForAction(_ entry:RemoteEntry){if !selected.contains(entry.id){selected=[entry.id]};selectionAnchor=entry.id}
    func applyAction(){if action=="move"{guard moveTarget.hasPrefix("/") else{m.error="Укажите абсолютный путь назначения";return};action="";runSelected("files_move")}else if action=="permissions"{action="";runSelected("files_chmod")}else{changeName()}}
    func runSelected(_ command:String){guard let server=m.current,!selected.isEmpty,!fileActionRunning else{return};if m.isDesignPreview{m.error="Изменение файлов отключено в демонстрации";return};let paths=selected.sorted();let directory=moveTarget;let mode=permissions;fileActionRunning=true;fileActionFeedback="Подготовка…"
        Task{var done=0;do{
            if command=="files_move",paths.count>1{let destination=try await m.readLive(["action":"files_stat","path":directory],server:server) as? [String:Any] ?? [:];guard destination["directory"] as? Bool==true else{throw AppFailure(message:"Выберите существующий каталог назначения")}}
            for item in paths{fileActionFeedback="Выполняется: "+String(done+1)+" / "+String(paths.count)+" · "+URL(fileURLWithPath:item).lastPathComponent
                var request:[String:Any]=["action":command,"path":item,"confirmed":true]
                if command=="files_move"{request["destination"]=paths.count>1 ? URL(fileURLWithPath:directory).appendingPathComponent(URL(fileURLWithPath:item).lastPathComponent).path:directory}
                if command=="files_chmod"{request["mode"]=mode}
                _=try await m.readLive(request,server:server);done+=1
            };fileActionRunning=false;fileActionFeedback="Готово. Обработано объектов: "+String(done);if m.selectedID==server.id{refresh()}
        }catch{fileActionRunning=false;fileActionFeedback="Обработано: "+String(done)+" / "+String(paths.count)+". "+error.localizedDescription;if m.selectedID==server.id{refresh()}}}
    }
    func chooseImport(){guard !m.isDesignPreview else{m.error="Передача файлов отключена в демонстрации";return};let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=true;if panel.runModal() == .OK{replaceImport=false;pendingImport=RemoteImport(urls:panel.urls,directory:path)}}
    func acceptDrop(_ providers:[NSItemProvider])->Bool{guard !m.transfer.running,!m.isDesignPreview else{return false};let group=DispatchGroup();let lock=NSLock();var urls:[URL]=[]
        for provider in providers{group.enter();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){data,_ in defer{group.leave()};if let data,let url=URL(dataRepresentation:data,relativeTo:nil),url.isFileURL{lock.lock();urls.append(url);lock.unlock()}}}
        group.notify(queue:.main){if !urls.isEmpty{replaceImport=false;pendingImport=RemoteImport(urls:urls,directory:path)}};return true
    }
    func open(_ entry:RemoteEntry){if entry.directory{path=entry.id;refresh()}else{editorPath=entry.id}}
    func destination()->String?{guard !newName.isEmpty,!newName.contains("/"),!newName.contains("\0"),![".",".."].contains(newName) else{m.error="Укажите имя без / и ..";return nil};return URL(fileURLWithPath:path).appendingPathComponent(newName).path}
    func changeName(){guard let target=destination() else{return};let kind=action;action="";if kind=="file"{editorPath=target}else if kind=="folder"{m.perform(["action":"files_mkdir","path":target,"confirmed":true]){_ in refresh()}}else if let current{m.perform(["action":"files_rename","path":current.id,"destination":target,"confirmed":true]){_ in refresh()}}}
    func prepareUpload(){guard !m.isDesignPreview else{m.error="Передача файлов отключена в демонстрации";return};let panel=NSOpenPanel();panel.canChooseDirectories=false;guard panel.runModal() == .OK,let local=panel.url else{return};uploadFile=local;uploadTarget=URL(fileURLWithPath:path).appendingPathComponent(local.lastPathComponent).path;m.perform(["action":"files_stat","path":uploadTarget]){let r=$0 as? [String:Any] ?? [:];uploadTarget=r["path"] as? String ?? uploadTarget;uploadHash=r["hash"] as? String ?? "absent";if r["exists"] as? Bool==true{confirmUpload=true}else{startUpload()};m.result=""}}
    func startUpload(){guard let server=m.current,let uploadFile else{return};m.transfer.upload(server:server,local:uploadFile,remote:uploadTarget,hash:uploadHash){if m.selectedID==server.id{refresh()}}}
    func download(){guard let server=m.current,let current,!m.isDesignPreview else{return};let panel=NSSavePanel();panel.nameFieldStringValue=current.name;guard panel.runModal() == .OK,let local=panel.url else{return};m.transfer.download(server:server,remote:current.id,local:local){}}
}
struct FileTransferView:View {
    @ObservedObject var transfer:FileTransfer
    let serverID:String
    var body:some View{if transfer.serverID==serverID && (!transfer.status.isEmpty || transfer.error != nil){VStack(alignment:.leading,spacing:8){HStack{Text(transfer.error ?? transfer.status).foregroundStyle(transfer.error==nil ? BackupTheme.muted:.orange);Spacer();if transfer.running{Button("Отменить"){transfer.cancel()}}};if transfer.running{ProgressView(value:transfer.progress)}}.padding(12).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))}}
}
struct RemoteFileEditor:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let path:String
    let onSaved:()->Void
    @State private var actualPath=""
    @State private var content=""
    @State private var original=""
    @State private var hash=""
    @State private var confirmSave=false
    @State private var confirmClose=false
    @State private var unit=""
    var body:some View{VStack(alignment:.leading,spacing:14){HStack{WorkspaceIntro(title:"Редактор файла",detail:actualPath.isEmpty ? path:actualPath,icon:"doc.text");Spacer();Button("Закрыть"){if content != original{confirmClose=true}else{dismiss()}}}
        if let error=m.error{Text(error).foregroundStyle(.orange).font(.caption)}
        TextEditor(text:$content).font(.system(size:13,design:.monospaced)).scrollContentBackground(.hidden).padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:10)).disabled(hash.isEmpty || m.busy)
        Text(unit.isEmpty ? "Перед записью сохраняется предыдущая версия. Проверка синтаксиса для произвольного файла не выполняется.":"Файл конфигурации службы: сохранение выполняется со штатной проверкой, если она доступна.").font(.caption).foregroundStyle(BackupTheme.muted)
        if !hash.isEmpty{DisclosureGroup("История версий"){if unit.isEmpty{RemoteFileHistory(path:actualPath,current:original,hash:hash,reload:load)}else{ConfigHistoryView(unit:unit,path:actualPath,current:original,hash:hash,onRestored:load)}}.disabled(content != original || m.busy)}
        HStack{Button("Загрузить заново"){load()}.disabled(m.busy);Spacer();if content != original{StatusBadge(title:"Не сохранено",color:.orange)};Button("Сохранить на сервер"){confirmSave=true}.buttonStyle(BackupPrimaryButtonStyle()).disabled(hash.isEmpty || (content==original && hash != "absent") || m.busy)}
    }.padding(24).frame(width:1000,height:740).onAppear{load()}.interactiveDismissDisabled(content != original).confirmationDialog("Сохранить файл на сервере?",isPresented:$confirmSave){Button("Сохранить"){m.perform(["action":"files_write","path":actualPath,"content":content,"hash":hash,"confirmed":true]){let r=$0 as? [String:Any] ?? [:];hash=r["hash"] as? String ?? hash;original=content;m.result="";onSaved()}}}.confirmationDialog("Закрыть без сохранения изменений?",isPresented:$confirmClose){Button("Закрыть без сохранения",role:.destructive){dismiss()}}}
    func load(){m.perform(["action":"files_read","path":actualPath.isEmpty ? path:actualPath]){let r=$0 as? [String:Any] ?? [:];actualPath=r["path"] as? String ?? path;content=r["content"] as? String ?? "";original=content;hash=r["hash"] as? String ?? "";unit=r["unit"] as? String ?? "";m.result=""}}
}
struct RemoteFileHistory:View {
    @EnvironmentObject var m:Model
    let path:String;let current:String;let hash:String;let reload:()->Void
    @State private var versions:[[String:Any]]=[]
    @State private var chosen=""
    @State private var prior=""
    @State private var loaded=false
    @State private var confirm=false
    var body:some View{VStack(alignment:.leading,spacing:10){Button("Загрузить историю"){m.perform(["action":"files_versions","path":path]){versions=($0 as? [String:Any])?["versions"] as? [[String:Any]] ?? [];m.result=""}};Picker("Версия",selection:$chosen){Text("Выберите").tag("");ForEach(versions.indices,id:\.self){i in Text(backupTime(versions[i]["time"] as? String)).tag(versions[i]["id"] as? String ?? "")}}.onChange(of:chosen){_,id in loaded=false;if !id.isEmpty{m.perform(["action":"files_version","path":path,"version_id":id]){prior=($0 as? [String:Any])?["content"] as? String ?? "";loaded=true;m.result=""}}};if loaded{ScrollView([.horizontal,.vertical]){Text(diff).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}.frame(height:120);Button("Вернуть версию"){confirm=true}}}.confirmationDialog("Вернуть выбранную версию файла?",isPresented:$confirm){Button("Вернуть"){m.perform(["action":"files_rollback","path":path,"version_id":chosen,"hash":hash,"confirmed":true]){_ in reload()}}}}
    var diff:String{current.components(separatedBy:"\n").difference(from:prior.components(separatedBy:"\n")).map{switch $0{case .remove(_,let line,_):return "− "+line;case .insert(_,let line,_):return "+ "+line}}.joined(separator:"\n")}
}
struct RemoteTrashView:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let onChanged:()->Void
    @State private var items:[[String:Any]]=[]
    @State private var chosen:String?
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Text("Корзина сервера").font(.title2);Spacer();Button("Закрыть"){dismiss()}};List(items.indices,id:\.self){i in HStack{VStack(alignment:.leading){Text(items[i]["path"] as? String ?? "");Text(backupTime(items[i]["time"] as? String)).font(.caption)};Spacer();Button("Вернуть"){chosen=items[i]["id"] as? String}}};Text("Возврат не перезаписывает существующий файл. Окончательное удаление через приложение не выполняется.").font(.caption).foregroundStyle(BackupTheme.muted)}.padding(24).frame(width:760,height:500).onAppear{load()}.confirmationDialog("Вернуть файл из корзины?",isPresented:Binding(get:{chosen != nil},set:{if !$0{chosen=nil}})){Button("Вернуть"){guard let chosen else{return};m.perform(["action":"files_untrash","id":chosen,"confirmed":true]){_ in self.chosen=nil;load();onChanged()}}}}
    func load(){m.perform(["action":"files_trash_list"]){items=($0 as? [String:Any])?["items"] as? [[String:Any]] ?? [];m.result=""}}
}
