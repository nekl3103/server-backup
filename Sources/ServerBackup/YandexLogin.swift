import Foundation
import Combine

@MainActor final class YandexLogin:ObservableObject {
    @Published var running=false
    @Published var message=""
    private var process:Process?
    private var timeout:Task<Void,Never>?
    private var generation=UUID()
    nonisolated static func extractToken(_ output:String)throws->String {
        let regex=try NSRegularExpression(pattern:"\\{[^\\n]*\\\"access_token\\\"[^\\n]*\\}")
        for match in regex.matches(in:output,range:NSRange(output.startIndex...,in:output)){guard let range=Range(match.range,in:output),let data=String(output[range]).data(using:.utf8),let token=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let access=token["access_token"] as? String,!access.isEmpty else{continue};return String(decoding:try JSONSerialization.data(withJSONObject:token,options:[.sortedKeys]),as:UTF8.self)}
        throw AppFailure(message:"Яндекс не вернул токен. Повторите вход.")
    }
    func start(completion:@escaping(String)->Void){guard !running else{return};let bundled=Bundle.main.resourceURL?.appendingPathComponent("rclone");let local=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("server-backup-macos/vendor/rclone/rclone");guard let executable=[bundled,local].compactMap({$0}).first(where:{FileManager.default.isExecutableFile(atPath:$0.path)}) else{message="Компонент входа rclone отсутствует. Используйте готовую .app или ручной токен.";return}
        let p=Process();p.executableURL=executable;p.arguments=["authorize","yandex","--config","/dev/null"];p.standardInput=FileHandle.nullDevice;let out=Pipe(),err=Pipe();p.standardOutput=out;p.standardError=err
        do{try p.run()}catch{message="Не удалось открыть вход в Яндекс";return}
        process=p;running=true;message="Завершите вход в Яндекс в браузере";let id=UUID();generation=id
        timeout=Task{try? await Task.sleep(for:.seconds(300));if !Task.isCancelled && generation==id{cancel();message="Время ожидания истекло. Повторите вход."}}
        DispatchQueue.global().async{[weak self] in let group=DispatchGroup();let box=Runner.OutputBox();group.enter();DispatchQueue.global().async{box.stdout=out.fileHandleForReading.readDataToEndOfFile();group.leave()};group.enter();DispatchQueue.global().async{box.stderr=err.fileHandleForReading.readDataToEndOfFile();group.leave()};p.waitUntilExit();group.wait();let output=String(decoding:box.stdout,as:UTF8.self);let code=p.terminationStatus
            Task{@MainActor [weak self] in guard let self,self.generation==id else{return};self.timeout?.cancel();self.process=nil;self.running=false
                guard code==0 else{self.message="Вход отменён или Яндекс отклонил авторизацию";return}
                do{let token=try Self.extractToken(output);completion(token);self.message="Вход выполнен. Сохраните подключение хранилища."}catch{self.message=error.localizedDescription}
            }
        }
    }
    func cancel(){guard running else{return};generation=UUID();timeout?.cancel();if let process,process.isRunning{process.terminate()};process=nil;running=false;message="Вход отменён"}
}
