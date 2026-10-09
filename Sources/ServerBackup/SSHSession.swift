import Foundation
import CryptoKit
import Darwin

struct SSHFailure:LocalizedError{let message:String;var errorDescription:String?{message}}
struct SSHInvocation {let args:[String];let input:Data;let environment:[String:String]}
extension SSH {
    static func options(_ s:Server)->[String]{
        var args=["-p",String(s.port),"-o","ConnectTimeout=15","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=3","-o","StrictHostKeyChecking=yes","-o","UserKnownHostsFile=\""+Paths.known(s.id).path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\"","-o","NumberOfPasswordPrompts=1"]
        if !s.keyPath.isEmpty{args += ["-i",s.keyPath,"-o","IdentitiesOnly=yes"]};return args
    }
    static func environment(_ s:Server)->[String:String]{["SSH_ASKPASS":Paths.resourceRoot.appendingPathComponent("askpass.sh").path,"SSH_ASKPASS_REQUIRE":"force","DISPLAY":":0","SERVER_BACKUP_EXECUTABLE":CommandLine.arguments[0],"SERVER_BACKUP_SECRET_ID":s.id]}
    static func channelRefused(_ result:ProcessResult)->Bool {
        guard result.code==255 else{return false}
        return ["session request failed", "Session open refused by peer", "open failed: administratively prohibited"].contains{result.error.contains($0)}
    }
    static func connectionAvailable(_ server:Server)->Bool {
        guard FileManager.default.fileExists(atPath:Paths.known(server.id).path) else{return false}
        let args=options(server)+["-o","ControlMaster=no","-o","ControlPath=none","-o","BatchMode=no",server.user+"@"+server.host,"true"]
        return (try? Runner.run("/usr/bin/ssh",args,environment:environment(server)).code)==0
    }
    static func invocation(_ s:Server,_ request:[String:Any],independent:Bool=false)throws->SSHInvocation{
        try validate(s);guard FileManager.default.fileExists(atPath:Paths.known(s.id).path) else{throw SSHFailure(message:"Сначала подтвердите ключ SSH сервера")}
        let socket=independent ? "none":try SSHSessionPool.shared.ensure(s)
        let source=try String(contentsOf:Paths.resourceRoot.appendingPathComponent("helper.py"),encoding:.utf8)
        let code="import io,json,os,sys,base64,zlib; envelope=json.load(sys.stdin); src=envelope['source']; os.environ['SB_HELPER_SOURCE_ZLIB']=base64.b64encode(zlib.compress(src.encode())).decode(); sys.stdin=io.StringIO(json.dumps(envelope['request'])); exec(compile(src,'server-backup-helper','exec'))"
        let quote:(String)->String={"'"+$0.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        var script="python3 -u -c "+quote(code)
        if request["action"] as? String=="install"{script="if ! command -v python3 >/dev/null 2>&1; then apt-get update >&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >&2 || exit 1; fi; "+script}
        else if ["probe","overview"].contains(request["action"] as? String ?? ""){script="if ! command -v python3 >/dev/null 2>&1; then printf '%s\\n' '{\"ok\":true,\"result\":{\"installed\":false,\"tools\":{},\"python_missing\":true}}'; else "+script+"; fi"}
        let command=(s.useSudo ? "sudo -n ":"")+"/bin/sh -c "+quote(script)
        let args=options(s)+["-o","ControlMaster=no","-o","ControlPath="+socket,"-o",independent ? "BatchMode=no":"BatchMode=yes",s.user+"@"+s.host,command]
        return SSHInvocation(args:args,input:try JSONSerialization.data(withJSONObject:["source":source,"request":request]),environment:environment(s))
    }
}
final class SSHSessionPool:@unchecked Sendable {
    static let shared=SSHSessionPool()
    private let lock=NSLock()
    private var closed=false
    private var entries:[String:(Server,String,String)]=[:]
    private let directory:URL
    private init(){directory=URL(fileURLWithPath:"/private/tmp/sb-ssh-\(getuid())-\(UUID().uuidString.prefix(8))");try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    func ensure(_ server:Server)throws->String{
        lock.lock();defer{lock.unlock()};guard !closed else{throw SSHFailure(message:"SSH-сеансы закрыты")};try SSH.validate(server)
        if !FileManager.default.fileExists(atPath:directory.path){try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];var identity=try encoder.encode(server);identity.append(try Data(contentsOf:Paths.known(server.id)));identity.append(Vault.get("ssh-"+server.id) ?? Data())
        if !server.keyPath.isEmpty{identity.append(try Data(contentsOf:URL(fileURLWithPath:(server.keyPath as NSString).expandingTildeInPath)))}
        let stamp=SHA256.hash(data:identity).map{String(format:"%02x",$0)}.joined()
        if let (old,socket,oldStamp)=entries[server.id]{
            if oldStamp==stamp,try Runner.run("/usr/bin/ssh",["-S",socket,"-O","check",old.user+"@"+old.host]).code==0{return socket}
            close(old,socket);entries.removeValue(forKey:server.id)
        }
        let socket=directory.appendingPathComponent(String(stamp.prefix(20))).path
        let errorURL=directory.appendingPathComponent("connect-error");FileManager.default.createFile(atPath:errorURL.path,contents:Data(),attributes:[.posixPermissions:0o600])
        let errorFile=try FileHandle(forWritingTo:errorURL);defer{try? errorFile.close();try? FileManager.default.removeItem(at:errorURL)}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");process.arguments=SSH.options(server)+["-M","-N","-f","-S",socket,"-o","ControlPersist=600",server.user+"@"+server.host]
        process.environment=ProcessInfo.processInfo.environment.merging(SSH.environment(server)){_,new in new};process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=errorFile
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else{let detail=(try? String(contentsOf:errorURL,encoding:.utf8)) ?? "";throw SSHFailure(message:"SSH: проверьте доступ и ключ сервера. "+String(detail.prefix(1500)))}
        entries[server.id]=(server,socket,stamp);return socket
    }
    private func close(_ server:Server,_ socket:String){_=try? Runner.run("/usr/bin/ssh",["-S",socket,"-O","exit",server.user+"@"+server.host]);try? FileManager.default.removeItem(atPath:socket)}
    func closeAll(){lock.lock();defer{lock.unlock()};closed=true;for (_,entry) in entries{close(entry.0,entry.1)};entries.removeAll();try? FileManager.default.removeItem(at:directory)}
}
