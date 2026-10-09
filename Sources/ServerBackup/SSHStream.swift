import Foundation
import Combine
import Darwin

final class StreamProcess:@unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var stopped=false
    func stop(){lock.lock();stopped=true;let process=process;lock.unlock();if let process,process.isRunning{process.terminate()}}
    func run(_ server:Server,_ request:[String:Any],allowFinish:Bool=false,event:@escaping([String:Any])throws->Void)throws{
        signal(SIGPIPE,SIG_IGN);let invocation=try SSH.invocation(server,request)
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");p.arguments=invocation.args;p.environment=ProcessInfo.processInfo.environment.merging(invocation.environment){_,new in new}
        let out=Pipe(),err=Pipe(),input=Pipe();p.standardOutput=out;p.standardError=err;p.standardInput=input
        lock.lock();if stopped{lock.unlock();return};do{try p.run()}catch{lock.unlock();throw error};process=p;lock.unlock()
        defer{if p.isRunning{p.terminate()};lock.lock();process=nil;lock.unlock()}
        let group=DispatchGroup(),box=Runner.OutputBox();group.enter();DispatchQueue.global().async{box.stderr=err.fileHandleForReading.readDataToEndOfFile();group.leave()}
        try? input.fileHandleForWriting.write(contentsOf:invocation.input);try? input.fileHandleForWriting.close()
        var pending=Data()
        while true{let data=out.fileHandleForReading.availableData;if data.isEmpty{break};pending.append(data);guard pending.count<3*1024*1024 else{throw AppFailure(message:"Слишком большое событие потока")}
            while let end=pending.firstIndex(of:10){let line=pending[..<end];pending.removeSubrange(...end);if line.isEmpty{continue};guard let item=try JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else{throw AppFailure(message:"Ответ потока не распознан")};if item["event"] as? String=="error" || item["ok"] as? Bool==false{throw AppFailure(message:item["error"] as? String ?? "Ошибка потока")};if item["event"] != nil{try event(item)}}
        }
        p.waitUntilExit();_=group.wait(timeout:.now()+5);lock.lock();let wasStopped=stopped;lock.unlock()
        if !wasStopped && !(allowFinish && p.terminationStatus==0){throw SSHFailure(message:"SSH-поток прерван. "+String(String(decoding:box.stderr,as:UTF8.self).prefix(1000)))}
    }
}
@MainActor final class SSHStream:ObservableObject {
    @Published var state="Остановлен"
    @Published var error:String?
    @Published var lastEvent:Date?
    private var task:Task<Void,Never>?
    private var process:StreamProcess?
    private var watchdog:Task<Void,Never>?
    private var generation=UUID()
    func start(model:Model,request:[String:Any],event:@escaping([String:Any])->Void){
        stop();guard let server=model.current else{return};let id=UUID();generation=id;error=nil;lastEvent=nil;state="Подключение…"
        watchdog=Task{[weak self] in while !Task.isCancelled{try? await Task.sleep(for:.seconds(5));guard let self,self.generation==id else{return};if let last=self.lastEvent,Date().timeIntervalSince(last)>20{self.state="Нет новых данных";if Date().timeIntervalSince(last)>60{self.process?.stop()}}}}
        task=Task{var retry=1
            while !Task.isCancelled && generation==id{
                if model.isDesignPreview{state="Онлайн";lastEvent=Date();model.connectionOnline=true
                    let kind=request["kind"] as? String ?? "metrics";let action=kind=="metrics" ? "metrics":kind=="operations" ? "logs":"server_log"
                    if let result=model.designResponse(["action":action,"path":request["path"] ?? "journal"]){event(["event":kind=="operation_journal" ? "journal":kind,"mode":"replace","result":result])}
                    try? await Task.sleep(for:.seconds(Double(request["interval"] as? Int ?? 2)));continue
                }
                let runner=StreamProcess();process=runner
                do{try await Task.detached{try runner.run(server,request){item in Task{@MainActor [weak self] in guard let self,self.generation==id,model.selectedID==server.id else{return};self.state="Онлайн";self.error=nil;self.lastEvent=Date();model.connectionOnline=true;event(item)}}}.value}
                catch{guard generation==id,!Task.isCancelled else{return};self.error=error.localizedDescription;state="Переподключение…";if error is SSHFailure{await model.confirmConnectionFailure(server:server)}}
                guard generation==id,!Task.isCancelled else{return};process=nil;try? await Task.sleep(for:.seconds(retry));retry=min(retry*2,15)
            }
        }
    }
    func stop(){generation=UUID();watchdog?.cancel();watchdog=nil;task?.cancel();task=nil;process?.stop();process=nil;state="Пауза"}
    deinit{watchdog?.cancel();task?.cancel();process?.stop()}
}
enum LogBuffer {
    static func append(_ old:String,_ new:String)->String{
        var text=old+new
        if text.utf8.count>512*1024{text=String(decoding:Array(text.utf8.suffix(512*1024)),as:UTF8.self)}
        let lines=text.split(separator:"\n",omittingEmptySubsequences:false);if lines.count>501{text=lines.suffix(501).joined(separator:"\n")};return text
    }
}
