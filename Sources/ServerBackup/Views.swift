import SwiftUI
import AppKit

func lines(_ s:String)->[String]{s.split(separator:"\n").map{String($0).trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}}
func fieldID(_ value:String)->Bool{value.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil}
struct StorageView:View {
    @EnvironmentObject var m:Model
    @State var id="storage-01";@State var type="s3";@State var password="";@State var path="/srv/restic/server-01";@State var host="";@State var user="backup";@State var port=22;@State var mount="";@State var uuid="";@State var endpoint="";@State var bucket="";@State var prefix="server-01";@State var region="us-east-1";@State var access="";@State var secret=""
    @State var capacityGB=0.0
    @State var trackCapacity=true
    @StateObject private var yandexLogin=YandexLogin()
    @State var yandexToken=""
    @State var yandexPath="ServerBackup/server-01"
    @State var yandexQuota=""
    @State private var editingStorage=false
    @State private var editingExistingStorage=false
    @State private var draftServerID=""
    @State var installRclone=false
    @State var trustScan:[String:Any]=[:];@State var initialize=false;@State var publicKey="";@State var storageServerID="";@State var authorizeKey=false
    var body:some View{VStack(alignment:.leading,spacing:18){
        WorkspaceIntro(title:"Куда сохранять копии",detail:"Подключите хранилище к выбранному серверу. Копии будут зашифрованы Restic.",icon:"externaldrive")
        HStack{Text("Хранилища сервера").font(.headline);Spacer();Button("Добавить хранилище",systemImage:"plus"){newStorage()}}
        if !m.repositories.isEmpty{BackupPanel(title:"Подключённые хранилища",icon:"checkmark.circle"){
            ForEach(m.repositories.indices,id: \.self){i in let r=m.repositories[i];HStack(spacing:12){Image(systemName:storageIcon(r["type"] as? String ?? "")).foregroundStyle(BackupTheme.blue);VStack(alignment:.leading,spacing:5){Text(r["id"] as? String ?? "").font(.headline);Text(r["repository"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted).lineLimit(1)};Spacer();StatusBadge(title:"Подключено",color:.green);Button("Изменить"){if load(r["id"] as? String ?? ""){editingStorage=true;editingExistingStorage=true}}}}
        }}
        if editingStorage{
        HStack{Text(editingExistingStorage ? "Изменение подключения":"Новое хранилище").font(.headline);Spacer();Button("Закрыть настройки"){persistDraft();editingStorage=false}}
        HStack(alignment:.top,spacing:18){
            BackupPanel(title:"Подключение хранилища",icon:"plus.circle"){
                HStack(spacing:8){storageChoice("disk","Диск / каталог","externaldrive");storageChoice("sftp","Другой сервер","server.rack");storageChoice("s3","Облако S3","cloud");storageChoice("yandex","Яндекс Диск","cloud.fill")}
                FieldLabel(title:"Название хранилища"){TextField("Например, storage-01",text:$id).disabled(editingExistingStorage)}
                if type=="yandex"{yandexFields}else if type=="s3"{s3Fields}else if type=="sftp"{sftpFields}else{diskFields}
                if ["s3","sftp"].contains(type){FieldLabel(title:"Доступный объём, ГБ · 0 неизвестен"){TextField("0",value:$capacityGB,format:.number)}}
                Toggle("Записывать размер после успешных копий",isOn:$trackCapacity)
                Divider();FieldLabel(title:"Пароль шифрования резервных копий"){SecureField("Пароль Restic",text:$password)}
                Text("Задайте пароль для нового репозитория или введите пароль существующего.").font(.caption).foregroundStyle(BackupTheme.muted)
                HStack{Button("Подключить существующее"){save(false)}.buttonStyle(BackupPrimaryButtonStyle());Button("Создать новое"){initialize=true}}
            }.disabled(m.busy)
            VStack(spacing:18){BackupPanel(title:"Порядок подключения",icon:"list.number"){
                help("1", "Выберите место хранения", "Диск сервера, SFTP, S3 или Яндекс Диск.")
                help("2", "Укажите доступы", "Приложение проверит доступ и пароль репозитория.")
                help("3", "Подключите или создайте", "Для пустого хранилища создайте новый репозиторий.")
            };BackupPanel(title:"Дальше — задание",icon:"calendar"){
                Text("После подключения выберите файлы и ежедневное расписание.").font(.callout).foregroundStyle(BackupTheme.muted)
                Button("Перейти к заданиям"){m.section="Задания"}.disabled(m.repositories.isEmpty || m.busy)
            };Text("Сохраните пароль шифрования отдельно или экспортируйте профили.").font(.caption).foregroundStyle(BackupTheme.muted).padding(.horizontal,4)
            }.frame(width:270)
        }
        }else if m.repositories.isEmpty{BackupPanel(title:"Хранилище ещё не подключено",icon:"externaldrive.badge.plus"){Text("Нажмите «Добавить хранилище», выберите тип и укажите доступы.")}}
        ResultView()
    }.textFieldStyle(.roundedBorder).onAppear{draftServerID=m.selectedID ?? "";let draft=StorageDrafts.read(serverID:draftServerID,preview:m.isDesignPreview);if !draft.isEmpty{apply(draft)}}.onDisappear{persistDraft()}.onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in persistDraft()}.confirmationDialog("Подготовить Яндекс Диск: установить rclone и обновить серверный помощник?",isPresented:$installRclone){Button("Подготовить"){m.perform(["action":"install_rclone"]){_ in m.loadProbe()}}}.confirmationDialog("Установить публичный ключ и подготовить пользователя/каталог хранилища?",isPresented:$authorizeKey){Button("Установить ключ"){guard let server=m.servers.first(where:{$0.id==storageServerID}) else{m.error="Выберите SSH-профиль сервера хранения";return};m.perform(["action":"authorize_storage_key","public_key":publicKey,"user":user,"path":path,"confirmed":true],server:server)}}.confirmationDialog("Создать новый зашифрованный репозиторий?",isPresented:$initialize){Button("Создать"){save(true)}}}
    var yandexFields:some View{VStack(alignment:.leading,spacing:14){
        FieldLabel(title:"Папка на Яндекс Диске"){TextField("ServerBackup/server-01",text:$yandexPath)}
        HStack{Button(yandexLogin.running ? "Ожидание входа…":"Войти в Яндекс через браузер"){if !m.isDesignPreview{yandexLogin.start{yandexToken=$0;m.error=nil;persistDraft()}}}.buttonStyle(BackupPrimaryButtonStyle()).disabled(yandexLogin.running);if yandexLogin.running{Button("Отменить"){yandexLogin.cancel()}}}
        if !yandexLogin.message.isEmpty{Text(yandexLogin.message).font(.caption).foregroundStyle(BackupTheme.muted)}
        FieldLabel(title:"OAuth-токен Яндекс Диска"){SecureField("Полный JSON из rclone authorize",text:$yandexToken)}
        if !yandexToken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{StatusBadge(title:yandexQuota.isEmpty ? "Токен получен · проверьте доступ с сервера":"Токен получен",color:BackupTheme.blue)}
        Text("Нужен полный JSON с access_token и refresh_token, с правами чтения и записи. Пароль аккаунта сюда вводить не нужно.").font(.caption).foregroundStyle(BackupTheme.muted)
        DisclosureGroup("Как получить токен"){VStack(alignment:.leading,spacing:8){Text("На компьютере с rclone выполните команду, войдите в Яндекс в открывшемся браузере и скопируйте выданный JSON в поле токена.");Text("rclone authorize yandex").font(.system(.caption,design:.monospaced)).textSelection(.enabled);Link("Инструкция rclone для Яндекс Диска",destination:URL(string:"https://rclone.org/yandex/")!)}}.font(.caption)
        HStack{StatusBadge(title:m.tools["rclone"] as? String ?? "rclone не установлен",color:m.tools["rclone"] as? String != nil ? .green:.orange);Button("Подготовить Яндекс Диск"){installRclone=true}}
        Text("Перед первым сохранением нажмите «Подготовить Яндекс Диск», чтобы обновить помощник для автономных заданий.").font(.caption).foregroundStyle(BackupTheme.muted)
        Button("Проверить доступ и свободное место"){guard validateYandex() else{return};persistDraft();m.perform(["action":"yandex_check","repository":value()]){response in let r=response as? [String:Any] ?? [:];let quota=r["quota"] as? [String:Any] ?? [:];yandexQuota="Доступ подтверждён";if let free=quota["free"] as? Int64{yandexQuota += " · свободно "+ByteCountFormatter.string(fromByteCount:free,countStyle:.binary)};m.result=""}}.disabled(yandexToken.isEmpty || m.tools["rclone"] as? String==nil)
        if !yandexQuota.isEmpty{Text(yandexQuota).font(.caption).foregroundStyle(.green)}
        Text("Копии сохраняются напрямую с сервера. При истечении или отзыве токена замените его. Удалённые файлы могут оставаться в корзине Яндекс Диска и занимать место.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.onDisappear{yandexLogin.cancel()}.onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in yandexLogin.cancel()}.onChange(of:yandexToken){_,_ in yandexQuota="";persistDraft()}.onChange(of:yandexPath){_,_ in yandexQuota=""}}
    var s3Fields:some View{VStack(spacing:14){FieldLabel(title:"Адрес S3"){TextField("https://s3.example.com",text:$endpoint)};HStack{FieldLabel(title:"Бакет"){TextField("backups",text:$bucket)};FieldLabel(title:"Папка сервера в бакете"){TextField("server-01",text:$prefix)}};FieldLabel(title:"Регион"){TextField("us-east-1",text:$region)};FieldLabel(title:"Access key"){SecureField("Ключ доступа",text:$access)};FieldLabel(title:"Secret key"){SecureField("Секретный ключ",text:$secret)}}}
    var diskFields:some View{VStack(alignment:.leading,spacing:14){
        FieldLabel(title:"Каталог на сервере"){TextField("/mnt/backup/restic",text:$path)}
        FieldLabel(title:"Точка подключения диска"){TextField("/mnt/backup",text:$mount)}
        FieldLabel(title:"UUID файловой системы"){TextField("UUID диска",text:$uuid)}
        DisclosureGroup("Выбрать подключённый диск"){ForEach((m.probe["disks"] as? [[String:Any]] ?? []).indices,id: \.self){i in let d=(m.probe["disks"] as! [[String:Any]])[i];Button{mount=d["target"] as? String ?? "";uuid=d["uuid"] as? String ?? "";path=mount+"/restic/"+(m.current?.name ?? "server")}label:{HStack{Image(systemName:"externaldrive");Text(d["target"] as? String ?? "");Spacer();Text("Свободно: \(d["avail"] ?? "—")").font(.caption)}}.buttonStyle(.plain).padding(.vertical,5)}}
        Text("Диск должен быть смонтирован на сервере. UUID проверяется перед записью.").font(.caption).foregroundStyle(BackupTheme.muted)
    }}
    var sftpFields:some View{VStack(alignment:.leading,spacing:14){
        HStack{FieldLabel(title:"Сервер хранения"){TextField("backup.example.com",text:$host)};FieldLabel(title:"SSH-порт"){TextField("22",value:$port,format:.number)}.frame(width:90)}
        FieldLabel(title:"Пользователь"){TextField("backup",text:$user)};FieldLabel(title:"Каталог на сервере хранения"){TextField("/srv/restic/server-01",text:$path)}
        HStack{Button("Создать ключ"){m.perform(["action":"sftp_key","repository_id":id]){publicKey=($0 as? [String:Any])?["public_key"] as? String ?? ""}};Button("Проверить SSH-ключ сервера"){m.perform(["action":"sftp_scan","host":host,"port":port]){trustScan=$0 as? [String:Any] ?? [:]}}}
        if !publicKey.isEmpty{DisclosureGroup("Установить публичный ключ"){VStack(alignment:.leading,spacing:12){Text(publicKey).font(.system(.caption,design:.monospaced)).textSelection(.enabled);Picker("Профиль сервера хранения",selection:$storageServerID){Text("Выберите сервер").tag("");ForEach(m.servers){Text($0.name).tag($0.id)}};Button("Установить ключ и подготовить каталог"){authorizeKey=true};Text("Либо добавьте ключ в authorized_keys пользователя сервера хранения.").font(.caption).foregroundStyle(BackupTheme.muted)}}}
        if !trustScan.isEmpty{Text(trustScan["fingerprints"] as? String ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled);Button("Подтвердить отпечаток"){m.perform(["action":"sftp_trust","repository_id":id,"known_hosts":trustScan["known_hosts"] ?? "","confirmed":true])}}
    }}
    func newStorage(){id="storage-"+String(m.repositories.count+1);while m.repositories.contains(where:{$0["id"] as? String==id}){id+="-new"};path="/srv/restic/"+id;yandexPath="ServerBackup/"+id;prefix=id;password="";host="";endpoint="";bucket="";access="";secret="";yandexToken="";yandexQuota="";publicKey="";trustScan=[:];mount="";uuid="";storageServerID="";editingExistingStorage=false;editingStorage=true;persistDraft()}
    func storageChoice(_ value:String,_ title:String,_ image:String)->some View{Button{type=value}label:{VStack(spacing:8){Image(systemName:image).font(.title3);Text(title).font(.caption.weight(.medium))}.frame(maxWidth:.infinity).padding(.vertical,14).foregroundStyle(type==value ? .white:BackupTheme.muted).background(type==value ? BackupTheme.blue.opacity(0.25):BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(type==value ? BackupTheme.blue:BackupTheme.border))}.buttonStyle(.plain)}
    func storageIcon(_ type:String)->String{["s3","yandex"].contains(type) ? "cloud":type=="sftp" ? "server.rack":"externaldrive"}
    func help(_ number:String,_ title:String,_ detail:String)->some View{HStack(alignment:.top,spacing:12){Text(number).foregroundStyle(BackupTheme.blue).font(.headline);VStack(alignment:.leading,spacing:5){Text(title).font(.callout.bold());Text(detail).font(.caption).foregroundStyle(BackupTheme.muted)}}}
    func value()->[String:Any]{var r:[String:Any]=["id":id,"type":type,"password":password,"capacity_bytes":max(0,capacityGB)*1_000_000_000,"track_capacity":trackCapacity]
        if type=="yandex"{r.merge(["repository":"rclone:yandex:"+yandexPath,"path":yandexPath,"token":yandexToken]){_,n in n}}
        else if type=="s3"{r.merge(["repository":"s3:"+endpoint.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/"+bucket+"/"+prefix,"endpoint":endpoint,"bucket":bucket,"prefix":prefix,"region":region,"access_key":access,"secret_key":secret]){_,n in n}}
        else if type=="sftp"{r.merge(["repository":"sftp:sb-"+id+":"+path,"host":host,"port":port,"user":user,"path":path]){_,n in n}}
        else{r.merge(["repository":path,"mount":mount,"uuid":uuid]){_,n in n}};return r}
    func save(_ initRepo:Bool){guard fieldID(id),!password.isEmpty else{m.error="Укажите ID без пробелов и пароль шифрования";return};if type=="s3" && (!endpoint.hasPrefix("https://") || bucket.isEmpty || access.isEmpty || secret.isEmpty){m.error="Укажите HTTPS endpoint, бакет и ключи S3";return};if type=="yandex" && !validateYandex(){return};let r=value();do{try Vault.put("repo-"+(m.selectedID ?? "")+"-"+id,r);m.perform(["action":"save_repository","repository":r,"initialize":initRepo,"confirmed":initRepo]){_ in editingStorage=false;m.loadProbe()}}catch{m.error=error.localizedDescription}}
    func validateYandex()->Bool{if yandexPath.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{m.error="Укажите папку на Яндекс Диске";return false};if yandexToken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{m.error="OAuth-токен отсутствует. Войдите в Яндекс через браузер или вставьте токен.";return false};return true}
    func persistDraft(){guard !draftServerID.isEmpty else{return};do{try StorageDrafts.save(draftValue(),serverID:draftServerID,preview:m.isDesignPreview)}catch{m.error="Не удалось сохранить форму хранилища в Keychain: "+error.localizedDescription}}
    func draftValue()->[String:Any]{["id":id,"type":type,"password":password,"path":path,"host":host,"user":user,"port":port,"mount":mount,"uuid":uuid,"endpoint":endpoint,"bucket":bucket,"prefix":prefix,"region":region,"access_key":access,"secret_key":secret,"capacity_bytes":max(0,capacityGB)*1_000_000_000,"track_capacity":trackCapacity,"token":yandexToken,"yandex_path":yandexPath,"yandex_quota":yandexQuota,"storage_server_id":storageServerID,"public_key":publicKey,"trust_scan":trustScan]}
    func load(_ id:String)->Bool{let r=Vault.dictionary("repo-"+(m.selectedID ?? "")+"-"+id);guard !r.isEmpty else{m.error="Секреты этого репозитория отсутствуют в Keychain. Импортируйте экспорт профилей.";return false};apply(r);persistDraft();return true}
    func apply(_ r:[String:Any]){self.id=r["id"] as? String ?? "storage-01";trackCapacity=r["track_capacity"] as? Bool ?? false;capacityGB=(r["capacity_bytes"] as? Double ?? 0)/1_000_000_000;yandexToken=r["token"] as? String ?? "";yandexPath=r["yandex_path"] as? String ?? (r["type"] as? String=="yandex" ? r["path"] as? String:nil) ?? "ServerBackup/server-01";yandexQuota=r["yandex_quota"] as? String ?? "";storageServerID=r["storage_server_id"] as? String ?? "";publicKey=r["public_key"] as? String ?? "";trustScan=r["trust_scan"] as? [String:Any] ?? [:];type=r["type"] as? String ?? "s3";password=r["password"] as? String ?? "";path=r["path"] as? String ?? r["repository"] as? String ?? "";host=r["host"] as? String ?? "";user=r["user"] as? String ?? "backup";port=r["port"] as? Int ?? 22;mount=r["mount"] as? String ?? "";uuid=r["uuid"] as? String ?? "";endpoint=r["endpoint"] as? String ?? "";bucket=r["bucket"] as? String ?? "";prefix=r["prefix"] as? String ?? "";region=r["region"] as? String ?? "us-east-1";access=r["access_key"] as? String ?? "";secret=r["secret_key"] as? String ?? ""}
}
struct BrowserView:View {
    @EnvironmentObject var m:Model;@Environment(\.dismiss)var dismiss
    @State var path="/";@State var entries:[[String:Any]]=[]
    let choose:(String)->Void
    var body:some View{VStack(alignment:.leading){Text("Файлы и каталоги сервера").font(.title2);HStack{TextField("Путь",text:$path);Button("Открыть"){browse()};Button("Выше"){path=URL(fileURLWithPath:path).deletingLastPathComponent().path;browse()}}
        List(entries.indices,id:\.self){i in let e=entries[i];HStack{Image(systemName:e["directory"] as? Bool==true ? "folder":"doc");Text(e["name"] as? String ?? "");Spacer();if e["directory"] as? Bool==true{Button("Открыть"){path=e["path"] as? String ?? "/";browse()}};Button("Выбрать"){choose(e["path"] as? String ?? "/");dismiss()}}}
        HStack{Button("Отмена"){dismiss()};Spacer();Button("Выбрать текущий каталог"){choose(path);dismiss()}}
    }.padding(20).frame(width:750,height:560).onAppear{browse()}}
    func browse(){m.perform(["action":"browse","path":path]){entries=$0 as? [[String:Any]] ?? []}}
}
struct JobsView:View {
    @EnvironmentObject var m:Model
    @State private var jobName=""
    @State private var verifyRestore=false
    @State private var verifyFull=false
    @State private var replicas=Set<String>()
    @State var id="daily";@State var repo="";@State var sources="";@State var excludes="";@State var time="03:00";@State var daily=14;@State var weekly=4;@State var limit=0;@State var concurrency=2;@State var enabled=true
    @State var databaseIDs=Set<String>();@State var selection:[String:String]=[:];@State var acknowledge=false;@State var browse=false;@State var confirmRun=false
    @State var includeDatabases=false
    @State var includeDocker=false
    @State var savedSignature=""
    @State private var filesystemsExpanded=false
    @State private var performanceExpanded=false
    @State private var confirmResticUpdate=false
    @State private var draftServerID=""
    @State private var creating=false
    @State private var editing=false
    var fingerprint:String{Model.pretty(jobValue())}
    var canRun:Bool{!savedSignature.isEmpty && savedSignature==fingerprint && m.jobs.contains{$0["id"] as? String==id}}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{WorkspaceIntro(title:"Задания резервного копирования",detail:"Выберите данные, хранилище и расписание",icon:"calendar");Button("Обновить"){m.loadProbe()}.disabled(m.busy);Button("Новое задание",systemImage:"plus"){newJob()};if editing || creating{Button("Закрыть настройку"){editing=false;creating=false}}}
        if !m.jobs.isEmpty{ScrollView(.horizontal){HStack(spacing:12){ForEach(m.jobs.indices,id: \.self){i in let j=m.jobs[i];Button{load(j)}label:{VStack(alignment:.leading,spacing:8){HStack{Image(systemName:"calendar").foregroundStyle(BackupTheme.blue);Text(j["name"] as? String ?? j["id"] as? String ?? "").font(.headline);Spacer();StatusBadge(title:j["enabled"] as? Bool != false ? "По расписанию":"Выключено",color:j["enabled"] as? Bool != false ? .green:BackupTheme.muted)};Text("Ежедневно в \(j["time"] ?? "03:00") · \(j["repository_id"] ?? "")").font(.caption).foregroundStyle(BackupTheme.muted);Text("Источников: \((j["sources"] as? [String] ?? []).count)").font(.caption).foregroundStyle(BackupTheme.muted)}.padding(16).frame(width:290).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(editing && id==j["id"] as? String ? BackupTheme.blue:BackupTheme.border))}.buttonStyle(.plain)}}}}
        if creating{BackupPanel(title:"1. Выберите хранилище",icon:"externaldrive"){
            Picker("Куда сохранять копии",selection:$repo){Text("Выберите хранилище").tag("");ForEach(m.repositories.indices,id:\.self){i in Text(m.repositories[i]["id"] as? String ?? "").tag(m.repositories[i]["id"] as? String ?? "")}}
            if m.repositories.isEmpty{Button("Подключить хранилище"){m.section="Хранилища"}}
        }}
        if (editing || creating) && !repo.isEmpty{
        HStack(alignment:.top,spacing:18){
            VStack(spacing:18){BackupPanel(title:"Что сохранять",subtitle:"Отметьте папки или файлы на сервере",icon:"folder"){
                DirectorySelector(sources:$sources)
                ClickableDisclosure(title:"Добавить файловую систему",isExpanded:$filesystemsExpanded){ForEach(availableDisks.indices,id: \.self){i in let d=availableDisks[i];Button("Добавить \(d["target"] ?? "")"){let p=d["target"] as? String ?? "";if !lines(sources).contains(p){sources=([sources,p].filter{!$0.isEmpty}).joined(separator:"\n")}}};Text("Выбор / не включает остальные диски автоматически.").font(.caption).foregroundStyle(BackupTheme.muted)}
            };BackupPanel(title:"Исключения",subtitle:"Пути или маски — по одному в строке",icon:"line.3.horizontal.decrease.circle"){
                TextEditor(text:$excludes).font(.system(.caption,design:.monospaced)).frame(height:80).scrollContentBackground(.hidden).padding(8).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))
                Text("Системные временные каталоги и файлы работающих БД исключаются автоматически.").font(.caption).foregroundStyle(BackupTheme.muted)
            };databaseSelection;dockerSelection
            }
            VStack(spacing:18){BackupPanel(title:"Настройки задания",icon:"slider.horizontal.3"){
                FieldLabel(title:"Название задания"){TextField("Ежедневная копия сайтов",text:$jobName)}
                FieldLabel(title:"Технический ID"){TextField("daily",text:$id).disabled(editing)}
                if editing,let job=m.jobs.first(where:{$0["id"] as? String==id}){JobManagementView(job:job)}
                Text("Дополнительные направления").font(.callout.bold())
                ForEach(m.repositories.indices,id:\.self){i in let r=m.repositories[i];let rid=r["id"] as? String ?? "";if rid != repo{Toggle(r["name"] as? String ?? rid,isOn:Binding(get:{replicas.contains(rid)},set:{if $0{replicas.insert(rid)}else{replicas.remove(rid)}}))}}
                Text("После основной копии снимок копируется в выбранные хранилища. Результат каждого направления доступен в журнале.").font(.caption).foregroundStyle(BackupTheme.muted)
                Text("Хранилище: "+repo).font(.caption).foregroundStyle(BackupTheme.muted)
                if m.repositories.isEmpty{Button("Подключить хранилище"){m.section="Хранилища"}}
                Divider();Toggle("Ежедневный запуск",isOn:$enabled)
                FieldLabel(title:"Время по часовому поясу сервера"){TextField("03:00",text:$time)}
                Text("Часовой пояс: \(m.probe["timezone"] as? String ?? "не проверен")").font(.caption).foregroundStyle(BackupTheme.muted)
                Divider();Text("Сколько копий хранить").font(.callout.bold())
                HStack{FieldLabel(title:"Ежедневных"){TextField("14",value:$daily,format:.number)};FieldLabel(title:"Еженедельных"){TextField("4",value:$weekly,format:.number)}}
                Text("Очистка и проверка структуры — по воскресеньям после успешного бэкапа.").font(.caption).foregroundStyle(BackupTheme.muted)
                ClickableDisclosure(title:"Скорость и производительность",isExpanded:$performanceExpanded){VStack(spacing:12){FieldLabel(title:"Лимит отправки, KiB/s · 0 без лимита"){TextField("0",value:$limit,format:.number)};FieldLabel(title:"Параллельное чтение"){TextField("2",value:$concurrency,format:.number).disabled(m.probe["restic_read_concurrency"] as? Bool==false)};if m.probe["restic_read_concurrency"] as? Bool==false{Text("В этой версии Restic используется стандартный параллелизм. Для изменения обновите Restic.").font(.caption).foregroundStyle(BackupTheme.muted)}}.padding(.top,10)}
                Button{save()}label:{Label("Сохранить задание",systemImage:"checkmark")}.buttonStyle(BackupPrimaryButtonStyle()).controlSize(.large).disabled(m.busy || repo.isEmpty || lines(sources).isEmpty)
            };BackupPanel(title:"Запуск",subtitle:canRun ? "Задание сохранено и готово к запуску":"Сначала сохраните выбранные настройки",icon:"play.circle"){
                if m.probe["restic_dry_run"] as? Bool==false || m.probe["restic_read_concurrency"] as? Bool==false{Text("Установленный Restic поддерживает не все параметры задания. Обновление включит недостающие возможности.").font(.caption).foregroundStyle(.orange);Button("Обновить Restic"){confirmResticUpdate=true}}
                Button("Пробный запуск без записи"){m.perform(["action":"start_job","job_id":id,"dry_run":true])}.disabled(m.busy || !canRun || m.probe["restic_dry_run"] as? Bool==false)
                Button{confirmRun=true}label:{Label("Запустить сейчас",systemImage:"play.fill")}.buttonStyle(BackupPrimaryButtonStyle()).controlSize(.large).disabled(m.busy || !canRun)
            }
            }.frame(width:305)
        }
        }else if !creating{BackupPanel(title:"Выберите задание",icon:"calendar"){Text("Нажмите на карточку задания, чтобы открыть его данные, расписание и настройки.").foregroundStyle(BackupTheme.muted)}}
        ResultView()
    }.textFieldStyle(.roundedBorder).confirmationDialog("Запустить задание? Выбранные контейнеры могут быть временно остановлены.",isPresented:$confirmRun){Button("Запустить"){m.perform(["action":"start_job","job_id":id])}}.confirmationDialog("Обновить Restic с официального сервера и серверный помощник?",isPresented:$confirmResticUpdate){Button("Обновить"){m.perform(["action":"update_restic","confirmed":true]){_ in m.loadProbe()}}}.onAppear{draftServerID=m.selectedID ?? "";if let draft=m.jobDrafts[draftServerID],draft["draft_creating"] as? Bool==true{load(draft);creating=true;editing=false;savedSignature=draft["draft_signature"] as? String ?? "";includeDatabases=draft["draft_databases"] as? Bool ?? includeDatabases;includeDocker=draft["draft_docker"] as? Bool ?? includeDocker}else{editing=false;creating=false;repo=""}}.onDisappear{var draft=jobValue();draft["draft_creating"]=creating;draft["draft_signature"]=savedSignature;draft["draft_databases"]=includeDatabases;draft["draft_docker"]=includeDocker;if !draftServerID.isEmpty && (editing || creating){m.jobDrafts[draftServerID]=draft}}}
    var availableDisks:[[String:Any]]{(m.probe["disks"] as? [[String:Any]] ?? []).filter{!($0["uuid"] as? String ?? "").isEmpty || $0["target"] as? String=="/"}}
    var databaseSelection:some View{BackupPanel(title:"Базы данных",subtitle:"Необязательно · согласованные дампы",icon:"cylinder.split.1x2"){
        Toggle("Включить базы в задание",isOn:$includeDatabases)
        if includeDatabases{if m.databases.isEmpty{Text("Сначала добавьте подключение к базе.").font(.caption).foregroundStyle(BackupTheme.muted)};ForEach(m.databases.indices,id: \.self){i in let db=m.databases[i];let key=db["id"] as? String ?? "";Toggle(key+" · "+(db["engine"] as? String ?? ""),isOn:Binding(get:{databaseIDs.contains(key)},set:{if $0{databaseIDs.insert(key)}else{databaseIDs.remove(key)}}))};Button("Подключить базу данных"){m.section="Базы данных"}}
    }}
    var dockerSelection:some View{BackupPanel(title:"Docker",subtitle:"Необязательно · контейнеры и тома",icon:"shippingbox"){
        Toggle("Включить Docker в задание",isOn:$includeDocker)
        if includeDocker{Button("Обнаружить контейнеры"){m.perform(["action":"docker"]){m.containers=$0 as? [[String:Any]] ?? []}}.disabled(m.busy)
            ForEach(m.containers.indices,id: \.self){i in let c=m.containers[i];let name=c["name"] as? String ?? "";Picker(name,selection:Binding(get:{selection[name] ?? "skip"},set:{selection[name]=$0})){Text("Не включать").tag("skip");Text("Дамп БД").tag("dump");Text("Остановить на время копии").tag("stop");Text("Копировать работающий").tag("live")}}
            if selection.values.contains("live"){Toggle("Понимаю: работающий контейнер может дать несогласованную копию",isOn:$acknowledge)}
            Text("Режим «Дамп БД» требует подключения базы из этого контейнера в задании. Остановленные заданием контейнеры запускаются после копирования.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
    }}
    func jobValue()->[String:Any]{let containers=includeDocker ? selection.filter{$0.value != "skip"}.sorted{$0.key<$1.key}.map{["name":$0.key,"mode":$0.value,"acknowledge_inconsistent":acknowledge] as [String:Any]} : [];return ["verify_restore":verifyRestore,"verify_full":verifyFull,"name":jobName.isEmpty ? id:jobName,"replica_ids":Array(replicas).sorted(),"id":id,"repository_id":repo,"sources":lines(sources),"excludes":lines(excludes),"time":time,"daily":daily,"weekly":weekly,"limit_upload":limit,"read_concurrency":concurrency,"enabled":enabled,"host_id":m.selectedID ?? "server","database_ids":includeDatabases ? Array(databaseIDs).sorted():[],"containers":containers]}
    func newJob(){verifyRestore=false;verifyFull=false;jobName="";replicas=[];editing=false;creating=true;id="daily-"+String(m.jobs.count+1);while m.jobs.contains(where:{$0["id"] as? String==id}){id+="-new"};repo="";sources="";excludes="";time="03:00";daily=14;weekly=4;limit=0;concurrency=2;enabled=true;databaseIDs=[];selection=[:];acknowledge=false;includeDatabases=false;includeDocker=false;savedSignature=""}
    func save(){guard fieldID(id),fieldID(repo) else{m.error="Название должно содержать латинские буквы, цифры, дефис или подчёркивание";return};guard !lines(sources).isEmpty else{m.error="Выберите папки или файлы";return};if includeDatabases && databaseIDs.isEmpty{m.error="Выберите базы для дампа или выключите включение баз";return};if includeDocker && selection.values.contains("live") && !acknowledge{m.error="Подтвердите режим копирования работающего контейнера";return};let j=jobValue();m.perform(["action":"save_job","job":j]){_ in savedSignature=Model.pretty(j);creating=false;editing=true}}
    func load(_ j:[String:Any]){verifyRestore=j["verify_restore"] as? Bool ?? false;verifyFull=j["verify_full"] as? Bool ?? false;jobName=j["name"] as? String ?? j["id"] as? String ?? "";replicas=Set(j["replica_ids"] as? [String] ?? []);editing=true;creating=false;id=j["id"] as? String ?? "";repo=j["repository_id"] as? String ?? "";sources=(j["sources"] as? [String] ?? []).joined(separator:"\n");excludes=(j["excludes"] as? [String] ?? []).joined(separator:"\n");time=j["time"] as? String ?? "03:00";daily=j["daily"] as? Int ?? 14;weekly=j["weekly"] as? Int ?? 4;limit=j["limit_upload"] as? Int ?? 0;concurrency=j["read_concurrency"] as? Int ?? 2;enabled=j["enabled"] as? Bool ?? true;databaseIDs=Set(j["database_ids"] as? [String] ?? []);includeDatabases = !databaseIDs.isEmpty;includeDocker = !(j["containers"] as? [[String:Any]] ?? []).isEmpty;acknowledge=false;selection=[:];for c in j["containers"] as? [[String:Any]] ?? []{selection[c["name"] as? String ?? ""]=c["mode"] as? String ?? "skip";if c["acknowledge_inconsistent"] as? Bool==true{acknowledge=true}};savedSignature=fingerprint}
}
struct DatabasesView:View {
    @EnvironmentObject var m:Model
    @State var id="database-01";@State var engine="mysql";@State var host="localhost";@State var port=3306;@State var user="root";@State var password="";@State var container="";@State var names="";@State var consistency="transaction";@State var peer=false
    @State var discovery:[String:Any]=[:];@State var installClients=false
    @State var allDatabases=true
    @State private var backupMode="dump"
    @State private var walArchive=""
    @State private var resetChain=false
    @State private var editingDatabase=false
    @State private var editingExistingDatabase=false
    var body:some View{VStack(alignment:.leading,spacing:18){
        WorkspaceIntro(title:"Подключение к базам данных",detail:"Добавьте базы, если нужны согласованные дампы. Затем включите их в задание.",icon:"cylinder.split.1x2")
        HStack{Text("Подключения сервера").font(.headline);Spacer();Button("Добавить подключение",systemImage:"plus"){newDatabase()}}
        if !m.databases.isEmpty{BackupPanel(title:"Сохранённые подключения",icon:"checkmark.circle"){
            ForEach(m.databases.indices,id: \.self){i in let db=m.databases[i];HStack{Image(systemName:"cylinder.split.1x2").foregroundStyle(BackupTheme.blue);Text(db["id"] as? String ?? "").font(.headline);Text(db["engine"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Text((db["container"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? db["host"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted);StatusBadge(title:"Подключено",color:.green);Button("Изменить"){if load(db["id"] as? String ?? ""){editingDatabase=true;editingExistingDatabase=true}}}}
        }}
        if editingDatabase{
        HStack{Text(editingExistingDatabase ? "Изменение подключения":"Новое подключение").font(.headline);Spacer();Button("Закрыть настройки"){editingDatabase=false}}
        HStack(alignment:.top,spacing:18){BackupPanel(title:"Доступ к базе",icon:"key"){
            FieldLabel(title:"Название подключения"){TextField("database-01",text:$id).disabled(editingExistingDatabase)}
            Picker("СУБД",selection:$engine){Text("MySQL").tag("mysql");Text("MariaDB").tag("mariadb");Text("PostgreSQL").tag("postgres")}.pickerStyle(.segmented).onChange(of:engine){_,new in port=new=="postgres" ? 5432:3306;user=new=="postgres" ? "postgres":"root";discovery=[:]}
            HStack{FieldLabel(title:"Адрес базы"){TextField("localhost",text:$host)};FieldLabel(title:"Порт"){TextField("3306",value:$port,format:.number)}.frame(width:100)}
            HStack{FieldLabel(title:"Пользователь"){TextField("root",text:$user)};FieldLabel(title:"Пароль"){SecureField("Пароль",text:$password)}}
            FieldLabel(title:"Docker-контейнер · если база в Docker"){TextField("Оставьте пустым для локальной базы",text:$container)}
            if engine=="postgres"{Toggle("Локальный peer-доступ через runuser",isOn:$peer)}else{FieldLabel(title:"Согласованность дампа"){Picker("",selection:$consistency){Text("Транзакционный · InnoDB").tag("transaction");Text("Блокировка записей · все таблицы").tag("lock")}.labelsHidden()}}
            Button("Проверить подключение и найти базы"){m.perform(["action":"db_discover","database":value()]){discovery=$0 as? [String:Any] ?? [:]}}.buttonStyle(BackupPrimaryButtonStyle()).disabled(m.busy)
            DisclosureGroup("Клиентские инструменты"){Text("Для дампов нужны клиентские утилиты СУБД. В Docker используются утилиты контейнера.").font(.caption).foregroundStyle(BackupTheme.muted);Button("Установить утилиты выбранной СУБД"){installClients=true}.padding(.top,8)}
        };BackupPanel(title:"Выбор баз",subtitle:discovery.isEmpty ? "Проверьте подключение для обнаружения баз":discovery["version"] as? String ?? "Доступ проверен",icon:"checklist"){
            Picker("Режим резервирования",selection:$backupMode){Text("Дамп каждой базы").tag("dump");Text("Базовая копия + изменения").tag("journal")}.onChange(of:backupMode){_,mode in if mode=="journal"{allDatabases=true;names=""}}
            if backupMode=="journal"{Text("Первая копия сохраняет весь сервер БД, следующие — закрытые журналы изменений. Каждый снимок содержит самостоятельную цепочку. Нужен прямой TCP-доступ.").font(.caption).foregroundStyle(BackupTheme.muted)
                if engine=="postgres"{FieldLabel(title:"Каталог WAL-архива на сервере"){TextField("/srv/postgres-wal",text:$walArchive)};Text("Требуются archive_mode=on, wal_level=replica, full_page_writes=on и настроенный archive_command. Приложение не меняет эти параметры и не перезапускает СУБД.").font(.caption).foregroundStyle(.orange)}else{Text("Требуются binlog_format=ROW и права на чтение binlog и FLUSH BINARY LOGS. Сохраняется весь сервер БД.").font(.caption).foregroundStyle(.orange)}
                if editingExistingDatabase{Button("Создать новую базовую копию при следующем бэкапе"){resetChain=true}}
            }
            Toggle("Все доступные базы",isOn:$allDatabases).disabled(backupMode=="journal")
            if !allDatabases{if let discovered=discovery["databases"] as? [String],!discovered.isEmpty{ForEach(discovered,id: \.self){name in Toggle(name,isOn:Binding(get:{lines(names).contains(name)},set:{include in var selected=lines(names);if include{if !selected.contains(name){selected.append(name)}}else{selected.removeAll{$0==name}};names=selected.joined(separator:"\n")}))}}
                DisclosureGroup("Указать названия вручную"){TextEditor(text:$names).font(.system(.caption,design:.monospaced)).frame(height:100).scrollContentBackground(.hidden).padding(8).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))}
            }
            Text("Сохраняются дампы и версии СУБД. Для нетранзакционных таблиц выберите блокировку записей.").font(.caption).foregroundStyle(BackupTheme.muted)
            Button("Сохранить подключение"){save()}.buttonStyle(BackupPrimaryButtonStyle()).disabled(m.busy)
            Divider();Button("Перейти к заданию"){m.section="Задания"}
        }.frame(width:305)}
        }else if m.databases.isEmpty{BackupPanel(title:"Базы не подключены",icon:"cylinder.split.1x2"){Text("Если нужны дампы БД, нажмите «Добавить подключение».")}}
        ResultView()
    }.textFieldStyle(.roundedBorder).confirmationDialog("Следующий бэкап заново создаст базовую копию БД. Сохранённые снимки останутся доступны.",isPresented:$resetChain){Button("Новая базовая копия"){m.perform(["action":"database_chain_reset","database_id":id,"confirmed":true])}}.confirmationDialog("Установить клиентские пакеты СУБД через apt? Это может изменить установленные клиентские версии.",isPresented:$installClients){Button("Установить"){m.perform(["action":"install_db_clients","engine":engine,"journal":backupMode=="journal","confirmed":true])}}}
    func newDatabase(){id="database-"+String(m.databases.count+1);while m.databases.contains(where:{$0["id"] as? String==id}){id+="-new"};engine="mysql";host="localhost";port=3306;user="root";password="";container="";names="";consistency="transaction";peer=false;allDatabases=true;backupMode="dump";walArchive="";discovery=[:];editingDatabase=true;editingExistingDatabase=false}
    func value()->[String:Any]{["id":id,"engine":engine,"host":host,"port":port,"user":user,"password":password,"container":container,"databases":allDatabases ? []:lines(names),"consistency":consistency,"peer":peer,"backup_mode":backupMode,"wal_archive":walArchive]}
    func save(){guard fieldID(id) else{m.error="Неверный ID";return};if !allDatabases && lines(names).isEmpty{m.error="Выберите базы или включите все доступные базы";return};let db=value();do{try Vault.put("db-"+(m.selectedID ?? "")+"-"+id,db);m.perform(["action":"save_database","database":db]){discovery=$0 as? [String:Any] ?? [:];editingDatabase=false;m.loadProbe()}}catch{m.error=error.localizedDescription}}
    func load(_ id:String)->Bool{let db=Vault.dictionary("db-"+(m.selectedID ?? "")+"-"+id);guard !db.isEmpty else{m.error="Секретов нет в Keychain: импортируйте экспорт профилей";return false};self.id=id;engine=db["engine"] as? String ?? "mysql";host=db["host"] as? String ?? "localhost";port=db["port"] as? Int ?? 3306;user=db["user"] as? String ?? "root";password=db["password"] as? String ?? "";container=db["container"] as? String ?? "";names=(db["databases"] as? [String] ?? []).joined(separator:"\n");allDatabases=names.isEmpty;discovery=[:];consistency=db["consistency"] as? String ?? "transaction";peer=db["peer"] as? Bool ?? false;backupMode=db["backup_mode"] as? String ?? "dump";walArchive=db["wal_archive"] as? String ?? "";return true}
}
struct DockerView:View {
    @EnvironmentObject var m:Model
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{WorkspaceIntro(title:"Docker-проекты",detail:"Контейнеры, Compose-файлы и тома для резервного копирования",icon:"shippingbox");Button("Обнаружить"){m.perform(["action":"docker"]){m.containers=$0 as? [[String:Any]] ?? []}}.buttonStyle(BackupPrimaryButtonStyle()).disabled(m.busy)}
        if m.containers.isEmpty{BackupPanel(title:"Подключение Docker",icon:"shippingbox"){Text("Нажмите «Обнаружить», чтобы получить список контейнеров сервера.").foregroundStyle(BackupTheme.muted);Text("Подключение Docker необязательно. Режим копирования каждого контейнера выбирается в задании.").font(.caption).foregroundStyle(BackupTheme.muted)}}
        ForEach(m.containers.indices,id: \.self){i in let c=m.containers[i];BackupPanel(title:c["name"] as? String ?? "Контейнер",subtitle:c["image"] as? String ?? "",icon:"shippingbox"){
            HStack{StatusBadge(title:c["running"] as? Bool==true ? "Работает":"Остановлен",color:c["running"] as? Bool==true ? .green:BackupTheme.muted);if let db=c["database"] as? String{StatusBadge(title:"База: "+db,color:.orange)};Spacer();Button("Настроить в задании"){m.section="Задания"}}
            let labels=c["labels"] as? [String:String] ?? [:]
            if let project=labels["com.docker.compose.project"]{HStack{Text("Compose-проект").foregroundStyle(BackupTheme.muted);Text(project)}.font(.caption)}
            if let files=labels["com.docker.compose.project.config_files"],!files.isEmpty{Text(files).font(.system(.caption,design:.monospaced)).foregroundStyle(BackupTheme.muted).textSelection(.enabled)}
            ForEach((c["mounts"] as? [[String:Any]] ?? []).indices,id: \.self){index in let mount=(c["mounts"] as! [[String:Any]])[index];HStack{Image(systemName:"externaldrive").foregroundStyle(BackupTheme.blue);VStack(alignment:.leading,spacing:4){Text(mount["Name"] as? String ?? mount["Source"] as? String ?? "").font(.system(.caption,design:.monospaced));Text("→ \(mount["Destination"] ?? "")").font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();StatusBadge(title:mount["Type"] as? String ?? "Том")}}
        }}
        BackupPanel(title:"Как сохранить данные Docker",icon:"info.circle"){HStack(alignment:.top,spacing:18){mode("Дамп базы","Подключите СУБД, затем выберите дамп в задании.");mode("Остановить контейнер","Остановить на время копии и запустить после неё.");mode("Копировать работающий","Согласованность данных не гарантируется.")}}
    }}
    func mode(_ title:String,_ detail:String)->some View{VStack(alignment:.leading,spacing:7){Text(title).font(.callout.bold());Text(detail).font(.caption).foregroundStyle(BackupTheme.muted)}.frame(maxWidth:.infinity,alignment:.leading)}
}
struct CopyRepositoryView:View {
    @EnvironmentObject var m:Model
    let destination:String
    @State private var source=""
    @State private var password=""
    @State private var show=false
    @State private var keyConfirm=false
    var body:some View{VStack(alignment:.leading,spacing:14){
        Text("Копировать версии из другого хранилища").font(.headline)
        HStack{Picker("Откуда",selection:$source){Text("Выберите хранилище").tag("");ForEach(m.repositories.indices,id:\.self){index in let repo=m.repositories[index];if repo["id"] as? String != destination{Text(repo["name"] as? String ?? repo["id"] as? String ?? "").tag(repo["id"] as? String ?? "")}}};Button("Копировать сюда"){show=true}.disabled(source.isEmpty || destination.isEmpty || m.busy)}
        Divider()
        Text("Дополнительный пароль доступа").font(.headline)
        Text("Добавляет ещё один пароль для открытия этого хранилища. Существующий пароль продолжит работать.").font(.caption).foregroundStyle(BackupTheme.muted)
        HStack{SecureField("Новый пароль хранилища",text:$password);Button("Добавить пароль"){keyConfirm=true}.disabled(password.isEmpty || destination.isEmpty || m.busy)}
    }.confirmationDialog("Скопировать копии из \(source) в выбранное хранилище?",isPresented:$show){Button("Копировать"){m.perform(["action":"command","repository_id":destination,"command":"copy","args":[],"from_repository_id":source,"confirmed":true])}}
    .confirmationDialog("Добавить новый пароль доступа к хранилищу?",isPresented:$keyConfirm){Button("Добавить пароль"){m.perform(["action":"command","repository_id":destination,"command":"key","args":["add"],"key_password":password,"confirmed":true]);password=""}}
}}
struct RestoreView:View {
    @EnvironmentObject var m:Model
    @State var repo="storage-01";@State var snapshot="latest";@State var target="/";@State var includes="";@State var targetID="";@State var overwrite=false;@State var confirmed=false;@State var newServer:Server?
    @State var dbid="database-01";@State var dbconfig="";@State var roles=false;@State var dockerNames="";@State var bindPaths="{}";@State var compose="";@State var start=false;@State var dockerOverwrite=false;@State var phase="files";@State var confirmDB=false;@State var confirmDocker=false
    @State private var importTarget="/srv/server-backup-restore"
    @State private var recoveryTime=""
    @State private var pgdata="/srv/server-backup-pgdata"
    @State private var targetFile:String?
    @State private var visualRules=false
    @State private var selectiveRestore=false
    @State private var restoreAdvanced=false
    @State private var showDestinationPicker=false
    @State private var restoreStep=0
    @State private var restoreKind="files"
    @State private var manualCopy=false
    @State private var copies:[[String:Any]]=[]
    @State private var copiesLoading=false
    @State private var copiesError:String?
    @State private var copiesGeneration=UUID()
    func copyLabel(_ copy:[String:Any])->String{
        let raw=copy["time"] as? String ?? ""
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let date=parser.date(from:raw) ?? ISO8601DateFormatter().date(from:raw)
        let label=date.map{ $0.formatted(date:.numeric,time:.shortened) } ?? raw
        return label+" · "+String((copy["short_id"] as? String ?? copy["id"] as? String ?? "").prefix(8))+" · "+(copy["hostname"] as? String ?? "")
    }
    func loadCopies(){
        guard let server=m.current,!repo.isEmpty else{return}
        let repository=repo;let generation=UUID();copiesGeneration=generation;copiesLoading=true;copiesError=nil
        Task{do{let value=try await m.readLive(["action":"command","repository_id":repository,"command":"snapshots","args":["--json"]],server:server)
            guard generation==copiesGeneration else{return}
            let text=(value as? [String:Any])?["output"] as? String ?? ""
            copies=(try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [[String:Any]] ?? []).sorted{($0["time"] as? String ?? "") > ($1["time"] as? String ?? "")}
            if snapshot=="latest",let id=copies.first?["id"] as? String{snapshot=id}
            copiesLoading=false
        }catch{guard generation==copiesGeneration else{return};copiesError=error.localizedDescription;copiesLoading=false}}
    }
    var destination:Server?{m.servers.first{$0.id==targetID} ?? m.current}
    var body:some View{VStack(alignment:.leading,spacing:16){
        Text("Восстановление из резервной копии").font(.title2).fontWeight(.semibold)
        HStack(spacing:10){ForEach(0..<3){i in Button{restoreStep=i}label:{HStack{Image(systemName:restoreStep>i ? "checkmark.circle.fill":"\(i+1).circle.fill");Text(["Выберите копию","Сервер назначения","Восстановите данные"][i])}.font(.callout).foregroundStyle(restoreStep==i ? Color.white:BackupTheme.muted).padding(.horizontal,14).padding(.vertical,10).background(restoreStep==i ? BackupTheme.blue:BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}}
        if restoreStep==0{
        Text("Какую версию нужно восстановить?").font(.headline)
        Text("Выберите хранилище и копию по дате. Затем укажите сервер, куда вернуть данные.").font(.callout).foregroundStyle(.secondary)
        HStack{if m.repositories.isEmpty{TextField("ID хранилища",text:$repo)}else{Picker("Хранилище",selection:$repo){if !m.repositories.contains(where:{$0["id"] as? String==repo}){Text(repo).tag(repo)};ForEach(m.repositories.indices,id:\.self){i in let r=m.repositories[i];Text(r["name"] as? String ?? r["id"] as? String ?? "").tag(r["id"] as? String ?? "")}}};Button("Обновить копии"){loadCopies()}.disabled(copiesLoading);if copiesLoading{ProgressView().controlSize(.small)}}
        if let error=copiesError{Text(error).font(.caption).foregroundStyle(.red)}
        if !copies.isEmpty{Picker("Версия копии",selection:$snapshot){if !copies.contains(where:{$0["id"] as? String==snapshot}){Text(snapshot=="latest" ? "Последняя доступная копия":snapshot).tag(snapshot)};ForEach(copies.indices,id:\.self){i in Text(copyLabel(copies[i])).tag(copies[i]["id"] as? String ?? "")}}
            if let selected=copies.first(where:{$0["id"] as? String==snapshot}){Text((selected["paths"] as? [String] ?? []).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            Text("Доступно версий: "+String(copies.count)+". Дата и время показаны в часовом поясе Mac.").font(.caption).foregroundStyle(.secondary)
        }else if !copiesLoading && copiesError==nil{Text("В хранилище нет доступных копий.").font(.caption).foregroundStyle(.secondary)}
        ClickableDisclosure(title:"Указать ID копии вручную",isExpanded:$manualCopy){TextField("ID копии",text:$snapshot)}
        }
        if restoreStep==1{
        Text("Куда восстановить данные?").font(.headline)
        Text("Выберите исходный сервер или добавьте новый. Проверьте подключение и подключите к нему выбранное хранилище.").font(.callout).foregroundStyle(.secondary)
        HStack{Picker("Сервер назначения",selection:$targetID){Text("Исходный сервер").tag("");ForEach(m.servers){s in Text(s.name+" · "+s.host).tag(s.id)}};Button("Новый сервер"){newServer=Server()}}
        HStack{Button("Проверить целевой сервер"){if let s=destination{m.perform(["action":"probe"],server:s)}};Button("Установить инструменты на целевой сервер"){phase="install";confirmed=true};Button("Подключить хранилище к целевому серверу"){connectRepository()}}
        Text("Для нового сервера сначала подтвердите его SSH-отпечаток через «Подключиться». S3 доступен независимо от исходного сервера; для SFTP настройте отдельный ключ на новом сервере. Локальная копия доступна только при подключённом диске.").font(.caption).foregroundStyle(.secondary)
        }
        if restoreStep==2{
        HStack{Text("Копия: "+(copies.first(where:{$0["id"] as? String==snapshot}).map{copyLabel($0)} ?? (snapshot=="latest" ? "Последняя доступная":String(snapshot.prefix(12))))).font(.caption);Spacer();Text(destination?.name ?? "Сервер не выбран").font(.caption).foregroundStyle(.secondary)}
        Picker("Что восстановить",selection:$restoreKind){Text("Файлы и папки").tag("files");Text("Базы данных").tag("databases");Text("Docker").tag("docker")}.pickerStyle(.segmented)
        if restoreKind=="files"{
        HStack(alignment:.top,spacing:16){
            BackupPanel(title:"Откуда",subtitle:"Копия · "+String(snapshot.prefix(12)),icon:"archivebox"){
                Picker("Объём восстановления",selection:$selectiveRestore){Text("Вся копия").tag(false);Text("Выбрать данные").tag(true)}.pickerStyle(.segmented).onChange(of:selectiveRestore){_,value in if !value{includes=""}}
                SnapshotFileSelection(repository:repo,snapshot:snapshot,includes:$includes).onChange(of:includes){_,value in if !value.isEmpty{selectiveRestore=true}}
                Text("Нажмите на папку, чтобы открыть. Галочка выбирает папку со всем содержимым или отдельный файл.").font(.caption).foregroundStyle(BackupTheme.muted)
            }.frame(maxWidth:.infinity)
            BackupPanel(title:"Куда",subtitle:"Целевой сервер",icon:"server.rack"){
                if let server=destination{RestoreDestinationBrowser(server:server,target:$target,targetFile:$targetFile)}
                Text("Выберите папку назначения или файл для замены одним выбранным файлом копии.").font(.caption).foregroundStyle(BackupTheme.muted)
                HStack{TextField("Каталог назначения",text:$target).onChange(of:target){_,value in if let file=targetFile,URL(fileURLWithPath:file).deletingLastPathComponent().path != value{targetFile=nil}};if targetFile != nil{Button("В папку"){targetFile=nil}}}
                if targetFile==nil{Text("Исходные пути сохраняются внутри выбранной папки.").font(.caption).foregroundStyle(BackupTheme.muted)}
                Toggle("Разрешить замену существующих файлов",isOn:$overwrite)
            }.frame(maxWidth:.infinity)
        }
        ClickableDisclosure(title:"Выбрать по имени или типу файла",isExpanded:$visualRules){RestoreRuleBuilder(includes:$includes).onChange(of:includes){_,value in if !value.isEmpty{selectiveRestore=true}}}
        ClickableDisclosure(title:"Пути и маски вручную · для опытных пользователей",isExpanded:$restoreAdvanced){Text("Один путь или правило на строку. Визуальный выбор доступен выше.").font(.caption);TextEditor(text:$includes).frame(height:70).border(.quaternary).onChange(of:includes){_,value in if !value.isEmpty{selectiveRestore=true}}}
        Button("Проверить доступ и начать восстановление"){phase="files";confirmed=true}.buttonStyle(.borderedProminent).disabled(target.isEmpty || (selectiveRestore && lines(includes).isEmpty) || (targetFile != nil && lines(includes).count != 1))
        }
        if restoreKind=="databases"{
        Text("Импорт баз из восстановленной копии").font(.headline)
        Text("Сначала восстановите файлы копии. Затем укажите тот же каталог и доступы к целевой базе. Импорт требует отдельного подтверждения.").font(.callout).foregroundStyle(.secondary)
        TextField("Каталог восстановленной копии",text:$importTarget)
        TextField("ID подключения БД из манифеста копии",text:$dbid)
        Button("Использовать сохранённые доступы к БД"){dbconfig=Model.pretty(Vault.dictionary("db-"+(destination?.id ?? "")+"-"+dbid))}
        Text("Подключение к целевой БД можно задать здесь. Пароль не сохраняется в журнале.").font(.caption)
        SecureJSONEditor(text:$dbconfig)
        Toggle("В PostgreSQL также импортировать роли",isOn:$roles)
        FieldLabel(title:"Восстановить на момент времени · UTC, для цепочки журналов"){TextField("2026-10-09T12:30:00Z · пусто — конец сохранённой цепочки",text:$recoveryTime)}
        FieldLabel(title:"Отдельный пустой PGDATA · для PostgreSQL с WAL"){TextField("/srv/server-backup-pgdata",text:$pgdata)}
        Text("PostgreSQL с WAL: подготовка отдельного кластера без запуска. MySQL/MariaDB: базовый дамп и применение binlog в целевую БД. Используйте отдельный тестовый сервер.").font(.caption).foregroundStyle(BackupTheme.muted)
        Button("Импортировать БД"){confirmDB=true}
        }
        if restoreKind=="docker"{
        Text("Тома Docker и Compose").font(.headline)
        Text("Сначала восстановите файлы копии. Здесь можно перенести тома и отдельно включить запуск Compose после проверки настроек.").font(.callout).foregroundStyle(.secondary)
        TextField("Каталог восстановленной копии",text:$importTarget)
        TextField("Контейнеры из манифеста · имена через запятую",text:$dockerNames)
        Text("Замена путей bind mounts: JSON-объект старый путь → новый путь").font(.caption);TextEditor(text:$bindPaths).font(.system(.caption,design:.monospaced)).frame(height:60).border(.quaternary)
        Toggle("Разрешить перезапись существующих томов",isOn:$dockerOverwrite);Toggle("После переноса запустить проверенные Compose-проекты",isOn:$start)
        if start{Text("Проверьте пути, порты и .env в восстановленных Compose-файлах перед запуском.").foregroundStyle(.orange);TextEditor(text:$compose).frame(height:65).border(.quaternary)}
        Button("Восстановить выбранные тома Docker"){confirmDocker=true}
        }
        }
        Divider()
        HStack{if restoreStep>0{Button("Назад"){restoreStep-=1}};Spacer();if restoreStep<2{Button("Далее"){restoreStep+=1}.buttonStyle(.borderedProminent).disabled(repo.isEmpty || snapshot.isEmpty || copiesLoading)}}
        ResultView()
    }.onAppear{snapshot=m.selectedSnapshot;if !m.preferredRepository.isEmpty{repo=m.preferredRepository}else if !m.repositories.contains(where:{$0["id"] as? String==repo}){repo=m.repositories.first?["id"] as? String ?? repo};includes=m.restoreIncludes.joined(separator:"\n");selectiveRestore = !includes.isEmpty;loadCopies()}.onChange(of:target){_,value in if value != "/"{importTarget=value}}.onChange(of:repo){_,_ in if copies.contains(where:{$0["id"] as? String==snapshot}){snapshot="latest"};copies=[];loadCopies()}.onDisappear{copiesGeneration=UUID();copiesLoading=false}.sheet(item:$newServer){ServerEditor(server:$0)}.sheet(isPresented:$showDestinationPicker){if let server=destination{RestoreDirectoryPicker(server:server,target:$target)}}
        .confirmationDialog(phase=="install" ? "Установить пакеты на целевой сервер?":"Восстановить "+(includes.isEmpty ? "всю копию":"выбранные пути: "+String(lines(includes).count))+" на "+(destination?.name ?? "")+" в "+(targetFile ?? target)+"?",isPresented:$confirmed){Button("Продолжить"){if phase=="install"{m.perform(["action":"install"],server:destination)}else{m.perform(["action":"restore","repository_id":repo,"snapshot":snapshot,"target":target,"includes":lines(includes),"overwrite":overwrite,"allow_root":target=="/","target_file":targetFile as Any? ?? NSNull(),"confirmed":true],server:destination)}}}
        .confirmationDialog("Импорт может изменить или перезаписать целевые базы. Продолжить?",isPresented:$confirmDB){Button("Импортировать",role:.destructive){do{let db=try JSONSerialization.jsonObject(with:Data(dbconfig.utf8));guard db is [String:Any] else{throw AppFailure(message:"Укажите объект подключения к БД")};m.perform(["action":"restore_database","target":importTarget,"database_id":dbid,"database":db,"restore_roles":roles,"recovery_time":recoveryTime,"pgdata":pgdata,"confirmed":true],server:destination)}catch{m.error=error.localizedDescription}}}
        .confirmationDialog("Перенести выбранные тома и выполнить выбранные действия запуска?",isPresented:$confirmDocker){Button("Восстановить"){do{let paths=try JSONSerialization.jsonObject(with:Data(bindPaths.utf8));guard paths is [String:String] else{throw AppFailure(message:"Нужен объект путей")};m.perform(["action":"restore_docker","target":importTarget,"containers":dockerNames.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)},"bind_paths":paths,"compose_files":lines(compose),"overwrite":dockerOverwrite,"start":start,"confirmed":true],server:destination)}catch{m.error=error.localizedDescription}}}
    }
    func connectRepository(){let r=Vault.dictionary("repo-"+(m.selectedID ?? "")+"-"+repo);guard !r.isEmpty else{m.error="Доступы к хранилищу отсутствуют в Keychain";return};m.perform(["action":"save_repository","repository":r,"initialize":false],server:destination)}
}
struct SecureJSONEditor:View { @Binding var text:String;@State var visible=false;var body:some View{VStack(alignment:.leading){Toggle("Показать настройки подключения",isOn:$visible);if visible{TextEditor(text:$text).font(.system(.caption,design:.monospaced)).frame(height:120).border(.quaternary)}else{SecureField("JSON подключения: engine, host, port, user, password, container, peer",text:$text)}}}}
struct MetricCard:View {let title:String;let value:String;var body:some View{VStack(alignment:.leading){Text(title).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3.bold())}.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius:8))}}
struct LogView:View {
    @EnvironmentObject var m:Model
    @State var records:[[String:Any]]=[]
    @State var journal=""
    @State var notificationErrors=""
    @State var search=""
    @State var selection:Int?
    @State private var detailRecord:[String:Any]?
    @State private var showDetails=false
    @State var source="Сервер"
    @State private var live=true
    @State private var loading=false
    @State private var updated:Date?
    @State private var loadError:String?
    @StateObject private var stream=SSHStream()
    @StateObject private var journalStream=SSHStream()
    @State private var journalStarted=false
    var text:String{source=="Приложение" ? m.events.joined(separator:"\n") : journal+(notificationErrors.isEmpty ? "":"\n\nОшибки уведомлений\n"+notificationErrors)}
    var filteredText:String{search.isEmpty ? text : text.components(separatedBy:"\n").filter{$0.localizedCaseInsensitiveContains(search)}.joined(separator:"\n")}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{Picker("Журнал",selection:$source){Text("Сервер").tag("Сервер");Text("Приложение").tag("Приложение");Text("Логи сервера").tag("Логи сервера")}.pickerStyle(.segmented).frame(width:440);Spacer();if source != "Логи сервера"{Button("Обновить",systemImage:"arrow.clockwise"){load()}.disabled(m.busy);Button("Скопировать"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(filteredText,forType:.string)};Button("Сохранить…"){export()}}}
        if source=="Логи сервера"{ServerLogsView()}else{
        HStack{Toggle("Онлайн · поток",isOn:$live);if loading{ProgressView().controlSize(.small)};Text(stream.state).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Text(updated.map{"Обновлено: "+$0.formatted(date:.omitted,time:.standard)} ?? "Нет данных").font(.caption).foregroundStyle(BackupTheme.muted)}
        if let loadError=stream.error ?? journalStream.error ?? loadError{Text(loadError).font(.caption).foregroundStyle(.orange)}
        if source=="Сервер"{Text("История заданий и операций").font(.headline)
            if records.isEmpty{Text("Нет записей. Обновите журнал после подключения.").foregroundStyle(.secondary)}
            ForEach(records.indices,id: \.self){i in let r=records[i];Button{selection=i;detailRecord=r;showDetails=true}label:{HStack{Image(systemName:r["status"] as? String=="success" ? "checkmark.circle.fill":"clock.fill").foregroundStyle(r["status"] as? String=="success" ? .green:.orange);VStack(alignment:.leading,spacing:4){Text(operationHistoryTitle(r)).font(.headline);Text(operationHistoryContext(r)).font(.caption).foregroundStyle(BackupTheme.muted);Text(resultTitle(r["status"] as? String ?? "—")+" · "+backupTime(r["finished"] as? String ?? r["started"] as? String)).font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right")}.padding(12).background(selection==i ? Color.blue.opacity(0.08):Color(nsColor:.windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain)}

        }
        TextField("Поиск в журнале",text:$search)
        ScrollView([.horizontal,.vertical]){Text(filteredText.isEmpty ? "Журнал пуст":filteredText).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(16)}.frame(minHeight:240,maxHeight:450).background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
        }
    }.sheet(isPresented:$showDetails){OperationDetails(value:detailRecord ?? [:])}.onAppear{if !m.probe.isEmpty{load()}}.onDisappear{stream.stop();journalStream.stop()}.onChange(of:source){_,_ in stream.stop();journalStream.stop();if source=="Сервер"{load()}}.onChange(of:live){_,enabled in if enabled && source=="Сервер"{start()}else{stream.stop();journalStream.stop()}}}
    func start(){journalStarted=false
        stream.start(model:m,request:["action":"stream","kind":"operations"]){event in guard event["event"] as? String=="operations",let r=event["result"] as? [String:Any] else{return};let selectedID=selection.flatMap{records.indices.contains($0) ? records[$0]["id"] as? String:nil};records=r["records"] as? [[String:Any]] ?? [];selection=selectedID.flatMap{id in records.firstIndex{$0["id"] as? String==id}};if !journalStarted{journal=r["journal"] as? String ?? ""};let errors=r["notification_errors"] as? [[String:Any]] ?? [];notificationErrors=errors.isEmpty ? "":Model.pretty(errors);updated=Date();loadError=nil}
        journalStream.start(model:m,request:["action":"stream","kind":"operation_journal"]){event in guard event["event"] as? String=="journal",let r=event["result"] as? [String:Any] else{return};if !journalStarted{journal="";journalStarted=true};journal=LogBuffer.append(journal,r["text"] as? String ?? "");updated=Date()}
    }
    func load(){if live && source=="Сервер"{start();return};guard let server=m.current,!loading else{return};loading=true
        Task{do{let response=try await m.readLive(["action":"logs"],server:server);guard m.selectedID==server.id else{loading=false;return};let r=response as? [String:Any] ?? [:];let selectedID=selection.flatMap{records.indices.contains($0) ? records[$0]["id"] as? String:nil};records=r["records"] as? [[String:Any]] ?? [];selection=selectedID.flatMap{id in records.firstIndex{$0["id"] as? String==id}};journal=r["journal"] as? String ?? "";let errors=r["notification_errors"] as? [[String:Any]] ?? [];notificationErrors=errors.isEmpty ? "":Model.pretty(errors);if let selection,!records.indices.contains(selection){self.selection=nil};updated=Date();loadError=nil}catch{if m.selectedID==server.id{loadError=error.localizedDescription}};loading=false}}

    func export(){let panel=NSSavePanel();panel.nameFieldStringValue="ServerBackup-log.txt";if panel.runModal() == .OK,let url=panel.url{do{try filteredText.write(to:url,atomically:true,encoding:.utf8)}catch{m.error=error.localizedDescription}}}
}
struct ExportView:View {
    @EnvironmentObject var m:Model;@Environment(\.dismiss)var dismiss
    @State var password="";@State var busy=false;@State var message=""
    var body:some View{VStack(alignment:.leading,spacing:18){Text("Зашифрованный экспорт профилей").font(.title2);Text("Экспорт включает SSH-доступы, доступы к хранилищам и БД, Telegram и почты, приватные SSH-ключи и подтверждённые ключи серверов. Храните архив отдельно от Mac.");SecureField("Пароль архива · не менее 12 символов",text:$password);if busy{ProgressView()};Text(message).foregroundStyle(.secondary);HStack{Button("Закрыть"){dismiss()};Spacer();Button("Импортировать"){importFile()};Button("Экспортировать"){exportFile()}}.disabled(busy)}.padding(24).frame(width:650)}
    func exportFile(){let panel=NSSavePanel();panel.nameFieldStringValue="ServerBackup-profiles.sbexport";guard panel.runModal() == .OK,let url=panel.url else{return};busy=true
        do{var records:[String:String]=[:];for (key,value) in try Vault.all(){records[key]=value.base64EncodedString()}
            var files:[String:String]=[:];for s in m.servers{if let d=try? Data(contentsOf:Paths.known(s.id)){files["known-"+s.id]=d.base64EncodedString()};if !s.keyPath.isEmpty{files["private-"+s.id]=(try Data(contentsOf:URL(fileURLWithPath:s.keyPath))).base64EncodedString()}}
            let servers=try JSONSerialization.jsonObject(with:JSONEncoder().encode(m.servers));let payload=try JSONSerialization.data(withJSONObject:["servers":servers,"credentials":records,"files":files]);let pass=password
            Task{do{let data=try await Task.detached{try ProfileExport.seal(payload,password:pass)}.value;try data.write(to:url,options:.atomic);message="Экспорт сохранён"}catch{message=error.localizedDescription};busy=false}
        }catch{message=error.localizedDescription;busy=false}
    }
    func importFile(){let panel=NSOpenPanel();panel.allowsMultipleSelection=false;guard panel.runModal() == .OK,let url=panel.url else{return};busy=true;let pass=password
        Task{do{let data=try Data(contentsOf:url);let plain=try await Task.detached{try ProfileExport.open(data,password:pass)}.value;guard let payload=try JSONSerialization.jsonObject(with:plain) as? [String:Any],let serverData=payload["servers"] else{throw AppFailure(message:"Неверный архив")};var servers=try JSONDecoder().decode([Server].self,from:JSONSerialization.data(withJSONObject:serverData));for s in servers{try SSH.validate(s);guard fieldID(s.id) else{throw AppFailure(message:"Неверный ID профиля")}}
            for (key,value) in payload["credentials"] as? [String:String] ?? [:]{guard let data=Data(base64Encoded:value) else{throw AppFailure(message:"Повреждённый секрет")};try Vault.set(key,data)}
            let files=payload["files"] as? [String:String] ?? [:];for i in servers.indices{let id=servers[i].id;if let value=files["known-"+id],let d=Data(base64Encoded:value){try d.write(to:Paths.known(id),options:.atomic)};if let value=files["private-"+id],let d=Data(base64Encoded:value){let u=Paths.support.appendingPathComponent("private-"+id);try d.write(to:u,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:u.path);servers[i].keyPath=u.path}}
            for s in servers{if let i=m.servers.firstIndex(where:{$0.id==s.id}){m.servers[i]=s}else{m.servers.append(s)}};try m.persist();message="Импортировано серверов: \(servers.count)"
        }catch{message="Импорт не выполнен: неверный пароль или повреждённый архив. \(error.localizedDescription)"};busy=false}
    }
}
