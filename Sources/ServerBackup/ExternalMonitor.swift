import SwiftUI

struct ExternalMonitorView:View {
    @EnvironmentObject var m:Model
    @State private var selected=Set<String>()
    @State private var enabled=true
    @State private var confirm=false
    @State private var status:[String:Any]=[:]
    @State private var feedback=""
    @State private var selectedResult:CheckResult?
    var activityKey:String{m.activityKey("external")}
    var activity:ServerActivityState{m.activities[activityKey] ?? ServerActivityState()}
    var checking:Bool{activity.running}
    var checkError:String?{activity.error}
    @State private var statusLoading=false
    @State private var configuring=false
    @State private var settingsLoaded=false
    @State private var generation=UUID()
    var candidates:[Server]{m.servers.filter{$0.id != m.selectedID && $0.host != m.current?.host}}
    var settings:[String:Any]{status["settings"] as? [String:Any] ?? [:]}
    var savedTargets:Set<String>{Set((settings["targets"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})}
    var configured:Bool{settings["enabled"] as? Bool==true && !savedTargets.isEmpty}
    var dirty:Bool{selected != savedTargets || enabled != (settings["enabled"] as? Bool ?? true)}
    var states:[[String:Any]]{
        let values=(status["states"] as? [[String:Any]] ?? [])+(activity.data["servers"] as? [[String:Any]] ?? [])
        var latest:[String:[String:Any]]=[:]
        for row in values{let id=row["id"] as? String ?? row["name"] as? String ?? "";if let current=latest[id],(current["updated"] as? String ?? "") >= (row["updated"] as? String ?? ""){continue};latest[id]=row}
        return latest.values.filter{savedTargets.contains($0["id"] as? String ?? "") || m.isDesignPreview}.sorted{($0["name"] as? String ?? "")<($1["name"] as? String ?? "")}
    }
    var body:some View{VStack(alignment:.leading,spacing:18){WorkspaceIntro(title:"Внешний контроль",detail:"Этот сервер проверяет остальные каждые 10 минут, даже когда Mac выключен",icon:"network.badge.shield.half.filled")
        BackupPanel(title:"Сервер-наблюдатель: "+(m.current?.name ?? ""),icon:"server.rack"){
            Text("Выберите серверы, которые нужно наблюдать. На них установится отдельный SSH-ключ, разрешающий только получение состояния бэкапов. Пароли профилей на наблюдатель не копируются.").font(.callout).foregroundStyle(BackupTheme.muted)
            HStack{StatusBadge(title:configured ? "Контроль настроен":"Контроль не настроен или выключен",color:configured ? .green:.orange);if statusLoading{ProgressView().controlSize(.small)}}
            if let timer=status["timer"] as? [String:String],configured{Text(timer["ActiveState"]=="active" ? "Таймер активен · проверка каждые 10 минут":"Таймер не активен: повторите настройку контроля").font(.caption).foregroundStyle(timer["ActiveState"]=="active" ? BackupTheme.muted:.orange)}
            if candidates.isEmpty{Text("Добавьте другой сервер с отдельным адресом.").foregroundStyle(.orange)}
            ForEach(candidates){server in Toggle(server.name+" · "+server.host,isOn:Binding(get:{selected.contains(server.id)},set:{if $0{selected.insert(server.id)}else{selected.remove(server.id)}})).disabled(configuring || statusLoading)}
            Toggle("Включить внешний контроль",isOn:$enabled).disabled(configuring || statusLoading)
            if selected.isEmpty && enabled{Label("Выберите хотя бы один сервер выше, затем нажмите «Настроить контроль».",systemImage:"info.circle").font(.callout).foregroundStyle(BackupTheme.blue)}else if dirty && settingsLoaded{Text("Изменения ещё не сохранены. Примените настройку контроля.").font(.caption).foregroundStyle(.orange)}
            HStack{Button(configuring ? "Настраивается…":configured ? "Применить изменения":"Настроить контроль"){confirm=true}.buttonStyle(BackupPrimaryButtonStyle()).disabled(configuring || statusLoading || (enabled && selected.isEmpty));Button(checking ? "Проверяется…":"Проверить сейчас"){test()}.disabled(configuring || checking || !configured);Button("Обновить состояние"){load()}.disabled(statusLoading || configuring)}
            if configuring{HStack{ProgressView().controlSize(.small);Text(feedback).font(.caption)}}
            if checking{HStack{ProgressView().controlSize(.small);Text(activity.message).font(.caption);Button("Отменить"){m.cancelActivity(activityKey)}.disabled(activity.operationID==nil)}}
            if let checkError{Text(checkError).font(.caption).foregroundStyle(.orange)}
            if !activity.message.isEmpty && !checking{Text(activity.message).font(.caption).foregroundStyle(BackupTheme.muted)}
            if !feedback.isEmpty && !configuring{Text(feedback).font(.caption).foregroundStyle(BackupTheme.muted)}
            Text("Уведомления отправляет сервер-наблюдатель: настройте на нём Telegram или почту. Недоступность самого наблюдателя требует второго независимого наблюдателя.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
        BackupPanel(title:"Состояние наблюдаемых серверов",icon:"checklist"){
            let states=self.states
            if states.isEmpty{Text("Проверок пока нет. Настройте контроль и нажмите «Проверить сейчас».").foregroundStyle(BackupTheme.muted)}
            ForEach(states.indices,id:\.self){i in let record=states[i];Button{selectedResult=CheckResult(value:record)}label:{VStack(alignment:.leading,spacing:8){HStack{Text(record["name"] as? String ?? "").font(.headline);Spacer();StatusBadge(title:record["issue"] as? String==nil ? "Доступен":"Требует внимания",color:record["issue"] as? String==nil ? .green:.orange);Image(systemName:"chevron.right")};Text(backupTime(record["updated"] as? String)).font(.caption).foregroundStyle(BackupTheme.muted);if let issue=record["issue"] as? String{Text(issue).foregroundStyle(.orange)}}.padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())}.buttonStyle(.plain)}
        }
    }.sheet(item:$selectedResult){CheckResultDetails(value:$0.value)}.onAppear{load()}.onChange(of:checking){_,running in if !running{load()}}.task{await m.restoreActivity("external_test",key:activityKey)}.confirmationDialog("Настроить наблюдатель и разрешить ему ограниченный SSH-доступ к выбранным серверам?",isPresented:$confirm){Button("Настроить"){prepare()}}}
    func test(){m.startActivity("external_test",key:activityKey)}
    func load(){guard let server=m.current,!statusLoading else{return};statusLoading=true
        Task{defer{statusLoading=false};do{let value=try await m.readLive(["action":"external_status"],server:server) as? [String:Any] ?? [:];guard m.selectedID==server.id else{return};let apply = !settingsLoaded;status=value;if apply{selected=savedTargets;enabled=settings["enabled"] as? Bool ?? true;settingsLoaded=true};if !checking{m.activities[activityKey]?.data=["servers":status["states"] ?? []]}}catch{feedback=error.localizedDescription}}
    }
    func prepare(){guard let observer=m.current,!configuring else{return};if m.isDesignPreview{m.error="В демонстрационном режиме настройка отключена";return};let targets=candidates.filter{selected.contains($0.id)};let active=enabled;configuring=true;m.error=nil;feedback="Настройка доступа…"
        Task{do{let result=try await Task.detached{() throws -> Any in
                    for server in targets{guard FileManager.default.fileExists(atPath:Paths.known(server.id).path) else{throw AppFailure(message:"Сначала подключитесь к "+server.name+" и подтвердите SSH-ключ")}}
                    let key=try SSH.call(observer,["action":"external_key"]) as? [String:Any] ?? [:];guard let publicKey=key["public_key"] as? String else{throw AppFailure(message:"Не удалось получить ключ наблюдателя")}
                    var profiles:[[String:Any]]=[]
                    for server in targets{_=try SSH.call(server,["action":"allow_monitor","user":server.user,"public_key":publicKey,"confirmed":true]);profiles.append(["id":server.id,"name":server.name,"host":server.host,"port":server.port,"user":server.user,"known_hosts":try String(contentsOf:Paths.known(server.id),encoding:.utf8)])}
                    return try SSH.call(observer,["action":"external_setup","targets":profiles,"enabled":active,"confirmed":true])
                }.value
                guard m.selectedID==observer.id else{configuring=false;return}
                configuring=false;feedback=active ? "Контроль настроен. Начинается первая проверка…":"Контроль выключен.";m.result=Model.pretty(result);settingsLoaded=false;load();if active{test()}
            }catch{configuring=false;m.error=error.localizedDescription;feedback="Настройка не завершена: "+error.localizedDescription}}
    }
}
