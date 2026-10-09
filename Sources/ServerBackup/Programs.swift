import SwiftUI

struct ProgramsView:View {
    @EnvironmentObject var m:Model
    @State private var packages:[[String:Any]]=[]
    @State private var services:[[String:Any]]=[]
    @State private var search=""
    @State private var tab="services"
    @State private var category="all"
    @State private var showInstall=false
    @State private var showEditor=false
    @State private var selected=""
    @State private var files:[[String:Any]]=[]
    @State private var path=""
    @State private var content=""
    @State private var original=""
    @State private var hash=""
    @State private var syntaxCheck=false
    @State private var pendingAction=""
    @State private var confirmAction=false
    @State private var confirmSave=false
    @State private var packageError=""
    @State private var serviceError=""
    @State private var feedback=""
    @State private var journal=""
    @State private var journalOpen=false
    @State private var packageLimit=100
    var current:[String:Any]?{services.first{$0["unit"] as? String==selected}}
    var filteredServices:[[String:Any]]{services.filter{serviceCategory($0) && (search.isEmpty || String(describing:$0["unit"] ?? "").localizedCaseInsensitiveContains(search) || String(describing:$0["description"] ?? "").localizedCaseInsensitiveContains(search))}}
    var filteredPackages:[[String:Any]]{packages.filter{(category=="all" || $0["category"] as? String==category) && (search.isEmpty || ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(search))}}
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{WorkspaceIntro(title:"Программы сервера",detail:"Установленные пакеты, состояние служб и конфигурации",icon:"square.stack.3d.up");Button("Установить программу"){showInstall=true};Button("Обновить"){refresh()}.disabled(m.busy)}
        HStack{Picker("Показать",selection:$tab){Text("Службы").tag("services");Text("Все пакеты · \(packages.count)").tag("packages")}.pickerStyle(.segmented).frame(width:330);Spacer();TextField("Поиск программы",text:$search).frame(width:260)}
        Picker("Группа",selection:$category){Text("Все").tag("all");Text(tab=="services" ? "Серверные программы":"Установлены вручную").tag("manual");Text("Системные").tag("system");if tab=="packages"{Text("Зависимости").tag("dependency");Text("Не определено").tag("unknown")}}.pickerStyle(.segmented)
        Text(tab=="services" ? "Серверные программы — поддерживаемые приложением службы. Остальные службы показаны отдельно как системные.":"Системные — Essential / Priority required и important. Вручную и зависимости — по меткам APT; это не история установки.").font(.caption).foregroundStyle(BackupTheme.muted)
        if tab=="packages"{packageList}else{serviceList}
    }.textFieldStyle(.roundedBorder).onAppear{if !m.probe.isEmpty{refresh()}}.onChange(of:tab){_,_ in category="all"}
        .sheet(isPresented:$showInstall){PackageInstallView()}
        .sheet(isPresented:$showEditor){ConfigEditorView(unit:selected,files:files,path:$path,content:$content,original:original,hash:hash,syntaxCheck:syntaxCheck,reload:readConfig,save:saveConfig)}
        .confirmationDialog(actionTitle+" · "+selected+"?",isPresented:$confirmAction){Button(actionTitle){act()}}
        .confirmationDialog("Сохранить конфигурацию без перезапуска службы?",isPresented:$confirmSave){Button("Сохранить"){saveConfig()}}
    }
    var packageList:some View{BackupPanel(title:"Установленные пакеты",subtitle:"Пакеты dpkg / APT и их версии",icon:"shippingbox"){
        if !packageError.isEmpty{Text(packageError).foregroundStyle(.orange)}
        HStack{Text("Название").frame(maxWidth:.infinity,alignment:.leading);Text("Версия").frame(width:220,alignment:.leading);Text("Архитектура").frame(width:100,alignment:.leading)}.font(.caption).foregroundStyle(BackupTheme.muted)
        ForEach(Array(filteredPackages.prefix(packageLimit).enumerated()),id:\.offset){index,p in HStack{Text(p["name"] as? String ?? "").font(.system(.callout,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading);Text(p["version"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted).frame(width:220,alignment:.leading);Text(p["architecture"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted).frame(width:100,alignment:.leading)}.padding(.vertical,6);if index<min(packageLimit,filteredPackages.count)-1{Divider()}}
        if filteredPackages.count>packageLimit{Button("Показать ещё 100"){packageLimit+=100}}
        Text("Показано \(min(packageLimit,filteredPackages.count)) из \(filteredPackages.count). Здесь отображаются пакеты системы; приложения внутри Docker смотрите в разделе Docker.").font(.caption).foregroundStyle(BackupTheme.muted)
    }}
    var serviceList:some View{HStack(alignment:.top,spacing:18){BackupPanel(title:"Службы systemd",subtitle:"Выберите программу для просмотра настроек",icon:"gearshape.2"){
        if !serviceError.isEmpty{Text(serviceError).font(.caption).foregroundStyle(.orange)}
        if filteredServices.isEmpty{Text("Нет данных. Подключитесь к серверу и обновите список.").foregroundStyle(BackupTheme.muted)}
        ScrollView{LazyVStack(spacing:3){ForEach(filteredServices.indices,id:\.self){i in let service=filteredServices[i];let unit=service["unit"] as? String ?? "";Button{select(unit)}label:{HStack(spacing:10){Image(systemName:service["manageable"] as? Bool==true ? "slider.horizontal.3":"gearshape").foregroundStyle(BackupTheme.blue);VStack(alignment:.leading,spacing:4){Text(unit).font(.system(size:13,weight:.medium));Text(service["description"] as? String ?? "Системная служба").font(.caption).foregroundStyle(BackupTheme.muted).lineLimit(1)};Spacer();StatusBadge(title:status(service),color:service["active"] as? String=="active" ? .green:BackupTheme.muted)}.padding(10).background(selected==unit ? BackupTheme.blue.opacity(0.15):.clear).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain).disabled(m.busy)}}}.frame(height:500)
    };VStack(spacing:18){if let service=current{serviceControls(service);configuration}else{BackupPanel(title:"Настройки программы",icon:"slider.horizontal.3"){Text("Выберите службу слева. Управление доступно для Nginx, Apache, PHP-FPM, MySQL / MariaDB, PostgreSQL, Redis и Docker.").font(.callout).foregroundStyle(BackupTheme.muted)}}}.frame(width:380)}}
    func serviceControls(_ service:[String:Any])->some View{BackupPanel(title:selected,icon:"gearshape"){
        HStack{StatusBadge(title:status(service),color:service["active"] as? String=="active" ? .green:BackupTheme.muted);StatusBadge(title:service["enabled"] as? String ?? "Автозапуск неизвестен")}
        if service["manageable"] as? Bool==true{HStack{Button("Запустить"){ask("start")};Button("Остановить"){ask("stop")};Button("Перезапустить"){ask("restart")}};HStack{Button("Перечитать настройки"){ask("reload")};Menu("Автозапуск"){Button("Включить"){ask("enable")};Button("Выключить"){ask("disable")}}}}else{Text("Эта системная служба доступна для просмотра. Изменения через приложение ограничены основными серверными программами.").font(.caption).foregroundStyle(BackupTheme.muted)}
        Button("Журнал службы"){m.perform(["action":"program_journal","unit":selected]){journal=($0 as? [String:Any])?["output"] as? String ?? "";journalOpen=true}}
        if journalOpen{DisclosureGroup("Журнал",isExpanded:$journalOpen){ScrollView([.horizontal,.vertical]){Text(journal.isEmpty ? "Нет записей":journal).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}.frame(height:180)}}
    }.disabled(m.busy)}
    var configuration:some View{BackupPanel(title:"Конфигурация",icon:"doc.text"){
        if current?["manageable"] as? Bool==true{
            if files.isEmpty{Text("Поддерживаемые конфигурационные файлы не найдены.").font(.caption).foregroundStyle(BackupTheme.muted)}else{
                Picker("Файл",selection:Binding(get:{path},set:{new in if content != original && !hash.isEmpty{m.error="Сохраните изменения или загрузите файл заново"}else{path=new}})){Text("Выберите файл").tag("");ForEach(files.indices,id:\.self){i in let file=files[i];Text((file["path"] as? String ?? "")+(file["exists"] as? Bool==false ? " · создать":"")).tag(file["path"] as? String ?? "")}}.onChange(of:path){_,new in if !new.isEmpty{readConfig()}}
                if !path.isEmpty{Text(path).font(.system(.caption,design:.monospaced)).foregroundStyle(BackupTheme.muted).textSelection(.enabled)}
                if !hash.isEmpty{Button("Открыть редактор конфигурации"){showEditor=true}.buttonStyle(BackupPrimaryButtonStyle());Text(content != original ? "Есть несохранённые изменения":"Файл загружен · \(content.components(separatedBy:"\n").count) строк").font(.caption).foregroundStyle(BackupTheme.muted)}
            }
            if !feedback.isEmpty{Text(feedback).font(.caption).foregroundStyle(.green)}
            Text("Перед записью сохраняется резервная копия файла. Чтобы применить изменения, используйте отдельное действие службы.").font(.caption).foregroundStyle(BackupTheme.muted)
        }else{Text("Редактор конфигурации для этой службы недоступен.").font(.caption).foregroundStyle(BackupTheme.muted)}
    }.disabled(m.busy)}
    var actionTitle:String{["start":"Запустить","stop":"Остановить","restart":"Перезапустить","reload":"Перечитать настройки","enable":"Включить автозапуск","disable":"Выключить автозапуск"][pendingAction] ?? "Выполнить"}
    func serviceCategory(_ service:[String:Any])->Bool{category=="all" || (category=="manual" && service["manageable"] as? Bool==true) || (category=="system" && service["manageable"] as? Bool != true)}
    func status(_ service:[String:Any])->String{switch service["active"] as? String{case "active":return "Работает";case "inactive":return "Остановлена";case "failed":return "Ошибка";case "activating":return "Запускается";case "deactivating":return "Останавливается";default:return "Неизвестно"}}
    func refresh(){m.perform(["action":"programs"]){value in let r=value as? [String:Any] ?? [:];packages=r["packages"] as? [[String:Any]] ?? [];services=r["services"] as? [[String:Any]] ?? [];packageError=r["package_error"] as? String ?? "";serviceError=r["service_error"] as? String ?? ""}}
    func select(_ unit:String){guard selected != unit else{return};if !hash.isEmpty && content != original{m.error="Сохраните изменения или загрузите файл заново";return};selected=unit;files=[];path="";hash="";content="";original="";feedback="";journal="";journalOpen=false;if current?["manageable"] as? Bool==true{m.perform(["action":"program_config","unit":unit]){let r=$0 as? [String:Any] ?? [:];files=r["files"] as? [[String:Any]] ?? [];syntaxCheck=r["syntax_check"] as? Bool ?? false;path=files.first?["path"] as? String ?? "";if !path.isEmpty{readConfig()}}}}
    func readConfig(){m.perform(["action":"program_config","unit":selected,"path":path]){let r=$0 as? [String:Any] ?? [:];content=r["content"] as? String ?? "";original=content;hash=r["hash"] as? String ?? "";syntaxCheck=r["syntax_check"] as? Bool ?? false;feedback="";m.result=""}}
    func saveConfig(){let submitted=content;m.perform(["action":"save_program_config","unit":selected,"path":path,"content":submitted,"hash":hash,"confirmed":true]){let r=$0 as? [String:Any] ?? [:];hash=r["hash"] as? String ?? hash;original=submitted;feedback="Сохранено. Служба не перезапускалась.";m.result=""}}
    func ask(_ action:String){if !hash.isEmpty && content != original{m.error="Сначала сохраните изменения конфигурации";return};pendingAction=action;confirmAction=true}
    func act(){m.perform(["action":"service_action","unit":selected,"operation":pendingAction,"confirmed":true]){_ in feedback="Действие выполнено";refresh()}}
}
