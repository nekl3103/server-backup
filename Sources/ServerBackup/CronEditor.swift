import SwiftUI

struct CronEditRequest:Identifiable{let id=UUID();let entry:[String:Any]?}
struct CronEditor:View{
    @EnvironmentObject var m:Model
    @Environment(\.dismiss) var dismiss
    let entry:[String:Any]?
    let onSave:()->Void
    @State private var user="root"
    @State private var schedule="0 3 * * *"
    @State private var command=""
    @State private var preset="custom"
    @State private var content=""
    @State private var hash=""
    @State private var loaded=false
    @State private var busy=false
    @State private var error=""
    @State private var advanced=false
    @State private var confirmSave=false
    @State private var confirmDelete=false
    var kind:String{entry?["kind"] as? String ?? "user"}
    var rawOnly:Bool{kind=="periodic" || kind=="anacron" || entry?["valid"] as? Bool==false}
    var source:String{kind=="periodic" ? entry?["command"] as? String ?? "":entry?["source"] as? String ?? ""}
    var request:[String:Any]{["kind":kind,"user":user,"source":source]}
    var body:some View{VStack(alignment:.leading,spacing:16){
        HStack{Label(entry==nil ? "Новое задание Cron":"Редактирование Cron",systemImage:"calendar.badge.clock").font(.title2);Spacer();Button("Закрыть"){dismiss()}}
        Text(entry==nil ? "Задание будет добавлено в crontab выбранного пользователя. Время — по часовому поясу сервера.":source).font(.caption).foregroundStyle(BackupTheme.muted).textSelection(.enabled)
        if !rawOnly{
            HStack{TextField("Пользователь",text:$user).disabled(entry != nil || loaded || busy);if entry==nil{Button(loaded ? "Сменить":"Прочитать расписание"){if loaded{loaded=false;hash=""}else{load()}}.disabled(busy || user.isEmpty)}}
            CronSchedulePicker(schedule:$schedule)
            Text("Команда").font(.headline)
            TextEditor(text:$command).font(.body.monospaced()).frame(height:90).border(.quaternary)
            Text("Cron выполняет команду автоматически от указанного пользователя. Для программ и файлов используйте полные пути.").font(.caption).foregroundStyle(BackupTheme.muted)
        }
        if rawOnly{sourceEditor}else{ClickableDisclosure(title:"Редактировать весь файл расписания",isExpanded:$advanced){sourceEditor;Text("В этом режиме сохраняется весь текст. Поля задания выше не применяются.").font(.caption).foregroundStyle(.orange)}}
        if busy{HStack{ProgressView().controlSize(.small);Text("Обмен с сервером…")}}
        if !error.isEmpty{Text(error).foregroundStyle(.orange).textSelection(.enabled)}
        HStack{if entry != nil && !rawOnly{Button("Удалить задание",role:.destructive){confirmDelete=true}.disabled(!loaded || busy)};Spacer();Button("Сохранить"){confirmSave=true}.buttonStyle(.borderedProminent).disabled(!loaded || busy || (!rawOnly && !advanced && (command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || schedule.isEmpty)))}
    }.padding(24).frame(width:760).textFieldStyle(.roundedBorder).task{user=entry?["user"] as? String ?? "root";schedule=entry?["schedule"] as? String ?? "0 3 * * *";command=entry?["command"] as? String ?? "";load()}
        .confirmationDialog("Сохранить расписание? Cron начнёт использовать его автоматически.",isPresented:$confirmSave){Button("Сохранить расписание"){save(deleting:false)}}
        .confirmationDialog("Удалить это задание из расписания?",isPresented:$confirmDelete){Button("Удалить",role:.destructive){save(deleting:true)}}
    }
    var sourceEditor:some View{TextEditor(text:$content).font(.caption.monospaced()).frame(height:230).border(.quaternary).disabled(!loaded)}
    func load(){guard let server=m.current else{return};busy=true;error="";let input=request;Task{do{let value=try await m.readLive(input.merging(["action":"cron_read"]){_,new in new},server:server) as? [String:Any] ?? [:];content=value["content"] as? String ?? "";hash=value["hash"] as? String ?? "";loaded=true}catch{self.error=error.localizedDescription};busy=false}}
    func save(deleting:Bool){guard let server=m.current else{return};var text=content
        if deleting || (!rawOnly && !advanced){var rows=text.components(separatedBy:"\n");let line=schedule.trimmingCharacters(in:.whitespacesAndNewlines)+" "+(kind=="system" ? user+" ":"")+command.trimmingCharacters(in:.whitespacesAndNewlines)
            if (command.contains("\n") || schedule.contains("\n")) && !deleting{error="Расписание и команда должны занимать по одной строке. Для скрипта укажите путь к файлу.";return}
            if let index=entry?["line"] as? Int{guard index>0,index<=rows.count else{error="Строка не найдена. Обновите расписание.";return};if deleting{rows.remove(at:index-1)}else{rows[index-1]=line}}
            else{if rows.last==""{rows.removeLast()};rows.append(line)}
            text=rows.joined(separator:"\n")
        }
        let input=request.merging(["action":"cron_save","content":text,"hash":hash,"confirmed":true]){_,new in new};busy=true;error="";Task{do{_ = try await m.readLive(input,server:server);onSave();dismiss()}catch{self.error=error.localizedDescription};busy=false}
    }
}
