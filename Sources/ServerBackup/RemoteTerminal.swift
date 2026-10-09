import SwiftUI
import AppKit
import SwiftTerm
import Darwin

final class InteractiveTerminal:LocalProcessTerminalView{
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        guard let attachedWindow=window else{return}
        DispatchQueue.main.async{[weak self,weak attachedWindow] in
            guard let self,let attachedWindow,self.window===attachedWindow else{return}
            attachedWindow.makeFirstResponder(self)
        }
    }
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);super.mouseDown(with:event)}
    override func performKeyEquivalent(with event:NSEvent)->Bool{
        guard window?.firstResponder===self,event.modifierFlags.intersection([.command,.control,.option])==[.command] else{return super.performKeyEquivalent(with:event)}
        switch event.charactersIgnoringModifiers?.lowercased(){
        case "c":copy(self);return true
        case "v":paste(self);return true
        case "k":feed(text:"\u{1b}[3J\u{1b}[2J\u{1b}[H");return true
        default:return super.performKeyEquivalent(with:event)
        }
    }
}
@MainActor final class RemoteTerminalSession:NSObject,ObservableObject,LocalProcessTerminalViewDelegate{
    let view=InteractiveTerminal(frame:CGRect(x:0,y:0,width:900,height:460))
    @Published var connected=false
    @Published var connecting=false
    @Published var message="Не подключён"
    @Published var title="SSH"
    private var generation=UUID()
    override init(){
        super.init()
        view.processDelegate=self
        view.font=NSFont.monospacedSystemFont(ofSize:14,weight:.regular)
        view.nativeBackgroundColor=NSColor(calibratedRed:0.045,green:0.055,blue:0.07,alpha:1)
        view.nativeForegroundColor=NSColor(calibratedWhite:0.9,alpha:1)
    }
    static func arguments(_ server:Server,socket:String)->[String]{
        SSH.options(server)+["-tt","-o","ControlMaster=no","-o","ControlPath="+socket,"-o","BatchMode=yes",server.user+"@"+server.host]
    }
    func connect(_ server:Server,preview:Bool){
        guard !connected,!connecting else{return}
        if preview{
            if ProcessInfo.processInfo.environment["SERVER_BACKUP_DESIGN_TERMINAL"]=="1"{
                message="Локальный тестовый терминал · без подключения к серверу"
                view.startProcess(executable:"/bin/bash",args:["--noprofile","--norc","-i"],environment:["TERM=xterm-256color","PATH=/usr/bin:/bin","PS1=local-test$ "])
                connected=view.process.running
            }else{message="Демонстрационный режим";view.feed(text:"\r\nSSH-терминал выбранного сервера. Подключение доступно в обычном режиме.\r\n")}
            return
        }
        let token=UUID();generation=token;connecting=true;message="Подключение…"
        Task{do{
            let socket=try await Task.detached{try SSHSessionPool.shared.ensure(server)}.value
            guard token==generation else{return}
            var environment=ProcessInfo.processInfo.environment
            environment.merge(SSH.environment(server)){_,new in new}
            environment["TERM"]="xterm-256color"
            view.feed(text:"\r\nПодключение к "+server.user+"@"+server.host+"…\r\n")
            view.startProcess(executable:"/usr/bin/ssh",args:Self.arguments(server,socket:socket),environment:environment.map{"\($0.key)=\($0.value)"})
            connected=view.process.running;connecting=false;message=connected ? "SSH-сеанс открыт":"Не удалось открыть SSH-сеанс"
            view.window?.makeFirstResponder(view)
        }catch{guard token==generation else{return};connecting=false;message=error.localizedDescription}}
    }
    func disconnect(){generation=UUID();connecting=false;connected=false;message="Отключён";if view.process.running{view.terminate()}}
    func sizeChanged(source:LocalProcessTerminalView,newCols:Int,newRows:Int){}
    func setTerminalTitle(source:LocalProcessTerminalView,title:String){self.title=String(title.prefix(120))}
    func hostCurrentDirectoryUpdate(source:TerminalView,directory:String?){}
    func processTerminated(source:TerminalView,exitCode:Int32?){connected=false;connecting=false;message=exitCode==0 ? "Сеанс завершён":"Соединение закрыто · код "+(exitCode.map(String.init) ?? "неизвестен")}
}

struct EmbeddedTerminal:NSViewRepresentable{
    let session:RemoteTerminalSession
    func makeNSView(context:Context)->LocalProcessTerminalView{session.view}
    func updateNSView(_ nsView:LocalProcessTerminalView,context:Context){}
}
struct RemoteTerminalView:View{
    @EnvironmentObject var m:Model
    let server:Server
    @ObservedObject var session:RemoteTerminalSession
    var body:some View{VStack(alignment:.leading,spacing:14){
        HStack{
            Label(server.user+"@"+server.host+" · порт "+String(server.port),systemImage:"terminal").font(.headline)
            Spacer()
            StatusBadge(title:session.connecting ? "Подключение…":session.connected ? "SSH-сеанс открыт":"Отключён",color:session.connected ? .green:.orange)
            if session.connected || session.connecting{Button("Отключиться"){session.disconnect()}}
            else{Button("Подключиться"){session.connect(server,preview:m.isDesignPreview)}.buttonStyle(.borderedProminent)}
        }
        Text(session.message).font(.caption).foregroundStyle(session.connected ? BackupTheme.muted:.orange).textSelection(.enabled)
        EmbeddedTerminal(session:session).frame(maxWidth:.infinity).frame(height:480).clipShape(RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(BackupTheme.border))
        Text("Вводите команды прямо в терминале · Tab — дополнение · ↑/↓ — история · Ctrl+C — прервать · Ctrl+L — очистить экран · ⌘C/⌘V — копировать/вставить · ⌘K — очистить историю экрана").font(.caption).foregroundStyle(BackupTheme.muted)
        Text("При смене раздела SSH-сеанс сохраняется. Закрытие приложения отключает терминал; задания резервного копирования продолжают работать на сервере.").font(.caption).foregroundStyle(BackupTheme.muted)
    }.onAppear{if !session.connected && !session.connecting{session.connect(server,preview:m.isDesignPreview)}}}
}

final class TerminalPTYTest:LocalProcessDelegate{
    var output=""
    var exitCode:Int32?
    var finished=false
    func dataReceived(slice:ArraySlice<UInt8>){output+=String(decoding:slice,as:UTF8.self)}
    func getWindowSize()->winsize{winsize(ws_row:24,ws_col:80,ws_xpixel:0,ws_ypixel:0)}
    func processTerminated(_ source:LocalProcess,exitCode:Int32?){self.exitCode=exitCode;finished=true}
    static func run()throws{
        let delegate=TerminalPTYTest()
        let process=LocalProcess(delegate:delegate)
        process.startProcess(executable:"/bin/sh",args:["-c","test -t 0 || exit 4; printf 'PTY_READY\\n'; read value; printf 'REPLY:%s\\n' \"$value\""])
        defer{if process.running{process.terminate()}}
        let deadline=Date().addingTimeInterval(10);var sent=false
        while !delegate.finished && Date()<deadline{
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
            if !sent && delegate.output.contains("PTY_READY"){process.send(data:Array("terminal-test\n".utf8)[...]);sent=true}
        }
        guard delegate.finished,delegate.exitCode==0,delegate.output.contains("REPLY:terminal-test") else{throw AppFailure(message:"Interactive PTY round trip failed")}
    }
}
