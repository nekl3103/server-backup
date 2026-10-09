import SwiftUI

struct NotificationsView:View {
    @EnvironmentObject var m:Model
    @State var telegramEnabled=false
    @State var token=""
    @State var chat=""
    @State var telegramSuccess=false
    @State var emailEnabled=false
    @State var host=""
    @State var port="587"
    @State var tls="starttls"
    @State var username=""
    @State var password=""
    @State var sender=""
    @State var recipients=""
    @State var emailSuccess=false
    var body:some View {
        VStack(alignment:.leading,spacing:22){
            Text("Уведомления необязательны. Можно выбрать почту, Telegram, оба канала или оставить их выключенными. Отправка выполняется на сервере.").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment:.leading,spacing:12){
                    Toggle("Включить Telegram",isOn:$telegramEnabled).font(.headline)
                    if telegramEnabled{SecureField("Токен бота",text:$token);TextField("Chat ID",text:$chat);Toggle("Сообщать об успешных копиях",isOn:$telegramSuccess)}
                    HStack{Button("Сохранить"){saveTelegram(false)};Button("Сохранить и отправить тест"){saveTelegram(true)}.disabled(!telegramEnabled)}
                }.padding(12)
            } label:{Label("Telegram",systemImage:"paperplane")}
            GroupBox {
                VStack(alignment:.leading,spacing:12){
                    Toggle("Включить электронную почту",isOn:$emailEnabled).font(.headline)
                    if emailEnabled {
                        HStack{TextField("SMTP-сервер",text:$host);TextField("Порт",text:$port).frame(width:100)}
                        Picker("Защита соединения",selection:$tls){Text("STARTTLS · обычно 587").tag("starttls");Text("TLS · обычно 465").tag("ssl")}
                        TextField("Логин SMTP",text:$username);SecureField("Пароль SMTP",text:$password)
                        TextField("Email отправителя",text:$sender);TextField("Получатели через запятую",text:$recipients)
                        Toggle("Сообщать об успешных копиях",isOn:$emailSuccess)
                    }
                    HStack{Button("Сохранить"){saveEmail(false)};Button("Сохранить и отправить тест"){saveEmail(true)}.disabled(!emailEnabled)}
                }.padding(12)
            } label:{Label("Электронная почта",systemImage:"envelope")}
            Text("Включённые каналы сообщают об ошибках, неполных копиях и отсутствии успешного ежедневного бэкапа более 26 часов. Ошибка отправки не меняет результат бэкапа.").font(.caption).foregroundStyle(.secondary)
            ResultView()
        }.disabled(m.busy).onAppear{load()}
    }
    func load(){
        let t=Vault.dictionary("telegram-"+(m.selectedID ?? ""));token=t["token"] as? String ?? "";chat=t["chat_id"] as? String ?? "";telegramEnabled=t["enabled"] as? Bool ?? !token.isEmpty;telegramSuccess=t["success"] as? Bool ?? false
        let e=Vault.dictionary("email-"+(m.selectedID ?? ""));emailEnabled=e["enabled"] as? Bool ?? false;host=e["host"] as? String ?? "";port=String(e["port"] as? Int ?? 587);tls=e["tls"] as? String ?? "starttls";username=e["username"] as? String ?? "";password=e["password"] as? String ?? "";sender=e["sender"] as? String ?? "";recipients=e["recipients"] as? String ?? "";emailSuccess=e["success"] as? Bool ?? false
    }
    func saveTelegram(_ test:Bool){save("telegram",["enabled":telegramEnabled,"token":token,"chat_id":chat,"success":telegramSuccess],test)}
    func saveEmail(_ test:Bool){guard let number=Int(port),(1...65535).contains(number) else{m.error="Укажите SMTP-порт от 1 до 65535";return};save("email",["enabled":emailEnabled,"host":host,"port":number,"tls":tls,"username":username,"password":password,"sender":sender,"recipients":recipients,"success":emailSuccess],test)}
    func save(_ channel:String,_ value:[String:Any],_ test:Bool){do{try Vault.put(channel+"-"+(m.selectedID ?? ""),value);m.perform(["action":channel,"settings":value,"test":test])}catch{m.error=error.localizedDescription}}
}
