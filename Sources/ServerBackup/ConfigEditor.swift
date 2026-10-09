import SwiftUI
struct ConfigEditorView:View {
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let unit:String
    let files:[[String:Any]]
    @Binding var path:String
    @Binding var content:String
    let original:String
    let hash:String
    let syntaxCheck:Bool
    let reload:()->Void
    let save:()->Void
    @State private var confirmSave=false
    var body:some View{VStack(alignment:.leading,spacing:16){
        HStack{WorkspaceIntro(title:"Редактор конфигурации",detail:unit,icon:"doc.text");Spacer();Button("Закрыть"){dismiss()}}
        HStack(alignment:.top,spacing:18){
            VStack(alignment:.leading,spacing:10){Text("Файлы на сервере").font(.headline);ScrollView{LazyVStack(alignment:.leading){ForEach(files.indices,id:\.self){i in let file=files[i];let name=file["path"] as? String ?? "";Button{if content==original{path=name}else{m.error="Сохраните изменения или загрузите файл заново перед выбором другого файла."}}label:{Label(name,systemImage:"doc.text").font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(path==name ? BackupTheme.blue.opacity(0.2):Color.clear)}.buttonStyle(.plain)}}}}.frame(width:260)
            VStack(alignment:.leading,spacing:10){HStack{Text(path).font(.system(.callout,design:.monospaced)).textSelection(.enabled);Spacer();if content != original{StatusBadge(title:"Не сохранено",color:.orange)}}
                TextEditor(text:$content).font(.system(size:13,design:.monospaced)).scrollContentBackground(.hidden).padding(12).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:10)).frame(minHeight:350)
                Text(syntaxCheck ? "Перед записью сохраняется предыдущая версия и проверяется активная конфигурация.":"Автоматическая проверка синтаксиса недоступна. Перед записью сохраняется предыдущая версия.").font(.caption).foregroundStyle(BackupTheme.muted)
                DisclosureGroup("История и сравнение версий"){ConfigHistoryView(unit:unit,path:path,current:original,hash:hash,onRestored:reload).id(unit+path).disabled(content != original || m.busy)}
                HStack{Button("Загрузить заново",action:reload).disabled(m.busy);Spacer();Button("Сохранить на сервер"){confirmSave=true}.buttonStyle(BackupPrimaryButtonStyle()).disabled(content==original || hash.isEmpty || m.busy)}
            }
        }
        if let error=m.error{Text(error).foregroundStyle(.orange).font(.caption)}
    }.padding(24).frame(width:1060,height:760).background(BackupTheme.panel).confirmationDialog("Сохранить конфигурацию на сервере без перезапуска службы?",isPresented:$confirmSave){Button("Сохранить",action:save)}}
}
