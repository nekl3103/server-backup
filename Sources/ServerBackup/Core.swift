import Foundation
import Combine
import Security
import CryptoKit
import AppKit
import Darwin

struct Server: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = "Новый сервер"
    var host = ""
    var port = 22
    var user = "root"
    var keyPath = ""
    var useSudo = false
    var group:String? = nil
}
struct AppFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
enum Vault {
    static let service = "ru.serverbackup.credentials"
    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess else { return nil }; return result as? Data
    }
    static func set(_ account: String,_ data: Data) throws {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let status = SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var added=q; added[kSecValueData as String]=data; added[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(added as CFDictionary,nil)==errSecSuccess else { throw AppFailure(message:"Не удалось сохранить секрет в Keychain") }
        } else if status != errSecSuccess { throw AppFailure(message:"Keychain недоступен: \(status)") }
    }
    static func dictionary(_ account:String)->[String:Any] { guard let d=get(account), let o=try? JSONSerialization.jsonObject(with:d) as? [String:Any] else { return [:] }; return o }
    static func put(_ account:String,_ value:[String:Any]) throws { try set(account,JSONSerialization.data(withJSONObject:value)) }
}
struct ProcessResult { let code:Int32; let output:String; let error:String }
enum Runner {
    static func run(_ executable:String,_ args:[String],input:Data?=nil,environment:[String:String]=[:]) throws -> ProcessResult {
        signal(SIGPIPE,SIG_IGN)
        let p=Process(); p.executableURL=URL(fileURLWithPath:executable); p.arguments=args
        p.environment=ProcessInfo.processInfo.environment.merging(environment){_,new in new}
        let out=Pipe(),err=Pipe(),stdin=Pipe(); p.standardOutput=out;p.standardError=err;p.standardInput=stdin
        try p.run()
        // Drain both streams concurrently to avoid pipe deadlocks on long logs.
        let group=DispatchGroup(); let box=OutputBox()
        group.enter();DispatchQueue.global().async { box.stdout=out.fileHandleForReading.readDataToEndOfFile();group.leave() }
        group.enter();DispatchQueue.global().async { box.stderr=err.fileHandleForReading.readDataToEndOfFile();group.leave() }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf:input) }
        try stdin.fileHandleForWriting.close();p.waitUntilExit();group.wait()
        return ProcessResult(code:p.terminationStatus,output:String(decoding:box.stdout,as:UTF8.self),error:String(decoding:box.stderr,as:UTF8.self))
    }
    final class OutputBox: @unchecked Sendable {var stdout=Data();var stderr=Data()}
}
enum Paths {
    static var support:URL { let u=ProcessInfo.processInfo.environment["SERVER_BACKUP_SUPPORT_ROOT"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ServerBackup");try? FileManager.default.createDirectory(at:u,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return u }
    static func known(_ id:String)->URL { support.appendingPathComponent("known-\(id)") }
    static var resourceRoot:URL { Bundle.module.resourceURL!.appendingPathComponent("Resources") }
}
enum SSH {
    static func scan(_ s:Server) throws -> (String,String) {
        try validate(s)
        let result=try Runner.run("/usr/bin/ssh-keyscan",["-T","10","-p",String(s.port),s.host])
        guard !result.output.isEmpty else { throw AppFailure(message:"Не удалось получить ключ SSH сервера") }
        let fingerprints=try Runner.run("/usr/bin/ssh-keygen",["-lf","-"],input:Data(result.output.utf8))
        return (result.output,fingerprints.output)
    }
    static func validate(_ s:Server) throws {
        guard s.host.range(of:"^[A-Za-z0-9.:-]+$",options:.regularExpression) != nil,
              s.user.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil,
              (1...65535).contains(s.port) else { throw AppFailure(message:"Проверьте адрес, пользователя и порт SSH") }
    }
    static func call(_ s:Server,_ request:[String:Any]) throws -> Any {
        let invocation=try invocation(s,request)
        var result=try Runner.run("/usr/bin/ssh",invocation.args,input:invocation.input,environment:invocation.environment)
        // A refused multiplexed channel never started the remote command; retry only this case.
        if channelRefused(result){let fresh=try self.invocation(s,request,independent:true);result=try Runner.run("/usr/bin/ssh",fresh.args,input:fresh.input,environment:fresh.environment)}
        if result.code==255{throw SSHFailure(message:"SSH: проверьте доступ и ключ сервера. "+String(result.error.prefix(1500)))}
        guard let data=result.output.data(using:.utf8),let response=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw AppFailure(message:result.code==255 ? "SSH: проверьте доступ и ключ сервера. \(result.error.prefix(1500))" : "Ответ сервера не распознан: \(result.error.prefix(1500))")
        }
        if response["ok"] as? Bool != true {throw AppFailure(message:response["error"] as? String ?? "Ошибка серверной операции")}
        return response["result"] ?? NSNull()
    }
}
struct ExportEnvelope: Codable {let version:Int;let salt:Data;let combined:Data}
enum ProfileExport {
    // PBKDF2-HMAC-SHA256 implemented with CryptoKit, avoiding third-party crypto dependencies.
    static func key(_ password:String,_ salt:Data)->SymmetricKey {
        let passwordKey=SymmetricKey(data:Data(password.utf8));var block=salt;block.append(contentsOf:[0,0,0,1])
        var u=Data(HMAC<SHA256>.authenticationCode(for:block,using:passwordKey));var result=[UInt8](u)
        for _ in 1..<210_000 {u=Data(HMAC<SHA256>.authenticationCode(for:u,using:passwordKey));for (i,b) in u.enumerated(){result[i] ^= b}}
        return SymmetricKey(data:Data(result))
    }
    static func seal(_ data:Data,password:String)throws->Data {
        guard password.count>=12 else {throw AppFailure(message:"Пароль экспорта должен содержать не менее 12 символов")}
        var salt=Data(count:16);let status=salt.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!)}
        guard status==errSecSuccess else {throw AppFailure(message:"Генератор случайных чисел недоступен")}
        let sealed=try AES.GCM.seal(data,using:key(password,salt))
        return try JSONEncoder().encode(ExportEnvelope(version:1,salt:salt,combined:sealed.combined!))
    }
    static func open(_ data:Data,password:String)throws->Data {
        let e=try JSONDecoder().decode(ExportEnvelope.self,from:data)
        guard e.version==1,e.salt.count==16 else {throw AppFailure(message:"Неизвестный формат экспорта")}
        return try AES.GCM.open(AES.GCM.SealedBox(combined:e.combined),using:key(password,e.salt))
    }
}
@MainActor final class Model: ObservableObject {
    @Published var servers:[Server]=[]
    @Published var fleet:[String:FleetStatus]=[:]
    @Published var fleetLoading=false
    @Published var preferredRepository=""
    @Published var selectedID:String?
    @Published var section="Обзор"
    @Published var connectionOnline=false
    let transfer=FileTransfer()
    var filePaths:[String:String]=[:]
    @Published var favouriteFolders:[String:[String]]=UserDefaults.standard.dictionary(forKey:"serverBackupFavouriteFolders") as? [String:[String]] ?? [:]
    func toggleFavourite(_ path:String){guard let id=selectedID else{return};var items=favouriteFolders[id] ?? [];if items.contains(path){items.removeAll{$0==path}}else{items.append(path)};favouriteFolders[id]=items;UserDefaults.standard.set(favouriteFolders,forKey:"serverBackupFavouriteFolders")}
    @Published var result=""
    @Published var error:String?
    @Published var busy=false
    @Published var probe:[String:Any]=[:]
    @Published var workspaceLoaded=false
    @Published var history:[[String:Any]]=[]
    var jobDrafts:[String:[String:Any]]=[:]
    @Published var notice:String?
    @Published var repositories:[[String:Any]]=[]
    @Published var jobs:[[String:Any]]=[]
    @Published var databases:[[String:Any]]=[]
    @Published var states:[[String:Any]]=[]
    @Published var containers:[[String:Any]]=[]
    @Published var metrics:[String:Any]=[:]
    @Published var metricsLoading=false
    @Published var metricError:String?
    @Published var metricUpdated:Date?
    @Published var metricHistory:[String:[MetricPoint]]=[:]
    @Published var pendingTrust:(Server,String,String)?
    @Published var snapshotPages:[SnapshotPageKey:SnapshotPage]=[:]
    var snapshotRequests:[SnapshotPageKey:Task<SnapshotPage,Error>]=[:]
    @Published var activities:[String:ServerActivityState]=[:]
    var activityTasks:[String:Task<Void,Never>]=[:]
    var terminalSessions:[String:RemoteTerminalSession]=[:]
    func terminalSession(for server:Server)->RemoteTerminalSession{if let existing=terminalSessions[server.id]{return existing};let session=RemoteTerminalSession();terminalSessions[server.id]=session;return session}
    func closeTerminals(){for session in terminalSessions.values{session.disconnect()}}
    @Published var operationID:String?
    var operationServer:Server?
    @Published var operationState:[String:Any]=[:]
    @Published var operationDismissed=false
    private var operationGeneration=UUID()
    private var operationPolling=false
    func trackOperation(_ id:String,server:Server){operationID=id;operationServer=server;operationGeneration=UUID();operationDismissed=false;operationState=["id":id,"status":"queued","operation":"backup"]}
    @Published var snapshots:[[String:Any]]=[]
    @Published var snapshotNodes:[[String:Any]]=[]
    @Published var selectedSnapshot="latest"
    @Published var restoreIncludes:[String]=[]
    @Published var events:[String]=[]
    var current:Server? {servers.first{$0.id==selectedID}}
    init(){if isDesignPreview{seedDesignServers();return};if let d=try? Data(contentsOf:Paths.support.appendingPathComponent("servers.json")),let s=try? JSONDecoder().decode([Server].self,from:d){servers=s}}
    func save(_ server:Server,secret:String)throws {
        if let i=servers.firstIndex(where:{$0.id==server.id}) {servers[i]=server}else{servers.append(server)}
        try persist()
        try Vault.set("ssh-"+server.id,Data(secret.utf8))
    }
    func persist()throws {let u=Paths.support.appendingPathComponent("servers.json");try JSONEncoder().encode(servers).write(to:u,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:u.path)}
    static func pretty(_ value:Any)->String {guard JSONSerialization.isValidJSONObject(value),let d=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]) else{return String(describing:value)};return String(decoding:d,as:UTF8.self)}
    func perform(_ request:[String:Any],server:Server?=nil,completion:((Any)->Void)?=nil) {
        if isDesignPreview{if let response=designResponse(request){completion?(response)}else{error="В демонстрационном режиме доступен только просмотр интерфейса"};return}
        guard let s=server ?? current,!busy else{return};busy=true;error=nil
        Task {
            do {let response=try await Task.detached {try SSH.call(s,request)}.value
                if let d=response as? [String:Any], let code=d["exit_code"] as? Int, code != 0 { throw AppFailure(message:d["error"] as? String ?? "Команда завершилась с ошибкой") }
                if s.id==selectedID{connectionOnline=true};result=Self.pretty(response);events.append("\(Date().formatted()) · \(request["action"] ?? "") · успешно")
                if let d=response as? [String:Any],let id=d["operation_id"] as? String{trackOperation(id,server:s)}
                if request["action"] as? String=="start_job",let id=request["job_id"] as? String,request["dry_run"] as? Bool != true {trackOperation(id,server:s)}
                busy=false
                let action=request["action"] as? String ?? ""
                if action=="save_repository"{snapshotPages.removeAll()}
                let messages=["save_repository":"Хранилище подключено", "save_job":"Задание сохранено", "save_database":"Подключение к базе сохранено", "telegram":"Настройки Telegram сохранены", "email":"Настройки почты сохранены"]
                if let message=messages[action]{notice=message}
                completion?(response)
                if ["save_repository","save_job","save_database"].contains(action), !busy, s.id==selectedID {loadProbe()}
                return
            }catch{if error is SSHFailure,s.id==selectedID{await confirmConnectionFailure(server:s)};self.error=error.localizedDescription;events.append("\(Date().formatted()) · \(request["action"] ?? "") · ошибка")}
            busy=false
        }
    }
    func connect(){if isDesignPreview{connectionOnline=true;error=nil;applyWorkspace(Self.designWorkspace);containers=Self.designContainers;if ProcessInfo.processInfo.environment["SERVER_BACKUP_DESIGN_OPERATION"]=="1",let server=current{trackOperation("demo-operation",server:server);tick()};return};guard let s=current,!busy else{return};busy=true
        Task{do{let (keys,fingerprint)=try await Task.detached{try SSH.scan(s)}.value
            let saved=try? String(contentsOf:Paths.known(s.id),encoding:.utf8)
            let newKeys=Set(keys.split(separator:"\n").map(String.init));let oldKeys=Set((saved ?? "").split(separator:"\n").map(String.init))
            busy=false
            if saved==nil || newKeys != oldKeys{pendingTrust=(s,keys,fingerprint)}else{loadProbe()}
        }catch{busy=false;self.error=error.localizedDescription}}
    }
    func trust(){guard let (s,keys,_)=pendingTrust else{return};do{try keys.write(to:Paths.known(s.id),atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:Paths.known(s.id).path);pendingTrust=nil;loadProbe()}catch{self.error=error.localizedDescription}}
    func loadProbe(){perform(["action":"overview"]){self.applyWorkspace($0 as? [String:Any] ?? [:]);self.result=""}}
    func applyWorkspace(_ value:[String:Any]) {
        probe=value;workspaceLoaded=true
        repositories=value["repositories"] as? [[String:Any]] ?? []
        jobs=value["jobs"] as? [[String:Any]] ?? []
        databases=value["databases"] as? [[String:Any]] ?? []
        states=value["states"] as? [[String:Any]] ?? []
        history=value["history"] as? [[String:Any]] ?? []
        resumeServerOperation()
    }
    func resumeServerOperation(){
        guard let server=current else{return}
        let active=states.filter{["running","queued","waiting"].contains($0["status"] as? String ?? "") && !($0["id"] as? String ?? "").isEmpty}
        let record=active.first{($0["id"] as? String)==operationID && operationServer?.id==server.id} ?? active.sorted{($0["started"] as? String ?? "") > ($1["started"] as? String ?? "")}.first
        guard let record,let id=record["id"] as? String else{return}
        if operationID != id || operationServer?.id != server.id{trackOperation(id,server:server)}
        operationState=record
    }
    var tools:[String:Any]{probe["tools"] as? [String:Any] ?? [:]}
    var installed:Bool{probe["installed"] as? Bool==true && tools["restic"] as? String != nil}
    var successfulBackup:[String:Any]?{history.first{($0["status"] as? String)=="success" && ($0["dry_run"] as? Bool) != true && ($0["operation"] as? String ?? "backup")=="backup"}}
    func openServer(_ server:Server){let same=selectedID==server.id;reset();section="Обзор";selectedID=server.id;if same{connect()}}

    func refresh(_ kind:String){perform(["action":"list","kind":kind]){r in let values=r as? [[String:Any]] ?? [];switch kind{case "repositories":self.repositories=values;case "jobs":self.jobs=values;case "databases":self.databases=values;case "states":self.states=values;default:break}}}
    func tick(){guard current != nil,!operationPolling,let id=operationID,let server=operationServer else{return};operationPolling=true;let generation=operationGeneration
        Task{defer{operationPolling=false};do{let value=try await readLive(["action":"state","id":id],server:server);guard generation==operationGeneration else{return};operationState=value as? [String:Any] ?? [:]
            if ["success","failed","incomplete","cancelled"].contains(operationState["status"] as? String ?? ""){operationID=nil;Task{try? await Task.sleep(for:.seconds(30));if generation==operationGeneration{operationDismissed=true}}}
        }catch{if generation==operationGeneration{self.error=error.localizedDescription}}}
    }
    func reset(){operationGeneration=UUID();operationDismissed=false;connectionOnline=false;workspaceLoaded=false;history=[];notice=nil;error=nil;containers=[];probe=[:];repositories=[];jobs=[];databases=[];states=[];metrics=[:];metricError=nil;metricUpdated=nil;metricHistory=[:];operationID=nil;operationServer=nil;operationState=[:];snapshots=[];snapshotNodes=[];selectedSnapshot="latest";restoreIncludes=[];preferredRepository="";result=""}
}
extension Vault {
    static func all()throws->[String:Data]{
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnData as String:true,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitAll]
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return [:]};guard status==errSecSuccess else{throw AppFailure(message:"Keychain недоступен")}
        var records:[String:Data]=[:];for r in result as? [[String:Any]] ?? []{if let account=r[kSecAttrAccount as String] as? String,let data=r[kSecValueData as String] as? Data{records[account]=data}};return records
    }
}
enum SelfTests {
    static func run()throws {
        guard SSH.channelRefused(ProcessResult(code:255,output:"",error:"mux_client_request_session: session request failed")), !SSH.channelRefused(ProcessResult(code:255,output:"",error:"Connection timed out")), !SSH.channelRefused(ProcessResult(code:1,output:"",error:"session request failed")) else{throw AppFailure(message:"SSH transport and channel errors confused")}

        guard humanCronSchedule("0 3 * * *")=="Ежедневно в 03:00",humanCronSchedule("0 3 * * 1")=="Понедельник, в 03:00",humanCronSchedule("*/15 * * * *")=="Каждые 15 мин",humanCronSchedule("@reboot")=="При запуске сервера" else{throw AppFailure(message:"Расписание Cron")}

        guard LogBuffer.append("",String(repeating:"line\n",count:1000)).split(separator:"\n").count<=500 else{throw AppFailure(message:"Log stream buffer is unbounded")}
        let oauth=try YandexLogin.extractToken("Paste the following: \n{\"access_token\":\"fixture-token\",\"token_type\":\"OAuth\"}\n")
        guard oauth.contains("fixture-token") else{throw AppFailure(message:"OAuth response parsing failed")}
        var badOAuth=false;do{_=try YandexLogin.extractToken("Cancelled")}catch{badOAuth=true};guard badOAuth else{throw AppFailure(message:"Invalid OAuth response accepted")}
        let payload=Data("профили SSH и S3".utf8);let password="test-password-12345"
        let archive=try ProfileExport.seal(payload,password:password)
        guard try ProfileExport.open(archive,password:password)==payload else{throw AppFailure(message:"Export round trip failed")}
        var rejected=false;do{_=try ProfileExport.open(archive,password:"incorrect-password")}catch{rejected=true}
        guard rejected else{throw AppFailure(message:"Wrong password accepted")}
        var s=Server();s.host="127.0.0.1";try SSH.validate(s);s.host="host; touch /tmp/test";rejected=false;do{try SSH.validate(s)}catch{rejected=true};guard rejected else{throw AppFailure(message:"SSH injection accepted")}
        let p=try Runner.run("/bin/cat",[],input:payload);guard p.code==0,Data(p.output.utf8)==payload else{throw AppFailure(message:"Process stdin failed")}
        try MainActor.assumeIsolated {
            let draftID="self-test-"+UUID().uuidString
            let draft:[String:Any]=["type":"yandex","token":"fixture-token","yandex_path":"Server Backup/test","path":"/disk path","password":"fixture-password"]
            try StorageDrafts.save(draft,serverID:draftID,preview:true)
            let restored=StorageDrafts.read(serverID:draftID,preview:true)
            guard NSDictionary(dictionary:restored).isEqual(to:draft),StorageDrafts.read(serverID:draftID+"-other",preview:true).isEmpty else{throw AppFailure(message:"Storage draft lost fields or crossed servers")}
            guard backupResultColor("success") == .green,backupResultColor("incomplete") == .orange else{throw AppFailure(message:"Calendar colors disagree with result badges")}
            let model=Model()
            let sample=try JSONSerialization.jsonObject(with:Data("{\"cpu_percent\":0,\"memory\":{\"MemTotal\":100,\"MemAvailable\":25},\"network\":{\"eth0\":{\"rx_per_second\":2000000,\"tx_per_second\":0}}}".utf8)) as! [String:Any]
            model.acceptMetrics(sample)
            guard model.metricHistory["cpu"]?.last?.value==0,model.metricHistory["memory"]?.last?.value==75,model.metricHistory["network"]?.first(where:{$0.series=="eth0 · Приём"})?.value==2 else{throw AppFailure(message:"Metric conversion failed")}
            let count=model.metricHistory["cpu"]!.count;model.acceptMetrics([:])
            guard model.metricHistory["cpu"]?.count==count else{throw AppFailure(message:"Missing metric became zero")}
            model.reset();guard model.metricHistory.isEmpty else{throw AppFailure(message:"Metric history was not cleared")}
            let server=Server();model.servers=[server];model.selectedID=server.id
            model.applyWorkspace(["states":[["id":"old-job","status":"success","started":"2026-10-08T03:00:00Z"],["id":"daily","status":"running","started":"2026-10-09T03:00:00Z","stage":"backup","progress":["bytes_done":1234]]]])
            guard model.operationID=="daily",model.operationServer?.id==server.id,(model.operationState["progress"] as? [String:Int])?["bytes_done"]==1234 else{throw AppFailure(message:"Running server backup was not resumed after reconnect")}
            model.operationDismissed=true
            model.applyWorkspace(["states":[["id":"daily","status":"running","started":"2026-10-09T03:00:00Z"]]])
            guard model.operationDismissed else{throw AppFailure(message:"Refresh reopened a deliberately hidden operation")}
            model.reset();model.applyWorkspace(["states":[["id":"daily","status":"success"]]])
            guard model.operationID==nil,model.operationState.isEmpty else{throw AppFailure(message:"Finished backup resumed as running")}
        }
        let data=try JSONEncoder().encode([Server()]);_=try JSONDecoder().decode([Server].self,from:data)
    }
}
extension SelfTests {
    static func ssh() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let port=env["SERVER_BACKUP_TEST_PORT"].flatMap(Int.init), let key=env["SERVER_BACKUP_TEST_KEY"],env["SERVER_BACKUP_SUPPORT_ROOT"] != nil else {throw AppFailure(message:"Test environment missing")}
        var s=Server();s.name="Integration fixture";s.host="127.0.0.1";s.port=port
        let scan=try SSH.scan(s);try scan.0.write(to:Paths.known(s.id),atomically:true,encoding:.utf8)
        defer{SSHSessionPool.shared.closeAll();try? FileManager.default.removeItem(at:Paths.known(s.id));SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Vault.service,kSecAttrAccount as String:"ssh-"+s.id] as CFDictionary)}
        try Vault.set("ssh-"+s.id,Data("sbtestpassword".utf8))
        let probe=try SSH.call(s,["action":"probe"]) as? [String:Any];guard probe?["root"] as? Bool==true else{throw AppFailure(message:"SSH password test failed")}
        s.keyPath=key;try Vault.set("ssh-"+s.id,Data("sbtestpassphrase".utf8))
        if env["SERVER_BACKUP_TEST_HISTORY"]=="1"{try await historyWithBusyChannel(s)}
        _=try SSH.call(s,["action":"probe"])
        let firstSocket=try SSHSessionPool.shared.ensure(s);_=try SSH.call(s,["action":"probe"])
        guard try SSHSessionPool.shared.ensure(s)==firstSocket else{throw AppFailure(message:"SSH session was not reused")}
        let metricsStream=StreamProcess();var samples=0
        try metricsStream.run(s,["action":"stream","kind":"metrics","interval":2]){event in if event["event"] as? String=="metrics"{samples+=1;if samples>=2{metricsStream.stop()}}}
        guard samples>=2 else{throw AppFailure(message:"Metric stream failed")}
        let folder="/srv/server-backup-native-fixture-"+s.id;_=try SSH.call(s,["action":"files_mkdir","path":folder,"confirmed":true])
        let remote=folder+"/quote \" backslash \\ файл.bin";let payload=Data((0..<1_100_000).map{UInt8($0%256)})
        let upload=try SSH.call(s,["action":"upload_begin","path":remote,"size":payload.count,"hash":"absent","confirmed":true]) as! [String:Any];let uploadID=upload["id"] as! String
        for offset in stride(from:0,to:payload.count,by:1024*1024){let data=payload.subdata(in:offset..<min(offset+1024*1024,payload.count));_=try SSH.call(s,["action":"upload_chunk","id":uploadID,"offset":offset,"data":data.base64EncodedString()])}
        let digest=SHA256.hash(data:payload).map{String(format:"%02x",$0)}.joined();_=try SSH.call(s,["action":"upload_commit","id":uploadID,"sha256":digest])
        let download=StreamProcess();var received=Data();var downloadHash=""
        try download.run(s,["action":"files_download","path":remote],allowFinish:true){event in let result=event["result"] as? [String:Any] ?? [:];if event["event"] as? String=="file_data",let encoded=result["data"] as? String,let data=Data(base64Encoded:encoded){received.append(data)};if event["event"] as? String=="file_end"{downloadHash=result["sha256"] as? String ?? ""}}
        guard received==payload,downloadHash==digest else{throw AppFailure(message:"File transfer checksum failed")}
        let log="/var/log/server-backup-native-fixture-"+s.id+".log";_=try SSH.call(s,["action":"files_write","path":log,"content":"first\n","hash":"absent","confirmed":true])
        let logStream=StreamProcess();var logEvents=0;var logText=""
        try logStream.run(s,["action":"stream","kind":"logs","source":"file","path":log]){event in guard event["event"] as? String=="logs",let value=event["result"] as? [String:Any] else{return};logEvents+=1;logText += value["text"] as? String ?? "";if logEvents==1{let stat=try SSH.call(s,["action":"files_stat","path":log]) as! [String:Any];_=try SSH.call(s,["action":"files_write","path":log,"content":"second\n","hash":stat["hash"]!,"confirmed":true])}else{logStream.stop()}}
        guard logText=="first\nsecond\n" else{throw AppFailure(message:"Rotation stream failed")}
        try await batchUploadTest(s,remote:folder)
        print("PERSISTENT SSH, METRICS, ROTATION, UPLOAD, DOWNLOAD PASSED")
        if env["SERVER_BACKUP_TEST_RECONNECT"]=="1",let docker=env["SERVER_BACKUP_TEST_DOCKER"]{
            try await reconnect(s,docker:docker)
            print("AUTOMATIC RECONNECTION AFTER CONTAINER RESTART PASSED")
        }

        try "[127.0.0.1]:\(port) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINoZKSZ/P/oomcQsHGEh7ufHSLkEjIdEj34PvNEiWP/A\n".write(to:Paths.known(s.id),atomically:true,encoding:.utf8)
        var rejected=false;do{_=try SSH.call(s,["action":"probe"])}catch{rejected=true};guard rejected else{throw AppFailure(message:"Changed host key was accepted")}
    }
    static func historySSH()async throws {
        let env=ProcessInfo.processInfo.environment
        guard let port=env["SERVER_BACKUP_TEST_PORT"].flatMap(Int.init),let key=env["SERVER_BACKUP_TEST_KEY"],let publicKey=env["SERVER_BACKUP_TEST_HOST_KEY"],env["SERVER_BACKUP_SUPPORT_ROOT"] != nil else{throw AppFailure(message:"Local fixture environment missing")}
        var server=Server();server.host="127.0.0.1";server.port=port;server.keyPath=key
        try ("[127.0.0.1]:\(port) "+publicKey+"\n").write(to:Paths.known(server.id),atomically:true,encoding:.utf8)
        defer{SSHSessionPool.shared.closeAll();try? FileManager.default.removeItem(at:Paths.known(server.id))}
        guard SSH.connectionAvailable(server) else{throw AppFailure(message:"Local SSH fixture is unavailable")}
        try await historyWithBusyChannel(server)
    }
    @MainActor static func historyWithBusyChannel(_ server:Server)async throws {
        let runner=StreamProcess();let ready=DispatchSemaphore(value:0)
        let task=Task.detached{try runner.run(server,["action":"stream","kind":"metrics","interval":2]){_ in ready.signal()}}
        defer{runner.stop();task.cancel()}
        var available=false
        for _ in 0..<150{if ready.wait(timeout:.now()) == .success{available=true;break};try await Task.sleep(for:.milliseconds(100))}
        guard available else{throw AppFailure(message:"Fixture stream did not start")}
        let model=Model();model.servers=[server];model.selectedID=server.id;model.connectionOnline=true
        let result=try await model.readLive(["action":"snapshot_file_history","repository_id":"fixture-history","path":"/history/file.txt","limit":5],server:server) as? [String:Any] ?? [:]
        guard (result["versions"] as? [[String:Any]])?.count==2,model.connectionOnline else{throw AppFailure(message:"File history lost SSH connection while channel was busy")}
        do{_=try await model.readLive(["action":"snapshot_file_history","repository_id":"absent-fixture","path":"/history/file.txt"],server:server);throw AppFailure(message:"Missing fixture repository accepted")}catch{guard model.connectionOnline else{throw AppFailure(message:"Repository error marked the server offline")}}
        print("FILE HISTORY WITH BUSY SSH CHANNEL AND CONNECTION STATUS PASSED")
    }
    @MainActor static func batchUploadTest(_ server:Server,remote:String) async throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("sb-batch-"+UUID().uuidString);try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:temp)}
        let folder=temp.appendingPathComponent("Folder with space");let nested=folder.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true);try Data("original".utf8).write(to:folder.appendingPathComponent("file.txt"));try Data("nested-content".utf8).write(to:nested.appendingPathComponent("other.txt"))
        let transfer=FileTransfer();var done=false
        transfer.uploadItems(server:server,locals:[folder],directory:remote,replace:false){done=true}
        let deadline=Date().addingTimeInterval(45);while !done && Date()<deadline{try await Task.sleep(for:.milliseconds(100))};guard done,transfer.error==nil else{throw AppFailure(message:transfer.error ?? "Batch upload timed out")}
        let target=remote+"/Folder with space/file.txt"
        let read=try SSH.call(server,["action":"files_read","path":target]) as? [String:Any] ?? [:];guard read["content"] as? String=="original" else{throw AppFailure(message:"Folder upload content mismatch")}
        done=false;transfer.uploadItems(server:server,locals:[folder],directory:remote,replace:false){done=true};while !done && Date()<deadline{try await Task.sleep(for:.milliseconds(100))};guard done,transfer.error==nil,transfer.status.contains("пропущено: 2") else{throw AppFailure(message:"Existing batch files were not skipped")}
        _=try SSH.call(server,["action":"files_chmod","path":target,"mode":"0600","confirmed":true]);let listing=try SSH.call(server,["action":"files_list","path":remote+"/Folder with space"]) as? [String:Any] ?? [:];guard (listing["entries"] as? [[String:Any]])?.contains(where:{$0["name"] as? String=="file.txt" && $0["mode"] as? String=="0600"})==true else{throw AppFailure(message:"Remote chmod failed")}
        _=try SSH.call(server,["action":"files_move","path":target,"destination":remote+"/moved file.txt","confirmed":true])
        let moved=try SSH.call(server,["action":"files_read","path":remote+"/moved file.txt"]) as? [String:Any] ?? [:];guard moved["content"] as? String=="original" else{throw AppFailure(message:"Remote move failed")}
        print("FOLDER UPLOAD, EXISTING FILE SKIP, CHMOD AND MOVE PASSED")
    }
    @MainActor static func reconnect(_ server:Server,docker:String) async throws {
        let model=Model();model.servers=[server];model.selectedID=server.id
        let stream=SSHStream();var phase="initial";var recovered=false;var hadError=false
        stream.start(model:model,request:["action":"stream","kind":"metrics","interval":2]){event in
            guard event["event"] as? String=="metrics" else{return}
            if phase=="initial"{phase="stopping";Task.detached{
                _=try? Runner.run(docker,["stop","-t","1","server-backup-stream-test"])
                await MainActor.run{phase="down"}
                try? await Task.sleep(for:.seconds(2))
                _=try? Runner.run(docker,["start","server-backup-stream-test"])
                await MainActor.run{phase="restarted"}
            }}else if phase=="restarted"{recovered=true;stream.stop()}
        }
        let deadline=Date().addingTimeInterval(50)
        while !recovered && Date()<deadline{try await Task.sleep(for:.milliseconds(100));if stream.error != nil{hadError=true}}
        stream.stop();guard recovered,hadError else{throw AppFailure(message:"Automatic SSH stream reconnection failed (phase=\(phase), state=\(stream.state), error=\(stream.error ?? "none"))")}
    }

}
