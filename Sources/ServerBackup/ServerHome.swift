import SwiftUI
import Combine

struct ServerHomeView:View{
    @EnvironmentObject var m:Model
    let onAdd:()->Void
    let onEdit:(Server)->Void
    @State private var search=""
    @State private var filter="all"
    @AppStorage("fleet.table") private var table=false
    @State private var group=""
    private let fleetTimer=Timer.publish(every:10,on:.main,in:.common).autoconnect()
    var visible:[Server]{m.servers.filter{server in
        let match=search.isEmpty || [server.name,server.host,server.user].contains{$0.localizedCaseInsensitiveContains(search)}
        return match && matches(server,filter:filter) && (group.isEmpty || server.group==group)
    }}
    func matches(_ server:Server,filter:String)->Bool{
        let status=m.fleet[server.id]
        switch filter{
        case "attention":return status?.attention==true
        case "healthy":return status != nil && status?.attention==false && status?.jobs.contains(where:{$0["enabled"] as? Bool ?? true})==true
        case "unknown":return status==nil
        default:return true
        }
    }
    var body:some View{VStack(alignment:.leading,spacing:22){
        HStack(alignment:.center){
            VStack(alignment:.leading,spacing:7){Text("ВАША ИНФРАСТРУКТУРА").font(.system(size:10,weight:.semibold)).tracking(1.5).foregroundStyle(BackupTheme.blue);Text("Серверы").font(.system(size:30,weight:.bold));Text("Подключения, резервные копии и состояние заданий").font(.callout).foregroundStyle(BackupTheme.muted)}
            Spacer()
            Button(action:onAdd){Label("Добавить сервер",systemImage:"plus")}.buttonStyle(BackupPrimaryButtonStyle()).controlSize(.large)
        }
        if m.servers.isEmpty{emptyServers}
        else{
            summary
            HStack(spacing:12){
                HStack(spacing:9){Image(systemName:"magnifyingglass").foregroundStyle(BackupTheme.muted);TextField("Найти сервер по имени или адресу",text:$search).textFieldStyle(.plain);if !search.isEmpty{Button{search=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted)}}.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:360).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(BackupTheme.border))
                Picker("Вид",selection:$table){Text("Карточки").tag(false);Text("Таблица").tag(true)}.pickerStyle(.segmented).frame(width:180)
                Picker("Группа",selection:$group){Text("Все группы").tag("");ForEach(Array(Set(m.servers.compactMap{$0.group}.filter{!$0.isEmpty})).sorted(),id:\.self){Text($0).tag($0)}}.frame(width:160)
                Spacer()
                if m.fleetLoading{ProgressView().controlSize(.small);Text("Проверка серверов…").font(.caption).foregroundStyle(BackupTheme.muted)}
                Button{m.refreshFleet()}label:{Label("Обновить",systemImage:"arrow.clockwise")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted).disabled(m.fleetLoading)
            }
            HStack(spacing:8){filterChip("Все","all");filterChip("Копии актуальны","healthy");filterChip("Требуют внимания","attention");filterChip("Не проверены","unknown");Spacer();Text("Показано: "+String(visible.count)).font(.caption).foregroundStyle(BackupTheme.muted)}
            ScrollView{
                if visible.isEmpty{VStack(spacing:12){Image(systemName:"magnifyingglass").font(.title).foregroundStyle(BackupTheme.muted);Text("Серверы не найдены").font(.headline);Button("Сбросить поиск и фильтр"){search="";filter="all"}}.frame(maxWidth:.infinity).padding(.vertical,70)}
                else if table{FleetTableView(servers:visible,edit:onEdit)}
                else{LazyVGrid(columns:[GridItem(.adaptive(minimum:370),spacing:16,alignment:.top)],alignment:.leading,spacing:16){ForEach(visible){server in ServerHomeCard(server:server,status:m.fleet[server.id],open:{m.openServer(server)},edit:{onEdit(server)})}}.padding(.bottom,12)}
            }
        }
        Spacer(minLength:0)
        HStack(spacing:8){Image(systemName:"lock.shield").foregroundStyle(BackupTheme.blue);Text("Доступы защищены Keychain. Бэкапы работают на сервере, даже когда Mac выключен.").font(.caption).foregroundStyle(BackupTheme.muted)}
    }.padding(30).background(BackupTheme.background).onAppear{m.refreshFleet()}.onReceive(fleetTimer){_ in m.refreshFleet()}}
    var summary:some View{HStack(spacing:0){
        summaryItem("Всего серверов",count:m.servers.count,color:BackupTheme.blue,icon:"server.rack",filter:"all")
        separator
        summaryItem("Копии актуальны",count:m.servers.filter{matches($0,filter:"healthy")}.count,color:.green,icon:"checkmark.shield",filter:"healthy")
        separator
        summaryItem("Требуют внимания",count:m.servers.filter{matches($0,filter:"attention")}.count,color:.orange,icon:"exclamationmark.circle",filter:"attention")
        separator
        summaryItem("Не проверены",count:m.servers.filter{matches($0,filter:"unknown")}.count,color:BackupTheme.muted,icon:"clock",filter:"unknown")
    }.padding(.vertical,16).background(BackupTheme.panel.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(BackupTheme.border))}
    var separator:some View{Rectangle().fill(BackupTheme.border).frame(width:1,height:34)}
    func summaryItem(_ title:String,count:Int,color:Color,icon:String,filter key:String)->some View{Button{filter=key}label:{HStack(spacing:12){Image(systemName:icon).font(.system(size:18)).foregroundStyle(color);VStack(alignment:.leading,spacing:4){Text(String(count)).font(.system(size:22,weight:.semibold)).foregroundStyle(.primary);Text(title).font(.caption).foregroundStyle(BackupTheme.muted)};Spacer(minLength:0)}.padding(.horizontal,20).frame(maxWidth:.infinity).contentShape(Rectangle())}.buttonStyle(.plain)}
    func filterChip(_ title:String,_ key:String)->some View{Button{filter=key}label:{HStack(spacing:7){Text(title);Text(String(m.servers.filter{matches($0,filter:key)}.count)).font(.system(size:10,weight:.semibold)).padding(.horizontal,5).padding(.vertical,2).background(filter==key ? Color.white.opacity(0.12):BackupTheme.border).clipShape(Capsule())}.font(.caption.weight(filter==key ? .semibold:.regular)).padding(.horizontal,11).padding(.vertical,8).foregroundStyle(filter==key ? Color.white:BackupTheme.muted).background(filter==key ? BackupTheme.blue.opacity(0.22):.clear).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}
    var emptyServers:some View{VStack(spacing:16){Spacer();Image(systemName:"server.rack").font(.system(size:42)).foregroundStyle(BackupTheme.blue).frame(width:88,height:88).background(BackupTheme.blue.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:22));Text("Подключите первый сервер").font(.title2.weight(.semibold));Text("Добавьте SSH-доступ, затем настройте хранилище\nи ежедневное резервное копирование.").font(.callout).multilineTextAlignment(.center).foregroundStyle(BackupTheme.muted);Button("Добавить сервер",action:onAdd).buttonStyle(BackupPrimaryButtonStyle());Spacer()}.frame(maxWidth:.infinity)}
}

struct ServerHomeCard:View{
    let server:Server
    let status:FleetStatus?
    let open:()->Void
    let edit:()->Void
    @State private var hovering=false
    var color:Color{status==nil ? BackupTheme.muted:status?.attention==true ? .orange:status?.jobs.contains(where:{$0["enabled"] as? Bool ?? true})==true ? .green:BackupTheme.muted}
    var lastSuccess:String?{status?.jobs.compactMap{$0["last_success"] as? String}.sorted().last}
    var issue:String?{
        guard let status else{return nil}
        if status.error != nil{return "Не удалось проверить подключение"}
        guard let job=status.jobs.first(where:{($0["enabled"] as? Bool ?? true) && ($0["stale"] as? Bool==true || ["failed","incomplete"].contains($0["last_status"] as? String ?? "") || $0["replication_error"] as? Bool==true || $0["maintenance_error"] as? Bool==true || ($0["verification"] as? [String:Any])?["status"] as? String=="failed")}) else{return nil}
        let name=job["id"] as? String ?? "Задание"
        if job["stale"] as? Bool==true{return name+" · нет свежей копии"}
        if job["maintenance_error"] as? Bool==true{return name+" · ошибка обслуживания"}
        if (job["verification"] as? [String:Any])?["status"] as? String=="failed"{return name+" · проверка не пройдена"}
        return name+" · "+resultTitle(job["last_status"] as? String ?? "failed")
    }
    var body:some View{VStack(alignment:.leading,spacing:0){
        Button(action:open){VStack(alignment:.leading,spacing:12){
            HStack(spacing:12){Image(systemName:"server.rack").font(.system(size:19)).foregroundStyle(BackupTheme.blue).frame(width:42,height:42).background(BackupTheme.blue.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:11));VStack(alignment:.leading,spacing:5){Text(server.name).font(.system(size:17,weight:.semibold)).foregroundStyle(.primary).lineLimit(1);Text(server.user+"@"+server.host).font(.system(size:11,design:.monospaced)).foregroundStyle(BackupTheme.muted).lineLimit(1).truncationMode(.middle)};Spacer(minLength:0);Image(systemName:"arrow.up.right").font(.system(size:12,weight:.medium)).foregroundStyle(hovering ? BackupTheme.blue:BackupTheme.muted)}
            StatusBadge(title:status?.title ?? "Не проверен",color:color)
            FleetResourceView(value:status?.health["metrics"] as? [String:Any] ?? [:])
            Rectangle().fill(BackupTheme.border).frame(height:1)
            VStack(alignment:.leading,spacing:6){Text("ПОСЛЕДНЯЯ УСПЕШНАЯ КОПИЯ").font(.system(size:9,weight:.medium)).tracking(0.7).foregroundStyle(BackupTheme.muted);Text(lastSuccess.map{backupTime($0)} ?? (status==nil || status?.error != nil ? "Пока нет данных":"Нет успешных копий")).font(.system(size:13,weight:.medium)).foregroundStyle(.primary).lineLimit(1)}
            HStack(spacing:14){Label(status==nil || status?.error != nil ? "Задания: —":"Заданий: "+String(status?.jobs.count ?? 0),systemImage:"calendar");Spacer();Label("Порт "+String(server.port),systemImage:"network")}.font(.system(size:11)).foregroundStyle(BackupTheme.muted)
            Text(issue ?? (status?.jobs.isEmpty==true ? "Создайте первое задание":"Открыть сервер и настройки" )).font(.caption).foregroundStyle(issue==nil ? BackupTheme.blue:.orange).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain)
        HStack{HStack(spacing:5){Circle().fill(color).frame(width:5,height:5);Text(status.map{"Проверено в "+$0.checked.formatted(date:.omitted,time:.shortened)} ?? "Ожидает проверки").font(.system(size:10)).foregroundStyle(BackupTheme.muted)};Spacer();Button(action:edit){Label("Изменить",systemImage:"slider.horizontal.3").font(.system(size:11))}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted).help("Изменить SSH-подключение")}.padding(.horizontal,20).padding(.vertical,12).background(Color.white.opacity(0.025))
    }.background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(hovering ? BackupTheme.blue.opacity(0.65):BackupTheme.border)).onHover{hovering=$0}}
}

struct ResourceGauge:View{
    let title:String
    let value:Double?
    var body:some View{VStack(spacing:7){Text(title).font(.caption.weight(.medium)).foregroundStyle(BackupTheme.muted);ZStack{Circle().stroke(BackupTheme.blue.opacity(0.18),lineWidth:7);Circle().trim(from:0,to:min(max((value ?? 0)/100,0),1)).stroke(AngularGradient(colors:[BackupTheme.blue,.green],center:.center),style:StrokeStyle(lineWidth:7,lineCap:.round)).rotationEffect(.degrees(-90));Text(value.map{String(format:"%.0f%%",$0)} ?? "—").font(.system(size:17,weight:.semibold)).monospacedDigit()}.frame(width:65,height:65)}}
}
struct FleetResourceView:View{
    let value:[String:Any]
    var mem:[String:Double]{value["memory"] as? [String:Double] ?? [:]}
    var ram:Double?{guard let total=mem["MemTotal"],let free=mem["MemAvailable"],total>0 else{return nil};return 100*(total-free)/total}
    var mounts:[[String:Any]]{value["physical_disks"] as? [[String:Any]] ?? []}
    var net:[String:[String:Double]]{value["network"] as? [String:[String:Double]] ?? [:]}
    var io:[String:[String:Double]]{value["disk_io"] as? [String:[String:Double]] ?? [:]}
    func rate(_ field:String,network:Bool=false)->String{let readings=(network ? net:io).filter{network ? $0.key != "lo":!$0.key.hasPrefix("dm-") && !$0.key.hasPrefix("md")}.values.compactMap{$0[field]};guard !readings.isEmpty else{return "—"};return ByteCountFormatter.string(fromByteCount:Int64(max(0,readings.reduce(0,+))),countStyle:.binary)+"/с"}
    var body:some View{VStack(alignment:.leading,spacing:14){HStack{Label((value["cores"] as? NSNumber).map{$0.stringValue+" ядер"} ?? "Ядра: —",systemImage:"cpu");Spacer();Label((mem["MemTotal"]).map{ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.binary)} ?? "RAM: —",systemImage:"memorychip");Spacer();Label(value["physical_disks"] is [[String:Any]] ? "Дисков: "+String(mounts.count):"Диски: —",systemImage:"internaldrive")}.font(.system(size:10)).foregroundStyle(BackupTheme.muted)
        HStack(alignment:.center,spacing:18){ResourceGauge(title:"CPU",value:value["cpu_percent"] as? Double);ResourceGauge(title:"RAM",value:ram);Spacer(minLength:0);VStack(alignment:.leading,spacing:8){Text("СЕТЬ").font(.system(size:9)).foregroundStyle(BackupTheme.muted);Label(rate("tx_per_second",network:true),systemImage:"arrow.up.circle");Label(rate("rx_per_second",network:true),systemImage:"arrow.down.circle")}.font(.system(size:10).monospacedDigit());VStack(alignment:.leading,spacing:8){Text("ДИСК").font(.system(size:9)).foregroundStyle(BackupTheme.muted);Text("R "+rate("read_per_second"));Text("W "+rate("write_per_second"))}.font(.system(size:10).monospacedDigit())}
        ScrollView(.vertical){VStack(alignment:.leading,spacing:12){
            if mounts.isEmpty{Text(value.isEmpty ? "Метрики ещё не получены":"Нет данных о дисках").font(.caption).foregroundStyle(BackupTheme.muted).frame(maxWidth:.infinity,alignment:.leading)}
            ForEach(mounts.indices,id:\.self){i in HomeDiskSummary(value:mounts[i])}
        }.frame(maxWidth:.infinity,alignment:.leading)}.scrollIndicators(mounts.count>2 ? .visible:.hidden).frame(height:116,alignment:.top)

    }}
}

struct HomeDiskSummary:View{
    let value:[String:Any]
    func size(_ field:String)->String{(value[field] as? NSNumber).map{ByteCountFormatter.string(fromByteCount:$0.int64Value,countStyle:.binary)} ?? "—"}
    var body:some View{VStack(alignment:.leading,spacing:6){HStack{Label(value["name"] as? String ?? "Диск",systemImage:"internaldrive").font(.caption.weight(.medium));Spacer();Text("Объём: "+size("total_bytes")).font(.system(size:10)).foregroundStyle(BackupTheme.muted)}
        if let used=value["used_percent"] as? Double{ProgressView(value:min(max(used,0),100),total:100).tint(used>=90 ? .orange:BackupTheme.blue);HStack{Text("Занято: "+size("used_bytes"));Spacer();Text("Свободно: "+size("free_bytes"))}.font(.system(size:10)).foregroundStyle(BackupTheme.muted)}
        else{Text(value["shared"] as? Bool==true ? "Общий том на нескольких дисках":"Диск не смонтирован").font(.system(size:10)).foregroundStyle(BackupTheme.muted)}
    }}
}
