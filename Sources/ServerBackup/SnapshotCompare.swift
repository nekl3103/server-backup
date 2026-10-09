import SwiftUI

struct SnapshotCompareView:View{
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let repository:String
    let snapshot:String
    let roots:[String]
    @State private var path="/"
    @State private var target="/"
    @State private var rows:[[String:Any]]=[]
    @State private var counts:[String:Int]=[:]
    @State private var total=0
    @State private var offset=0
    @State private var loading=false
    @State private var error=""
    @State private var differences=false
    @State private var contentRow:CheckResult?
    @State private var history:[(String,String)]=[]
    var titles:[String:String]{["changed":"Изменён","missing":"Только в копии","server_only":"Только на сервере","same_metadata":"Метаданные совпадают","unavailable":"Недоступен"]}
    var body:some View{VStack(alignment:.leading,spacing:16){
        HStack{Label("Копия и текущие файлы сервера",systemImage:"arrow.left.arrow.right").font(.title2);Spacer();Button("Закрыть"){dismiss()}}
        Text("Сравниваются тип, размер, время изменения, права и владелец. Содержимое файлов не читается: совпадение метаданных не гарантирует совпадение содержимого.").font(.caption).foregroundStyle(BackupTheme.muted)
        HStack{VStack(alignment:.leading){Text("Папка в копии").font(.caption);TextField("/",text:$path).disabled(loading)};Image(systemName:"arrow.left.arrow.right");VStack(alignment:.leading){Text("Папка на сервере").font(.caption);TextField("/",text:$target).disabled(loading)};Button("Сравнить"){offset=0;history=[];load()}.buttonStyle(.borderedProminent).disabled(loading)}
        if !roots.isEmpty{HStack{Text("Источники:").font(.caption);ForEach(roots,id:\.self){root in Button(root){path=root;target=root;offset=0;history=[];load()}.font(.caption).disabled(loading)}}}
        HStack{Button("Выше"){if let previous=history.popLast(){path=previous.0;target=previous.1}else{path=URL(fileURLWithPath:path).deletingLastPathComponent().path;target=URL(fileURLWithPath:target).deletingLastPathComponent().path};offset=0;load()}.disabled(loading || path=="/");Toggle("Только различия",isOn:$differences).toggleStyle(.checkbox).disabled(loading).onChange(of:differences){_,_ in offset=0;load()};Spacer();if loading{ProgressView().controlSize(.small)}}
        HStack{ForEach(["changed","missing","server_only","same_metadata"],id:\.self){status in StatusBadge(title:(titles[status] ?? status)+": "+String(counts[status] ?? 0),color:status=="same_metadata" ? BackupTheme.muted:BackupTheme.blue)}}
        if !error.isEmpty{Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
        ScrollView{LazyVStack(alignment:.leading,spacing:6){ForEach(rows.indices,id:\.self){index in let row=rows[index];HStack{
            Image(systemName:row["folder"] as? Bool==true ? "folder.fill":"doc").foregroundStyle(BackupTheme.blue)
            if row["snapshot_folder"] as? Bool==true{Button(row["name"] as? String ?? ""){history.append((path,target));path=row["path"] as? String ?? path;target=row["target"] as? String ?? target;offset=0;load()}.buttonStyle(.plain).disabled(loading)}else{Text(row["name"] as? String ?? "").textSelection(.enabled)}
            if row["folder"] as? Bool != true && row["status"] as? String != "missing" && row["status"] as? String != "server_only"{Button("Содержимое"){contentRow=CheckResult(value:row)}};Spacer();VStack(alignment:.trailing,spacing:3){Text(titles[row["status"] as? String ?? ""] ?? "—").font(.caption.weight(.medium));if let reason=row["reason"] as? String,!reason.isEmpty{Text(reason).font(.caption).foregroundStyle(BackupTheme.muted)}}
        }.padding(10).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))};if rows.isEmpty && !loading && error.isEmpty{Text(differences ? "Различий в этой папке не обнаружено по метаданным":"В папке нет объектов").foregroundStyle(BackupTheme.muted)}}}.frame(minHeight:280)
        HStack{Text("Объектов: \(total). Подпапки открываются нажатием на название.").font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Button("Назад"){offset=max(0,offset-250);load()}.disabled(offset==0 || loading);Text("\(offset/250+1) / \(max(1,(total+249)/250))").font(.caption);Button("Далее"){offset+=250;load()}.disabled(offset+rows.count>=total || loading)}
    }.padding(24).frame(width:960,height:660).textFieldStyle(.roundedBorder).sheet(item:$contentRow){ContentComparisonView(repository:repository,snapshot:snapshot,path:$0.value["path"] as? String ?? "",target:$0.value["target"] as? String ?? "")}.task{path=roots.first ?? "/";target=path;load()}}
    func load(){guard let server=m.current,!loading else{return};let input:[String:Any]=["action":"snapshot_compare","repository_id":repository,"snapshot":snapshot,"path":path,"target":target,"offset":offset,"differences":differences];loading=true;error="";Task{do{let value=try await m.readLive(input,server:server) as? [String:Any] ?? [:];rows=value["entries"] as? [[String:Any]] ?? [];counts=value["counts"] as? [String:Int] ?? [:];total=value["total"] as? Int ?? 0}catch{rows=[];counts=[:];total=0;self.error=error.localizedDescription};loading=false}}
}
