import Foundation
struct ServerActivityState{
    var generation=UUID()
    var running=false
    var operationID:String?
    var data:[String:Any]=[:]
    var error:String?
    var message=""
}
extension Model{
    func activityKey(_ action:String,repository:String="")->String{(selectedID ?? "")+":"+action+":"+repository}
    func startActivity(_ action:String,key:String,repository:String="",resumeID:String?=nil){
        guard let server=current,activities[key]?.running != true else{return}
        activities[key]=ServerActivityState(running:true,data:activities[key]?.data ?? [:],message:"Запуск на сервере…")
        let generation=activities[key]!.generation
        activityTasks[key]=Task{
            do{
                let request:[String:Any]=repository.isEmpty ? ["action":action]:["action":action,"repository_id":repository]
                let result: [String:Any]
                if let resumeID{result=["operation_id":resumeID]}else{result=try await readLive(request,server:server) as? [String:Any] ?? [:]}
                guard let id=result["operation_id"] as? String else{throw AppFailure(message:"Сервер не вернул ID операции")}
                activities[key]?.operationID=id
                while !Task.isCancelled{
                    let state=try await readLive(["action":"state","id":id],server:server) as? [String:Any] ?? [:]
                    let status=state["status"] as? String ?? "waiting"
                    if ["success","failed","cancelled","incomplete"].contains(status){
                        activities[key]?.running=false
                        if status=="success"{let output=state["output"] as? String ?? "{}";activities[key]?.data=(try JSONSerialization.jsonObject(with:Data(output.utf8))) as? [String:Any] ?? [:];activities[key]?.message="Завершено"}
                        else if status=="cancelled"{activities[key]?.message="Отменено"}
                        else{activities[key]?.error=state["error"] as? String ?? "Операция не выполнена"}
                        break
                    }
                    if action=="external_test"{activities[key]?.message="Проверяется: "+(state["current_target"] as? String ?? "серверы")+" · \((state["targets_done"] as? NSNumber)?.intValue ?? 0) / \((state["targets_total"] as? NSNumber)?.intValue ?? 0)"}
                    else{activities[key]?.message="Измерение на сервере… Можно переходить в другие разделы."}
                    try await Task.sleep(for:.seconds(2))
                }
            }catch{if !Task.isCancelled,activities[key]?.generation==generation{activities[key]?.running=false;activities[key]?.error=error.localizedDescription}}
            if activities[key]?.generation==generation{activityTasks[key]=nil}
        }
    }
    func restoreActivity(_ action:String,key:String,repository:String="")async{
        guard let server=current,activities[key]?.running != true else{return}
        do{var request:[String:Any]=["action":action=="capacity_start" ? "capacity_status":"external_status"];if !repository.isEmpty{request["repository_id"]=repository};let value=try await readLive(request,server:server) as? [String:Any] ?? [:]
            if activities[key]?.running==true{return}
            let data=value["data"] as? [String:Any] ?? [:]
            if !data.isEmpty{activities[key]=ServerActivityState(data:data,message:action=="capacity_start" ? "Последнее успешное измерение":"Последняя проверка")}
            if let active=value["active"] as? [String:Any],let id=active["id"] as? String{startActivity(action,key:key,repository:repository,resumeID:id)}
        }catch{activities[key]?.error=error.localizedDescription}
    }
    func cancelActivity(_ key:String){
        guard let serverID=key.split(separator:":").first.map(String.init),let server=servers.first(where:{$0.id==serverID}),let id=activities[key]?.operationID else{return}
        activities[key]?.message="Остановка…"
        Task{do{_=try await readLive(["action":"cancel","id":id],server:server);activityTasks[key]?.cancel();activities[key]?.running=false;activities[key]?.message="Отменено"}catch{activities[key]?.error=error.localizedDescription}}
    }
}
func operationHistoryTitle(_ row:[String:Any])->String{
    let action=row["operation"] as? String ?? ""
    let title=["cron-save":"Изменение расписания Cron","backup":"Резервное копирование","restore":"Восстановление файлов","verify-restore":"Проверка восстановления","external-test":"Внешний контроль серверов","capacity":"Измерение ёмкости","check":"Проверка хранилища","prune":"Очистка хранилища","forget":"Удаление старых копий","copy":"Копирование в другое хранилище","database-import":"Восстановление базы данных","docker-import":"Восстановление Docker","package-install":"Установка программы"][action] ?? (action.isEmpty ? "Операция":action)
    if action=="backup"{return title+" · "+(row["job_name"] as? String ?? row["name"] as? String ?? row["id"] as? String ?? "задание")+(row["dry_run"] as? Bool==true ? " · пробный запуск":"")}
    return title
}
func operationHistoryContext(_ row:[String:Any])->String{
    var parts:[String]=[]
    if let repo=row["repository_name"] as? String ?? row["repository_id"] as? String,!repo.isEmpty{parts.append("Хранилище: "+repo)}
    if let snapshot=row["snapshot"] as? String{parts.append("Копия: "+String(snapshot.prefix(8)))}
    if let target=row["target"] as? String{parts.append("Куда: "+target)}
    if let name=row["name"] as? String{parts.append(name)}
    if let source=row["source"] as? String{parts.append(source)}
    if parts.isEmpty,let id=row["id"] as? String{parts.append(id)}
    return parts.joined(separator:" · ")
}
