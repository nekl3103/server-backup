import Foundation

@MainActor enum StorageDrafts {
    private static var previews:[String:[String:Any]]=[:]
    static func read(serverID:String,preview:Bool)->[String:Any]{
        guard !serverID.isEmpty else{return [:]}
        return preview ? previews[serverID] ?? [:]:Vault.dictionary("storage-draft-"+serverID)
    }
    static func save(_ value:[String:Any],serverID:String,preview:Bool)throws{
        guard !serverID.isEmpty else{return}
        if preview{previews[serverID]=value}else{try Vault.put("storage-draft-"+serverID,value)}
    }
}
