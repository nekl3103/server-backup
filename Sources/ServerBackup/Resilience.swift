import SwiftUI
import Charts

struct FleetStatus {
    var health:[String:Any]=[:]
    var error:String?
    var checked=Date()
    var jobs:[[String:Any]]{health["jobs"] as? [[String:Any]] ?? []}
    var attention:Bool{error != nil || jobs.contains{($0["enabled"] as? Bool ?? true) && ($0["stale"] as? Bool==true || ["failed","incomplete"].contains($0["last_status"] as? String ?? "") || $0["replication_error"] as? Bool==true || $0["maintenance_error"] as? Bool==true || ($0["verification"] as? [String:Any])?["status"] as? String=="failed")}}
    var title:String{if error != nil{return "Нет связи"};if jobs.isEmpty{return "Нет заданий"};if !jobs.contains(where:{$0["enabled"] as? Bool ?? true}){return "Задания выключены"};return attention ? "Требует внимания":"Копии актуальны"}
}
func resultTitle(_ value:String)->String{["success":"Успешно","failed":"Ошибка","incomplete":"Неполная копия","running":"Выполняется","cancelled":"Отменено"][value] ?? value}
func backupDate(_ text:String?)->Date?{guard let text else{return nil};let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.date(from:text) ?? ISO8601DateFormatter().date(from:text)}
func backupTime(_ text:String?)->String{backupDate(text).map{$0.formatted(date:.abbreviated,time:.shortened)} ?? "Не выполнено"}
func bytes(_ value:Any?)->String{guard let v=value as? Double else{return "Недоступно"};return v==0 ? "0 Б":ByteCountFormatter.string(fromByteCount:Int64(v),countStyle:.binary)}
extension Model {
    func refreshFleet(){guard !fleetLoading else{return};fleetLoading=true;let targets=servers
        Task{for start in stride(from:0,to:targets.count,by:3){let batch=Array(targets[start..<min(start+3,targets.count)]);let records=await withTaskGroup(of:(String,FleetStatus).self){group in
                for server in batch{let preview=isDesignPreview;let demoMetrics=designResponse(["action":"metrics"]) ?? [:];group.addTask{if preview{return (server.id,FleetStatus(health:["jobs":[["id":"daily","enabled":true,"last_success":"2026-10-08T03:00:00Z","last_status":server.id=="design-db" ? "failed":"success","stale":false]],"configured":true,"metrics":demoMetrics]))};do{let r=try SSH.call(server,["action":"fleet_health"]);return (server.id,FleetStatus(health:r as? [String:Any] ?? [:]))}catch{return (server.id,FleetStatus(error:error.localizedDescription))}}}
                var result:[(String,FleetStatus)]=[];for await record in group{result.append(record)};return result
            };for (id,status) in records{fleet[id]=status}}
            fleetLoading=false
        }
    }
}
struct FleetSummaryView:View {
    @EnvironmentObject var m:Model
    var body:some View{HStack(spacing:16){summary("Серверов",String(m.servers.count),.blue);summary("Копии актуальны",String(m.fleet.values.filter{!$0.attention && $0.jobs.contains(where:{$0["enabled"] as? Bool ?? true})}.count),.green);summary("Требуют внимания",String(m.fleet.values.filter(\.attention).count),.orange);summary("Не проверены",String(m.servers.filter{m.fleet[$0.id]==nil}.count),BackupTheme.muted)}}
    func summary(_ title:String,_ number:String,_ color:Color)->some View{BackupPanel(title:""){HStack{Text(title).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Text(number).font(.title2.bold()).foregroundStyle(color)}}}
}
struct FleetServerStatusView:View {
    let status:FleetStatus?
    var body:some View{VStack(alignment:.leading,spacing:8){if let status{StatusBadge(title:status.title,color:status.attention ? .orange:status.jobs.isEmpty ? BackupTheme.muted:.green);Text("Проверено: "+status.checked.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(BackupTheme.muted)
            if let error=status.error{Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)}
            ForEach(status.jobs.prefix(3).indices,id:\.self){i in let job=status.jobs[i];HStack{Text(job["id"] as? String ?? "");Spacer();Text(backupTime(job["last_success"] as? String)).foregroundStyle(BackupTheme.muted)}.font(.caption)}
            if let disk=(status.health["disks"] as? [[String:Any]])?.first(where:{$0["target"] as? String=="/"}){Text("Свободно на /: \(disk["avail"] ?? "—")").font(.caption).foregroundStyle(BackupTheme.muted)}
        }else{Text("Состояние ещё не проверено").font(.caption).foregroundStyle(BackupTheme.muted)}}}
}
struct VerificationView:View {
    @EnvironmentObject var m:Model
    @State private var repository=""
    @State private var snapshot="latest"
    @State private var records:[[String:Any]]=[]
    @State private var full=false
    @State private var selectedResult:CheckResult?
    @State private var loading=false
    @State private var loadError:String?
    var body:some View{VStack(alignment:.leading,spacing:18){WorkspaceIntro(title:"Проверка восстановления",detail:"Выборочная или полная проверка в отдельном каталоге",icon:"checkmark.shield")
        BackupPanel(title:"Проверить выбранную копию",icon:"arrow.counterclockwise"){Picker("Хранилище",selection:$repository){Text("Выберите").tag("");ForEach(m.repositories.indices,id:\.self){i in Text(m.repositories[i]["id"] as? String ?? "").tag(m.repositories[i]["id"] as? String ?? "")}};TextField("ID копии или latest",text:$snapshot);Toggle("Полная проверка: файлы, импорт БД в изолированный Docker и тома",isOn:$full);if full{Text("Нужен тестовый сервер с Docker и заранее установленными образами той же основной версии СУБД. Нужно место для двух восстановленных копий. Контейнеры без сети и опубликованных портов удаляются после проверки.").font(.caption).foregroundStyle(.orange)};Text(full ? "Восстанавливается вся копия: файлы проверяются Restic, базы импортируются в отдельные контейнеры, тома копируются и проверяется Compose. Временные данные удаляются. Запуск сайтов и восстановление ОС не проверяются.":"Restic восстанавливает выборку, проверяет содержимое и SHA-256. Рабочие файлы не изменяются; временные данные удаляются. Эта проверка не подтверждает запуск сайтов, БД или всей системы.").font(.caption).foregroundStyle(BackupTheme.muted);Button("Проверить восстановление"){m.perform(["action":"verify_restore","repository_id":repository,"snapshot":snapshot,"full":full])}.buttonStyle(BackupPrimaryButtonStyle()).disabled(repository.isEmpty || m.busy)}
        BackupPanel(title:"Автоматическая проверка после успешного бэкапа",icon:"calendar"){ForEach(m.jobs.indices,id:\.self){i in let job=m.jobs[i];Toggle(job["id"] as? String ?? "",isOn:Binding(get:{job["verify_restore"] as? Bool ?? false},set:{enabled in m.perform(["action":"verification_schedule","job_id":job["id"] ?? "","enabled":enabled,"full":full]){_ in m.loadProbe()}})).disabled(m.busy)};Text("Выполняется сервером независимо от Mac. Включение обновляет помощник сервера.").font(.caption).foregroundStyle(BackupTheme.muted)}
        MetricCard(title:"Последняя успешная полная проверка",value:backupTime(records.filter{$0["status"] as? String=="success" && $0["sample_only"] as? Bool==false}.compactMap{$0["finished"] as? String}.sorted().last))
        BackupPanel(title:"Результаты проверок",icon:"checklist"){
            HStack{Text("Всего: "+String(records.count)).font(.caption);Text("Успешно: "+String(records.filter{$0["status"] as? String=="success"}.count)).font(.caption).foregroundStyle(.green);Spacer();Button("Обновить"){load()}.disabled(loading);if loading{ProgressView().controlSize(.small)}}
            if let loadError{Text(loadError).foregroundStyle(.orange)}
            if records.isEmpty && !loading{Text("Проверок пока нет").foregroundStyle(BackupTheme.muted)}
            ForEach(records.indices,id:\.self){i in let record=records[i];Button{selectedResult=CheckResult(value:record)}label:{HStack(spacing:12){Image(systemName:record["status"] as? String=="success" ? "checkmark.shield.fill":"exclamationmark.shield.fill").font(.title2).foregroundStyle(record["status"] as? String=="success" ? Color.green:Color.orange);VStack(alignment:.leading,spacing:5){Text(resultTitle(record["status"] as? String ?? "—")+" · "+(record["repository_id"] as? String ?? "")).font(.headline);Text(backupTime(record["finished"] as? String)+(record["sample_only"] as? Bool==false ? " · Полная проверка · этапов: "+String((record["checks"] as? [[String:Any]] ?? []).count):" · файлов: "+String((record["files"] as? [[String:Any]] ?? []).count))).font(.caption).foregroundStyle(BackupTheme.muted);if let error=record["error"] as? String{Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)}};Spacer();Text(String((record["snapshot"] as? String ?? "").prefix(8))).font(.caption.monospaced()).foregroundStyle(BackupTheme.muted);Image(systemName:"chevron.right")}.padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())}.buttonStyle(.plain)}
        }
    }.onAppear{repository=m.preferredRepository.isEmpty ? m.repositories.first?["id"] as? String ?? "":m.preferredRepository;snapshot=m.selectedSnapshot;load()}.onChange(of:m.operationState["status"] as? String){_,value in if ["success","failed"].contains(value ?? ""),m.operationState["operation"] as? String=="verify-restore"{load()}}.sheet(item:$selectedResult){CheckResultDetails(value:$0.value)}}
    func load(){guard let server=m.current,!loading else{return};loading=true;loadError=nil;Task{do{let response=try await m.readLive(["action":"verification_results"],server:server);guard m.selectedID==server.id else{loading=false;return};records=(response as? [String:Any])?["records"] as? [[String:Any]] ?? [];loading=false}catch{loading=false;loadError=error.localizedDescription}}}
}
struct CheckResult:Identifiable{let id=UUID();let value:[String:Any]}
struct CheckResultDetails:View{
    let value:[String:Any]
    @Environment(\.dismiss) var dismiss
    @State private var technical=false
    var external:Bool{value["name"] != nil && value["repository_id"] == nil}
    var issue:String?{value["error"] as? String ?? value["issue"] as? String}
    var successful:Bool{external ? issue==nil:value["status"] as? String=="success"}
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Label(external ? "Проверка сервера":"Проверка восстановления",systemImage:"checkmark.shield").font(.title2);Spacer();Button("Закрыть"){dismiss()}}
        ScrollView{VStack(alignment:.leading,spacing:14){StatusBadge(title:successful ? "Проверка пройдена":"Требует внимания",color:successful ? .green:.orange)
            Text(external ? value["name"] as? String ?? "":value["repository_id"] as? String ?? "").font(.headline)
            Text("Проверено: "+backupTime(value["finished"] as? String ?? value["updated"] as? String)).font(.caption).foregroundStyle(BackupTheme.muted)
            if let issue{Text(issue).foregroundStyle(.orange).textSelection(.enabled)}
            if !external{Text("Копия: "+(value["snapshot"] as? String ?? "Не указана")).font(.caption).textSelection(.enabled);Text("Проверено файлов: "+String((value["files"] as? [[String:Any]] ?? []).count)).font(.headline)
                ForEach((value["files"] as? [[String:Any]] ?? []).indices,id:\.self){i in let file=(value["files"] as? [[String:Any]] ?? [])[i];VStack(alignment:.leading,spacing:5){Label(file["path"] as? String ?? "",systemImage:"doc.badge.checkmark").textSelection(.enabled);if let hash=file["sha256"] as? String{Text("SHA-256: "+hash).font(.caption.monospaced()).foregroundStyle(BackupTheme.muted).textSelection(.enabled)}}.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))}
                ForEach((value["checks"] as? [[String:Any]] ?? []).indices,id:\.self){i in let check=(value["checks"] as? [[String:Any]] ?? [])[i];Label((check["kind"] as? String ?? "")+" · "+(check["id"] as? String ?? "")+" · "+resultTitle(check["status"] as? String ?? ""),systemImage:"checkmark.circle")};Text(value["sample_only"] as? Bool==false ? "Проверены файлы и импорт БД в изолированную СУБД; тома перенесены в отдельный каталог. Запуск сайтов и Compose не проверялся.":"Проверена выборка файлов. Результат не подтверждает запуск сайтов, баз данных или всей системы.").font(.caption).foregroundStyle(BackupTheme.muted)
            }else{let jobs=(value["health"] as? [String:Any])?["jobs"] as? [[String:Any]] ?? [];ForEach(jobs.indices,id:\.self){i in Text((jobs[i]["id"] as? String ?? "")+" · "+resultTitle(jobs[i]["last_status"] as? String ?? "Не выполнено")).font(.callout)}}
            ClickableDisclosure(title:"Технические подробности",isExpanded:$technical){JSONOutput(value:value)}
        }}
    }.padding(24).frame(width:760,height:570)}
}
func backupResultColor(_ status:String)->Color{switch status{case "success":return .green;case "failed","incomplete":return .orange;case "running","queued","waiting":return BackupTheme.blue;default:return BackupTheme.muted}}
struct CalendarBackupView:View {
    @EnvironmentObject var m:Model
    @State private var records:[[String:Any]]=[]
    @State private var month=Date()
    @State private var selected=""
    @State private var serverToday=""
    @State private var groups:[String:[[String:Any]]]=[:]
    @State private var loading=false
    @State private var loadError:String?
    var calendar:Calendar{var c=Calendar(identifier:.gregorian);c.firstWeekday=2;return c}
    func key(_ date:Date)->String{let f=DateFormatter();f.calendar=calendar;f.dateFormat="yyyy-MM-dd";return f.string(from:date)}
    var days:[Date?]{let start=calendar.date(from:calendar.dateComponents([.year,.month],from:month))!;let leading=(calendar.component(.weekday,from:start)+5)%7;return Array(repeating:nil,count:leading)+(calendar.range(of:.day,in:.month,for:month) ?? 1..<2).map{calendar.date(byAdding:.day,value:$0-1,to:start)}}
    var chosen:[[String:Any]]{groups[selected] ?? []}
    var body:some View{VStack(alignment:.leading,spacing:18){HStack{WorkspaceIntro(title:"Календарь бэкапов",detail:"Успешные, неполные и ошибочные копии · даты по серверу",icon:"calendar");Button(loading ? "Загрузка…":"Обновить"){load()}.disabled(loading)}
        BackupPanel(title:"",icon:""){HStack{Button{month=calendar.date(byAdding:.month,value:-1,to:month)!}label:{Image(systemName:"chevron.left")};Text(month.formatted(.dateTime.month(.wide).year())).font(.headline);Button{month=calendar.date(byAdding:.month,value:1,to:month)!}label:{Image(systemName:"chevron.right")};Spacer();StatusBadge(title:"Успех",color:.green);StatusBadge(title:"Ошибка / неполная",color:.orange)}
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:7),spacing:10){ForEach(["Пн","Вт","Ср","Чт","Пт","Сб","Вс"],id:\.self){Text($0).font(.caption).foregroundStyle(BackupTheme.muted)};ForEach(days.indices,id:\.self){i in if let date=days[i]{let day=key(date);let rows=groups[day] ?? [];Button{selected=day}label:{VStack(alignment:.leading,spacing:10){HStack{Text(String(calendar.component(.day,from:date))).font(.headline);Spacer();if day==serverToday{Circle().fill(BackupTheme.blue).frame(width:5,height:5)}};HStack{ForEach(rows.prefix(4).indices,id:\.self){j in Circle().fill(backupResultColor(rows[j]["status"] as? String ?? "")).frame(width:7,height:7)};Spacer();if !rows.isEmpty{Text(String(rows.count)).font(.caption)}}}.padding(12).frame(maxWidth:.infinity,minHeight:70).background(selected==day ? BackupTheme.blue.opacity(0.2):BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}else{Color.clear.frame(height:70)}}}
        }
        BackupPanel(title:selected.isEmpty ? "Выберите день":selected,icon:"clock.arrow.circlepath"){if chosen.isEmpty{Text("Нет записей за выбранный день").foregroundStyle(BackupTheme.muted)};ForEach(chosen.indices,id:\.self){i in let row=chosen[i];HStack{StatusBadge(title:resultTitle(row["status"] as? String ?? "—"),color:backupResultColor(row["status"] as? String ?? ""));Text(row["id"] as? String ?? "");Text(backupTime(row["finished"] as? String)).font(.caption);Spacer();if let snapshot=row["snapshot"] as? String,let repository=row["repository_id"] as? String{Button("Восстановить"){m.selectedSnapshot=snapshot;m.preferredRepository=repository;m.restoreIncludes=[];m.section="Восстановление"}}};if let error=row["error"] as? String,!error.isEmpty{Text(error).font(.caption).foregroundStyle(.orange)};if let warning=row["maintenance_error"] as? String,!warning.isEmpty{Text("Обслуживание: "+warning).font(.caption).foregroundStyle(.orange)}}};if let loadError{Text(loadError).foregroundStyle(.orange)}
    }.onAppear{load()}}
    func load(){guard let server=m.current,!loading else{return};loading=true;loadError=nil;Task{defer{loading=false};do{let r=try await m.readLive(["action":"calendar"],server:server) as? [String:Any] ?? [:];records=r["records"] as? [[String:Any]] ?? [];groups=Dictionary(grouping:records,by:{$0["day"] as? String ?? ""});serverToday=r["today"] as? String ?? "";if selected.isEmpty{selected=serverToday}}catch{loadError=error.localizedDescription}}}
}
struct CapacityView:View {
    @EnvironmentObject var m:Model
    @State private var repository=""
    var activityKey:String{m.activityKey("capacity",repository:repository)}
    var activity:ServerActivityState{m.activities[activityKey] ?? ServerActivityState()}
    var data:[String:Any]{activity.data}
    var loading:Bool{activity.running}
    var loadError:String?{activity.error}
    var samples:[[String:Any]]{data["samples"] as? [[String:Any]] ?? []}
    var forecast:[String:Any]{data["forecast"] as? [String:Any] ?? [:]}
    var body:some View{VStack(alignment:.leading,spacing:18){WorkspaceIntro(title:"Рост хранилища",detail:"Измерения размера и прогноз свободного места",icon:"chart.line.uptrend.xyaxis")
        HStack{Picker("Хранилище",selection:$repository){Text("Выберите").tag("");ForEach(m.repositories.indices,id:\.self){i in Text(m.repositories[i]["id"] as? String ?? "").tag(m.repositories[i]["id"] as? String ?? "")}};Button("Измерить сейчас"){load()}.buttonStyle(BackupPrimaryButtonStyle()).disabled(repository.isEmpty || loading);if loading{ProgressView().controlSize(.small);Text(activity.message).font(.caption);Button("Отменить"){m.cancelActivity(activityKey)}.disabled(activity.operationID==nil)}}
        if let loadError{Text(loadError).foregroundStyle(.orange)}
        if let warning=data["warning"] as? String{StatusBadge(title:warning,color:.orange)}
        if !data.isEmpty{HStack{MetricCard(title:"Размер репозитория",value:bytes(data["bytes"]));MetricCard(title:"Свободное место",value:bytes(data["free"]));MetricCard(title:"Хватит примерно",value:(forecast["days_remaining"] as? Double).map{String(format:"%.1f дней",$0)} ?? "Недостаточно данных")}
            BackupPanel(title:"Размер копий",icon:"chart.xyaxis.line"){Chart{ForEach(samples.indices,id:\.self){i in let point=samples[i];if let date=backupDate(point["time"] as? String),let size=point["bytes"] as? Double{LineMark(x:.value("Дата",date),y:.value("ГБ",size/1_000_000_000));PointMark(x:.value("Дата",date),y:.value("ГБ",size/1_000_000_000))}}}.foregroundStyle(BackupTheme.blue).frame(height:240);Text("Чистый рост в день: "+bytes(forecast["bytes_per_day"])).font(.caption);Text(forecast["reason"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted)}
            Text(data["actual_size"] as? Bool==true ? "Измерен размер каталога на диске.":"Размер данных Restic приблизительный: служебные файлы и корзина облака могут занимать дополнительное место.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
        Text("Для S3 и SFTP укажите доступный объём в настройках хранилища. Для Яндекс Диска учитывается свободное место всего аккаунта. Измерения сохраняются на сервере; прогноз появится после двух измерений с интервалом от часа.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.onAppear{repository=m.preferredRepository.isEmpty ? m.repositories.first?["id"] as? String ?? "":m.preferredRepository}.task(id:activityKey){if !repository.isEmpty{await m.restoreActivity("capacity_start",key:activityKey,repository:repository)}}}
    func load(){m.startActivity("capacity_start",key:activityKey,repository:repository)}
}
