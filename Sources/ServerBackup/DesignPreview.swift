import Foundation

extension Model {
    var isDesignPreview:Bool{CommandLine.arguments.contains("--design-preview") || ProcessInfo.processInfo.environment["SERVER_BACKUP_DESIGN_PREVIEW"]=="1"}
    func seedDesignServers(){connectionOnline=true;
        servers=[Server(id:"design-web",name:"Production",host:"web.example.com",group:"Рабочие"),Server(id:"design-db",name:"Staging",host:"db.example.com",group:"Тестовые"),Server(id:"design-dev",name:"Development",host:"dev.example.com")]
    }
    func designResponse(_ request:[String:Any])->Any? {
        switch request["action"] as? String ?? "" {
        case "error_center":return ["entries":[["id":"daily","job_id":"daily","name":"Сайты · ежедневно","category":"replication","title":"Дополнительная копия не создана","message":"S3: хранилище недоступно","hint":"Проверьте доступ к хранилищу и журнал копирования","time":"2026-10-09T03:00:00Z"],["category":"notification","title":"Ошибка уведомления · Почта","message":"SMTP-сервер не ответил","hint":"Проверьте SMTP и отправьте тестовое сообщение","time":"2026-10-09T03:00:00Z"]]]
        case "snapshot_file_history":return ["versions":[["snapshot":"demo-1","time":"2026-10-09T03:00:00Z","present":true,"node":["size":2048,"mtime":"2026-10-08T12:00:00Z"]],["snapshot":"demo-2","time":"2026-10-08T03:00:00Z","present":true,"node":["size":1800,"mtime":"2026-10-07T10:00:00Z"]]],"total":2]
        case "snapshot_content":return ["same":false,"snapshot_size":1800,"server_size":2048,"snapshot_sha256":"fixture-sha256-1","server_sha256":"fixture-sha256-2","diff":"--- Копия nginx.conf\n+++ Сервер nginx.conf\n@@ -1 +1 @@\n-worker_processes 2;\n+worker_processes auto;\n"]
        case "job_versions":return ["next_run":"10 окт. 2026 г., 03:00 UTC","versions":[["changed":"2026-10-09T02:00:00Z","before":["time":"04:00"],"after":["time":"03:00"]]]]
        case "health":return ["jobs":[["id":"daily","last_status":"success","last_success":"2026-10-08T03:00:00Z","stale":false]],"configured":true]
        case "calendar":return ["today":"2026-10-08","records":[["id":"daily","day":"2026-10-08","status":"success","maintenance_error":NSNull(),"finished":"2026-10-08T03:00:00Z","repository_id":"s3-backups","snapshot":"demo-snapshot"],["id":"daily","day":"2026-10-07","status":"incomplete","finished":"2026-10-07T03:00:00Z"],["id":"daily","day":"2026-10-06","status":"success","finished":"2026-10-06T03:00:00Z"]]]
        case "verification_results":return ["records":[["operation":"verify-restore","status":"success","repository_id":"s3-backups","snapshot":"demo-snapshot","finished":"2026-10-08T04:00:00Z","files":[["path":"/etc/nginx/nginx.conf"],["path":"/var/www/index.html"]]]]]
        case "capacity_status":return ["data":[:]]
        case "capacity_start":return ["operation_id":"demo-capacity"]
        case "capacity":return ["bytes":42000000000.0,"free":100000000000.0,"actual_size":false,"samples":[["time":"2026-10-01T03:00:00Z","bytes":30000000000.0],["time":"2026-10-04T03:00:00Z","bytes":36000000000.0],["time":"2026-10-08T03:00:00Z","bytes":42000000000.0]],"forecast":["bytes_per_day":1700000000.0,"days_remaining":58.8,"reason":"При текущем чистом росте"]]
        case "external_status":return ["timer":["ActiveState":"active"],"settings":["enabled":true,"targets":[["id":"design-db"]]],"states":[["id":"design-db","name":"Staging","issue":"Требует внимания задание daily","updated":"2026-10-08T22:00:00Z"]]]
        case "config_versions":return ["versions":[["id":"demo-version","time":"2026-10-07T10:00:00Z","exists":true]]]
        case "config_version":return ["content":"worker_processes 2;\nevents { worker_connections 512; }\n"]
        case "overview", "probe":return Self.designWorkspace
        case "metrics":return ["physical_disks":[["name":"vda","total_bytes":107374182400,"used_bytes":34359738368,"free_bytes":73014444032,"used_percent":32.0,"mounted":true,"mounts":[["target":"/","source":"/dev/vda1","used_bytes":34359738368,"free_bytes":73014444032]]],["name":"vdb","total_bytes":214748364800,"used_bytes":111669149696,"free_bytes":103079215104,"used_percent":52.0,"mounted":true,"mounts":[["target":"/mnt/data","source":"/dev/vdb1","used_bytes":111669149696,"free_bytes":103079215104]]]],"cores":8,"disk_count":2,"uptime_seconds":4406400,"cpu_percent":24.5,"memory":["MemTotal":8589934592.0,"MemAvailable":5368709120.0,"SwapTotal":2147483648.0,"SwapFree":2147483648.0],"load":[0.42,0.68,0.54],"network":["eth0":["rx_per_second":1250000.0,"tx_per_second":450000.0]],"disk_io":["vda":["read_per_second":3200000.0,"write_per_second":1500000.0]],"disks":[["target":"/","avail":"86 GiB","used_percent":32.0],["target":"/mnt/data","avail":"240 GiB","used_percent":52.0]],"process_rows":[["pid":124,"name":"nginx","user":"www-data","cpu_percent":12.4,"memory_percent":0.5,"memory_bytes":42949672],["pid":416,"name":"postgres","user":"postgres","cpu_percent":8.1,"memory_percent":12.0,"memory_bytes":1030792151],["pid":718,"name":"restic","user":"root","cpu_percent":24.0,"memory_percent":4.0,"memory_bytes":343597383]],"processes":["PID COMM             %CPU %MEM","124 nginx             2.4  0.5"],"docker":[["Name":"website-app","CPUPerc":"4.2%"]]]
        case "log_files":return ["files":[["path":"/var/log/nginx/error.log","size":2048],["path":"/var/log/syslog","size":4096]],"issues":[]]
        case "server_log":return ["text":"Oct 08 22:30:01 web systemd: Started daily maintenance.\nOct 08 22:30:02 web nginx: Configuration test successful.","updated":"2026-10-08T22:30:02Z","truncated":false]
        case "command":
            if request["command"] as? String=="ls"{let nodes:[[String:Any]]=[["path":"/etc","type":"dir"],["path":"/etc/nginx","type":"dir"],["path":"/etc/nginx/nginx.conf","type":"file","size":2048],["path":"/var","type":"dir"],["path":"/var/www","type":"dir"],["path":"/var/www/index.html","type":"file","size":4096]];return ["exit_code":0,"output":nodes.map{String(data:try! JSONSerialization.data(withJSONObject:$0),encoding:.utf8)!}.joined(separator:"\n")]}
            if request["command"] as? String=="snapshots"{let copies:[[String:Any]]=[["id":"demo-snapshot-08","short_id":"a8b93d21","time":"2026-10-08T03:00:00Z","hostname":"Production","paths":["/etc","/var/www","/srv"]],["id":"demo-snapshot-07","short_id":"d73c5f02","time":"2026-10-07T03:00:00Z","hostname":"Production","paths":["/etc","/var/www","/srv"]]];return ["output":String(data:try! JSONSerialization.data(withJSONObject:copies),encoding:.utf8)!]};return nil
        case "external_test":return ["operation_id":"demo-external"]
        case "snapshot_files":
            let nodes:[[String:Any]]=[["path":"/etc","type":"dir"],["path":"/etc/nginx","type":"dir"],["path":"/etc/nginx/nginx.conf","type":"file","size":2048,"mode":420,"uid":0,"gid":0,"mtime":"2026-10-08T03:00:00Z"],["path":"/var","type":"dir"],["path":"/var/www","type":"dir"],["path":"/var/www/index.html","type":"file","size":4096,"mode":420,"uid":33,"gid":33,"mtime":"2026-10-07T10:00:00Z"]]
            let path=request["path"] as? String ?? "/",query=request["query"] as? String ?? ""
            let matches=nodes.filter{node in let name=node["path"] as? String ?? "";return query.isEmpty ? URL(fileURLWithPath:name).deletingLastPathComponent().path==path:name.localizedCaseInsensitiveContains(query) && (path=="/" || name.hasPrefix(path+"/"))}
            return ["entries":matches,"total":matches.count,"summary":["total_size":6144,"total_file_count":2]]
        case "state":
            if request["id"] as? String=="demo-capacity"{return ["status":"success","output":Model.pretty(designResponse(["action":"capacity"]) ?? [:])]}

            if request["id"] as? String=="demo-external"{return ["id":"demo-external","operation":"external-test","status":"success","output":"{\"servers\":[{\"name\":\"Staging\",\"updated\":\"2026-10-09T03:00:00Z\",\"issue\":\"Требует внимания задание daily\"}]}"]}
            return ["id":"demo-operation","operation":"backup","status":"running","stages":[["id":"prepare","title":"Подготовка задания","status":"done"],["id":"databases","title":"Дампы баз данных","status":"done"],["id":"backup","title":"Копирование файлов","status":"running","detail":"Restic сканирует источники и передаёт изменения"]],"progress":["percent_done":0.42,"bytes_done":420000000,"total_bytes":1000000000,"files_done":840,"total_files":2000,"current_files":["/var/www/uploads/photo.jpg"]]]
        case "logs":return ["records":[["id":"demo-daily","operation":"backup","status":"success","finished":"2026-10-08T03:10:00Z","summary":["data_added_packed":1048576,"total_duration":12.5]]],"journal":"Демонстрационный журнал Server Backup","notification_errors":[]]
        case "files_list":return ["path":request["path"] ?? "/","entries":[["name":"etc","path":"/etc","directory":true,"size":4096,"mode":"0755","modified":"2026-10-09T00:00:00Z"],["name":"example.conf","path":"/example.conf","directory":false,"size":42,"mode":"0644","modified":"2026-10-09T00:00:00Z"]],"has_more":false]
        case "files_read":return ["path":request["path"] ?? "","content":"# Демонстрационная конфигурация\nport=8080\n","hash":"demo","mode":"0644"]
        case "programs":return ["packages":[["name":"nginx","version":"1.24.0","architecture":"amd64","category":"manual"],["name":"postgresql-16","version":"16.4","architecture":"amd64","category":"manual"],["name":"php8.3-fpm","version":"8.3.6","architecture":"amd64","category":"manual"],["name":"bash","version":"5.2","architecture":"amd64","category":"system"]],"services":[["unit":"nginx.service","active":"active","enabled":"enabled","description":"Nginx web server","manageable":true],["unit":"postgresql@16-main.service","active":"active","enabled":"enabled","description":"PostgreSQL Cluster 16-main","manageable":true],["unit":"php8.3-fpm.service","active":"active","enabled":"enabled","description":"PHP FastCGI Process Manager","manageable":true]],"package_error":"","service_error":""]
        case "program_config":if request["path"] != nil{return ["content":"worker_processes auto;\n\nevents {\n    worker_connections 1024;\n}\n\nhttp {\n    include /etc/nginx/mime.types;\n    include /etc/nginx/conf.d/*.conf;\n}\n","hash":"design-hash","syntax_check":true]};return ["files":[["path":"/etc/nginx/nginx.conf","exists":true]],"syntax_check":true]
        case "package_search":return ["packages":[["name":"nginx","description":"HTTP and reverse proxy server"]]]
        case "package_plan":return ["name":"nginx","output":"Будет установлен nginx и зависимости (демонстрация)","plan_hash":String(repeating:"a",count:64)]
        case "program_journal":return ["output":"nginx.service: active (running) · demonstration"]
        case "cron_read":return ["content":"# Задачи сервера\nMAILTO=\"\"\n0 4 * * * /usr/local/bin/cleanup-logs\n","hash":"demo"]
        case "cron_save":return ["saved":true]
        case "snapshot_compare":return ["entries":[["name":"nginx.conf","path":"/etc/nginx.conf","target":"/etc/nginx.conf","status":"changed","reason":"Время изменения","folder":false],["name":"website.conf","path":"/etc/website.conf","target":"/etc/website.conf","status":"missing","folder":false],["name":"hosts","path":"/etc/hosts","target":"/etc/hosts","status":"same_metadata","folder":false]],"total":3,"counts":["changed":1,"missing":1,"same_metadata":1]]
        case "cron":return ["entries":[["kind":"user","schedule":"0 4 * * *","user":"root","source":"crontab · root","line":3,"command":"/usr/local/bin/cleanup-logs","valid":true],["kind":"system","schedule":"*/15 * * * *","user":"www-data","source":"/etc/cron.d/website","line":1,"command":"/usr/bin/php /var/www/artisan schedule:run","valid":true],["kind":"periodic","schedule":"cron.daily","user":"root","source":"/etc/cron.daily","command":"/etc/cron.daily/logrotate","enabled":true,"valid":true]],"issues":[],"timer_error":"","timers":"NEXT                        UNIT                              ACTIVATES\n2026-10-09 03:00:00 UTC      server-backup-job-daily.timer      server-backup-job-daily.service\n","updated":"2026-10-08T22:00:00Z"]
        case "browse":
            let path=request["path"] as? String ?? "/"
            let names=path=="/" ? ["bin","boot","dev","etc","home","lib","mnt","opt","proc","root","run","srv","sys","tmp","usr","var"] : path=="/var" ? ["backups","cache","lib","log","www"] : ["config","data","logs","uploads"]
            return names.map{["name":$0,"path":(path=="/" ? "":path)+"/"+$0,"directory":true] as [String:Any]}
        case "docker":return Self.designContainers
        default:return nil
        }
    }
    static var designContainers:[[String:Any]]{[
        ["name":"website-app","image":"nginx:alpine","running":true,"labels":["com.docker.compose.project":"website","com.docker.compose.project.config_files":"/srv/website/compose.yaml"],"mounts":[["Type":"bind","Source":"/var/www","Destination":"/usr/share/nginx/html"]]],
        ["name":"website-db","image":"postgres:16","database":"postgres","running":true,"labels":["com.docker.compose.project":"website"],"mounts":[["Type":"volume","Name":"website-data","Source":"/var/lib/docker/volumes/website-data/_data","Destination":"/var/lib/postgresql/data"]]]
    ]}
    static var designWorkspace:[String:Any]{[
        "os":["PRETTY_NAME":"Ubuntu 24.04 LTS"],"architecture":"x86_64","timezone":"UTC","root":true,"installed":true,
        "tools":["restic":"restic 0.16.4","docker":"Docker 27","systemctl":"systemd 255"],
        "disks":[["target":"/","uuid":"demo-root","avail":"86 GiB"],["target":"/mnt/data","uuid":"demo-data","avail":"240 GiB"]],
        "repositories":[["id":"s3-backups","type":"s3","repository":"s3:https://s3.example.com/backups/production"]],
        "jobs":[["id":"daily","repository_id":"s3-backups","sources":["/etc","/var/www","/srv"],"excludes":["*.tmp"],"time":"03:00","daily":14,"weekly":4,"enabled":true,"database_ids":["website-db"],"containers":[]]],
        "databases":[["id":"website-db","engine":"postgres","host":"localhost","container":"website-db"]],
        "states":[],"history":[]
    ]}
}
