import SwiftUI

private let cronDays=["Воскресенье","Понедельник","Вторник","Среда","Четверг","Пятница","Суббота","Воскресенье"]
private let cronMonths=["Январь","Февраль","Март","Апрель","Май","Июнь","Июль","Август","Сентябрь","Октябрь","Ноябрь","Декабрь"]
func humanCronSchedule(_ schedule:String)->String{
    if let special=["@reboot":"При запуске сервера","@hourly":"Каждый час","@daily":"Ежедневно в 00:00","@midnight":"Ежедневно в 00:00","@weekly":"Каждое воскресенье в 00:00","@monthly":"Первого числа каждого месяца в 00:00","@yearly":"1 января в 00:00","@annually":"1 января в 00:00"][schedule]{return special}
    let parts=schedule.split(separator:" ").map(String.init);guard parts.count==5 else{return schedule}
    let minute=parts[0],hour=parts[1],day=parts[2],month=parts[3],week=parts[4]
    let clock=Int(hour).flatMap{h in Int(minute).map{String(format:"%02d:%02d",h,$0)}}
    if day=="*",month=="*",week=="*"{
        if let clock{return "Ежедневно в "+clock}
        if hour=="*",minute.hasPrefix("*/"){return "Каждые "+minute.dropFirst(2)+" мин"}
        if hour=="*",let min=Int(minute){return "Каждый час в "+String(min)+" мин"}
    }
    if let clock,day=="*",month=="*",let w=Int(week),w>=0,w<=7{return cronDays[w]+", в "+clock}
    if let clock,week=="*",month=="*",let d=Int(day){return "Каждого "+String(d)+" числа в "+clock}
    func field(_ value:String,_ names:[String]?=nil,offset:Int=0)->String{
        if value=="*"{return "каждый"}
        if value.hasPrefix("*/"){return "через "+value.dropFirst(2)}
        return value.split(separator:",").map{part in
            part.split(separator:"-").map{component in if let names,let index=Int(component),names.indices.contains(index-offset){return names[index-offset]};return String(component)}.joined(separator:"–")
        }.joined(separator:", ")
    }
    return (clock.map{"В "+$0+" · "} ?? "Минуты: "+field(minute)+" · часы: "+field(hour)+" · ")+"день месяца: "+field(day)+" · месяц: "+field(month,cronMonths,offset:1)+" · день недели: "+field(week,cronDays)+(day != "*" && week != "*" ? " (день месяца ИЛИ день недели)":"")
}
struct CronSchedulePicker:View{
    @Binding var schedule:String
    @State private var mode="daily"
    @State private var minute=0
    @State private var hour=3
    @State private var monthDay=1
    @State private var weekDay=1
    @State private var month=0
    @State private var step=15
    @State private var syncing=false
    @State private var lastEncoded=""
    var body:some View{VStack(alignment:.leading,spacing:12){
        Picker("Когда выполнять",selection:$mode){Text("Каждый день").tag("daily");Text("Каждую неделю").tag("weekly");Text("Каждый месяц").tag("monthly");Text("День и месяц").tag("date");Text("Каждый час").tag("hourly");Text("Через несколько минут").tag("interval");Text("При запуске сервера").tag("reboot");Text("Расширенное расписание").tag("advanced")}
        if ["daily","weekly","monthly","date","hourly"].contains(mode){
            HStack{if mode != "hourly"{Picker("Час",selection:$hour){ForEach(0..<24,id:\.self){Text(String(format:"%02d",$0)).tag($0)}}};Picker("Минута",selection:$minute){ForEach(0..<60,id:\.self){Text(String(format:"%02d",$0)).tag($0)}}}
        }
        if mode=="weekly"{Picker("День недели",selection:$weekDay){ForEach(0..<7,id:\.self){Text(cronDays[$0]).tag($0)}}}
        if mode=="monthly" || mode=="date"{HStack{Picker("Число",selection:$monthDay){ForEach(1..<32,id:\.self){Text(String($0)).tag($0)}};if mode=="date"{Picker("Месяц",selection:$month){Text("Каждый месяц").tag(0);ForEach(1..<13,id:\.self){Text(cronMonths[$0-1]).tag($0)}}}};Text("Если такого числа в месяце нет, запуск будет пропущен.").font(.caption).foregroundStyle(BackupTheme.muted)}
        if mode=="interval"{Stepper("Через \(step) минут",value:$step,in:1...59);Text("Интервал отсчитывается внутри каждого часа, начиная с нулевой минуты.").font(.caption).foregroundStyle(BackupTheme.muted)}
        if mode=="advanced"{TextField("Минуты часы день месяц день-недели",text:$schedule).font(.body.monospaced());Text("* — любое значение, */5 — через 5, 1,3 — список, 1-5 — диапазон.").font(.caption).foregroundStyle(BackupTheme.muted)}
        Label(humanCronSchedule(schedule),systemImage:"calendar.badge.clock").font(.callout.weight(.medium)).foregroundStyle(BackupTheme.blue)
        Text("По часовому поясу сервера. Cron: "+schedule).font(.caption.monospaced()).foregroundStyle(BackupTheme.muted)
    }.onAppear{decode()}.onChange(of:schedule){_,value in if value != lastEncoded{decode()}}.onChange(of:mode){_,_ in encode()}.onChange(of:minute){_,_ in encode()}.onChange(of:hour){_,_ in encode()}.onChange(of:monthDay){_,_ in encode()}.onChange(of:month){_,_ in encode()}.onChange(of:weekDay){_,_ in encode()}.onChange(of:step){_,_ in encode()}}
    func encode(){guard !syncing,mode != "advanced" else{return};defer{lastEncoded=schedule};switch mode{case "weekly":schedule="\(minute) \(hour) * * \(weekDay)";case "monthly":schedule="\(minute) \(hour) \(monthDay) * *";case "date":schedule="\(minute) \(hour) \(monthDay) \(month==0 ? "*":String(month)) *";case "hourly":schedule="\(minute) * * * *";case "interval":schedule="*/\(step) * * * *";case "reboot":schedule="@reboot";default:schedule="\(minute) \(hour) * * *"}}
    func decode(){syncing=true;defer{syncing=false;lastEncoded=schedule};if schedule=="@reboot"{mode="reboot";return};let p=schedule.split(separator:" ").map(String.init);guard p.count==5 else{mode="advanced";return};if let min=Int(p[0]),(0...59).contains(min){minute=min}else if p[0].hasPrefix("*/"),let n=Int(p[0].dropFirst(2)),(1...59).contains(n),p.dropFirst().allSatisfy({$0=="*"}){step=n;mode="interval";return}else{mode="advanced";return};if p[1]=="*",p.suffix(3).allSatisfy({$0=="*"}){mode="hourly";return};guard let h=Int(p[1]),(0...23).contains(h) else{mode="advanced";return};hour=h
        if p[2]=="*",p[3]=="*",p[4]=="*"{mode="daily"}
        else if p[2]=="*",p[3]=="*",let w=Int(p[4]),(0...7).contains(w){weekDay=w%7;mode="weekly"}
        else if let d=Int(p[2]),(1...31).contains(d),p[4]=="*"{monthDay=d;if p[3]=="*"{mode="monthly"}else if let mo=Int(p[3]),(1...12).contains(mo){month=mo;mode="date"}else{mode="advanced"}}
        else{mode="advanced"}
    }
}
