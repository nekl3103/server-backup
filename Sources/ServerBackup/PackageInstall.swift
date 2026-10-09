import SwiftUI

struct PackageInstallView:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    @State private var query=""
    @State private var candidates:[[String:Any]]=[]
    @State private var name=""
    @State private var plan=""
    @State private var planHash=""
    @State private var confirm=false
    var body:some View{VStack(alignment:.leading,spacing:16){
        HStack{WorkspaceIntro(title:"Установить программу",detail:"Пакеты из настроенных репозиториев APT сервера",icon:"shippingbox");Spacer();Button("Закрыть"){dismiss()}}
        HStack{TextField("Поиск в каталоге APT, например nginx",text:$query).onSubmit{search()};Button("Найти"){search()}.disabled(m.busy || query.count<2)}
        ScrollView{LazyVStack(alignment:.leading){ForEach(candidates.indices,id:\.self){i in let p=candidates[i];Button{name=p["name"] as? String ?? "";plan="";planHash=""}label:{VStack(alignment:.leading){Text(p["name"] as? String ?? "").font(.headline);Text(p["description"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted)}.frame(maxWidth:.infinity,alignment:.leading).padding(8).background(name==p["name"] as? String ? BackupTheme.blue.opacity(0.15):Color.clear)}.buttonStyle(.plain)}}}.frame(height:160)
        HStack{TextField("Точное имя пакета",text:$name).onChange(of:name){_,_ in plan="";planHash=""};Button("Проверить план установки"){m.perform(["action":"package_plan","name":name]){let r=$0 as? [String:Any] ?? [:];plan=r["output"] as? String ?? "";planHash=r["plan_hash"] as? String ?? "";m.result=""}}.disabled(m.busy || name.isEmpty)}
        if !planHash.isEmpty{ScrollView([.horizontal,.vertical]){Text(plan).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}.frame(height:180);Button("Установить «"+name+"»"){confirm=true}.buttonStyle(BackupPrimaryButtonStyle()).disabled(m.busy)}
        Text("Установка выполняется через systemd и продолжается без Mac. APT может добавить зависимости и запустить службу программы. Удаление пакетов запрещено; существующие конфигурации сохраняются. Индекс APT берётся с сервера.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.padding(24).frame(width:760).confirmationDialog("Установить пакет и зависимости по показанному плану?",isPresented:$confirm){Button("Установить"){m.perform(["action":"package_install","name":name,"plan_hash":planHash,"confirmed":true]){_ in m.notice="Установка запущена. Прогресс доступен в журнале операции."}}}}
    func search(){m.perform(["action":"package_search","query":query]){candidates=($0 as? [String:Any])?["packages"] as? [[String:Any]] ?? [];m.result=""}}
}
