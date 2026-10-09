import Foundation
import Combine
import CryptoKit
import Darwin

@MainActor final class FileTransfer:ObservableObject {
    @Published var running=false
    @Published var progress=0.0
    @Published var status=""
    @Published var error:String?
    var serverID=""
    private var task:Task<Void,Never>?
    private var process:StreamProcess?
    func cancel(){task?.cancel();process?.stop()}
    func upload(server:Server,local:URL,remote:String,hash:String,complete:@escaping()->Void){
        guard !running else{return};running=true;progress=0;error=nil;serverID=server.id;status="Загрузка на сервер…"
        task=Task.detached{[weak self] in var transaction:String?
            do{
                let size=(try local.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
                guard size<=2*1024*1024*1024 else{throw AppFailure(message:"Максимум 2 ГБ на файл")}
                let start=try SSH.call(server,["action":"upload_begin","path":remote,"size":size,"hash":hash,"confirmed":true]) as? [String:Any] ?? [:]
                guard let id=start["id"] as? String else{throw AppFailure(message:"Не удалось начать загрузку")};transaction=id
                let input=try FileHandle(forReadingFrom:local);defer{try? input.close()};var offset=0;var digest=SHA256()
                while let data=try input.read(upToCount:1024*1024),!data.isEmpty{
                    try Task.checkCancellation();digest.update(data:data)
                    _=try SSH.call(server,["action":"upload_chunk","id":id,"offset":offset,"data":data.base64EncodedString()]);offset+=data.count
                    let progress=size==0 ? 1:Double(offset)/Double(size);await MainActor.run{self?.progress=progress}
                }
                try Task.checkCancellation();_=try SSH.call(server,["action":"upload_commit","id":id,"sha256":digest.finalize().map{String(format:"%02x",$0)}.joined()]);transaction=nil
                await MainActor.run{self?.status="Загружено · SHA-256 проверен";self?.running=false;self?.progress=1;complete()}
            }catch{if let transaction{_=try? SSH.call(server,["action":"upload_abort","id":transaction])};await MainActor.run{self?.running=false;self?.error=error is CancellationError ? "Загрузка отменена":error.localizedDescription}}
        }
    }
    func uploadItems(server:Server,locals:[URL],directory:String,replace:Bool,complete:@escaping()->Void){
        guard !running else{return};running=true;progress=0;error=nil;serverID=server.id;status="Подготовка загрузки…"
        task=Task.detached{[weak self] in var transaction:String?;var completed=0;var skipped=0
            let scoped=locals.filter{$0.startAccessingSecurityScopedResource()};defer{for url in scoped{url.stopAccessingSecurityScopedResource()}}
            do{
                var plan:[(URL,String,Bool,Int)]=[]
                for suppliedRoot in locals{
                    guard (try suppliedRoot.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw AppFailure(message:"Ссылки не загружаются")};let root=suppliedRoot.standardizedFileURL.resolvingSymlinksInPath()
                    var items:[(URL,String)]=[(root,root.lastPathComponent)]
                    if (try root.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true{guard let iterator=FileManager.default.enumerator(atPath:root.path) else{throw AppFailure(message:"Не удалось прочитать папку")};for case let relative as String in iterator{items.append((root.appendingPathComponent(relative),root.lastPathComponent+"/"+relative));if items.count>10000{throw AppFailure(message:"Максимум 10000 объектов за загрузку")}}}
                    for (item,relative) in items{try Task.checkCancellation();let info=try item.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]);guard info.isSymbolicLink != true,info.isDirectory==true || info.isRegularFile==true else{throw AppFailure(message:"Ссылки и специальные файлы не загружаются: "+item.lastPathComponent)};let local=item;let size=info.fileSize ?? 0;guard size<=2*1024*1024*1024 else{throw AppFailure(message:"Максимум 2 ГБ на файл: "+local.lastPathComponent)};plan.append((local,URL(fileURLWithPath:directory).appendingPathComponent(relative).path,info.isDirectory==true,size));if plan.count>10000{throw AppFailure(message:"Максимум 10000 объектов за загрузку")}}
                }
                plan.sort{if $0.2 != $1.2{return $0.2};return $0.1.split(separator:"/").count<$1.1.split(separator:"/").count}
                let total=max(1,plan.reduce(0){$0+$1.3});var bytes=0
                for (local,remote,isDirectory,size) in plan{try Task.checkCancellation();await MainActor.run{self?.status="Загрузка: "+local.lastPathComponent+" · готово "+String(completed)}
                    if isDirectory{_=try SSH.call(server,["action":"files_ensure_directory","path":remote,"confirmed":true]);continue}
                    let stat=try SSH.call(server,["action":"files_stat","path":remote]) as? [String:Any] ?? [:]
                    if stat["exists"] as? Bool==true && !replace{skipped+=1;bytes+=size;continue}
                    let start=try SSH.call(server,["action":"upload_begin","path":remote,"size":size,"hash":stat["hash"] as? String ?? "absent","confirmed":true]) as? [String:Any] ?? [:]
                    guard let id=start["id"] as? String else{throw AppFailure(message:"Не удалось начать загрузку")};transaction=id
                    let input=try FileHandle(forReadingFrom:local);var offset=0;var digest=SHA256()
                    do{while let data=try input.read(upToCount:1024*1024),!data.isEmpty{try Task.checkCancellation();digest.update(data:data);_=try SSH.call(server,["action":"upload_chunk","id":id,"offset":offset,"data":data.base64EncodedString()]);offset+=data.count;let progress=Double(bytes+offset)/Double(total);await MainActor.run{self?.progress=progress}};try input.close()}catch{try? input.close();throw error}
                    try Task.checkCancellation();_=try SSH.call(server,["action":"upload_commit","id":id,"sha256":digest.finalize().map{String(format:"%02x",$0)}.joined()]);transaction=nil;completed+=1;bytes+=size
                }
                await MainActor.run{self?.status="Загружено файлов: \(completed) · пропущено: \(skipped) · SHA-256 проверен";self?.running=false;self?.progress=1;complete()}
            }catch{if let transaction{_=try? SSH.call(server,["action":"upload_abort","id":transaction])};await MainActor.run{self?.running=false;self?.error=(error is CancellationError ? "Загрузка отменена":error.localizedDescription)+" · уже загружено файлов: "+String(completed);complete()}}
        }
    }
    func download(server:Server,remote:String,local:URL,complete:@escaping()->Void){
        guard !running else{return};running=true;progress=0;error=nil;serverID=server.id;status="Скачивание…";let runner=StreamProcess();process=runner
        task=Task.detached{[weak self] in let temporary=local.deletingLastPathComponent().appendingPathComponent(".server-backup-download-"+UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:temporary)}
            do{
                guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw AppFailure(message:"Не удалось создать временный файл")}
                let output=try FileHandle(forWritingTo:temporary);defer{try? output.close()};var digest=SHA256();var offset=0;var total=0;var verified=false
                try runner.run(server,["action":"files_download","path":remote],allowFinish:true){event in
                    try Task.checkCancellation();let value=event["result"] as? [String:Any] ?? [:]
                    switch event["event"] as? String{
                    case "file_start":total=value["size"] as? Int ?? 0
                    case "file_data":guard let encoded=value["data"] as? String,let data=Data(base64Encoded:encoded),value["offset"] as? Int==offset else{throw AppFailure(message:"Неверный блок скачивания")};try output.write(contentsOf:data);digest.update(data:data);offset+=data.count;let progress=total==0 ? 1:Double(offset)/Double(total);Task{@MainActor in self?.progress=progress}
                    case "file_end":guard value["size"] as? Int==offset,offset==total,value["sha256"] as? String==digest.finalize().map({String(format:"%02x",$0)}).joined() else{throw AppFailure(message:"SHA-256 скачанного файла не совпал")};verified=true
                    default:break
                    }
                }
                try Task.checkCancellation();guard verified else{throw AppFailure(message:"Сервер не подтвердил целостность файла")};try output.synchronize();try output.close()
                guard rename(temporary.path,local.path)==0 else{throw AppFailure(message:"Не удалось сохранить скачанный файл")}
                await MainActor.run{self?.status="Скачано · SHA-256 проверен";self?.running=false;self?.progress=1;self?.process=nil;complete()}
            }catch{await MainActor.run{self?.running=false;self?.process=nil;self?.error=error is CancellationError ? "Скачивание отменено":error.localizedDescription}}
        }
    }
    deinit{task?.cancel();process?.stop()}
}
