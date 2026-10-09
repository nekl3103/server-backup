import SwiftUI
import Charts

struct MonitorDiskSelection:Identifiable{let id:String}
struct MainDiskCard:View{
    let value:[String:Any]
    var body:some View{VStack(alignment:.leading,spacing:12){HStack{Label(value["name"] as? String ?? "Диск",systemImage:"internaldrive.fill").font(.headline);Spacer();Text((value["used_percent"] as? NSNumber).map{String(format:"%.0f%%",$0.doubleValue)} ?? "—").font(.title2.weight(.semibold));Image(systemName:"chevron.right").foregroundStyle(BackupTheme.muted)};if let used=value["used_percent"] as? Double{ProgressView(value:min(max(used,0),100),total:100).tint(used>=90 ? .orange:BackupTheme.blue)};HStack{VStack(alignment:.leading){Text("Занято").foregroundStyle(BackupTheme.muted);Text(bytes("used_bytes"))};Spacer();VStack(alignment:.trailing){Text("Свободно").foregroundStyle(BackupTheme.muted);Text(bytes("free_bytes"))}}.font(.callout);Text("Объём: "+bytes("total_bytes")).font(.caption).foregroundStyle(BackupTheme.muted);if value["mounted"] as? Bool==false{Text("Не смонтирован").font(.caption).foregroundStyle(.orange)};if value["shared"] as? Bool==true{Text("Общий том на нескольких дисках").font(.caption).foregroundStyle(BackupTheme.muted)}}.padding(16).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:12)).contentShape(Rectangle())}
    func bytes(_ key:String)->String{(value[key] as? NSNumber).map{ByteCountFormatter.string(fromByteCount:$0.int64Value,countStyle:.binary)} ?? "Недоступно"}
}
struct MonitorDiskDetails:View{
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let name:String
    var disk:[String:Any]{(m.metrics["physical_disks"] as? [[String:Any]] ?? []).first{$0["name"] as? String==name} ?? ["name":name]}
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Label("Диск "+name,systemImage:"internaldrive").font(.title2);Spacer();Button("Закрыть"){dismiss()}};MainDiskCard(value:disk);let io=(m.metrics["disk_io"] as? [String:[String:Double]] ?? [:])[name] ?? [:];HStack{Text("Чтение: "+rate(io["read_per_second"]));Spacer();Text("Запись: "+rate(io["write_per_second"]));Spacer();Text(io["busy_percent"].map{String(format:"Активность: %.0f%%",$0)} ?? "Активность недоступна")}.font(.callout)
        let points=m.metricHistory["io",default:[]].filter{$0.series.hasPrefix(name+" · ")}
        if !points.isEmpty{Chart(points){point in LineMark(x:.value("Время",point.time),y:.value("МБ/с",point.value),series:.value("Линия",point.segment)).foregroundStyle(by:.value("Показатель",point.series))}.frame(height:160)}
        Text("Файловые системы на этом диске").font(.headline)
        ScrollView{VStack(spacing:10){let mounts=disk["mounts"] as? [[String:Any]] ?? [];if mounts.isEmpty{Text("Нет доступных сведений о смонтированных файловых системах").foregroundStyle(BackupTheme.muted)};ForEach(mounts.indices,id:\.self){i in let mount=mounts[i];HStack{VStack(alignment:.leading){Text(mount["target"] as? String ?? "").font(.callout.monospaced());Text(mount["source"] as? String ?? "").font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();VStack(alignment:.trailing){Text("Занято: "+bytes(mount["used_bytes"]));Text("Свободно: "+bytes(mount["free_bytes"])).foregroundStyle(BackupTheme.muted)}}.font(.caption).padding(12).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:8))}}}.frame(minHeight:120)
    }.padding(24).frame(width:760,height:640)}
    func bytes(_ value:Any?)->String{(value as? NSNumber).map{ByteCountFormatter.string(fromByteCount:$0.int64Value,countStyle:.binary)} ?? "—"}
    func rate(_ value:Double?)->String{value.map{ByteCountFormatter.string(fromByteCount:Int64(max(0,$0)),countStyle:.binary)+"/с"} ?? "—"}
}
struct MonitorProcess:Identifiable{
    let value:[String:Any]
    var id:Int{value["pid"] as? Int ?? 0}
    var name:String{value["name"] as? String ?? ""}
    var user:String{value["user"] as? String ?? "—"}
    var cpu:Double{(value["cpu_percent"] as? NSNumber)?.doubleValue ?? 0}
    var memory:Double{(value["memory_percent"] as? NSNumber)?.doubleValue ?? 0}
}
struct ProcessMonitorTable:View{
    @EnvironmentObject var m:Model
    @State private var search=""
    @State private var sort="cpu"
    var rows:[MonitorProcess]{let values=(m.metrics["process_rows"] as? [[String:Any]] ?? []).map{MonitorProcess(value:$0)};return values.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.user.localizedCaseInsensitiveContains(search) || String($0.id).contains(search)}.sorted{sort=="cpu" ? $0.cpu>$1.cpu:$0.memory>$1.memory}}
    var body:some View{VStack(alignment:.leading,spacing:14){HStack{TextField("Поиск процесса, PID или пользователя",text:$search);Picker("Сортировка",selection:$sort){Text("CPU").tag("cpu");Text("Память").tag("memory")}.frame(width:180)};if let error=m.metrics["process_error"] as? String{Text(error).foregroundStyle(.orange)}
        if !rows.isEmpty{Chart(Array(rows.prefix(8))){row in BarMark(x:.value("Процент",sort=="cpu" ? row.cpu:row.memory),y:.value("Процесс",row.name+" · "+String(row.id))).foregroundStyle(BackupTheme.blue).annotation(position:.trailing){Text(String(format:"%.1f%%",sort=="cpu" ? row.cpu:row.memory)).font(.caption)}}.chartXAxisLabel(sort=="cpu" ? "CPU, %":"Память, %").frame(height:200)
            Table(rows){TableColumn("PID"){Text(String($0.id)).monospacedDigit()}.width(65);TableColumn("Процесс"){Text($0.name).textSelection(.enabled)};TableColumn("Пользователь"){Text($0.user)}.width(100);TableColumn("CPU"){Text(String(format:"%.1f%%",$0.cpu)).monospacedDigit()}.width(75);TableColumn("Память"){Text(String(format:"%.1f%%",$0.memory)).monospacedDigit()}.width(75);TableColumn("RAM"){row in Text((row.value["memory_bytes"] as? NSNumber).map{ByteCountFormatter.string(fromByteCount:$0.int64Value,countStyle:.binary)} ?? "—")}.width(90)}.frame(height:300)
        }else{Text("Нет данных о процессах для выбранного поиска").foregroundStyle(BackupTheme.muted)}
        Text("CPU процесса — средняя доля процессорного времени за его время работы (ps). Значение может превышать 100% у многопоточных процессов.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.textFieldStyle(.roundedBorder)}
}
