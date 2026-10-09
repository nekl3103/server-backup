import SwiftUI
import Combine

func workspaceIcon(_ s:String)->String {switch s{case "Обзор":return "square.grid.2x2";case "Хранилища":return "externaldrive";case "Задания":return "calendar";case "Базы данных":return "cylinder.split.1x2";case "Docker":return "shippingbox";case "Терминал":return "terminal";case "Файлы":return "folder";case "Программы":return "square.stack.3d.up";case "Cron":return "clock.badge.checkmark";case "Копии":return "clock.arrow.circlepath";case "Восстановление":return "arrow.counterclockwise";case "Мониторинг":return "chart.xyaxis.line";case "Уведомления":return "bell";case "Центр ошибок":return "exclamationmark.bubble";default:return "text.alignleft"}}
struct ServerSidebar:View {
    @EnvironmentObject var m:Model
    let server:Server
    let onEdit:()->Void
    var body:some View{VStack(alignment:.leading,spacing:20){
        Button{m.selectedID=nil;m.section="Обзор"}label:{Label("Все серверы",systemImage:"chevron.left")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted).disabled(m.busy)
        VStack(alignment:.leading,spacing:10){HStack{Image(systemName:"server.rack").foregroundStyle(BackupTheme.blue);Text(server.name).font(.headline);Spacer()};Text(server.user+"@"+server.host).font(.caption).foregroundStyle(BackupTheme.muted).lineLimit(1);StatusBadge(title:m.busy && m.probe.isEmpty ? "Подключение…":m.probe.isEmpty ? "Не подключён":m.connectionOnline ? "Подключён":"Нет связи",color:m.probe.isEmpty ? BackupTheme.muted:m.connectionOnline ? .green:.orange)}.padding(14).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:12))
        ScrollView{VStack(alignment:.leading,spacing:5){Text("НАСТРОЙКА").font(.system(size:10,weight:.semibold)).foregroundStyle(BackupTheme.muted).padding(.horizontal,12).padding(.bottom,6);ForEach(Array(sections.prefix(5)),id:\.self){item in navigation(item)};Text("УПРАВЛЕНИЕ").font(.system(size:10,weight:.semibold)).foregroundStyle(BackupTheme.muted).padding(.horizontal,12).padding(.top,20).padding(.bottom,6);ForEach(Array(sections.dropFirst(5)),id:\.self){item in navigation(item)}}}
        Button(action:onEdit){Label("SSH-подключение",systemImage:"gearshape")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted).disabled(m.busy)
    }.padding(18).frame(width:225).frame(maxHeight:.infinity,alignment:.top).background(BackupTheme.sidebar)}
    func navigation(_ item:String)->some View{Button{m.section=item}label:{HStack(spacing:10){Image(systemName:workspaceIcon(item)).frame(width:19);Text(item).font(.system(size:13,weight:m.section==item ? .semibold:.regular));Spacer();if done(item){Circle().fill(.green).frame(width:5,height:5)}}.padding(.horizontal,12).padding(.vertical,11).contentShape(Rectangle()).foregroundStyle(m.section==item ? .white:BackupTheme.muted).background(m.section==item ? BackupTheme.blue.opacity(0.20):.clear).clipShape(RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain).disabled(m.busy)}
    func done(_ item:String)->Bool{switch item{case "Обзор":return m.installed;case "Хранилища":return !m.repositories.isEmpty;case "Задания":return !m.jobs.isEmpty;case "Базы данных":return !m.databases.isEmpty;case "Docker":return m.jobs.contains{!($0["containers"] as? [[String:Any]] ?? []).isEmpty};default:return false}}
}
struct WorkspaceHeader:View {
    @EnvironmentObject var m:Model
    let server:Server
    var body:some View{HStack{VStack(alignment:.leading,spacing:5){Text(m.section).font(.system(size:25,weight:.bold));Text(server.name+" · "+server.host).font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();if m.busy{ProgressView().controlSize(.small);Text("Выполняется…").font(.caption).foregroundStyle(BackupTheme.muted)};Button{m.connect()}label:{Label(m.probe.isEmpty ? "Подключиться":"Обновить",systemImage:"arrow.clockwise")}.disabled(m.busy)}}
}
struct OverviewView:View {
    @EnvironmentObject var m:Model
    @State private var confirmInstall=false
    var done:Int{[!m.probe.isEmpty,m.installed,!m.repositories.isEmpty,!m.jobs.isEmpty,m.successfulBackup != nil].filter{$0}.count}
    var nextTitle:String{if m.probe.isEmpty{return "Подключить сервер"};if !m.installed{return "Установить инструменты"};if m.repositories.isEmpty{return "Подключить хранилище"};if m.jobs.isEmpty{return "Создать задание"};return "Открыть задания"}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack(spacing:14){summary("Система",(m.probe["os"] as? [String:String])?["PRETTY_NAME"] ?? "Не проверена","server.rack");summary("Хранилища",m.workspaceLoaded ? String(m.repositories.count):"—","externaldrive");summary("Задания",m.workspaceLoaded ? String(m.jobs.count):"—","calendar");summary("Последний бэкап",m.successfulBackup.map{shortTime($0["finished"] as? String ?? "")} ?? (m.workspaceLoaded ? "Нет успешных копий":"Не проверен"),"clock.arrow.circlepath")}
        HStack(alignment:.top,spacing:18){
            BackupPanel(title:"Готовность сервера",subtitle:"Что выполнено и что ещё нужно настроить",icon:"checklist"){
                HStack{GeometryReader{geometry in Capsule().fill(Color.white.opacity(0.08)).overlay(alignment:.leading){Capsule().fill(BackupTheme.blue).frame(width:geometry.size.width*Double(done)/5)}}.frame(height:5).accessibilityLabel("Готовность сервера: \(done) из 5");Text("\(done) из 5").font(.caption).foregroundStyle(BackupTheme.muted)}
                StepRow(number:1,title:"SSH-подключение",detail:"Проверка ключа сервера и прав доступа",status:m.probe.isEmpty ? "Ожидает":"Подключён",complete:!m.probe.isEmpty,enabled:!m.busy){m.connect()}
                StepRow(number:2,title:"Restic и серверный помощник",detail:m.installed ? (m.tools["restic"] as? String ?? "Установлены"):"Инструменты для автономных бэкапов",status:m.installed ? "Установлены":"Не установлены",complete:m.installed,enabled:!m.busy && !m.probe.isEmpty){confirmInstall=true}
                StepRow(number:3,title:"Хранилище",detail:"Диск, SFTP, S3 или Яндекс Диск",status:status(!m.repositories.isEmpty),complete:!m.repositories.isEmpty,enabled:!m.busy){m.section="Хранилища"}
                StepRow(number:4,title:"Ежедневное задание",detail:"Выбрать файлы, расписание и срок хранения",status:status(!m.jobs.isEmpty),complete:!m.jobs.isEmpty,enabled:!m.busy){m.section="Задания"}
                StepRow(number:5,title:"Первая успешная копия",detail:"Запустить задание и проверить результат",status:m.successfulBackup != nil ? "Выполнено":m.workspaceLoaded ? "Нет копий":"Не проверено",complete:m.successfulBackup != nil,enabled:!m.busy){m.section="Задания"}
            }
            VStack(spacing:18){BackupPanel(title:done==5 ? "Сервер настроен":"Следующий шаг",icon:done==5 ? "checkmark.shield":"arrow.right.circle"){
                Text(nextTitle).font(.title3.bold());Text(nextDetail).font(.callout).foregroundStyle(BackupTheme.muted)
                Button(nextTitle){next()}.buttonStyle(BackupPrimaryButtonStyle()).controlSize(.large).disabled(m.busy).frame(maxWidth:.infinity,alignment:.leading)
            };BackupPanel(title:"Дополнительно",subtitle:"Подключите только то, что нужно",icon:"slider.horizontal.3"){
                extra("Базы данных","Согласованные дампы MySQL и PostgreSQL","cylinder.split.1x2",m.databases.isEmpty ? "Не настроены":"Подключено: \(m.databases.count)")
                Divider();extra("Docker","Compose, контейнеры и тома","shippingbox",m.tools["docker"] as? String != nil ? "Обнаружен":"Не проверен")
                Divider();extra("Уведомления","Telegram или электронная почта","bell","Необязательно")
            };Text("Бэкапы выполняются на сервере, даже когда Mac выключен.").font(.caption).foregroundStyle(BackupTheme.muted).padding(.horizontal,4)
            }.frame(width:300)
        }
        if !m.probe.isEmpty{DisclosureGroup("Сведения о системе и инструментах"){JSONOutput(value:m.tools)}}
    }.confirmationDialog(m.installed ? "Обновить серверный помощник?":"Установить Restic и серверный помощник?",isPresented:$confirmInstall){Button(m.installed ? "Обновить":"Установить"){m.perform(["action":"install"]){_ in m.loadProbe()}}}}
    var nextDetail:String{if m.probe.isEmpty{return "Подключитесь по SSH, чтобы проверить систему и получить актуальное состояние."};if !m.installed{return "Установите Restic и помощник. После этого можно подключить хранилище."};if m.repositories.isEmpty{return "Выберите, где хранить зашифрованные резервные копии."};if m.jobs.isEmpty{return "Выберите папки и задайте ежедневное время запуска."};return "Запустите пробную копию или проверьте расписание существующих заданий."}
    func next(){if m.probe.isEmpty{m.connect()}else if !m.installed{confirmInstall=true}else{m.section=m.repositories.isEmpty ? "Хранилища":"Задания"}}
    func status(_ complete:Bool)->String{complete ? "Настроено":m.workspaceLoaded ? "Не настроено":"Не проверено"}
    func summary(_ title:String,_ value:String,_ icon:String)->some View{BackupPanel(title:""){HStack{Text(title).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Image(systemName:icon).foregroundStyle(BackupTheme.blue)};Text(value).font(.system(size:16,weight:.semibold)).lineLimit(1)}}
    func extra(_ title:String,_ detail:String,_ icon:String,_ state:String)->some View{Button{m.section=title}label:{HStack(alignment:.top,spacing:10){Image(systemName:icon).foregroundStyle(BackupTheme.blue).frame(width:20);VStack(alignment:.leading,spacing:5){Text(title).font(.callout.bold()).foregroundStyle(.primary);Text(detail).font(.caption).foregroundStyle(BackupTheme.muted).fixedSize(horizontal:false,vertical:true);Text(state).font(.system(size:10)).foregroundStyle(BackupTheme.muted)};Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(BackupTheme.muted)}}.buttonStyle(.plain).disabled(m.busy)}
    func shortTime(_ value:String)->String{guard let date=ISO8601DateFormatter().date(from:value) else{return String(value.prefix(16))};return date.formatted(date:.abbreviated,time:.shortened)}
}
