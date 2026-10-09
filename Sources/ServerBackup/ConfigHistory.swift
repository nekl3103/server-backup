import SwiftUI
struct ConfigHistoryView:View {
    @EnvironmentObject var m:Model
    let unit:String
    let path:String
    let current:String
    let hash:String
    let onRestored:()->Void
    @State private var versions:[[String:Any]]=[]
    @State private var chosen=""
    @State private var content=""
    @State private var confirm=false
    @State private var loaded=false
    var body:some View{VStack(alignment:.leading,spacing:12){
        Button("Получить историю версий"){m.perform(["action":"config_versions","unit":unit,"path":path]){versions=($0 as? [String:Any])?["versions"] as? [[String:Any]] ?? [];m.result=""}}.disabled(m.busy)
        if !versions.isEmpty{Picker("Версия",selection:$chosen){Text("Выберите").tag("");ForEach(versions.indices,id:\.self){i in let version=versions[i];Text(backupTime(version["time"] as? String)+(version["exists"] as? Bool==false ? " · файла не было":"")).tag(version["id"] as? String ?? "")}}.onChange(of:chosen){_,id in loaded=false;content="";if !id.isEmpty{m.perform(["action":"config_version","unit":unit,"path":path,"version_id":id]){content=($0 as? [String:Any])?["content"] as? String ?? "";loaded=true;m.result=""}}}
            if !chosen.isEmpty && loaded{Text("− предыдущая версия · + текущая версия").font(.caption).foregroundStyle(BackupTheme.muted);ScrollView([.horizontal,.vertical]){Text(diff).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}.frame(height:170).padding(8).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8));Button("Вернуть выбранную версию"){confirm=true}.disabled(m.busy)}
        }else{Text("До первого сохранения версий может не быть.").font(.caption).foregroundStyle(BackupTheme.muted)}
    }.confirmationDialog("Вернуть предыдущую конфигурацию? Текущий файл будет сохранён, синтаксис проверен. Служба не перезапускается.",isPresented:$confirm){Button("Вернуть версию"){m.perform(["action":"rollback_config","unit":unit,"path":path,"version_id":chosen,"hash":hash,"confirmed":true]){_ in onRestored();chosen="";content="";m.result=""}}}}
    var diff:String{let before=content.components(separatedBy:"\n");let after=current.components(separatedBy:"\n");return after.difference(from:before).inferringMoves().map{change in switch change{case .remove(let offset,let element,_):return "− \(offset+1) "+element;case .insert(let offset,let element,_):return "+ \(offset+1) "+element}}.joined(separator:"\n")}
}
