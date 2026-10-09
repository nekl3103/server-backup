import SwiftUI
import Charts

struct MetricPoint:Identifiable {
    let id=UUID()
    let time:Date
    let series:String
    let segment:String
    let value:Double
}
struct MonitorView:View {
    @EnvironmentObject var m:Model
    @State private var live=true
    @State private var interval=2
    @StateObject private var stream=SSHStream()
    @State private var disk="Все"
    @State private var network="Все"
    @State private var selectedDisk:MonitorDiskSelection?
    var body:some View{VStack(alignment:.leading,spacing:18){
        HStack{WorkspaceIntro(title:"Нагрузка сервера",detail:"Текущая нагрузка · непрерывный SSH-поток",icon:"chart.xyaxis.line");Button("Обновить"){if live{start()}else{m.refreshMetrics()}}.disabled(m.metricsLoading)}
        HStack{Toggle("Онлайн",isOn:$live);Picker("Интервал",selection:$interval){Text("2 сек").tag(2);Text("5 сек").tag(5);Text("10 сек").tag(10)}.frame(width:180);if m.metricsLoading{ProgressView().controlSize(.small)};Spacer();StatusBadge(title:live ? stream.state : "Пауза",color:live && stream.state=="Онлайн" ? .green:.orange)}
        if let error=stream.error ?? m.metricError{Text(error).font(.caption).foregroundStyle(.orange)}
        HStack{StatusBadge(title:m.metricUpdated.map{"Обновлено: "+$0.formatted(date:.omitted,time:.standard)} ?? "Нет данных");Spacer();Text("История сохраняется в памяти до смены сервера").font(.caption).foregroundStyle(BackupTheme.muted)}
        HStack(spacing:16){MetricCard(title:"CPU",value:percent(m.metrics["cpu_percent"] as? Double));MetricCard(title:"Память",value:memory("MemTotal","MemAvailable"));MetricCard(title:"Swap",value:memory("SwapTotal","SwapFree"))}
        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:18){
            graph("CPU",group:"cpu",unit:"%",fixed:true)
            graph("Память и Swap",group:"memory",unit:"%",fixed:true)
            graph("Load average",group:"load",unit:"")
            BackupPanel(title:"Сеть",icon:"network"){Picker("Интерфейс",selection:$network){Text("Все").tag("Все");ForEach(keys("network"),id:\.self){Text($0).tag($0)}};plot(points("network",device:network),unit:"МБ/с")}
            BackupPanel(title:"Дисковый ввод / вывод",icon:"externaldrive"){Picker("Диск",selection:$disk){Text("Все").tag("Все");ForEach(keys("disk_io"),id:\.self){Text($0).tag($0)}};plot(points("io",device:disk),unit:"МБ/с");let devices=m.metrics["disk_io"] as? [String:[String:Double]] ?? [:];ForEach(devices.keys.sorted().filter{disk=="Все" || $0==disk},id:\.self){name in let value=devices[name] ?? [:];HStack{Text(name).font(.caption.monospaced()).frame(width:65,alignment:.leading);if let busy=value["busy_percent"]{ProgressView(value:min(max(busy,0),100),total:100).tint(busy>=90 ? .orange:BackupTheme.blue);Text(String(format:"%.0f%% активности",busy)).font(.caption).monospacedDigit()}else{Text("Активность недоступна").font(.caption).foregroundStyle(BackupTheme.muted)}}}}
            graph("Нагрузка Docker · CPU",group:"docker",unit:"%")
        }
        BackupPanel(title:"Основные диски",subtitle:"Занято и свободно · нажмите на диск для подробностей",icon:"internaldrive"){
            let disks=m.metrics["physical_disks"] as? [[String:Any]] ?? []
            if disks.isEmpty{Text("Данные об основных дисках недоступны").foregroundStyle(BackupTheme.muted)}
            LazyVGrid(columns:[GridItem(.adaptive(minimum:280),alignment:.leading)],spacing:12){ForEach(disks.indices,id:\.self){i in Button{selectedDisk=MonitorDiskSelection(id:disks[i]["name"] as? String ?? "")}label:{MainDiskCard(value:disks[i])}.buttonStyle(.plain)}}
        }
        BackupPanel(title:"Наиболее нагруженные процессы",icon:"terminal"){ProcessMonitorTable()}
        Text("При потере подключения остаются последние данные. Пропуски измерений не отображаются как нулевая нагрузка.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.sheet(item:$selectedDisk){MonitorDiskDetails(name:$0.id).environmentObject(m)}.onAppear{start()}.onDisappear{stream.stop()}.onChange(of:live){_,enabled in if enabled{start()}else{stream.stop()}}.onChange(of:interval){_,_ in if live{start()}}}
    func start(){guard !m.probe.isEmpty else{return};stream.start(model:m,request:["action":"stream","kind":"metrics","interval":interval]){event in if event["event"] as? String=="metrics",let value=event["result"] as? [String:Any]{m.acceptMetrics(value);m.metricError=nil}}}
    func percent(_ value:Double?)->String{value.map{String(format:"%.1f %%",$0)} ?? "Недоступно"}
    func memory(_ total:String,_ free:String)->String{let mem=m.metrics["memory"] as? [String:Any] ?? [:];guard let t=mem[total] as? Double,let f=mem[free] as? Double else{return "Недоступно"};return (t==f ? "0 Б":ByteCountFormatter.string(fromByteCount:Int64(max(0,t-f)),countStyle:.binary))+" / "+ByteCountFormatter.string(fromByteCount:Int64(t),countStyle:.binary)}
    func keys(_ field:String)->[String]{(m.metrics[field] as? [String:Any] ?? [:]).keys.sorted()}
    func points(_ group:String,device:String="Все")->[MetricPoint]{m.metricHistory[group,default:[]].filter{device=="Все" || $0.series.hasPrefix(device+" · ")}}
    func graph(_ title:String,group:String,unit:String,fixed:Bool=false)->some View{BackupPanel(title:title,icon:"waveform.path.ecg"){plot(points(group),unit:unit,fixed:fixed)}}
    @ViewBuilder func plot(_ points:[MetricPoint],unit:String,fixed:Bool=false)->some View{
        if points.isEmpty{ContentUnavailableView("Нет измерений",systemImage:"chart.xyaxis.line",description:Text("Метрика недоступна или ещё не получена")).frame(height:180)}else{
            Chart(points){point in
                LineMark(x:.value("Время",point.time),y:.value(unit,point.value),series:.value("Линия",point.segment))
                    .foregroundStyle(by:.value("Показатель",point.series))
                PointMark(x:.value("Время",point.time),y:.value(unit,point.value)).foregroundStyle(by:.value("Показатель",point.series)).symbolSize(12)
            }.chartYScale(domain:fixed ? 0...100:0...max(1,(points.map(\.value).max() ?? 1)*1.15)).chartXAxis{AxisMarks(values:.automatic(desiredCount:4)){AxisGridLine();AxisValueLabel(format:.dateTime.hour().minute().second())}}.chartLegend(position:.bottom).frame(height:180)
            HStack{Text(unit).font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Text((points.last?.series ?? "")+": "+String(format:"%.2f",points.last?.value ?? 0)+" "+unit).font(.caption)}
        }
    }
}
extension Model {
    func confirmConnectionFailure(server:Server)async {
        let online=await Task.detached{SSH.connectionAvailable(server)}.value
        guard selectedID==server.id else{return}
        connectionOnline=online
    }
    func readLive(_ request:[String:Any],server:Server)async throws->Any{if isDesignPreview{guard let response=designResponse(request) else{throw AppFailure(message:"Нет демонстрационных данных")};return response};do{let response=try await Task.detached{try SSH.call(server,request)}.value;if selectedID==server.id{connectionOnline=true};return response}catch{if error is SSHFailure,selectedID==server.id{await confirmConnectionFailure(server:server)};throw error}}
    func refreshMetrics(){guard let server=current,!metricsLoading else{return};metricsLoading=true
        Task{do{let response=try await readLive(["action":"metrics"],server:server);guard selectedID==server.id else{metricsLoading=false;return};acceptMetrics(response as? [String:Any] ?? [:]);metricError=nil}catch{if selectedID==server.id{metricError=error.localizedDescription}};metricsLoading=false}}

    func acceptMetrics(_ value:[String:Any]){
        metrics=value;let time=Date();metricUpdated=time
        func add(_ group:String,_ series:String,_ value:Double?){guard let value,value.isFinite else{return};let previous=metricHistory[group,default:[]].last{$0.series==series};let segment=previous.map{time.timeIntervalSince($0.time)<18 ? $0.segment:UUID().uuidString} ?? UUID().uuidString;metricHistory[group,default:[]].append(MetricPoint(time:time,series:series,segment:segment,value:max(0,value)))}
        add("cpu","CPU",value["cpu_percent"] as? Double)
        let mem=value["memory"] as? [String:Double] ?? [:]
        for (name,total,free) in [("Память","MemTotal","MemAvailable"),("Swap","SwapTotal","SwapFree")]{if let t=mem[total],let f=mem[free],t>0{add("memory",name,100*(t-f)/t)}}
        for (i,v) in (value["load"] as? [Double] ?? []).enumerated(){add("load",["1 мин","5 мин","15 мин"][min(i,2)],v)}
        for (key,v) in value["network"] as? [String:[String:Double]] ?? [:]{add("network",key+" · Приём",v["rx_per_second"].map{$0/1_000_000});add("network",key+" · Передача",v["tx_per_second"].map{$0/1_000_000})}
        for (key,v) in value["disk_io"] as? [String:[String:Double]] ?? [:]{add("io",key+" · Чтение",v["read_per_second"].map{$0/1_000_000});add("io",key+" · Запись",v["write_per_second"].map{$0/1_000_000})}
        for container in value["docker"] as? [[String:Any]] ?? []{add("docker",container["Name"] as? String ?? "Контейнер",Double((container["CPUPerc"] as? String ?? "").replacingOccurrences(of:"%",with:"")))}
        for key in Array(metricHistory.keys){metricHistory[key]?.removeAll{$0.time<time.addingTimeInterval(-1200)}}
    }
}

struct DiskUsageCard:View{
    let value:[String:Any]
    var used:Double?{value["used_percent"] as? Double}
    var color:Color{(used ?? 0)>=90 ? .orange:(used ?? 0)>=75 ? .yellow:BackupTheme.blue}
    var body:some View{VStack(alignment:.leading,spacing:14){HStack(spacing:12){Image(systemName:"internaldrive.fill").font(.title2).foregroundStyle(color).padding(12).background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius:10));VStack(alignment:.leading,spacing:4){Text(value["target"] as? String ?? "—").font(.headline.monospaced()).lineLimit(1).textSelection(.enabled);Text(value["source"] as? String ?? value["fstype"] as? String ?? "Файловая система").font(.caption).foregroundStyle(BackupTheme.muted)};Spacer();Text(used.map{String(format:"%.0f%%",$0)} ?? "—").font(.title2.weight(.semibold)).foregroundStyle(color)}
        if let used{ProgressView(value:min(max(used,0),100),total:100).tint(color)}
        HStack{Text("Свободно").foregroundStyle(BackupTheme.muted);Spacer();Text(String(describing:value["avail"] ?? "Недоступно")).fontWeight(.semibold)}.font(.callout)
        if let used,used>=90{Label("Мало свободного места",systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)}
    }.padding(16).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:12))}
}
