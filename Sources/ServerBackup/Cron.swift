import SwiftUI

struct CronView:View {
    @EnvironmentObject var m:Model
    @State private var entries:[[String:Any]]=[]
    @State private var issues:[String]=[]
    @State private var timers=""
    @State private var timerError=""
    @State private var updated=""
    @State private var search=""
    @State private var kind="all"
    @State private var loaded=false
    @State private var editor:CronEditRequest?
    @State private var loading=false
    @State private var error=""
    var filtered:[[String:Any]]{entries.filter{entry in (kind=="all" || entry["kind"] as? String==kind) && (search.isEmpty || ["command","user","source","schedule"].contains{(entry[$0] as? String ?? "").localizedCaseInsensitiveContains(search)})}}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{WorkspaceIntro(title:"Cron и расписания сервера",detail:"Задачи пользователей, системные задания и таймеры systemd",icon:"clock.badge.checkmark");Button("Добавить задание"){editor=CronEditRequest(entry:nil)}.buttonStyle(.borderedProminent);Button("Обновить"){refresh()}.disabled(loading)}
        HStack{StatusBadge(title:loaded ? "Задач Cron: \(entries.count)":"Не загружено",color:loaded ? BackupTheme.blue:BackupTheme.muted);Spacer();if !updated.isEmpty{Text("Обновлено: "+String(updated.prefix(19)).replacingOccurrences(of:"T",with:" ")).font(.caption).foregroundStyle(BackupTheme.muted)}}
        HStack{Picker("Тип задач",selection:$kind){Text("Все").tag("all");Text("Пользователи").tag("user");Text("Системные").tag("system");Text("Периодические").tag("periodic");Text("Anacron").tag("anacron");Text("systemd").tag("timers")}.pickerStyle(.segmented);TextField("Поиск команды или пользователя",text:$search).frame(width:260)}
        if loading{ProgressView().controlSize(.small)};if !error.isEmpty{Text(error).foregroundStyle(.orange)}
        if kind=="timers"{timerPanel}else{
            if !issues.isEmpty{BackupPanel(title:"Часть данных недоступна",icon:"exclamationmark.triangle"){ForEach(issues,id:\.self){Text($0).font(.caption).foregroundStyle(.orange)}}}
            if filtered.isEmpty{BackupPanel(title:loaded ? "Задания не найдены":"Получите расписания сервера",icon:"calendar"){Text(loaded ? "Для выбранного типа и поиска нет записей.":"Подключитесь к серверу и нажмите «Обновить». Для просмотра всех пользователей нужен root или sudo.").foregroundStyle(BackupTheme.muted)}}
            ForEach(filtered.indices,id:\.self){i in let entry=filtered[i];BackupPanel(title:"",icon:""){
                HStack{Image(systemName:"clock").foregroundStyle(BackupTheme.blue);Text(humanCronSchedule(entry["schedule"] as? String ?? "—")).font(.callout.weight(.semibold));Spacer();StatusBadge(title:kindTitle(entry["kind"] as? String ?? ""));StatusBadge(title:entry["user"] as? String ?? "—")}
                HStack{Button("Редактировать"){editor=CronEditRequest(entry:entry)};Spacer()}
                Text(entry["command"] as? String ?? "").font(.system(.callout,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))
                HStack{Text(entry["source"] as? String ?? "").textSelection(.enabled);if let line=entry["line"] as? Int{Text("· строка \(line)")};Spacer();if let timezone=entry["timezone"] as? String{Text("TZ: "+timezone)}}.font(.caption).foregroundStyle(BackupTheme.muted)
                if entry["valid"] as? Bool==false{Text("Строка не распознана как стандартное задание Cron.").font(.caption).foregroundStyle(.orange)}
                if entry["enabled"] as? Bool==false{Text("У скрипта нет права запуска.").font(.caption).foregroundStyle(.orange)}
            }}
            Text("Для Cron показаны исходные расписания. Каталоги cron.daily / weekly запускаются согласно системному crontab или Anacron. Задания Server Backup находятся во вкладке systemd.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
    }.textFieldStyle(.roundedBorder).onAppear{if !m.probe.isEmpty{refresh()}}.sheet(item:$editor){CronEditor(entry:$0.entry,onSave:refresh).environmentObject(m)}}
    var timerPanel:some View{BackupPanel(title:"Таймеры systemd",subtitle:"Следующий и последний запуск — по времени сервера",icon:"calendar.badge.clock"){
        if !timerError.isEmpty{Text(timerError).foregroundStyle(.orange)}else{let text=search.isEmpty ? timers:timers.components(separatedBy:"\n").filter{$0.localizedCaseInsensitiveContains(search)}.joined(separator:"\n");ScrollView(.horizontal){Text(text.isEmpty ? "Таймеры не найдены":text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))}
    }}
    func kindTitle(_ value:String)->String{["user":"Cron пользователя","system":"Системный Cron","periodic":"Периодический","anacron":"Anacron"][value] ?? value}
    func refresh(){guard let server=m.current,!loading else{return};loading=true;error="";Task{do{let r=try await m.readLive(["action":"cron"],server:server) as? [String:Any] ?? [:];entries=r["entries"] as? [[String:Any]] ?? [];issues=r["issues"] as? [String] ?? [];timers=r["timers"] as? String ?? "";timerError=r["timer_error"] as? String ?? "";updated=r["updated"] as? String ?? "";loaded=true}catch{self.error=error.localizedDescription};loading=false}}
}
