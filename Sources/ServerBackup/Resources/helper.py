#!/usr/bin/env python3
"""Server Backup protocol v1. JSON stdin; structured JSON stdout. No external modules."""
import smtplib, ssl, stat, pwd, zlib, selectors, codecs
from email.message import EmailMessage
from email.utils import parseaddr
import argparse, base64, contextlib, datetime, fcntl, fnmatch, hashlib, json, os, pathlib, re, shlex, shutil, signal, subprocess, sys, tempfile, time, urllib.request, uuid
VERSION = "1.9.1"
ROOT = pathlib.Path(os.environ.get("SERVER_BACKUP_ROOT", "/var/lib/server-backup"))
HELPER = "/usr/local/lib/server-backup/helper.py"
UNITDIR = pathlib.Path(os.environ.get("SERVER_BACKUP_UNITDIR", "/etc/systemd/system"))
MUTATING = {"init", "backup", "restore", "forget", "prune", "copy", "key", "unlock", "repair", "migrate", "tag", "recover", "self-update", "cache"}

def helper_source():
    compressed=os.environ.get("SB_HELPER_SOURCE_ZLIB")
    return zlib.decompress(base64.b64decode(compressed)).decode() if compressed else os.environ.get("SB_HELPER_SOURCE")

def within(path, parent):
    return os.path.commonpath([str(path.resolve()), str(parent.resolve())]) == str(parent.resolve())

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def run(argv, *, env=None, data=None, check=True, timeout=120):
    p = subprocess.run(argv, input=data, text=True, capture_output=True, env=env, timeout=timeout)
    if check and p.returncode: raise RuntimeError("Команда завершилась с кодом %s: %s" % (p.returncode, p.stderr[-3000:]))
    return p

def write(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent)); os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f: json.dump(value, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

def read(path, default=None):
    try: return json.loads(pathlib.Path(path).read_text())
    except FileNotFoundError: return default

def ident(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", value): raise ValueError("Недопустимый идентификатор")
    return value

def config(kind, key):
    result = read(ROOT / kind / (ident(key) + ".json"))
    if result is None: raise ValueError("Настройка не найдена: " + key)
    return result

def require_admin():
    if os.geteuid() != 0 and not os.environ.get("SERVER_BACKUP_ROOT"): raise RuntimeError("Нужен root или sudo без пароля")

def redacted(value):
    if isinstance(value, dict): return {k: ("••••••" if k.lower() in {"password", "secret", "token", "access_key", "secret_key", "key_passphrase"} and v else redacted(v)) for k, v in value.items()}
    if isinstance(value, list): return [redacted(x) for x in value]
    return value

def tool_version(tool):
    if not shutil.which(tool): return None
    p = run([tool, "--version"], check=False)
    return (p.stdout or p.stderr).splitlines()[0] if (p.stdout or p.stderr) else tool

def restic_backup_supports(flag):
    if not shutil.which("restic"): return False
    p=run(["restic","backup","--help"],check=False)
    return p.returncode==0 and re.search(r"(?<![\w-])"+re.escape(flag)+r"(?=[\s=,]|$)",p.stdout) is not None

def require_dry_run():
    if not restic_backup_supports("--dry-run"):
        raise ValueError("Установленный Restic не поддерживает пробный запуск --dry-run. Нажмите «Обновить Restic» в задании. Копирование не запускалось")


def probe():
    osrelease = {}
    try:
        for line in pathlib.Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1); osrelease[k] = v.strip('"')
    except FileNotFoundError: pass
    commands = []
    if shutil.which("restic"):
        commands = re.findall(r"^  ([a-z][a-z-]*)\s{2,}", run(["restic", "help"], check=False).stdout, re.M)
    return {"version": VERSION, "installed": pathlib.Path(HELPER).exists(), "os": osrelease, "architecture": os.uname().machine, "root": os.geteuid() == 0, "timezone": run(["date", "+%Z"], check=False).stdout.strip(), "tools": {t: tool_version(t) for t in ["restic", "rclone", "systemctl", "docker", "mysqldump", "mariadb-dump", "pg_dump", "pg_dumpall", "mysql", "mariadb", "psql", "pg_basebackup", "mysqlbinlog", "mariadb-binlog"]}, "restic_commands": commands, "restic_dry_run":restic_backup_supports("--dry-run"), "restic_read_concurrency":restic_backup_supports("--read-concurrency"), "disks": disks()}

def disks():
    if not shutil.which("findmnt"): return []
    p = run(["findmnt", "--json", "--list", "-o", "TARGET,SOURCE,FSTYPE,UUID,SIZE,AVAIL"], check=False)
    try: return json.loads(p.stdout).get("filesystems", [])
    except ValueError: return []

def list_dir(path):
    p = pathlib.Path(path)
    if not p.is_absolute(): raise ValueError("Нужен абсолютный путь")
    result = []
    with os.scandir(p) as entries:
        for e in entries:
            result.append({"name": e.name, "path": e.path, "directory": e.is_dir(follow_symlinks=False), "symlink": e.is_symlink()})
    return sorted(result, key=lambda e: (not e["directory"], e["name"]))

def docker():
    if not shutil.which("docker"): return []
    ids = run(["docker", "ps", "-aq"]).stdout.split()
    if not ids: return []
    items = json.loads(run(["docker", "inspect"] + ids).stdout)
    return [{"id": x["Id"], "name": x["Name"].lstrip("/"), "image": x["Config"]["Image"], "running": x["State"]["Running"], "mounts": x.get("Mounts", []), "labels": x["Config"].get("Labels") or {}, "database": next((d for d in ["postgres", "mariadb", "mysql"] if d in x["Config"]["Image"].lower()), None)} for x in items]

def yandex_repository(repo):
    ident(repo["id"])
    if not isinstance(repo.get("path"),str) or not isinstance(repo.get("token"),str): raise ValueError("Укажите папку и OAuth-токен строкой")
    path=repo.get("path", "").strip().strip("/")
    if not path or any(part in (".","..") for part in path.split("/")) or any(ord(c)<32 for c in path) or len(path)>1024: raise ValueError("Укажите отдельную папку на Яндекс Диске без . и ..")
    raw=repo.get("token", "").strip()
    try: token=json.loads(raw)
    except (ValueError,TypeError):
        raise ValueError("Нужен полный JSON-токен с refresh_token. Нажмите «Войти в Яндекс через браузер» или вставьте весь JSON из rclone authorize yandex; одного access_token недостаточно")
    if not isinstance(token,dict): raise ValueError("Нужен JSON OAuth-токена Яндекс Диска")
    for field in ("access_token","refresh_token"):
        value=token.get(field)
        if not isinstance(value,str) or not value or len(value)>4096 or any(ord(c)<33 or ord(c)>126 for c in value):
            raise ValueError("В токене отсутствует или неверен "+field+". Повторите вход в Яндекс через браузер и используйте полный JSON")
    normalized={"access_token":token["access_token"],"refresh_token":token["refresh_token"],"token_type":"OAuth"}
    if token.get("expiry") is not None:
        expiry=token["expiry"]
        if not isinstance(expiry,str) or len(expiry)>128: raise ValueError("Неверная дата expiry в OAuth-токене")
        try: datetime.datetime.fromisoformat(expiry.replace("Z","+00:00"))
        except ValueError: raise ValueError("Неверная дата expiry в OAuth-токене")
        normalized["expiry"]=expiry
    token=json.dumps(normalized,separators=(",",":"))
    alias="sby"+hashlib.sha256((repo["id"]+":"+path).encode()).hexdigest()[:24]
    return path,token,alias

def yandex_environment(repo):
    if not shutil.which("rclone"): raise ValueError("Для Яндекс Диска установите rclone кнопкой в настройках хранилища")
    path,token,alias=yandex_repository(repo)
    key="RCLONE_CONFIG_"+alias.upper()+"_"
    return {"RESTIC_REPOSITORY":"rclone:"+alias+":"+path,"RCLONE_CONFIG":"/dev/null",key+"TYPE":"yandex",key+"TOKEN":token,key+"UPLOAD_WAIT":"2s"}

def yandex_check(repo):
    env=os.environ.copy();env.update(yandex_environment(repo));_,_,alias=yandex_repository(repo)
    try: p=run(["rclone","about",alias+":","--json"],env=env,check=False,timeout=90)
    except subprocess.TimeoutExpired: raise RuntimeError("Яндекс Диск не ответил за 90 секунд. Проверьте доступ сервера к cloud-api.yandex.com и oauth.yandex.com")
    if p.returncode:
        detail=(p.stderr or "").lower()
        if "refreshtoken" in detail or "refresh_token" in detail:
            message="rclone не смог обновить OAuth-токен. Повторите вход в Яндекс через браузер и сохраните полный JSON с refresh_token"
        elif any(x in detail for x in ("401","unauthorized","invalid_grant","invalid token")):
            message="Яндекс отклонил OAuth-токен. Повторите вход в Яндекс через браузер"
        elif "403" in detail or "forbidden" in detail:
            message="Яндекс запретил доступ. Проверьте права приложения на чтение и запись Диска"
        elif any(x in detail for x in ("timeout","connection refused","no such host","network is unreachable","dial tcp","certificate")):
            message="Сервер не может подключиться к API Яндекс Диска. Проверьте DNS, сеть и HTTPS-доступ к cloud-api.yandex.com и oauth.yandex.com"
        else: message="Проверка Яндекс Диска завершилась с кодом "+str(p.returncode)+". Повторите вход через браузер; если ошибка сохраняется, проверьте сеть сервера и rclone"
        raise RuntimeError(message)
    return {"accessible":True,"quota":json.loads(p.stdout)}

def install_rclone():
    require_admin()
    if probe()["os"].get("ID") not in ("ubuntu","debian"): raise ValueError("Поддерживаются Ubuntu и Debian")
    if not shutil.which("rclone"):
        install_backup_packages(["rclone"])
    src=helper_source()
    if not src: raise RuntimeError("Отсутствует исходный код помощника")
    target=pathlib.Path(HELPER);target.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=target.parent)
    try:
        os.fchmod(fd,0o700)
        with os.fdopen(fd,"w") as stream: stream.write(src)
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    return {"installed":True,"version":tool_version("rclone"),"helper_version":VERSION}

@contextlib.contextmanager
def repository_env(repo):
    if repo["type"] == "disk":
        mount = repo.get("mount")
        if not mount or not repo.get("uuid"): raise ValueError("Для диска укажите точку подключения и UUID")
        run(["mountpoint", "-q", mount])
        actual = run(["findmnt", "-n", "-o", "UUID", "--target", mount]).stdout.strip()
        if actual != repo["uuid"]: raise RuntimeError("UUID подключённого диска отличается")
        target = pathlib.Path(repo["repository"])
        if not target.is_absolute() or not within(target, pathlib.Path(mount)): raise ValueError("Репозиторий должен находиться на выбранном диске")
    env = os.environ.copy()
    env.pop("RESTIC_PASSWORD", None); env.pop("RESTIC_PASSWORD_COMMAND", None)
    env.update(RESTIC_REPOSITORY=repo["repository"], RESTIC_CACHE_DIR=str(ROOT / "cache"))
    with tempfile.TemporaryDirectory(prefix="server-backup-") as tmp:
        pw = pathlib.Path(tmp) / "password"; pw.write_text(repo["password"]); pw.chmod(0o600)
        env["RESTIC_PASSWORD_FILE"] = str(pw)
        if repo["type"] == "yandex": env.update(yandex_environment(repo))
        if repo["type"] == "s3":
            env.update(AWS_ACCESS_KEY_ID=repo["access_key"], AWS_SECRET_ACCESS_KEY=repo["secret_key"], AWS_DEFAULT_REGION=repo.get("region", "us-east-1"))
        if repo["type"] == "sftp":
            alias = "sb-" + ident(repo["id"])
            key = ROOT / "sftp" / (alias + ".key")
            known = ROOT / "sftp" / (alias + ".known_hosts")
            if not key.exists() or not known.exists(): raise ValueError("Настройте SSH-ключ и подтвердите ключ сервера хранения")
            cfg = pathlib.Path(tmp) / "ssh-config"
            host = repo["host"]
            if not re.fullmatch(r"[A-Za-z0-9.:-]+", host): raise ValueError("Недопустимый адрес SFTP")
            user = repo["user"]
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", user): raise ValueError("Недопустимый пользователь SFTP")
            cfg.write_text(f"Host {alias}\n HostName {host}\n User {user}\n Port {int(repo.get('port', 22))}\n IdentityFile {key}\n UserKnownHostsFile {known}\n StrictHostKeyChecking yes\n BatchMode yes\n IdentitiesOnly yes\n ServerAliveInterval 60\n")
            env["RESTIC_REPOSITORY"] = "sftp:" + alias + ":" + repo["path"]
            env["SB_SFTP_CONFIG"] = str(cfg)
        yield env

def restic_args(env):
    args = ["restic"]
    if env.get("SB_SFTP_CONFIG"): args += ["-o", "sftp.args=" + shlex.join(["-F", env["SB_SFTP_CONFIG"]])]
    return args

@contextlib.contextmanager
def repo_lock(repo):
    lockid = hashlib.sha256(repo["repository"].encode()).hexdigest()
    folder = ROOT / "locks"; folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(folder / lockid, "w") as f:
        try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError("Репозиторий занят другой операцией")
        yield

def restic(repo, args, timeout=120):
    with repository_env(repo) as env:
        env["SB_REPO_ID"] = repo["id"]
        return run(restic_args(env) + args, env=env, check=False, timeout=timeout)

def inspect_repo(repo):
    p = restic(repo, ["cat", "config"])
    if p.returncode: raise RuntimeError("Проверка репозитория не пройдена: " + p.stderr[-1500:])
    return json.loads(p.stdout)

def official_apt_sources(info,architecture):
    distro=info.get('ID');suite=info.get('VERSION_CODENAME') or info.get('UBUNTU_CODENAME','')
    if distro not in ('ubuntu','debian') or not re.fullmatch(r'[a-z][a-z0-9-]*',suite):raise ValueError('Не удалось определить поддерживаемый выпуск Ubuntu/Debian')
    key='/usr/share/keyrings/'+('ubuntu-archive-keyring.gpg' if distro=='ubuntu' else 'debian-archive-keyring.gpg')
    if not pathlib.Path(key).is_file():raise ValueError('Отсутствует штатный ключ подписи '+distro+'; восстановите пакет ключей ОС перед установкой')
    if distro=='ubuntu':
        archive='https://archive.ubuntu.com/ubuntu' if architecture in ('amd64','i386') else 'https://ports.ubuntu.com/ubuntu-ports'
        security='https://security.ubuntu.com/ubuntu' if architecture in ('amd64','i386') else archive
        entries=[(archive,suite),(archive,suite+'-updates'),(security,suite+'-security')];components='main universe'
    else:entries=[('https://deb.debian.org/debian',suite),('https://deb.debian.org/debian',suite+'-updates'),('https://deb.debian.org/debian-security',suite+'-security')];components='main'
    return ''.join('deb [signed-by='+key+'] '+url+' '+release+' '+components+'\n' for url,release in entries)

def install_backup_packages(packages,info=None):
    require_admin()
    info=info or probe()['os'];architecture=run(['dpkg','--print-architecture']).stdout.strip()
    sources=official_apt_sources(info,architecture)
    # Separate lists and sources: never edit administrator repositories or their trust keys.
    with tempfile.TemporaryDirectory(prefix='sb-apt-',dir='/var/tmp') as tmp:
        folder=pathlib.Path(tmp);folder.chmod(0o755);source=folder/'sources.list';source.write_text(sources);source.chmod(0o644)
        lists=folder/'lists';lists.mkdir(mode=0o755)
        options=['-o','Dir::Etc::sourcelist='+str(source),'-o','Dir::Etc::sourceparts=-','-o','Dir::State::lists='+str(lists),'-o','APT::Update::Error-Mode=any','-o','Acquire::AllowInsecureRepositories=false','-o','APT::Get::AllowUnauthenticated=false','-o','DPkg::Lock::Timeout=120']
        env={**os.environ,'DEBIAN_FRONTEND':'noninteractive'}
        try:
            run(['apt-get']+options+['update'],env=env,timeout=900)
            run(['apt-get']+options+['install','-y','--no-remove','--no-upgrade','-o','Dpkg::Options::=--force-confold','--']+packages,env=env,timeout=900)
        except RuntimeError as e:raise RuntimeError('Установка через подписанные репозитории ОС не выполнена. Сторонние источники и ключи не изменялись. '+str(e)) from e

def install():
    require_admin()
    info = probe()
    if info["os"].get("ID") not in ["ubuntu", "debian"]: raise RuntimeError("Поддерживаются Ubuntu и Debian")
    install_backup_packages(["restic", "python3", "openssh-client", "util-linux", "ca-certificates"],info['os'])
    # source is embedded at invocation; install exactly the same helper.
    src = helper_source()
    if not src: raise RuntimeError("Отсутствует исходный код помощника")
    target = pathlib.Path(HELPER); target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(src); target.chmod(0o700)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    unit("server-backup-watchdog", "[Unit]\nDescription=Server Backup watchdog\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 " + HELPER + " --watchdog\n")
    unit("server-backup-watchdog", "[Unit]\nDescription=Server Backup watchdog timer\n[Timer]\nOnBootSec=5m\nOnUnitActiveSec=1h\n[Install]\nWantedBy=timers.target\n", "timer")
    unit("server-backup-recover", "[Unit]\nDescription=Recover containers stopped by Server Backup\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 " + HELPER + " --recover\n[Install]\nWantedBy=multi-user.target\n")
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "--now", "server-backup-watchdog.timer", "server-backup-recover.service"])
    return probe()

def unit(name, content, suffix="service"):
    UNITDIR.mkdir(parents=True, exist_ok=True)
    path = UNITDIR / (name + "." + suffix)
    path.write_text(content); path.chmod(0o644)

def validate_job(j):
    ident(j["id"]); ident(j["repository_id"])
    if not j.get("sources"): raise ValueError("Выберите хотя бы один источник")
    if any(not isinstance(p, str) or not p.startswith("/") or "\x00" in p for p in j["sources"]): raise ValueError("Источники должны быть абсолютными путями")
    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", j.get("time", "03:00")): raise ValueError("Время должно иметь формат HH:MM")
    for key in ["daily", "weekly", "limit_upload", "read_concurrency"]:
        if int(j.get(key, 0)) < 0: raise ValueError("Отрицательное значение " + key)
    if int(j.get("daily", 14)) + int(j.get("weekly", 4)) == 0: raise ValueError("Нельзя удалить все точки восстановления")

def save_job(j):
    require_admin(); validate_job(j); config("repositories", j["repository_id"])
    if helper_source():install_helper_source()
    for extra in j.get("replica_ids",[]):
        ident(extra);config("repositories",extra)
        if extra==j["repository_id"]:raise ValueError("Дополнительное хранилище совпадает с основным")
    if not isinstance(j.get("name",j["id"]),str) or len(j.get("name",j["id"]))>160:raise ValueError("Название задания должно быть короче 160 символов")
    name = "server-backup-job-" + j["id"]
    previous = read(ROOT / "jobs" / (j["id"] + ".json"), {})
    j["created"] = previous.get("created", j.get("created", now()))
    write(ROOT/"job-versions"/j["id"]/(str(time.time_ns())+".json"),{"changed":now(),"before":previous,"after":j})
    write(ROOT / "jobs" / (j["id"] + ".json"), j)
    unit(name, f"[Unit]\nDescription=Server Backup job\nWants=network-online.target\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 {HELPER} --job {j['id']}\nExecStopPost=/usr/bin/python3 {HELPER} --recover --job-id {j['id']}\nTimeoutStartSec=infinity\nTimeoutStopSec=120\nNice=10\n")
    unit(name, f"[Unit]\nDescription=Server Backup schedule\n[Timer]\nOnCalendar=*-*-* {j.get('time', '03:00')}:00\nPersistent=true\nRandomizedDelaySec=10m\n[Install]\nWantedBy=timers.target\n", "timer")
    run(["systemctl", "daemon-reload"])
    if j.get("enabled", True): run(["systemctl", "enable", "--now", name + ".timer"])
    else: run(["systemctl", "disable", "--now", name + ".timer"])
    return {"saved": j["id"]}

def telegram_notify(message):
    c = read(ROOT / "telegram.json", {})
    if not c.get("enabled", bool(c.get("token"))) or not c.get("token") or not c.get("chat_id"): return {"sent": False, "reason": "Не настроено"}
    try:
        req = urllib.request.Request("https://api.telegram.org/bot" + c["token"] + "/sendMessage", data=json.dumps({"chat_id": c["chat_id"], "text": message}).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as response:
            result = json.load(response)
        if not result.get("ok"): raise RuntimeError("Telegram отклонил сообщение")
        return {"sent": True}
    except Exception:
        # Deliberately omit URL/exceptions: Telegram URL contains the token.
        write(ROOT / "notification-error.json", {"time": now(), "error": "Не удалось отправить уведомление Telegram"})
        return {"sent": False, "reason": "Ошибка отправки; подробности скрыты для защиты токена"}

def validate_email(c):
    if not c.get("enabled"): return
    if not c.get("host") or any(x in c["host"] for x in "\r\n /\t"): raise ValueError("Укажите SMTP-сервер")
    if not 1 <= int(c.get("port", 587)) <= 65535: raise ValueError("Неверный SMTP-порт")
    if c.get("tls", "starttls") not in ["starttls", "ssl"]: raise ValueError("Требуется защищённое SMTP-подключение")
    addresses = [c.get("sender", "")] + [x.strip() for x in c.get("recipients", "").split(",")]
    if len(addresses) < 2: raise ValueError("Укажите отправителя и получателя")
    for address in addresses:
        parsed = parseaddr(address)[1]
        if not parsed or "@" not in parsed or any(x in address for x in "\r\n"): raise ValueError("Неверный адрес электронной почты")

def email_notify(message):
    c = read(ROOT / "email.json", {})
    if not c.get("enabled", False): return {"sent": False, "reason": "Выключено"}
    try:
        validate_email(c)
        mail = EmailMessage(); mail["Subject"] = "Server Backup · " + os.uname().nodename
        mail["From"] = c["sender"]; mail["To"] = c["recipients"]; mail.set_content(message)
        context = ssl.create_default_context()
        factory = smtplib.SMTP_SSL if c.get("tls") == "ssl" else smtplib.SMTP
        options = {"timeout": 15}
        if c.get("tls") == "ssl": options["context"] = context
        with factory(c["host"], int(c.get("port", 587)), **options) as smtp:
            if c.get("tls") != "ssl": smtp.ehlo(); smtp.starttls(context=context); smtp.ehlo()
            if c.get("username"): smtp.login(c["username"], c.get("password", ""))
            refused = smtp.send_message(mail, to_addrs=[parseaddr(x.strip())[1] for x in c["recipients"].split(",")])
            if refused: raise RuntimeError("Часть получателей отклонена")
        return {"sent": True}
    except Exception:
        write(ROOT / "email-error.json", {"time": now(), "error": "Не удалось отправить почтовое уведомление. Проверьте SMTP, доступы и адреса."})
        return {"sent": False, "reason": "Ошибка отправки почты; доступы скрыты"}

def notify(message, success_only=False):
    channels = {}
    for name, sender in [("telegram", telegram_notify), ("email", email_notify)]:
        c = read(ROOT / (name + ".json"), {})
        if c.get("enabled", bool(c.get("token")) if name == "telegram" else False) and (not success_only or c.get("success")):
            channels[name] = sender(message)
    return {"sent": any(x.get("sent") for x in channels.values()), "channels": channels}

def logs(r):
    require_admin()
    records = [redacted(read(p)) for p in sorted((ROOT / "history").glob("*.json"), key=lambda p:p.stat().st_mtime, reverse=True)[:200]]
    selected = r.get("id")
    if selected:
        selected = ident(selected)
        unitname = "server-backup-" + selected if selected.startswith("op-") else "server-backup-job-" + selected
        records = [x for x in records if x.get("id") == selected]
    else: unitname = "server-backup-*"
    text = ""
    if shutil.which("journalctl"):
        p = run(["journalctl", "--no-pager", "-o", "short-iso", "-n", "500", "-u", unitname], check=False)
        text = p.stdout if p.returncode == 0 else "Журнал systemd недоступен: " + p.stderr[-1000:]
    else: text = "journalctl не установлен"
    errors = [read(ROOT / name, {}) for name in ["notification-error.json", "email-error.json"]]
    # Do not return request files or credentials. Structured history is already redacted.
    for c in [read(ROOT / "telegram.json", {}), read(ROOT / "email.json", {})]:
        for key in ["token", "password"]:
            if c.get(key): text = text.replace(c[key], "••••••")
    return {"records": records, "journal": text, "notification_errors": [x for x in errors if x]}

LOG_ROOT = pathlib.Path("/var/log")
def log_files():
    require_admin(); root = LOG_ROOT.resolve(); files = []; issues = []
    for folder, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if not pathlib.Path(folder,d).is_symlink()]
        for name in sorted(names):
            path = pathlib.Path(folder,name)
            if path.is_symlink() or not path.is_file() or name.endswith((".gz",".xz",".bz2",".zst",".journal",".journal~")) or name in ("wtmp","btmp","lastlog","faillog"): continue
            try:
                info=path.stat(); files.append({"path":str(path),"size":info.st_size,"modified":info.st_mtime})
            except OSError: issues.append("Не удалось прочитать "+str(path))
            if len(files)>=3000: return {"files":files,"issues":issues+["Показаны первые 3000 файлов"]}
    return {"files":sorted(files,key=lambda f:f["path"]),"issues":issues}

def server_log(r):
    require_admin()
    if r.get("source")=="journal":
        if not shutil.which("journalctl"): raise ValueError("journalctl не установлен")
        p=run(["journalctl","--no-pager","-o","short-iso","-n","500"],check=False,timeout=30)
        if p.returncode: raise RuntimeError("Системный журнал недоступен")
        return {"text":p.stdout[-512000:],"source":"journal","updated":now()}
    root=LOG_ROOT.resolve(); requested=pathlib.Path(r.get("path","")); path=requested.resolve()
    if root not in path.parents or requested.is_symlink() or not path.is_file(): raise ValueError("Выберите обычный файл внутри /var/log")
    if path.name.endswith((".gz",".xz",".bz2",".zst",".journal",".journal~")) or path.name in ("wtmp","btmp","lastlog","faillog"): raise ValueError("Этот бинарный или сжатый журнал не поддерживается")
    with path.open("rb") as f:
        f.seek(0,os.SEEK_END); size=f.tell();f.seek(max(0,size-512000));data=f.read(512000)
    if b"\x00" in data: raise ValueError("Файл содержит бинарные данные")
    text="\n".join(data.decode("utf-8",errors="replace").splitlines()[-500:])
    return {"text":text,"source":str(path),"updated":now(),"truncated":size>512000 or len(data.splitlines())>500}

def stream_emit(event,result=None,**fields):
    print(json.dumps({"event":event,"result":result,**fields},ensure_ascii=False),flush=True)

def stream_journal(unitname=None):
    if not shutil.which("journalctl"):raise ValueError("journalctl не установлен")
    args=["journalctl","--follow","--no-pager","-o","short-iso","-n","500"]
    if unitname:args += ["-u",unitname]
    process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ,"out");selector.register(process.stderr,selectors.EVENT_READ,"err")
    decoder=codecs.getincrementaldecoder('utf-8')('replace');errors=b'';pending='';last=time.monotonic()
    secrets=[]
    if unitname:
        for name in ['telegram','email']:
            c=read(ROOT/(name+'.json'),{})
            secrets += [c[k] for k in ['token','password'] if c.get(k)]
    try:
        while True:
            for key,_ in selector.select(timeout=1):
                data=os.read(key.fileobj.fileno(),65536)
                if not data:selector.unregister(key.fileobj);continue
                if key.data=='err':errors=(errors+data)[-2000:];continue
                pending+=decoder.decode(data)
                if len(pending)>1024**2:raise ValueError('Строка журнала превышает 1 МБ')
                if '\n' not in pending:continue
                text,pending=pending.rsplit('\n',1);text+='\n'
                for secret in secrets:text=text.replace(secret,'••••••')
                stream_emit('journal' if unitname else 'logs',{'text':text,'updated':now()},mode='append')
                last=time.monotonic()
            if process.poll() is not None and not selector.get_map():
                raise RuntimeError('Поток journalctl завершился; проверьте доступ к журналу')
            if time.monotonic()-last>=2:stream_emit('heartbeat',{'updated':now()});last=time.monotonic()
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        process.stdout.close();process.stderr.close()

def stream_file(r):
    # Recheck containment on every replacement; never follow a link outside /var/log.
    server_log({'source':'file','path':r['path']})
    requested=pathlib.Path(r['path']);file=None;inode=None;offset=0;last=time.monotonic();decoder=codecs.getincrementaldecoder('utf-8')('replace')
    try:
        while True:
            if requested.is_symlink():raise ValueError('Ссылки в потоке логов запрещены')
            resolved=requested.resolve()
            if not within(resolved,LOG_ROOT.resolve()):raise ValueError('Журнал вышел за пределы /var/log')
            try:info=resolved.stat()
            except FileNotFoundError:info=None
            if info and not stat.S_ISREG(info.st_mode):raise ValueError('Нужен обычный журнал')
            if info and (info.st_dev,info.st_ino)!=inode:
                first=inode is None
                if file:file.close()
                fd=os.open(resolved,os.O_RDONLY|os.O_NOFOLLOW);file=os.fdopen(fd,'rb');actual=os.fstat(fd)
                inode=(actual.st_dev,actual.st_ino);offset=max(0,actual.st_size-512000) if first else 0;file.seek(offset)
                data=file.read(512000);offset=file.tell()
                if b'\0' in data:raise ValueError('Журнал содержит бинарные данные')
                decoder=codecs.getincrementaldecoder('utf-8')('replace');text=decoder.decode(data)
                if first:text='\n'.join(text.splitlines()[-500:])+('\n' if data.endswith(b'\n') else '')
                stream_emit('logs',{'text':text,'updated':now(),'truncated':first and actual.st_size>512000},mode='replace' if first else 'append');last=time.monotonic()
            elif file:
                if os.fstat(file.fileno()).st_size<offset:file.seek(0);offset=0
                data=file.read(65536);offset=file.tell()
                if data:
                    if b'\0' in data:raise ValueError('Журнал содержит бинарные данные')
                    stream_emit('logs',{'text':decoder.decode(data),'updated':now()},mode='append');last=time.monotonic()
            if time.monotonic()-last>=2:stream_emit('heartbeat',{'updated':now()});last=time.monotonic()
            time.sleep(.2)
    finally:
        if file:file.close()

def stream(r):
    kind=r.get('kind')
    if kind=='metrics':
        interval=r.get('interval',2)
        if not isinstance(interval,int) or interval not in [2,5,10]:raise ValueError('Неверный интервал потока')
        while True:
            start=time.monotonic();stream_emit('metrics',metrics());time.sleep(max(0,interval-(time.monotonic()-start)))
    require_admin()
    if kind=='logs':return stream_journal() if r.get('source')=='journal' else stream_file(r)
    if kind=='operations':
        # Keep records current on one channel; the journal itself follows journalctl on another.
        previous=None
        while True:
            value=logs({});digest=hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()
            if digest!=previous:stream_emit('operations',value);previous=digest
            else:stream_emit('heartbeat',{'updated':now()})
            time.sleep(2)
    if kind=='operation_journal':return stream_journal('server-backup-*')
    raise ValueError('Неизвестный поток')


def state_path(jobid): return ROOT / "states" / (ident(jobid) + ".json")
def stopped_path(jobid): return ROOT / "stopped" / (ident(jobid) + ".json")
def recover(jobid=None):
    paths = [stopped_path(jobid)] if jobid else list((ROOT / "stopped").glob("*.json"))
    failures = []
    for path in paths:
        if jobid is None and shutil.which("systemctl"):
            active = run(["systemctl", "is-active", "server-backup-job-" + path.stem + ".service"], check=False)
            if active.returncode == 0: continue
        pending = read(path, [])
        for container in list(pending):
            p = run(["docker", "start", container], check=False)
            if p.returncode: failures.append(container)
            else:
                pending.remove(container); write(path, pending)
        if not pending: path.unlink(missing_ok=True)
    if failures: raise RuntimeError("Не удалось запустить остановленные контейнеры: " + ", ".join(failures))
    return {"recovered": True}

@contextlib.contextmanager
def db_command(db):
    engine = db["engine"]
    if engine not in ["mysql", "mariadb", "postgres"]: raise ValueError("Неизвестная СУБД")
    container = db.get("container")
    if container and not re.fullmatch(r"[A-Za-z0-9_.-]+", container): raise ValueError("Недопустимое имя контейнера")
    user = db.get("user", "postgres" if engine == "postgres" else "root")
    host = db.get("host", "localhost"); port = str(int(db.get("port", 5432 if engine == "postgres" else 3306)))
    if any("\n" in str(x) or "\x00" in str(x) for x in [host, user, db.get("password", "")]): raise ValueError("Недопустимое значение подключения")
    with tempfile.TemporaryDirectory(prefix="sb-db-") as folder:
        env = os.environ.copy(); prefix = []
        if container:
            # Password passed through docker stdin into a temporary 0600 option file, never argv.
            remote = "/tmp/sb-db-" + uuid.uuid4().hex
            content = "[client]\nuser=" + json.dumps(user) + "\npassword=" + json.dumps(db.get("password", "")) + "\n" if engine != "postgres" else ""
            if engine != "postgres":
                run(["docker", "exec", "-i", container, "sh", "-c", 'umask 077; cat > "$1"', "sh", remote], data=content)
                prefix = ["docker", "exec", "-i", container]
                options = ["--defaults-extra-file=" + remote]
            else:
                # libpq passfile, escaping colon and backslash.
                esc = lambda s: str(s).replace("\\", "\\\\").replace(":", "\\:")
                content = ":".join([esc(host), port, "*", esc(user), esc(db.get("password", ""))]) + "\n"
                run(["docker", "exec", "-i", container, "sh", "-c", 'umask 077; cat > "$1"', "sh", remote], data=content)
                prefix = ["docker", "exec", "-i", "-e", "PGPASSFILE=" + remote, container]
                options = ["-h", host, "-p", port, "-U", user]
            try: yield prefix, options, env
            finally: run(["docker", "exec", container, "rm", "-f", remote], check=False)
        elif engine == "postgres":
            if db.get("peer", False):
                prefix = ["runuser", "-u", user, "--"]; options = []
            else:
                passfile = pathlib.Path(folder) / "pgpass"
                esc = lambda s: str(s).replace("\\", "\\\\").replace(":", "\\:")
                passfile.write_text(":".join([esc(host), port, "*", esc(user), esc(db.get("password", ""))]) + "\n"); passfile.chmod(0o600)
                env["PGPASSFILE"] = str(passfile); options = ["-h", host, "-p", port, "-U", user]
            yield prefix, options, env
        else:
            cfg = pathlib.Path(folder) / "client.cnf"
            cfg.write_text("[client]\nuser=" + json.dumps(user) + "\npassword=" + json.dumps(db.get("password", "")) + "\nhost=" + json.dumps(host) + "\nport=" + port + "\n"); cfg.chmod(0o600)
            yield [], ["--defaults-extra-file=" + str(cfg)], env

def db_query(db, query):
    with db_command(db) as (prefix, opts, env):
        exe = "psql" if db["engine"] == "postgres" else ("mariadb" if db["engine"] == "mariadb" else "mysql")
        args = ["-d", db.get("maintenance_db", "postgres"), "-At", "-c", query] if exe == "psql" else ["-N", "-B", "-e", query]
        return run(prefix + [exe] + opts + args, env=env).stdout

def db_discover(db):
    query = "SELECT datname FROM pg_database WHERE NOT datistemplate;" if db["engine"] == "postgres" else "SHOW DATABASES;"
    databases = db_query(db, query).splitlines()
    version = db_query(db, "SELECT version();").strip()
    engines = [] if db["engine"] == "postgres" else db_query(db, "SELECT DISTINCT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys') AND ENGINE IS NOT NULL;").splitlines()
    return {"databases": databases, "version": version, "table_engines": engines}

def dump_db(db, folder):
    name = ident(db["id"]); engine = db["engine"]
    if db.get('backup_mode')=='journal':return database_chain(db,folder)
    info = db_discover(db)
    if engine != "postgres" and any(x.upper() != "INNODB" for x in info["table_engines"]) and db.get("consistency") != "lock":
        raise RuntimeError("Обнаружены нетранзакционные таблицы: выберите блокировку для " + name)
    names = db.get("databases", [])
    if any(not isinstance(n, str) or n.startswith("-") or "\x00" in n for n in names): raise ValueError("Недопустимое имя базы")
    outputs = []
    with db_command(db) as (prefix, opts, env):
        if engine == "postgres":
            commands = [("roles.sql", ["pg_dumpall"] + opts + ["--roles-only"])]
            selected = names or info["databases"]
            for i, database in enumerate(selected): commands.append(("database-%d.dump" % i, ["pg_dump"] + opts + ["-Fc", "--compress=0", "--dbname=" + database]))
        else:
            exe = "mariadb-dump" if engine == "mariadb" else "mysqldump"
            consistent = ["--lock-all-tables"] if db.get("consistency") == "lock" else ["--single-transaction"]
            args = [exe] + opts + consistent + ["--quick", "--routines", "--events", "--triggers"]
            if db.get("_journal_baseline"):args += ["--source-data=2" if engine=="mysql" and tuple(int(x) for x in re.search(r"(\d+)\.(\d+)",info["version"]).groups()) >= (8,4) else "--master-data=2"]
            args += ["--databases"] + names if names else ["--all-databases"]
            commands = [("database.sql", args)]
        for filename, args in commands:
            target = folder / filename; temp = folder / (filename + ".tmp")
            with open(temp, "wb") as out:
                p = subprocess.run(prefix + args, env=env, stdout=out, stderr=subprocess.PIPE)
            if p.returncode: raise RuntimeError("Ошибка дампа " + name + ": " + p.stderr.decode(errors="replace")[-1000:])
            os.replace(temp, target); outputs.append(filename)
    return {"id": name, "engine": engine, "version": info["version"], "databases": names or info["databases"], "files": outputs}

def excluded_mounts(sources):
    # Explicit source under a mount selects it; selecting / does not select every other mount.
    ignored = []
    for d in disks():
        mount = d.get("target", "")
        if mount == "/" or not mount: continue
        selected = any(p == mount or p.startswith(mount.rstrip("/") + "/") for p in sources)
        if not selected: ignored.append(mount)
    return ignored

def execute_job(jobid, dry=False, state_id=None):
    stateid = ident(state_id or jobid)
    require_admin(); j = config("jobs", jobid); repo = config("repositories", j["repository_id"])
    state = {"id": jobid, "operation": "backup", "status": "running", "repository_id":repo["id"], "repository_name":repo.get("name",repo["id"]), "job_name":j.get("name",jobid), "sources":j.get("sources",[]), "started": now(), "events": [], "summary": None, "dry_run": dry, "stages": []}
    outcome = "failed"
    def stage(key, title, detail=""):
        if state["stages"] and state["stages"][-1]["status"] == "running":
            state["stages"][-1].update(status="done", finished=now())
        state["stages"].append({"id":key,"title":title,"detail":detail,"status":"running","started":now()})
        state["stage"] = key
        state["progress"] = {}
        write(state_path(stateid), state)
    def end_stage(status="done"):
        if state["stages"] and state["stages"][-1]["status"] == "running":
            state["stages"][-1].update(status=status, finished=now())
    stage("prepare", "Подготовка задания", "Проверка хранилища и источников")
    write(state_path(stateid), state)
    stopped = []
    try:
        with repo_lock(repo):
            if dry: require_dry_run()
            if not dry: recover(jobid)
            dump_root = ROOT / "dumps" / jobid
            if not dry:
                # New staging tree ensures stale removed databases never enter the next snapshot.
                shutil.rmtree(dump_root, ignore_errors=True); dump_root.mkdir(parents=True, mode=0o700)
            manifest = {"version": VERSION, "created": now(), "sources": j["sources"], "databases": [], "docker": []}
            extra_sources = []
            container_info = docker() if j.get("containers") else []
            all_mounts = []
            for dbid in j.get("database_ids", []):
                database = config("databases", dbid)
                if database.get("container") and any(c["name"] == database["container"] and c["mode"] == "stop" for c in j.get("containers", [])):
                    raise ValueError("Выберите дамп или остановку для контейнера БД, не оба режима: " + database["container"])
            if j.get("containers"): stage("docker", "Подготовка Docker", "Проверка томов и остановка выбранных контейнеров" if not dry else "Проверка выбранных контейнеров без остановки")
            for selection in j.get("containers", []):
                item = next((c for c in container_info if c["name"] == selection["name"]), None)
                if not item: raise ValueError("Контейнер не найден: " + selection["name"])
                mode = selection["mode"]
                if mode not in ["stop", "live", "dump"]: raise ValueError("Неизвестный режим контейнера")
                if mode == "live" and not selection.get("acknowledge_inconsistent"): raise ValueError("Подтвердите отсутствие гарантированной согласованности")
                manifest["docker"].append(item)
                if mode == "dump" and not any(config("databases", d).get("container") == item["name"] for d in j.get("database_ids", [])): raise ValueError("Настройте дамп базы контейнера " + item["name"])
                mounts = [m["Source"] for m in item["mounts"] if m.get("Source")]
                all_mounts.extend(mounts)
                if mode != "dump": extra_sources.extend(mounts)
                labels = item["labels"]
                workdir = labels.get("com.docker.compose.project.working_dir", "")
                for compose in labels.get("com.docker.compose.project.config_files", "").split(","):
                    if compose: extra_sources.append(compose if compose.startswith("/") else str(pathlib.Path(workdir) / compose))
                if workdir and pathlib.Path(workdir, ".env").exists(): extra_sources.append(str(pathlib.Path(workdir, ".env")))
                if mode == "stop" and item["running"] and not dry:
                    # Record before stopping: an interruption between steps still permits recovery.
                    stopped.append(item["id"]); write(stopped_path(jobid), stopped)
                    run(["docker", "stop", "--time", "30", item["id"]], timeout=90)
            if j.get("database_ids") and not dry: stage("databases", "Дампы баз данных")
            for dbid in j.get("database_ids", []):
                db = config("databases", dbid)
                if not dry:
                    folder = dump_root / ident(dbid); folder.mkdir(mode=0o700)
                    state["stages"][-1]["detail"] = "База: " + dbid
                    write(state_path(stateid), state)
                    manifest["databases"].append(dump_db(db, folder))
            if not dry:
                write(dump_root / "manifest.json", manifest)
                extra_sources.append(str(dump_root))
            sources = list(dict.fromkeys(j["sources"] + extra_sources))
            excludes = ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/tmp", str(ROOT / "repositories"), str(ROOT / "databases"), str(ROOT / "sftp"), str(ROOT / "cache"), str(ROOT / "telegram.json"), "**/.server-backup-trash", "**/.server-backup-upload-*", "**/.server-backup-restore-*", "/var/lib/docker", "/var/lib/mysql", "/var/lib/postgresql"] + j.get("excludes", []) + excluded_mounts(sources)
            # Operation requests may contain DB credentials or a new repository password.
            # Only this job's prepared dump tree belongs in the snapshot.
            excludes += [str(p) for p in ROOT.iterdir() if p.name != "dumps"]
            if (ROOT / "dumps").exists(): excludes += [str(p) for p in (ROOT / "dumps").iterdir() if p.name != jobid]
            # Docker's selected volumes bypass broad Docker directory exclusion using /var/lib/docker/* exclusions.
            if extra_sources and any(p.startswith("/var/lib/docker/") for p in extra_sources):
                excludes.remove("/var/lib/docker")
                excludes += ["/var/lib/docker/overlay2", "/var/lib/docker/containers", "/var/lib/docker/image", "/var/lib/docker/buildkit", "/var/lib/docker/network", "/var/lib/docker/plugins", "/var/lib/docker/swarm"]
                selected_volumes = [m["Name"] for c in manifest["docker"] for m in c["mounts"] if m.get("Type") == "volume" and m.get("Source") in extra_sources]
                volume_root = pathlib.Path("/var/lib/docker/volumes")
                if volume_root.exists(): excludes += [str(p) for p in volume_root.iterdir() if p.name not in selected_volumes]
            # Exclude database container bind mounts in dump mode and any unselected container mounts.
            for c in container_info:
                selection = next((s for s in j.get("containers", []) if s["name"] == c["name"]), None)
                if not selection or selection["mode"] == "dump":
                    for m in c["mounts"]:
                        if m.get("Source") in extra_sources:
                            if selection and selection["mode"] == "dump": raise ValueError("Том выбран одновременно для дампа БД и файловой копии: " + m["Source"])
                        elif m.get("Source"): excludes.append(m["Source"])
            if repo["type"] == "disk": excludes.append(repo["repository"])
            args = ["backup", "--json", "--host", j.get("host_id", os.uname().nodename), "--tag", "sb-job-" + jobid]
            if dry: args += ["--dry-run"]
            if j.get("limit_upload"): args += ["--limit-upload", str(int(j["limit_upload"]))]
            if j.get("read_concurrency"):
                if restic_backup_supports("--read-concurrency"): args += ["--read-concurrency", str(int(j["read_concurrency"]))]
                else: state["warnings"] = ["Установленный Restic не поддерживает настройку параллельного чтения. Используется стандартное значение Restic."]
            for e in list(dict.fromkeys(excludes)): args += ["--exclude", e]
            args += ["--"] + sources
            stage("backup", "Пробное копирование" if dry else "Копирование файлов", "Restic сканирует источники и передаёт изменения")
            with repository_env(repo) as env:
                env["SB_REPO_ID"] = repo["id"]
                errors = tempfile.TemporaryFile(mode="w+")
                process = subprocess.Popen(restic_args(env) + args, env=env, stdout=subprocess.PIPE, stderr=errors, text=True)
                try:
                    for line in process.stdout:
                        try: event = json.loads(line)
                        except ValueError: continue
                        state["events"] = (state["events"] + [event])[-40:]
                        state["progress"] = event
                        if event.get("message_type") == "summary": state["summary"] = event
                        write(state_path(stateid), state)
                    rc = process.wait()
                finally:
                    if process.poll() is None: process.terminate(); process.wait(timeout=30)
                errors.seek(0); error_text = errors.read()[-3000:]; errors.close()
            outcome = "success" if rc == 0 else ("incomplete" if rc == 3 else "failed")
            end_stage("done" if rc == 0 else "failed")
            if error_text: state["error"] = error_text
            if rc == 0 and not dry and datetime.datetime.now().weekday() == 6:
                stage("cleanup", "Очистка старых копий")
                cleanup = restic(repo, ["forget", "--tag", "sb-job-" + jobid, "--group-by", "host,tags", "--keep-daily", str(j.get("daily", 14)), "--keep-weekly", str(j.get("weekly", 4)), "--prune"], timeout=86400)
                if cleanup.returncode == 0: stage("check", "Проверка структуры хранилища")
                check = restic(repo, ["check"], timeout=86400) if cleanup.returncode == 0 else cleanup
                if cleanup.returncode or check.returncode:
                    state["maintenance_error"] = (cleanup.stderr + check.stderr)[-2000:]
                    end_stage("failed")
    except BaseException as e:
        outcome = "failed"; state["error"] = str(e); end_stage("failed")
    finally:
        try:
            if not dry:
                if stopped_path(jobid).exists(): stage("restart", "Запуск остановленных контейнеров")
                recover(jobid)
        except Exception as e:
            state["container_recovery_error"] = str(e); outcome = "failed"; end_stage("failed")
        if not dry and outcome=="success":
            state["destinations"]=[{"repository_id":repo['id'],"status":"success","snapshot":(state.get('summary') or {}).get('snapshot_id')}]
            for destination in j.get('replica_ids',[]):
                try:
                    stage('replicate','Дополнительное хранилище',destination)
                    snapshot=(state.get('summary') or {}).get('snapshot_id')
                    if not snapshot:raise RuntimeError('Основная копия не вернула snapshot_id')
                    state['destinations'].append(copy_snapshot(repo,config('repositories',destination),snapshot))
                except Exception as e:
                    end_stage('failed');state.setdefault('replication_errors',[]).append({'repository_id':destination,'error':str(e)});state['destinations'].append({'repository_id':destination,'status':'failed','error':str(e)})
                write(state_path(stateid),state)
        if not dry and outcome=="success" and j.get("verify_restore") and (state.get("summary") or {}).get("snapshot_id"):
            try:
                stage("verify", "Проверка восстановления")
                with repo_lock(repo):state["verification"]=(verify_full_restore if j.get("verify_full") else verify_restore)(repo,state["summary"]["snapshot_id"],jobid)
            except Exception as e:
                end_stage("failed")
                state["verification_error"]=str(e);write(ROOT/"verifications"/("job-"+jobid+".json"),{"status":"failed","repository_id":repo["id"],"error":str(e),"finished":now(),"operation":"verify-restore"});notify("Server Backup · проверка восстановления не пройдена · "+jobid)
        if not dry and outcome=="success" and repo.get("track_capacity"):
            try:
                stage("capacity", "Измерение занятого места")
                state["capacity"]=capacity({"repository_id":repo["id"]})
                if state['capacity'].get('warning'):notify('Server Backup · '+repo['id']+' · '+state['capacity']['warning'])
            except Exception as e:
                end_stage("failed"); state["capacity_error"]=str(e)
        end_stage()
        state["status"] = outcome
        state["finished"] = now(); state["dry_run"] = dry
        write(state_path(stateid), state)
        write(ROOT / "history" / (datetime.datetime.now().strftime("%Y%m%dT%H%M%S") + "-" + jobid + "-" + uuid.uuid4().hex[:8] + ".json"), state)
        c = read(ROOT / "telegram.json", {}); e = read(ROOT / "email.json", {})
        only_success = state["status"] == "success" and not state.get("maintenance_error") and not state.get("replication_errors")
        if not dry and (not only_success or c.get("success") or e.get("success")):
            state["notification"] = notify("Server Backup · " + os.uname().nodename + " · " + jobid + "\nРезультат: " + state["status"] + ("; ошибка обслуживания" if state.get("maintenance_error") else ""), success_only=only_success)
            write(state_path(stateid), state)
    return state

def start_operation(request):
    require_admin()
    if helper_source():install_helper_source()
    operationid = "op-" + uuid.uuid4().hex
    write(ROOT / "operations" / (operationid + ".json"), request)
    unitname = "server-backup-" + operationid
    run(["systemd-run", "--unit=" + unitname, "--property=Type=exec", "--property=TimeoutStopSec=120", "/usr/bin/python3", HELPER, "--operation", operationid])
    return {"operation_id": operationid, "unit": unitname}

def operation(operationid):
    request = config("operations", operationid)
    repo = config("repositories", request["repository_id"]) if request.get("repository_id") else {"repository": "restore-local"}
    state = {"id": operationid, "operation": request["command"], "status": "running", "started": now()}
    state.update({key:request[key] for key in ["repository_id","snapshot","target","job_id","name","from_repository_id"] if key in request})
    if request.get("repository_id"):state["repository_name"]=repo.get("name",repo.get("id"))
    write(state_path(operationid), state)
    try:
        with (contextlib.nullcontext() if request["command"]=="capacity" else repo_lock(repo)):
            if request["command"]=="capacity":
                state.update(status="success",output=json.dumps(capacity(request)));p=None
            elif request["command"] == "package-install":
                p=install_package(request)
            elif request["command"] == "verify-restore":
                state.update((verify_full_restore if request.get("full") else verify_restore)(repo,request.get("snapshot","latest")));p=None
            elif request["command"] == "external-test":
                def monitor_progress(name, done, total):
                    state.update(current_target=name, targets_done=done, targets_total=total)
                    write(state_path(operationid),state)
                result=external_watchdog(monitor_progress)
                state.update(status="success",output=json.dumps(result),targets_done=len(result.get("servers",[])),current_target="");p=None
            elif request["command"] == "database-import":
                result = restore_database(request)
                state.update(status="success", output=json.dumps(result))
                p = None
            elif request["command"] == "docker-import":
                result = restore_docker(request)
                state.update(status="success", output=json.dumps(result))
                p = None
            elif request["command"] == "copy" and request.get("from_repository_id"):
                source = config("repositories", request["from_repository_id"])
                if source["repository"] == repo["repository"]: raise ValueError("Источник и назначение совпадают")
                with repo_lock(source), repository_env(repo) as env, repository_env(source) as source_env:
                    env["SB_REPO_ID"] = repo["id"]
                    env["RESTIC_FROM_REPOSITORY"] = source_env["RESTIC_REPOSITORY"]
                    env["RESTIC_FROM_PASSWORD_FILE"] = source_env["RESTIC_PASSWORD_FILE"]
                    # Cross-backend SFTP uses one SSH config containing both aliases.
                    if source_env.get("SB_SFTP_CONFIG"):
                        if env.get("SB_SFTP_CONFIG"):
                            with open(env["SB_SFTP_CONFIG"],"a") as f: f.write(pathlib.Path(source_env["SB_SFTP_CONFIG"]).read_text())
                        else: env["SB_SFTP_CONFIG"] = source_env["SB_SFTP_CONFIG"]
                    for key,value in source_env.items():
                        if key.startswith("RCLONE_CONFIG_"):
                            if key in env and env[key]!=value: raise ValueError("Конфликт доступов rclone при копировании")
                            env[key]=value
                    if source["type"]=="yandex": env["RCLONE_CONFIG"]="/dev/null"
                    args = command_args(request)
                    if source["type"] == "s3" and repo["type"] == "s3" and source.get("access_key") != repo.get("access_key"):
                        raise ValueError("Для copy между S3 используйте ключ с доступом к обоим репозиториям")
                    if source["type"] == "s3" and repo["type"] != "s3":
                        for k in ["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","AWS_DEFAULT_REGION"]: env[k]=source_env[k]
                    if env.get("SB_SFTP_CONFIG"):
                        args = ["-o", "sftp.args=" + shlex.join(["-F",env["SB_SFTP_CONFIG"]])] + args
                        env.pop("SB_SFTP_CONFIG",None)
                    p = run(["restic"] + args, env=env, check=False, timeout=604800)
            elif request["command"] == "key" and request.get("key_password"):
                with tempfile.TemporaryDirectory() as folder:
                    password_file=pathlib.Path(folder)/"new-password"; password_file.write_text(request["key_password"]); password_file.chmod(0o600)
                    p=restic(repo,command_args(request)+["--new-password-file",str(password_file)],timeout=3600)
            elif request["command"] == "restore":
                p = execute_restore(repo, request)
            else:
                args = command_args(request)
                p = restic(repo, args, timeout=604800)
            if p is not None: state.update(status="success" if p.returncode == 0 else "failed", exit_code=p.returncode, output=p.stdout[-30000:], error=p.stderr[-3000:])
    except Exception as e: state.update(status="failed", error=str(e))
    state["finished"] = now()
    if request["command"]=="verify-restore":write(ROOT/"verification-latest.json",state)
    write(state_path(operationid), state)
    write(ROOT / "history" / (operationid + ".json"), state)
    if state["status"] != "success": notify("Server Backup · ошибка операции " + request["command"])
    return state

def execute_restore(repo, request):
    restore_preflight(repo, request)
    target=pathlib.Path(request["target"])
    exact=request.get("target_file")
    if exact:
        destination=file_path(exact,True)
        staging=ROOT/"restore-temp";staging.mkdir(parents=True,exist_ok=True,mode=0o700)
        with tempfile.TemporaryDirectory(dir=staging) as folder:
            source=request["includes"][0]
            pattern=re.sub(r'([*?\[\]\\])',r'\\\1',source)
            result=restic(repo,["restore",request["snapshot"],"--target",folder,"--verify","--include",pattern],timeout=604800)
            if result.returncode:return result
            restored=pathlib.Path(folder)/source.lstrip("/")
            if restored.is_symlink() or not restored.is_file() or not restored.resolve().is_relative_to(pathlib.Path(folder).resolve()):raise ValueError("Не удалось получить обычный файл из копии")
            destination.parent.mkdir(parents=True,exist_ok=True)
            fd,temp=tempfile.mkstemp(dir=destination.parent,prefix=".server-backup-restore-");os.close(fd)
            try:
                run(["cp","-a","--",str(restored),temp],timeout=86400)
                if request.get("overwrite"):os.replace(temp,destination)
                else:os.link(temp,destination)
            finally:
                if os.path.exists(temp):os.unlink(temp)
            return result
    args=["restore",request["snapshot"],"--target",str(target),"--verify"]
    for item in request.get("includes",[]):args += ["--include",item]
    return restic(repo,args,timeout=604800)

def restore_preflight(repo, request):
    target = pathlib.Path(request["target"])
    exact = request.get("target_file")
    if not target.is_absolute(): raise ValueError("Укажите абсолютный каталог восстановления")
    if str(target) == "/" and not exact and not (request.get("allow_root") and request.get("confirmed") and request.get("overwrite")):
        raise ValueError("Для восстановления в корень явно разрешите замену существующих файлов и подтвердите запуск")
    if exact:
        file = file_path(exact, True)
        if file.parent != target.resolve(): raise ValueError("Файл назначения должен находиться в выбранном каталоге")
        if file.exists() and (not file.is_file() or not request.get("overwrite")): raise ValueError("Файл существует: подтвердите замену")
        selected=request.get("includes",[])
        if len(selected)!=1: raise ValueError("Для замены файла выберите один файл из копии")
        listing=restic(repo,["ls","--json",request["snapshot"]],timeout=900)
        if listing.returncode: raise RuntimeError("Не удалось прочитать копию")
        selected_node=next((node for node in (json.loads(line) for line in listing.stdout.splitlines() if line.strip()) if node.get("path")==selected[0] and node.get("type")=="file"),None)
        if selected_node is None:
            raise ValueError("Для замены файла выберите обычный файл, а не папку или правило")
    if not exact and target.exists() and (not target.is_dir() or any(target.iterdir())) and not request.get("overwrite"):
        raise ValueError("Каталог не пуст или не является каталогом; требуется подтверждение перезаписи")
    parent = target
    while not parent.exists(): parent = parent.parent
    includes = request.get("includes", [])
    if exact:
        required=selected_node.get("size",0)
        if required>shutil.disk_usage(ROOT).free:raise ValueError("Недостаточно места для временного восстановления файла")
    elif includes:
        p = restic(repo, ["ls", "--json", request["snapshot"]], timeout=900)
        if p.returncode: raise RuntimeError("Не удалось прочитать копию: " + p.stderr[-1000:])
        required = 0
        for line in p.stdout.splitlines():
            node = json.loads(line); path = node.get("path", "")
            if any(fnmatch.fnmatch(path, pattern) or path.startswith(pattern.rstrip("/") + "/") for pattern in includes): required += node.get("size", 0)
    else:
        p = restic(repo, ["stats", request["snapshot"], "--mode", "restore-size", "--json"], timeout=900)
        if p.returncode: raise RuntimeError("Не удалось определить размер копии: " + p.stderr[-1000:])
        required = json.loads(p.stdout)["total_size"]
    free = shutil.disk_usage(parent).free
    if exact: required = required * 2
    if required > free: raise ValueError("Недостаточно свободного места: нужно %s байт, доступно %s" % (required, free))
    return {"required_bytes": required, "free_bytes": free}

def command_args(r):
    args = r.get("args", [])
    if not isinstance(args, list) or any(not isinstance(x, str) or "\x00" in x for x in args): raise ValueError("Аргументы должны быть массивом строк")
    supported = ["snapshots", "ls", "find", "diff", "stats", "check", "forget", "prune", "copy", "key", "unlock", "repair", "migrate", "tag", "cat", "dump", "help", "version", "list", "mount", "generate", "cache", "backup", "options", "features", "recover", "self-update"]
    if r["command"] not in supported: raise ValueError("Неизвестная команда")
    # Repository selection and secret handling remain controlled by profile.
    if any(a in ["-r", "-p", "--repo", "--repository-file", "--password-file", "--password-command"] or a.startswith(("--repo=", "--repository-file=", "--password-file=", "--password-command=")) or (a.startswith("-r") and not a.startswith("--")) or (a.startswith("-p") and not a.startswith("--")) for a in args): raise ValueError("Репозиторий и секреты задаются профилем")
    if r["command"] in MUTATING and not r.get("confirmed"): raise ValueError("Требуется подтверждение операции")
    return [r["command"]] + args

def physical_disk_summary(storage):
    if not shutil.which('lsblk'):return None
    result=run(['lsblk','--json','--bytes','--output','NAME,TYPE,SIZE,MAJ:MIN'],check=False,timeout=15)
    if result.returncode:return None
    try:devices=json.loads(result.stdout)['blockdevices']
    except (ValueError,KeyError):return None
    physical={};owners={}
    def visit(nodes,parent=None):
        for node in nodes:
            owner=parent
            if node.get('type')=='disk':
                owner=node['name'];physical.setdefault(owner,{'name':owner,'physical_size_bytes':int(node.get('size') or 0),'total_bytes':0,'used_bytes':0,'free_bytes':0,'mounted':False,'shared':False,'mounts':[]})
            if owner and node.get('maj:min'):owners.setdefault(node['maj:min'],set()).add(owner)
            visit(node.get('children',[]),owner)
    visit(devices);seen=set()
    for mount in storage:
        target=mount.get('target')
        if not target:continue
        try:
            device=os.stat(target).st_dev;identity=str(os.major(device))+':'+str(os.minor(device))
            disks=owners.get(identity,set())
            if not disks or identity in seen:continue
            seen.add(identity);fs=os.statvfs(target)
            total=fs.f_blocks*fs.f_frsize;free=fs.f_bavail*fs.f_frsize
            for name in disks:
                row=physical[name];row['mounted']=True
                row['mounts'].append({**mount,'total_bytes':total,'free_bytes':free,'used_bytes':total-free})
                if len(disks)>1:row['shared']=True;continue
                row['total_bytes']+=total;row['free_bytes']+=free;row['used_bytes']+=total-free
        except OSError:continue
    for row in physical.values():
        if not row['mounted'] or row['shared']:
            row.update(total_bytes=row['physical_size_bytes'],used_bytes=None,free_bytes=None,used_percent=None)
        else:row['used_percent']=100*row['used_bytes']/row['total_bytes'] if row['total_bytes'] else None
    return sorted(physical.values(),key=lambda row:row['name'])

def metrics(light=False):
    def sample():
        cpu = list(map(int, pathlib.Path("/proc/stat").read_text().splitlines()[0].split()[1:]))
        net = {}
        for line in pathlib.Path("/proc/net/dev").read_text().splitlines()[2:]:
            name, counters = line.split(":", 1); fields = counters.split(); net[name.strip()] = [int(fields[0]), int(fields[8])]
        io = {}
        for line in pathlib.Path("/proc/diskstats").read_text().splitlines():
            f = line.split()
            if len(f) >= 14: io[f[2]] = [int(f[5]) * 512, int(f[9]) * 512, int(f[12])]
        return cpu, net, io
    first = sample(); time.sleep(0.5); second = sample()
    total = sum(second[0]) - sum(first[0]); idle = sum(second[0][3:5]) - sum(first[0][3:5])
    mem = {}
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1); mem[key] = int(value.split()[0]) * 1024
    network = {k: {"rx_per_second": (v[0]-first[1].get(k,v)[0])*2, "tx_per_second": (v[1]-first[1].get(k,v)[1])*2} for k,v in second[1].items()}
    io = {k: {"read_per_second": (v[0]-first[2].get(k,v)[0])*2, "write_per_second": (v[1]-first[2].get(k,v)[1])*2, "busy_percent": (v[2]-first[2].get(k,v)[2])/5} for k,v in second[2].items() if not k.startswith(("loop", "ram")) and (pathlib.Path("/sys/block")/k).exists()}
    process = [] if light else run(["ps", "-eo", "pid,comm,%cpu,%mem", "--sort=-%cpu"], check=False).stdout.splitlines()[:21]
    process_rows=[];process_error=None
    if not light:
        try:
            result=run(['ps','-eo','pid=,user=,pcpu=,pmem=,rss=,comm=','--sort=-%cpu'],check=False)
            if result.returncode:process_error='Не удалось получить список процессов'
            else:
                for line in result.stdout.splitlines()[:30]:
                    fields=line.split(None,5)
                    if len(fields)==6:
                        try:process_rows.append({'pid':int(fields[0]),'user':fields[1],'cpu_percent':float(fields[2]),'memory_percent':float(fields[3]),'memory_bytes':int(fields[4])*1024,'name':fields[5]})
                        except ValueError:continue
        except Exception:process_error='Список процессов временно недоступен' 
    containers = None
    if not light and shutil.which("docker"):
        p = run(["docker", "stats", "--no-stream", "--format", "{{json .}}"], check=False, timeout=20)
        if p.returncode == 0:
            containers = [json.loads(line) for line in p.stdout.splitlines() if line]
    storage = disks()
    for d in storage:
        try:
            fs = os.statvfs(d["target"]); total_bytes = fs.f_blocks * fs.f_frsize
            d["used_percent"] = 100 * (total_bytes - fs.f_bfree * fs.f_frsize) / total_bytes if total_bytes else None
        except OSError: d["used_percent"] = None
    physical=physical_disk_summary(storage)
    return {"physical_disks":physical,"cores":os.cpu_count(), "uptime_seconds":float(pathlib.Path("/proc/uptime").read_text().split()[0]), "disk_count":len([p for p in pathlib.Path("/sys/block").iterdir() if not p.name.startswith(("loop","ram","dm-","md"))]), "time": now(), "cpu_percent": 100*(1-idle/total) if total else None, "memory": mem, "load": list(os.getloadavg()), "disks": storage, "disk_io": io, "network": network, "processes": process, "process_rows":process_rows,"process_error":process_error, "docker": containers}

def watchdog():
    for path in (ROOT / "jobs").glob("*.json"):
        j = read(path)
        if not j.get("enabled", True): continue
        successful = [h for p in (ROOT / "history").glob("*.json") if (h:=read(p, {})).get("id") == j["id"] and h.get("status") == "success" and not h.get("dry_run")]
        timestamp = max((x["finished"] for x in successful), default=j.get("created", now()))
        age = (datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(timestamp)).total_seconds()
        alert = ROOT / "alerts" / (j["id"] + ".json")
        if age > 26*3600:
            previous = read(alert, {})
            if previous.get("for") != timestamp:
                result = notify("Server Backup · " + os.uname().nodename + " · " + j["id"] + "\nНет успешной копии более 26 часов")
                if result.get("sent"): write(alert, {"for": timestamp, "time": now()})
        else: alert.unlink(missing_ok=True)
    return {"checked": True}

# Inserted into the standalone helper; only the standard library is used.
def program_spec(unit):
    if unit == "nginx.service": return {"root":"/etc/nginx", "files":["nginx.conf", "conf.d/*.conf", "sites-available/*"], "validate":["nginx", "-t"]}
    if unit == "apache2.service": return {"root":"/etc/apache2", "files":["apache2.conf", "ports.conf", "sites-available/*.conf", "conf-available/*.conf", "mods-available/*.conf"], "validate":["apache2ctl", "configtest"]}
    match = re.fullmatch(r"php(\d+\.\d+)-fpm\.service", unit)
    if match: return {"root":"/etc/php/"+match[1]+"/fpm", "files":["php-fpm.conf", "php.ini", "pool.d/*.conf"], "validate":["php-fpm"+match[1], "-t"]}
    if unit in ["mysql.service", "mariadb.service"]: return {"root":"/etc/mysql", "files":["my.cnf", "mariadb.cnf", "conf.d/*.cnf", "mysql.conf.d/*.cnf", "mariadb.conf.d/*.cnf"], "validate":None}
    if re.fullmatch(r"postgresql(?:@[A-Za-z0-9_.-]+)?\.service", unit):
        match = re.fullmatch(r"postgresql@(\d+)-([A-Za-z0-9_.-]+)\.service", unit)
        prefix = match[1]+"/"+match[2]+"/" if match else "*/*/"
        return {"root":"/etc/postgresql", "files":[prefix+name for name in ["postgresql.conf", "pg_hba.conf", "pg_ident.conf"]], "validate":None}
    if unit in ["redis.service", "redis-server.service"]: return {"root":"/etc/redis", "files":["redis.conf"], "validate":None}
    if unit == "docker.service": return {"root":"/etc/docker", "files":["daemon.json"], "create":["daemon.json"], "validate":["dockerd", "--validate", "--config-file", "/etc/docker/daemon.json"], "json":True}
    return None

def service_inventory():
    if not shutil.which("systemctl"): return [], "systemd не установлен"
    files = run(["systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager"], check=False)
    if files.returncode: return [], "Не удалось получить список служб systemd"
    active = run(["systemctl", "list-units", "--type=service", "--all", "--plain", "--no-legend", "--no-pager"], check=False)
    runtime = {}
    if active.returncode == 0:
        for line in active.stdout.splitlines():
            parts = line.lstrip(" ●").split(None, 4)
            if len(parts) >= 4: runtime[parts[0]] = {"active":parts[2], "sub":parts[3], "description":parts[4] if len(parts)>4 else ""}
    services = []
    for line in files.stdout.splitlines():
        parts = line.split()
        if len(parts)<2 or not re.fullmatch(r"[A-Za-z0-9_.:@-]+\.service", parts[0]): continue
        unit = parts[0]
        services.append({"unit":unit, "enabled":parts[1], "active":None, "sub":None, **runtime.get(unit, {}), "manageable":bool(program_spec(unit)) and active.returncode == 0})
    return sorted(services, key=lambda x:(not bool(program_spec(x["unit"])),x["unit"])), "" if active.returncode == 0 else "Состояние служб недоступно: systemd не запущен или нет доступа"

def installed_programs():
    packages = []; package_error = ""
    if shutil.which("dpkg-query"):
        result = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Architecture}\t${Installed-Size}\t${Essential}\t${Priority}\n"], check=False)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                fields = line.split("\t")
                if len(fields)>=5 and len(fields[0])>1 and fields[0][1]=="i": packages.append({"name":fields[1], "version":fields[2], "architecture":fields[3], "size_kib":int(fields[4]) if fields[4].isdigit() else None,"category":"system" if len(fields)>6 and (fields[5]=="yes" or fields[6] in ("required","important")) else "unknown"})
        else: package_error = "Не удалось прочитать установленные пакеты"
    else: package_error = "dpkg-query не установлен"
    if packages and shutil.which("apt-mark"):
        marks=run(["apt-mark","showmanual"],check=False)
        if marks.returncode==0:
            manual=set(marks.stdout.split())
            for item in packages:
                if item["category"]!="system":item["category"]="manual" if item["name"] in manual or item["name"].split(":")[0] in manual else "dependency"
    services, service_error = service_inventory()
    return {"packages":sorted(packages,key=lambda x:x["name"]), "services":services, "package_error":package_error, "service_error":service_error, "updated":now()}

def package_name(name):
    if not isinstance(name,str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]{0,119}(?::[a-z0-9][a-z0-9-]{0,29})?",name): raise ValueError("Укажите одно имя пакета APT без параметров и пробелов")
    return name

def package_search(r):
    query=r.get("query","").strip()
    if not re.fullmatch(r"[A-Za-z0-9+._-]{2,80}",query):raise ValueError("Введите от 2 символов названия программы")
    result=run(["apt-cache","search","--names-only",re.escape(query)],check=False,timeout=120)
    if result.returncode:raise RuntimeError("Каталог APT недоступен")
    items=[]
    for line in result.stdout.splitlines():
        name,_,description=line.partition(" - ")
        if re.fullmatch(r"[a-z0-9][a-z0-9+.-]*",name):items.append({"name":name,"description":description})
    return {"packages":items[:100],"truncated":len(items)>100}

def package_plan(name):
    name=package_name(name)
    result=run(["apt-get","-s","--no-remove","--no-install-recommends","install","--",name],check=False,timeout=120)
    if result.returncode:raise RuntimeError("APT не может установить пакет без удаления других пакетов. Проверьте имя и каталог APT.")
    return {"name":name,"output":result.stdout[-30000:],"plan_hash":hashlib.sha256(result.stdout.encode()).hexdigest()}

def install_package(request):
    require_admin();name=package_name(request["name"])
    ROOT.mkdir(parents=True,exist_ok=True)
    with open(ROOT/"package-install.lock","a") as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError("Другая установка пакетов уже выполняется")
        plan=package_plan(name)
        if not request.get("confirmed") or plan["plan_hash"]!=request.get("plan_hash"):raise ValueError("План установки изменился. Проверьте его заново и подтвердите установку.")
        env=os.environ.copy();env["DEBIAN_FRONTEND"]="noninteractive"
        return run(["apt-get","-y","--no-remove","--no-install-recommends","-o","DPkg::Lock::Timeout=120","-o","Dpkg::Options::=--force-confold","install","--",name],env=env,check=False,timeout=3600)

def editable_configs(unit):
    spec = program_spec(unit)
    if not spec: raise ValueError("Для этой службы управление конфигурацией не поддерживается")
    root = pathlib.Path(spec["root"]).resolve(); result = {}
    for pattern in spec["files"]:
        paths = list(root.glob(pattern))
        if pattern in spec.get("create",[]) and not paths: paths = [root / pattern]
        for path in paths:
            resolved = path.resolve()
            if not within(resolved, root) or (resolved.exists() and not resolved.is_file()): continue
            result[str(resolved)] = {"path":str(resolved), "exists":resolved.exists()}
    return list(result.values())

def require_service(unit):
    if not isinstance(unit,str) or not re.fullmatch(r"[A-Za-z0-9_.:@-]+\.service",unit): raise ValueError("Неверное имя службы")
    services, error = service_inventory()
    item = next((x for x in services if x["unit"]==unit),None)
    if not item or not item["manageable"]: raise ValueError("Управление этой службой недоступно")
    return item

def program_config(r):
    require_admin(); unit = r["unit"]; require_service(unit)
    configs = editable_configs(unit)
    if not r.get("path"): return {"files":configs, "syntax_check":bool(program_spec(unit).get("validate"))}
    path = pathlib.Path(r["path"])
    if str(path) not in [x["path"] for x in configs]: raise ValueError("Этот файл нельзя редактировать через приложение")
    if path.exists() and path.stat().st_size > 1024*1024: raise ValueError("Файл больше 1 MiB; используйте отдельный редактор")
    data = path.read_bytes() if path.exists() else b""
    return {"path":str(path), "content":data.decode("utf-8"), "hash":hashlib.sha256(data).hexdigest(), "exists":path.exists(), "syntax_check":bool(program_spec(unit).get("validate"))}

def replace_program_file(path, data, metadata):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
    fd, temporary = tempfile.mkstemp(dir=str(path.parent),prefix=".server-backup-")
    try:
        os.fchmod(fd,stat.S_IMODE(metadata.st_mode) if metadata else 0o644)
        if metadata and os.geteuid()==0: os.fchown(fd,metadata.st_uid,metadata.st_gid)
        with os.fdopen(fd,"wb") as file: file.write(data);file.flush();os.fsync(file.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def save_program_config(r):
    require_admin()
    if not r.get("confirmed"): raise ValueError("Подтвердите сохранение конфигурации")
    unit = r["unit"]; require_service(unit)
    directory = ROOT / "program-locks";directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    with open(directory / (unit+".lock"),"a") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        current = program_config(r);path = pathlib.Path(current["path"])
        if r.get("hash") != current["hash"]: raise ValueError("Файл изменён другим процессом. Загрузите его повторно")
        data = r["content"].encode("utf-8")
        if len(data)>1024*1024 or b"\x00" in data: raise ValueError("Неверный размер или формат конфигурации")
        spec = program_spec(unit)
        if spec.get("json"):
            try:
                if not isinstance(json.loads(data),dict): raise ValueError()
            except Exception: raise ValueError("Конфигурация Docker должна быть JSON-объектом")
        previous = path.read_bytes() if path.exists() else None;metadata = path.stat() if path.exists() else None
        backupid = uuid.uuid4().hex
        write(ROOT / "program-backups" / (backupid+".json"),{"unit":unit,"path":str(path),"time":now(),"exists":previous is not None,"data":base64.b64encode(previous or b"").decode()})
        checked = False
        try:
            replace_program_file(path,data,metadata)
            validator = spec.get("validate")
            if validator:
                if not shutil.which(validator[0]): raise RuntimeError("Утилита проверки конфигурации не найдена")
                validation = run(validator,check=False,timeout=45)
                if validation.returncode: raise RuntimeError("Проверка синтаксиса завершилась с ошибкой. Изменения отменены")
                checked = True
        except BaseException:
            if previous is None: path.unlink(missing_ok=True)
            else: replace_program_file(path,previous,metadata)
            raise
        write(ROOT / "history" / ("config-"+backupid+".json"),{"id":"config-"+backupid,"operation":"service-config","status":"success","finished":now(),"unit":unit,"path":str(path),"syntax_checked":checked})
        return {"saved":True,"path":str(path),"hash":hashlib.sha256(data).hexdigest(),"backup_id":backupid,"syntax_checked":checked,"restart_required":True}

def service_action(r):
    require_admin()
    if not r.get("confirmed"): raise ValueError("Подтвердите действие со службой")
    unit = r["unit"];require_service(unit)
    action = r.get("operation")
    if action not in ["start","stop","restart","reload","enable","disable"]: raise ValueError("Недопустимое действие со службой")
    p = run(["systemctl",action,unit],check=False,timeout=60)
    if p.returncode: raise RuntimeError("systemd не выполнил действие. Проверьте журнал службы")
    recordid="service-"+uuid.uuid4().hex
    write(ROOT / "history" / (recordid+".json"),{"id":recordid,"operation":"service-"+action,"unit":unit,"status":"success","finished":now()})
    return {"done":True,"unit":unit,"operation":action}

def program_journal(r):
    require_admin(); unit=r.get("unit", "")
    services, _ = service_inventory()
    if unit not in [s["unit"] for s in services]: raise ValueError("Неизвестная служба")
    result=run(["journalctl","--no-pager","-o","short-iso","-n","200","-u",unit],check=False)
    if result.returncode: raise RuntimeError("Журнал службы недоступен")
    return {"output":result.stdout}

CRON_ETC = pathlib.Path("/etc")
CRON_SPOOL = pathlib.Path("/var/spool/cron/crontabs")
def parse_cron(text, source, user=None, kind="user"):
    entries=[];environment={}
    for number,line in enumerate(text.splitlines(),1):
        value=line.strip()
        if not value or value.startswith("#"): continue
        setting=re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$",value)
        if setting: environment[setting[1]]=setting[2].strip('"\'');continue
        special=value.startswith("@")
        count=(1 if special else 5)+(0 if user else 1)
        fields=value.split(None,count)
        valid=len(fields)==count+1
        schedule=" ".join(fields[:1 if special else 5]) if valid else "Не распознано"
        account=user or (fields[1 if special else 5] if valid else "—")
        command=fields[-1] if valid else value
        entries.append({"id":hashlib.sha256((source+":"+str(number)).encode()).hexdigest()[:20],"kind":kind,"source":source,"line":number,"schedule":schedule,"user":account,"command":command,"timezone":environment.get("CRON_TZ",environment.get("TZ")),"valid":valid})
    return entries

def cron_target(r):
    kind=r.get('kind','user');user=r.get('user','root')
    if kind=='user':
        if not isinstance(user,str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]*[$]?',user):raise ValueError('Неверное имя пользователя')
        pwd.getpwnam(user)
        return kind,user,None
    source=r.get('source','');path=pathlib.Path(source)
    allowed=path in (CRON_ETC/'crontab',CRON_ETC/'anacrontab') or (path.parent in [CRON_ETC/('cron.'+x) for x in ['d','hourly','daily','weekly','monthly']] and re.fullmatch(r'[A-Za-z0-9_-]+',path.name))
    if not allowed or not path.is_file() or path.is_symlink():raise ValueError('Выберите существующий файл Cron')
    return kind,user,path

def cron_content(kind,user,path):
    if path is not None:
        if path.stat().st_size>1024*1024:raise ValueError('Файл слишком большой')
        return path.read_text()
    result=run(['crontab','-u',user,'-l'],check=False)
    if result.returncode and 'no crontab for' not in result.stderr.lower():raise RuntimeError('Не удалось прочитать crontab: '+result.stderr[-500:])
    return result.stdout if not result.returncode else ''

def cron_read(r):
    require_admin();kind,user,path=cron_target(r);content=cron_content(kind,user,path)
    return {'content':content,'hash':hashlib.sha256(content.encode()).hexdigest(),'source':str(path) if path else 'crontab · '+user}

def validate_cron(content,system=False):
    specials={'@reboot','@yearly','@annually','@monthly','@weekly','@daily','@midnight','@hourly'}
    for number,line in enumerate(content.splitlines(),1):
        value=line.strip()
        if not value or value.startswith('#') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=',value):continue
        fields=value.split(None,(1 if value.startswith('@') else 5)+int(system))
        count=(1 if value.startswith('@') else 5)+int(system)
        if len(fields)!=count+1 or not fields[-1].strip():raise ValueError('Неверное задание, строка '+str(number))
        if value.startswith('@'):
            if fields[0] not in specials:raise ValueError('Неизвестное расписание, строка '+str(number))
        else:
            for index,field in enumerate(fields[:5]):
                maximum=[59,23,31,12,7][index];minimum=1 if index in (2,3) else 0
                for item in field.split(','):
                    match=re.fullmatch(r'(\*|[0-9]+(?:-[0-9]+)?|[A-Za-z]{3}(?:-[A-Za-z]{3})?)(?:/([0-9]+))?',item)
                    if not match or (match[2] and int(match[2])==0):raise ValueError('Неверное расписание, строка '+str(number))
                    base=match[1]
                    if base!='*':
                        names={'JAN':1,'FEB':2,'MAR':3,'APR':4,'MAY':5,'JUN':6,'JUL':7,'AUG':8,'SEP':9,'OCT':10,'NOV':11,'DEC':12} if index==3 else {'SUN':0,'MON':1,'TUE':2,'WED':3,'THU':4,'FRI':5,'SAT':6} if index==4 else {}
                        values=[names.get(x.upper(),-1) if x.isalpha() else int(x) for x in base.split('-')]
                        if any(x<minimum or x>maximum for x in values) or len(values)==2 and values[0]>values[1]:raise ValueError('Неверный диапазон расписания, строка '+str(number))
        if system:pwd.getpwnam(fields[count-1])

def cron_save(r):
    require_admin()
    if r.get('confirmed') is not True:raise ValueError('Подтвердите изменение расписания')
    kind,user,path=cron_target(r);content=r.get('content')
    if not isinstance(content,str) or '\x00' in content or len(content.encode())>1024*1024:raise ValueError('Неверное содержимое Cron')
    if content and not content.endswith('\n'):content+='\n'
    lockdir=ROOT/'cron-locks';lockdir.mkdir(parents=True,exist_ok=True,mode=0o700)
    key=hashlib.sha256((str(path) if path else user).encode()).hexdigest()
    with open(lockdir/key,'a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        current=cron_content(kind,user,path)
        if r.get('hash')!=hashlib.sha256(current.encode()).hexdigest():raise ValueError('Расписание изменилось на сервере. Обновите его перед сохранением')
        if path is None or path==CRON_ETC/'crontab' or path.parent==CRON_ETC/'cron.d':validate_cron(content,path is not None)
        if path==CRON_ETC/'anacrontab':
            for number,line in enumerate(content.splitlines(),1):
                value=line.strip()
                if not value or value.startswith('#') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=',value):continue
                fields=value.split(None,3)
                if len(fields)!=4 or not (fields[0]=='@monthly' or fields[0].isdigit() and int(fields[0])>0) or not fields[1].isdigit():raise ValueError('Неверное задание Anacron, строка '+str(number))
        backupid='cron-'+uuid.uuid4().hex
        write(ROOT/'cron-backups'/(backupid+'.json'),{'source':str(path) if path else user,'content':current,'created':now()})
        if path is None:
            result=run(['crontab','-u',user,'-'],data=content,check=False)
            if result.returncode:raise ValueError('Cron отклонил расписание: '+result.stderr[-1000:])
        else:
            metadata=path.stat();fd,temp=tempfile.mkstemp(dir=path.parent)
            try:
                os.fchmod(fd,stat.S_IMODE(metadata.st_mode));os.fchown(fd,metadata.st_uid,metadata.st_gid)
                with os.fdopen(fd,'w') as file:file.write(content);file.flush();os.fsync(file.fileno())
                os.replace(temp,path)
            finally:
                if os.path.exists(temp):os.unlink(temp)
        write(ROOT/'history'/(backupid+'.json'),{'id':backupid,'operation':'cron-save','source':str(path) if path else 'crontab · '+user,'status':'success','finished':now()})
        return {'saved':True,'backup_id':backupid}

def cron_inventory():
    require_admin(); entries=[];issues=[]
    def load(path,user=None,kind="system"):
        try:
            if path.stat().st_size>1024*1024: raise ValueError("Слишком большой файл")
            entries.extend(parse_cron(path.read_text(),str(path),user,kind))
        except Exception: issues.append("Не удалось прочитать "+str(path))
    main=CRON_ETC/"crontab"
    if main.is_file(): load(main)
    for path in sorted((CRON_ETC/"cron.d").glob("*")):
        if path.is_file() and re.fullmatch(r"[A-Za-z0-9_-]+",path.name): load(path)
    if CRON_SPOOL.exists():
        for path in sorted(CRON_SPOOL.iterdir()):
            if path.is_file() and re.fullmatch(r"[A-Za-z0-9_.-]+",path.name):
                if shutil.which('crontab'):
                    try:entries.extend(parse_cron(cron_content('user',path.name,None),'crontab · '+path.name,path.name,'user'))
                    except Exception:issues.append('Не удалось прочитать crontab пользователя '+path.name)
                else:load(path,path.name,"user")
    elif shutil.which("crontab"):
        for account in pwd.getpwall():
            p=run(["crontab","-u",account.pw_name,"-l"],check=False)
            if p.returncode==0: entries.extend(parse_cron(p.stdout,"crontab · "+account.pw_name,account.pw_name,"user"))
            elif p.returncode!=1: issues.append("Не удалось прочитать crontab пользователя "+account.pw_name)
    for frequency in ["hourly","daily","weekly","monthly"]:
        for path in sorted((CRON_ETC/("cron."+frequency)).glob("*")):
            if path.is_file() and re.fullmatch(r"[A-Za-z0-9_-]+",path.name):
                entries.append({"id":hashlib.sha256(str(path).encode()).hexdigest()[:20],"kind":"periodic","source":str(path.parent),"schedule":"cron."+frequency,"user":"root","command":str(path),"enabled":os.access(path,os.X_OK),"valid":True})
    anacron=CRON_ETC/"anacrontab"
    if anacron.is_file():
        for number,line in enumerate(anacron.read_text().splitlines(),1):
            value=line.strip();fields=value.split(None,3)
            if not value or value.startswith("#") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*=",value): continue
            if len(fields)==4: entries.append({"id":"anacron-"+str(number),"kind":"anacron","source":str(anacron),"line":number,"schedule":(fields[0] if fields[0].startswith("@") else fields[0]+" дней")+" · задержка "+fields[1]+" мин","user":"root","command":fields[3],"name":fields[2],"valid":True})
    timers="";timer_error=""
    if shutil.which("systemctl"):
        p=run(["systemctl","list-timers","--all","--no-pager","--no-legend"],check=False,env={**os.environ,"LC_ALL":"C"})
        if p.returncode==0: timers=p.stdout
        else: timer_error="Таймеры systemd недоступны"
    else: timer_error="systemd не установлен"
    return {"entries":entries,"issues":issues,"timers":timers,"timer_error":timer_error,"updated":now()}

def history_records(limit=1000):
    paths=sorted((ROOT/'history').glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)
    return [redacted(read(p,{})) for p in paths[:limit]]

def parse_time(value):
    try: return datetime.datetime.fromisoformat(value.replace('Z','+00:00')).astimezone(datetime.timezone.utc)
    except (ValueError,AttributeError): return None

def health():
    require_admin(); history=history_records(); jobs=[]; current=datetime.datetime.now(datetime.timezone.utc)
    for path in sorted((ROOT/'jobs').glob('*.json')):
        job=read(path); rows=[r for r in history if r.get('id')==job['id'] and r.get('operation','backup')=='backup' and not r.get('dry_run')]
        good=next((r for r in rows if r.get('status')=='success'),None);last=rows[0] if rows else None
        date=parse_time(good.get('finished')) if good else None
        threshold=int(job.get('stale_hours',26)); age=(current-date).total_seconds()/3600 if date else None
        created=parse_time(job.get('created'));stale=job.get('enabled',True) and ((age is not None and age>threshold) or (date is None and (created is None or (current-created).total_seconds()/3600>threshold)))
        jobs.append({'id':job['id'],'name':job.get('name',job['id']),'repository_id':job['repository_id'],'enabled':job.get('enabled',True),'last_success':good.get('finished') if good else None,'last_status':last.get('status') if last else None,'current_status':read(state_path(job['id']),{}).get('status'),'last_finished':last.get('finished') if last else None,'age_hours':age,'stale':bool(stale),'replication_error':bool(last and last.get('replication_errors')),'maintenance_error':bool(last and last.get('maintenance_error')),'verification':read(ROOT/'verifications'/('job-'+job['id']+'.json'),{})})
    return {'hostname':os.uname().nodename,'updated':now(),'jobs':jobs,'disks':disks(),'configured':bool(jobs),'verification':read(ROOT/'verification-latest.json',{})}

def sample_candidates(nodes,max_files=5,max_bytes=32*1024*1024):
    result=[];total=0
    for node in nodes:
        path=node.get('path','');size=node.get('size',0)
        if node.get('type')!='file' or not isinstance(path,str) or not path.startswith('/') or '..' in pathlib.PurePosixPath(path).parts or '\x00' in path or not isinstance(size,int) or size<0 or size>16*1024*1024: continue
        if total+size>max_bytes:continue
        if path not in [p['path'] for p in result]: result.append({'path':path,'size':size});total+=size
        if len(result)>=max_files:break
    return result

def verify_restore(repo,snapshot='latest',jobid=None):
    info=restic(repo,['snapshots','--json',snapshot],timeout=300)
    if info.returncode:raise RuntimeError('Не удалось найти копию для проверки')
    snapshots=json.loads(info.stdout)
    if len(snapshots)!=1:raise ValueError('Выберите одну конкретную копию')
    snapshot=snapshots[0]['id']; listing=restic(repo,['ls','--json',snapshot],timeout=900)
    if listing.returncode:raise RuntimeError('Не удалось прочитать дерево копии')
    nodes=[json.loads(line) for line in listing.stdout.splitlines() if line.strip()];samples=sample_candidates(nodes)
    if not samples:raise ValueError('В копии нет обычных файлов до 16 МБ для выборочной проверки')
    folder=ROOT/'verification-temp';folder.mkdir(mode=0o700,parents=True,exist_ok=True)
    result={'repository_id':repo['id'],'snapshot':snapshot,'operation':'verify-restore','started':now(),'status':'running','sample_only':True,'files':[]}
    with tempfile.TemporaryDirectory(dir=folder) as tmp:
        required=sum(p['size'] for p in samples)*2+64*1024*1024
        if shutil.disk_usage(tmp).free<required:raise RuntimeError('Недостаточно свободного места для проверки восстановления')
        args=['restore',snapshot,'--target',tmp,'--verify']
        for entry in samples: args+=['--include',re.sub(r'([*?\[\]\\])',r'\\\1',entry['path'])]
        restored=restic(repo,args,timeout=3600)
        if restored.returncode:raise RuntimeError('Restic не подтвердил восстановление и целостность выбранных файлов')
        for entry in samples:
            path=pathlib.Path(tmp)/entry['path'].lstrip('/')
            if path.is_symlink() or not within(path,pathlib.Path(tmp)) or not path.is_file() or path.stat().st_size!=entry['size']:raise RuntimeError('Восстановленный файл отсутствует или отличается по размеру')
            local=hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda:stream.read(1024*1024),b''):local.update(chunk)
            with repository_env(repo) as env, tempfile.TemporaryFile() as output:
                p=subprocess.run(restic_args(env)+['dump',snapshot,entry['path']],env=env,stdout=output,stderr=subprocess.PIPE,timeout=300)
                if p.returncode:raise RuntimeError('Не удалось прочитать исходное содержимое из копии')
                output.seek(0);expected=hashlib.sha256()
                for chunk in iter(lambda:output.read(1024*1024),b''):expected.update(chunk)
            if local.digest()!=expected.digest():raise RuntimeError('Контрольная сумма восстановленного файла отличается')
            result['files'].append({**entry,'sha256':local.hexdigest()})
    result.update(status='success',finished=now());write(ROOT/'verification-latest.json',result)
    if jobid:write(ROOT/'verifications'/('job-'+ident(jobid)+'.json'),result)
    return result

def verification_schedule(r):
    require_admin();install_helper_source();job=config('jobs',r['job_id']);job['verify_restore']=bool(r.get('enabled'));job['verify_full']=bool(r.get('full'));write(ROOT/'jobs'/(job['id']+'.json'),job)
    return {'saved':True,'enabled':job['verify_restore']}

def calendar_data():
    current=datetime.datetime.now().astimezone();rows=[]
    for record in history_records(3000):
        date=parse_time(record.get('finished') or record.get('started'))
        if date and record.get('operation','backup')=='backup' and not record.get('dry_run'):
            rows.append({'id':record.get('id'),'day':date.astimezone().strftime('%Y-%m-%d'),'finished':record.get('finished'),'status':record.get('status'),'repository_id':record.get('repository_id') or read(ROOT/'jobs'/(ident(record['id'])+'.json'),{}).get('repository_id'),'snapshot':(record.get('summary') or {}).get('snapshot_id'),'error':record.get('error'),'maintenance_error':record.get('maintenance_error')})
    return {'records':rows,'timezone':time.tzname,'today':current.strftime('%Y-%m-%d')}

def capacity_forecast(samples,free):
    points=[]
    for item in samples:
        date=parse_time(item.get('time'));size=item.get('bytes')
        if date and isinstance(size,(int,float)) and size>=0:points.append((date,size))
    points.sort(); rate=None;days=None
    if len(points)>=2:
        span=(points[-1][0]-points[0][0]).total_seconds()/86400
        if span>=1/24:rate=(points[-1][1]-points[0][1])/span
        if rate is not None and rate>0 and isinstance(free,(int,float)) and free>=0:days=free/rate
    return {'bytes_per_day':rate,'days_remaining':days,'reason':'Нужно минимум два измерения с интервалом от часа' if rate is None else 'При текущем чистом росте; изменение срока хранения и очистка меняют прогноз'}

def capacity(r):
    require_admin();repo=config('repositories',r['repository_id']);free=None;quota=None;actual=False
    with repo_lock(repo):
        if repo['type']=='disk':
            with repository_env(repo):
                p=run(['du','-sb','--',repo['repository']],check=False,timeout=300)
                if p.returncode:raise RuntimeError('Не удалось измерить размер репозитория')
                size=int(p.stdout.split()[0]);free=shutil.disk_usage(repo['repository']).free;actual=True
        else:
            p=restic(repo,['stats','--mode','raw-data','--json'],timeout=900)
            if p.returncode:raise RuntimeError('Не удалось получить размер репозитория')
            size=json.loads(p.stdout)['total_size']
            if repo['type']=='yandex':
                quota=yandex_check(repo)['quota'];free=quota.get('free')
            elif repo.get('capacity_bytes'):free=max(0,int(repo['capacity_bytes'])-size)
        folder=ROOT/'capacity';folder.mkdir(parents=True,exist_ok=True);file=folder/(ident(repo['id'])+'.json');samples=read(file,[])
        current={'time':now(),'bytes':size};samples.append(current);samples=samples[-365:];write(file,samples)
    return {'warning': 'Свободное место заканчивается' if isinstance(free,(int,float)) and (free<5*1024**3 or (capacity_forecast(samples,free).get('days_remaining') or 999)<7) else None,'repository_id':repo['id'],'samples':samples,'bytes':size,'free':free,'quota':quota,'actual_size':actual,'forecast':capacity_forecast(samples,free),'updated':now()}

def config_versions(r):
    require_admin();unit=r['unit'];require_service(unit);path=r['path']
    if str(pathlib.Path(path).resolve()) not in [str(pathlib.Path(f['path']).resolve()) for f in editable_configs(unit)]:raise ValueError('Файл вне поддерживаемой конфигурации')
    versions=[]
    for file in sorted((ROOT/'program-backups').glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True):
        item=read(file,{})
        if item.get('unit')==unit and item.get('path')==path:versions.append({'id':file.stem,'time':item.get('time'),'exists':item.get('exists'), 'hash':hashlib.sha256(base64.b64decode(item.get('data',''))).hexdigest()})
    return {'versions':versions[:100]}

def config_version(r):
    config_versions(r);item=config('program-backups',r['version_id'])
    if item.get('unit')!=r['unit'] or item.get('path')!=r['path']:raise ValueError('Версия относится к другому файлу')
    if not item.get('exists'):raise ValueError('Эта версия обозначает отсутствие файла')
    return {'content':base64.b64decode(item['data']).decode('utf-8')}

def rollback_config(r):
    if not r.get('confirmed'):raise ValueError('Подтвердите возврат конфигурации')
    previous=config_version(r);return save_program_config({**r,'content':previous['content']})

def install_helper_source():
    src=helper_source()
    if not src:raise RuntimeError('Отсутствует исходный код помощника')
    target=pathlib.Path(HELPER);target.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=target.parent)
    try:
        os.fchmod(fd,0o700)
        with os.fdopen(fd,'w') as output:output.write(src)
        os.replace(tmp,target)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def external_key():
    require_admin();folder=ROOT/'external';folder.mkdir(parents=True,exist_ok=True,mode=0o700);key=folder/'id_ed25519'
    if not key.exists():run(['ssh-keygen','-t','ed25519','-N','','-f',str(key),'-C','server-backup-monitor'])
    key.chmod(0o600);return {'public_key':pathlib.Path(str(key)+'.pub').read_text().strip()}

def allow_monitor(r):
    require_admin()
    if not r.get('confirmed'):raise ValueError('Подтвердите доступ наблюдателя')
    user=r['user'];account=pwd.getpwnam(user);key=r['public_key'].strip()
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]+)?',key):raise ValueError('Неверный ключ наблюдателя')
    install_helper_source()
    command=('/usr/bin/python3 '+HELPER+' --health') if account.pw_uid==0 else ('sudo -n /usr/bin/python3 '+HELPER+' --health')
    restriction='restrict,command="'+command+'" '
    folder=pathlib.Path(account.pw_dir)/'.ssh';folder.mkdir(mode=0o700,exist_ok=True);folder.chmod(0o700);os.chown(folder,account.pw_uid,account.pw_gid)
    file=folder/'authorized_keys';data=file.read_text() if file.exists() else '';bare=' '.join(key.split()[:2])
    if any(bare in line and not line.startswith(restriction) for line in data.splitlines()):raise ValueError('Этот ключ уже установлен с другими правами; проверьте authorized_keys')
    if not any(bare in line for line in data.splitlines()):
        with file.open('a') as output:output.write(('\n' if data and not data.endswith('\n') else '')+restriction+key+'\n')
    file.chmod(0o600);os.chown(file,account.pw_uid,account.pw_gid)
    return {'authorized':True,'restricted':True}

def external_setup(r):
    require_admin()
    if not r.get('confirmed'):raise ValueError('Подтвердите внешний контроль')
    targets=r.get('targets',[])
    if r.get('enabled',True) and not targets:raise ValueError('Выберите хотя бы один сервер для наблюдения')
    if len(targets)>100:raise ValueError('Максимум 100 серверов')
    external_key();install_helper_source();known=[];clean=[]
    for target in targets:
        ident(target['id'])
        if not re.fullmatch(r'[A-Za-z0-9.:-]+',target['host']) or not re.fullmatch(r'[A-Za-z0-9_.-]+',target['user']) or not 1<=int(target['port'])<=65535:raise ValueError('Неверный SSH-профиль наблюдаемого сервера')
        entries=target.get('known_hosts','').strip().splitlines();expected=target['host'] if int(target['port'])==22 else '['+target['host']+']:'+str(target['port'])
        if not entries or any(len(line.split())<3 or expected not in line.split()[0].split(',') or line.split()[1] not in ['ssh-ed25519','ssh-rsa','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521'] for line in entries):raise ValueError('Не подтверждён SSH-ключ '+target['host'])
        known+=entries;clean.append({k:target[k] for k in ['id','name','host','port','user']})
    folder=ROOT/'external';file=folder/'known_hosts';file.write_text('\n'.join(known)+'\n');file.chmod(0o600);write(folder/'settings.json',{'targets':clean,'enabled':bool(r.get('enabled',True))})
    unit('server-backup-external','[Unit]\nDescription=Server Backup external monitor\nWants=network-online.target\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 '+HELPER+' --external-watchdog\nTimeoutStartSec=3600\n')
    unit('server-backup-external','[Timer]\nOnBootSec=2m\nOnUnitActiveSec=10m\nPersistent=true\n[Install]\nWantedBy=timers.target\n','timer');run(['systemctl','daemon-reload'])
    run(['systemctl','enable' if r.get('enabled',True) else 'disable','--now','server-backup-external.timer'])
    return {'saved':True,'targets':len(clean)}

def external_watchdog(on_progress=None):
    require_admin();folder=ROOT/'external';settings=read(folder/'settings.json',{})
    if not settings.get('enabled'):raise ValueError('Внешний контроль выключен. Сначала сохраните настройку наблюдателя')
    if not settings.get('targets'):raise ValueError('Нет наблюдаемых серверов. Сначала выберите серверы и настройте контроль')
    lockfile=folder/'watchdog.lock';results=[]
    with lockfile.open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for target in settings.get('targets',[]):
            if on_progress: on_progress(target['name'],len(results),len(settings.get('targets',[])))
            previous=read(folder/('state-'+ident(target['id'])+'.json'),{});issue=None;response=None
            try:
                args=['ssh','-n','-T','-p',str(target['port']),'-i',str(folder/'id_ed25519'),'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(folder/'known_hosts'),'-o','ConnectTimeout=15','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2',target['user']+'@'+target['host']]
                p=run(args,check=False,timeout=45)
                if p.returncode:
                    detail=p.stderr.lower()
                    if 'host key verification failed' in detail or 'remote host identification has changed' in detail:issue='SSH-ключ сервера не совпадает. Подтвердите ключ в приложении и настройте контроль заново'
                    elif 'permission denied' in detail:issue='SSH-доступ наблюдателя отклонён. Повторите настройку ограниченного ключа'
                    elif 'connection refused' in detail:issue='Сервер отклонил подключение. Проверьте SSH-порт и службу SSH'
                    elif 'timed out' in detail or 'no route to host' in detail:issue='Нет связи с сервером. Проверьте сеть и firewall'
                    else:issue='Сервер не выполнил запрос состояния (код '+str(p.returncode)+')'
                else:
                    envelope=json.loads(p.stdout)
                    if not envelope.get('ok'):raise ValueError('Помощник сервера: '+str(envelope.get('error','ошибка проверки')))
                    response=envelope['result'];bad=[j['id'] for j in response['jobs'] if j.get('enabled') and (j.get('stale') or j.get('last_status') in ['failed','incomplete'] or j.get('maintenance_error') or j.get('verification',{}).get('status')=='failed')]
                    if bad:issue='Требуют внимания задания: '+', '.join(bad)
                    elif not response.get('jobs'):issue='На сервере не настроены задания резервного копирования'
            except subprocess.TimeoutExpired:issue='Сервер не ответил на проверку за 45 секунд'
            except Exception as error:issue='Не удалось получить состояние сервера: '+str(error)[:350]
            state={'id':target['id'],'name':target['name'],'updated':now(),'issue':issue,'health':response};results.append(state);write(folder/('state-'+target['id']+'.json'),state)
            last=parse_time(previous.get('notified'));current=datetime.datetime.now(datetime.timezone.utc)
            if issue and (previous.get('issue')!=issue or not last or (current-last).total_seconds()>21600):
                state['notification']=notify('Server Backup · '+target['name']+'\n'+issue)
                if state['notification'].get('sent'):state['notified']=now()
                write(folder/('state-'+target['id']+'.json'),state)
            elif issue and previous.get('notified'):state['notified']=previous['notified'];write(folder/('state-'+target['id']+'.json'),state)
            elif previous.get('issue') and not issue:
                state['notification']=notify('Server Backup · '+target['name']+'\nСостояние восстановлено');write(folder/('state-'+target['id']+'.json'),state)
    return {'updated':now(),'servers':results}

def activity_status(command,repository_id=None):
    values=[read(p,{}) for p in (ROOT/'states').glob('*.json')]
    values=[v for v in values if v.get('operation')==command and (repository_id is None or v.get('repository_id')==repository_id)]
    values.sort(key=lambda v:v.get('started',''),reverse=True)
    active=next((v for v in values if v.get('status') in ('running','queued','waiting')),None)
    # A recently launched unit may not yet have written its first state.
    if active is None:
        for p in (ROOT/'operations').glob('op-*.json'):
            req=read(p,{})
            if req.get('command')==command and (repository_id is None or req.get('repository_id')==repository_id) and not state_path(p.stem).exists():
                check=run(['systemctl','is-active','server-backup-'+p.stem+'.service'],check=False)
                if check.stdout.strip() in ('active','activating'):active={'id':p.stem,'status':'queued'};break
    latest=next((v for v in values if v.get('status')=='success'),{})
    try:data=json.loads(latest.get('output','{}'))
    except (ValueError,TypeError):data={}
    return {'active':active,'data':data}

def external_status():
    require_admin();folder=ROOT/'external'
    timer=run(['systemctl','show','server-backup-external.timer','--property=ActiveState,NextElapseUSecRealtime','--no-pager'],check=False)
    properties=dict(line.split('=',1) for line in timer.stdout.splitlines() if '=' in line)
    settings=read(folder/'settings.json',{});ids={x['id'] for x in settings.get('targets',[])}
    return {'settings':settings,'states':[value for value in (read(p) for p in folder.glob('state-*.json')) if value.get('id') in ids],'timer':properties,**activity_status('external-test')}

FILE_LIMIT=2*1024**3
TEXT_LIMIT=1024**2

def file_path(value,write_access=False):
    if not isinstance(value,str) or not value.startswith('/') or '\0' in value:raise ValueError('Нужен абсолютный путь без NUL')
    path=pathlib.Path(value).resolve()
    if any(within(path,pathlib.Path(p)) for p in ['/proc','/sys','/dev']):raise ValueError('Виртуальная файловая система недоступна в файловом менеджере')
    if write_access:
        require_admin()
        if path==pathlib.Path('/') or any(within(path,pathlib.Path(p)) for p in ['/proc','/sys','/dev',str(ROOT),str(pathlib.Path(HELPER).parent)]):raise ValueError('Изменение этого пути через файловый менеджер запрещено')
    return path

def file_hash(path):
    if not path.exists():return 'absent'
    if not path.is_file() or path.stat().st_size>FILE_LIMIT:raise ValueError('Нужен обычный файл до 2 ГБ')
    digest=hashlib.sha256()
    with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):raise ValueError('Нужен обычный файл')
        for chunk in iter(lambda:source.read(1024**2),b''):digest.update(chunk)
    return digest.hexdigest()

def files_list(r):
    path=file_path(r.get('path','/'))
    if not path.is_dir():raise ValueError('Нужен каталог')
    offset=r.get('offset',0)
    if not isinstance(offset,int) or offset<0:raise ValueError('Неверная страница каталога')
    entries=[]
    with os.scandir(path) as listing:
        for item in listing:
            try:
                info=item.stat(follow_symlinks=False)
                entries.append({'name':item.name,'path':str(path/item.name),'directory':item.is_dir(),'symlink':item.is_symlink(),'size':info.st_size,'mode':format(stat.S_IMODE(info.st_mode),'04o'),'uid':info.st_uid,'gid':info.st_gid,'modified':datetime.datetime.fromtimestamp(info.st_mtime,datetime.timezone.utc).isoformat()})
            except (PermissionError,FileNotFoundError):continue
    entries.sort(key=lambda p:(not p['directory'],p['name']))
    return {'path':str(path),'entries':entries[offset:offset+500],'has_more':offset+500<len(entries),'offset':offset,'total':len(entries)}

def files_stat(r):
    path=file_path(r['path'])
    return {'path':str(path),'exists':path.exists(),'directory':path.is_dir(),'hash':None if path.is_dir() else file_hash(path),'size':path.stat().st_size if path.exists() else 0}

def files_read(r):
    path=file_path(r['path'])
    if path.exists() and (not path.is_file() or path.stat().st_size>TEXT_LIMIT):raise ValueError('Редактор поддерживает текстовые файлы до 1 МБ. Используйте скачивание.')
    data=b''
    if path.exists():
        with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):raise ValueError('Нужен обычный файл')
            data=source.read(TEXT_LIMIT+1)
        if len(data)>TEXT_LIMIT:raise ValueError('Редактор поддерживает файлы до 1 МБ')
    if b'\0' in data:raise ValueError('Бинарный файл нельзя открыть в текстовом редакторе')
    try:content=data.decode('utf-8')
    except UnicodeDecodeError:raise ValueError('Редактор поддерживает UTF-8. Скачайте файл для другого кодирования.')
    services,_=service_inventory();unit=None
    for service in services:
        if service.get('manageable') and str(path) in [f['path'] for f in editable_configs(service['unit'])]:unit=service['unit'];break
    return {'path':str(path),'content':content,'hash':hashlib.sha256(data).hexdigest() if path.exists() else 'absent','mode':format(stat.S_IMODE(path.stat().st_mode),'04o') if path.exists() else '0644','unit':unit}

def file_backup(path):
    version='file-'+uuid.uuid4().hex;folder=ROOT/'file-versions';folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    info=path.stat() if path.exists() else None
    if info:
        if shutil.disk_usage(folder).free<info.st_size+16*1024**2:raise RuntimeError('Недостаточно места для предыдущей версии файла')
        target=folder/(version+'.data')
        with path.open('rb') as source,os.fdopen(os.open(target,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600),'wb') as output:shutil.copyfileobj(source,output,1024**2)
    write(folder/(version+'.json'),{'id':version,'path':str(path),'time':now(),'exists':info is not None,'mode':stat.S_IMODE(info.st_mode) if info else 0o644,'uid':info.st_uid if info else 0,'gid':info.st_gid if info else 0})
    return version

def files_write(r):
    path=file_path(r['path'],True)
    if not r.get('confirmed'):raise ValueError('Подтвердите сохранение файла')
    content=r.get('content')
    if not isinstance(content,str) or len(content.encode())>TEXT_LIMIT or '\0' in content:raise ValueError('Нужен текст UTF-8 до 1 МБ')
    if not path.parent.is_dir():raise ValueError('Родительский каталог не существует')
    with repo_lock({'repository':'file:'+str(path)}):
        if file_hash(path)!=r.get('hash'):raise ValueError('Файл изменён на сервере. Загрузите его заново.')
        # Reuse syntax validation for known service configurations.
        services,_=service_inventory()
        for service in services:
            if service.get('manageable') and str(path) in [f['path'] for f in editable_configs(service['unit'])]:return save_program_config({**r,'hash':hashlib.sha256(b'').hexdigest() if r.get('hash')=='absent' else r['hash'],'path':str(path),'unit':service['unit']})
        version=file_backup(path);metadata=path.stat() if path.exists() else None
        replace_program_file(path,content.encode(),metadata)
        return {'hash':file_hash(path),'version_id':version,'syntax_checked':False,'restart_required':False}

def files_versions(r):
    path=file_path(r['path']);result=[]
    for meta in (ROOT/'file-versions').glob('*.json'):
        record=read(meta)
        if record.get('path')==str(path):result.append(record)
    return {'versions':sorted(result,key=lambda r:r['time'],reverse=True)[:100]}

def files_version(r):
    path=file_path(r['path']);version=ident(r['version_id']);meta=read(ROOT/'file-versions'/(version+'.json'))
    if not meta or meta['path']!=str(path):raise ValueError('Версия относится к другому файлу')
    saved=ROOT/'file-versions'/(version+'.data')
    if meta['exists'] and saved.stat().st_size>TEXT_LIMIT:raise ValueError('Версия больше 1 МБ; используйте отдельный SSH-клиент')
    data=saved.read_bytes() if meta['exists'] else b''
    if len(data)>TEXT_LIMIT or b'\0' in data:raise ValueError('Скачайте предыдущую версию: она не поддерживается текстовым редактором')
    return {**meta,'content':data.decode('utf-8')}

def files_rollback(r):
    record=files_version(r)
    if not record['exists']:raise ValueError('В этой версии файла не было. Используйте перенос в корзину.')
    return files_write({**r,'content':record['content']})

def files_mkdir(r):
    path=file_path(r['path'],True)
    if not r.get('confirmed'):raise ValueError('Подтвердите создание каталога')
    path.mkdir(mode=0o755);return {'created':str(path)}

def files_rename(r):
    if pathlib.Path(r['path']).is_symlink():raise ValueError('Переименование ссылки через приложение запрещено')
    source=file_path(r['path'],True);destination=file_path(r['destination'],True)
    if within(ROOT,source) or within(pathlib.Path(HELPER),source):raise ValueError('Каталог содержит состояние приложения')
    if not r.get('confirmed'):raise ValueError('Подтвердите переименование')
    if destination.exists() or destination.is_symlink():raise ValueError('Путь назначения уже существует')
    source.rename(destination);return {'path':str(destination)}

def files_move(r):
    if not r.get('confirmed'):raise ValueError('Подтвердите перенос')
    if pathlib.Path(r['path']).is_symlink():raise ValueError('Перенос ссылки запрещён')
    source=file_path(r['path'],True);destination=file_path(r['destination'],True)
    if source==destination or within(destination,source):raise ValueError('Нельзя перенести каталог внутрь себя')
    if within(ROOT,source) or within(pathlib.Path(HELPER),source):raise ValueError('Каталог содержит состояние приложения')
    if destination.exists() or destination.is_symlink():raise ValueError('Путь назначения уже существует; перезапись не выполняется')
    if source.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError('Перенос между файловыми системами не поддерживается: сначала скопируйте и проверьте данные отдельно')
    source.rename(destination);return {'path':str(destination)}

def files_chmod(r):
    if not r.get('confirmed'):raise ValueError('Подтвердите изменение прав')
    if pathlib.Path(r['path']).is_symlink():raise ValueError('Изменение прав ссылки запрещено')
    path=file_path(r['path'],True);mode=r.get('mode','')
    if not isinstance(mode,str) or not re.fullmatch(r'0?[0-7]{3}',mode):raise ValueError('Укажите права от 000 до 777, например 644 или 755')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        old=stat.S_IMODE(os.fstat(fd).st_mode);os.fchmod(fd,int(mode,8))
    finally:os.close(fd)
    return {'path':str(path),'previous_mode':format(old,'04o'),'mode':format(int(mode,8),'04o')}

def files_ensure_directory(r):
    if not r.get('confirmed'):raise ValueError('Подтвердите создание каталога')
    if pathlib.Path(r['path']).is_symlink():raise ValueError('Каталог назначения является ссылкой')
    path=file_path(r['path'],True);path.mkdir(mode=0o755,exist_ok=True)
    return {'path':str(path)}

def files_trash(r):
    requested=pathlib.Path(r['path'])
    if requested.is_symlink():raise ValueError('Для ссылки используйте отдельный SSH-клиент; цель ссылки не переносится в корзину')
    path=file_path(r['path'],True)
    if not r.get('confirmed'):raise ValueError('Подтвердите перенос в корзину')
    if within(ROOT,path) or path==pathlib.Path(HELPER).parent.parent:raise ValueError('Каталог содержит состояние приложения')
    folder=path.parent/'.server-backup-trash'
    if folder.is_symlink():raise ValueError('Каталог корзины является ссылкой')
    folder.mkdir(mode=0o700,exist_ok=True);folder.chmod(0o700)
    key='trash-'+uuid.uuid4().hex;target=folder/key
    # Record first; if the process is interrupted after rename, undo remains available.
    write(ROOT/'file-trash'/(key+'.json'),{'id':key,'path':str(path),'trash':str(target),'time':now()})
    path.rename(target);return {'id':key,'path':str(path),'recoverable':True}

def files_trash_list():
    require_admin();return {'items':[r for p in (ROOT/'file-trash').glob('*.json') if (r:=read(p)) and pathlib.Path(r['trash']).exists()]}

def files_untrash(r):
    require_admin()
    if not r.get('confirmed'):raise ValueError('Подтвердите возврат из корзины')
    key=ident(r['id']);meta=read(ROOT/'file-trash'/(key+'.json'))
    if not meta:raise ValueError('Запись корзины отсутствует')
    path=file_path(meta['path'],True);target=pathlib.Path(meta['trash'])
    if path.exists() or path.is_symlink():raise ValueError('Исходный путь уже занят')
    if target.parent!=path.parent/'.server-backup-trash' or target.name!=key or target.parent.is_symlink():raise ValueError('Неверная запись корзины')
    target.rename(path);(ROOT/'file-trash'/(key+'.json')).unlink();return {'restored':str(path)}

def cleanup_uploads():
    for meta in (ROOT/'file-transfers').glob('*.json'):
        record=read(meta);created=parse_time(record.get('created'))
        if created and (datetime.datetime.now(datetime.timezone.utc)-created).total_seconds()>86400:
            try:upload_abort({'id':record['id']})
            except (ValueError,OSError):pass

def upload_begin(r):
    cleanup_uploads();path=file_path(r['path'],True);size=r.get('size')
    if not r.get('confirmed'):raise ValueError('Подтвердите загрузку файла')
    if not isinstance(size,int) or not 0<=size<=FILE_LIMIT:raise ValueError('Максимальный размер загрузки — 2 ГБ')
    if not path.parent.is_dir():raise ValueError('Каталог назначения не существует')
    if file_hash(path)!=r.get('hash'):raise ValueError('Файл изменён; подтвердите перезапись заново')
    if shutil.disk_usage(path.parent).free<size+16*1024**2:raise ValueError('Недостаточно свободного места')
    key='upload-'+uuid.uuid4().hex;tmp=path.parent/('.server-backup-'+key)
    fd=os.open(tmp,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd)
    write(ROOT/'file-transfers'/(key+'.json'),{'id':key,'path':str(path),'temporary':str(tmp),'size':size,'hash':r['hash'],'created':now()})
    return {'id':key}

def upload_record(r):
    require_admin();key=ident(r['id']);record=read(ROOT/'file-transfers'/(key+'.json'))
    if not record:raise ValueError('Загрузка не найдена')
    path=file_path(record['path'],True);tmp=pathlib.Path(record['temporary'])
    if tmp.parent!=path.parent or tmp.name!='.server-backup-'+key:raise ValueError('Неверный временный файл')
    return key,record,tmp,path

def upload_chunk(r):
    key,record,tmp,path=upload_record(r)
    if not isinstance(r.get('data'),str) or len(r['data'])>1_400_000:raise ValueError('Неверный размер блока')
    data=base64.b64decode(r['data'],validate=True)
    if len(data)>1024**2:raise ValueError('Блок больше 1 МБ')
    with repo_lock({'repository':'upload:'+key}),os.fdopen(os.open(tmp,os.O_WRONLY|os.O_NOFOLLOW),'r+b') as file:
        file.seek(0,os.SEEK_END);offset=file.tell()
        if offset!=r.get('offset') or offset+len(data)>record['size']:raise ValueError('Неверная позиция блока')
        file.write(data)
    return {'received':offset+len(data)}

def upload_abort(r):
    key,record,tmp,path=upload_record(r);tmp.unlink(missing_ok=True);(ROOT/'file-transfers'/(key+'.json')).unlink();return {'aborted':True}

def upload_commit(r):
    key,record,tmp,path=upload_record(r)
    with repo_lock({'repository':'file:'+str(path)}):
        if tmp.is_symlink() or tmp.stat().st_size!=record['size'] or file_hash(tmp)!=r.get('sha256'):raise ValueError('Размер или SHA-256 загруженного файла не совпал')
        if file_hash(path)!=record['hash']:raise ValueError('Файл изменён во время загрузки. Перезапись отменена.')
        # Generic uploads never overwrite supported service configs without their validator.
        services,_=service_inventory()
        for service in services:
            if service.get('manageable') and str(path) in [f['path'] for f in editable_configs(service['unit'])]:raise ValueError('Для конфигурации службы используйте текстовый редактор с проверкой синтаксиса')
        version=file_backup(path)
        if path.exists():metadata=path.stat();tmp.chmod(stat.S_IMODE(metadata.st_mode));os.chown(tmp,metadata.st_uid,metadata.st_gid)
        else:tmp.chmod(0o644)
        with tmp.open('rb') as file:os.fsync(file.fileno())
        os.replace(tmp,path);(ROOT/'file-transfers'/(key+'.json')).unlink()
        return {'path':str(path),'sha256':r['sha256'],'version_id':version}

def files_download(r):
    path=file_path(r['path'])
    if not path.is_file():raise ValueError('Нужен обычный файл')
    with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK),'rb') as file:
        info=os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size>FILE_LIMIT:raise ValueError('Скачивание поддерживает обычные файлы до 2 ГБ')
        stream_emit('file_start',{'size':info.st_size,'path':str(path)});digest=hashlib.sha256();size=0
        for data in iter(lambda:file.read(1024**2),b''):
            size+=len(data)
            if size>FILE_LIMIT:raise ValueError('Файл превысил лимит скачивания')
            digest.update(data);stream_emit('file_data',{'data':base64.b64encode(data).decode(),'offset':size-len(data)})
        current=os.fstat(file.fileno())
        if size!=info.st_size or current.st_mtime_ns!=info.st_mtime_ns:raise ValueError('Файл изменился во время скачивания; повторите загрузку')
        stream_emit('file_end',{'sha256':digest.hexdigest(),'size':size})
    return {'downloaded':True}


# Snapshot metadata is immutable. Index once on the server, then return bounded pages.
def snapshot_nodes(repo, snapshot):
    import threading
    with repository_env(repo) as env, tempfile.TemporaryFile() as errors:
        process=subprocess.Popen(restic_args(env)+['ls','--json',snapshot],env=env,stdout=subprocess.PIPE,stderr=errors,text=True,encoding='utf-8')
        timer=threading.Timer(900,process.kill);timer.daemon=True;timer.start()
        try:
            for line in process.stdout:
                if line.strip():
                    node=json.loads(line)
                    if isinstance(node,dict) and isinstance(node.get('path'),str):yield node
            code=process.wait()
            if code:
                errors.seek(0,os.SEEK_END);errors.seek(max(0,errors.tell()-1500));raise RuntimeError('Не удалось прочитать файлы копии: '+errors.read()[-1500:].decode('utf-8','replace'))
        finally:
            timer.cancel()
            if process.poll() is None:process.kill();process.wait()
            process.stdout.close()

def build_snapshot_index(repo, snapshot, destination):
    import sqlite3
    fd,temp=tempfile.mkstemp(dir=destination.parent,suffix='.tmp');os.fchmod(fd,0o600);os.close(fd)
    db=sqlite3.connect(temp)
    try:
        db.execute('CREATE TABLE nodes(path TEXT PRIMARY KEY,parent TEXT,name TEXT,sort_name TEXT,folder INTEGER,size INTEGER,payload TEXT,search_path TEXT)')
        for node in snapshot_nodes(repo,snapshot):
            node={key:value for key,value in node.items() if key in {'path','type','size','mtime','atime','ctime','mode','uid','gid','user','group','linktarget','inode','device_id','links'}}
            path=node['path']
            if not path.startswith('/') or '\x00' in path or '..' in pathlib.PurePosixPath(path).parts:continue
            path=str(pathlib.PurePosixPath(path));node['path']=path
            if path=='/':continue
            parent=str(pathlib.PurePosixPath(path).parent);name=pathlib.PurePosixPath(path).name
            size=node.get('size');size=size if isinstance(size,int) and size>=0 else None
            db.execute('INSERT OR REPLACE INTO nodes VALUES(?,?,?,?,?,?,?,?)',(path,parent,name,name.casefold(),int(node.get('type')=='dir'),size,json.dumps(node,ensure_ascii=False),path.casefold()))
            while parent!='/':
                p=pathlib.PurePosixPath(parent);virtual={'path':parent,'type':'dir','synthetic':True}
                db.execute('INSERT OR IGNORE INTO nodes VALUES(?,?,?,?,?,?,?,?)',(parent,str(p.parent),p.name,p.name.casefold(),1,None,json.dumps(virtual,ensure_ascii=False),parent.casefold()))
                parent=str(p.parent)
        db.execute('CREATE INDEX parent_order ON nodes(parent,folder DESC,sort_name,path)')
        totals=db.execute("SELECT COALESCE(SUM(size),0),COUNT(*) FROM nodes WHERE json_extract(payload,'$.type')='file'").fetchone()
        db.execute('CREATE TABLE metadata(size INTEGER,files INTEGER)');db.execute('INSERT INTO metadata VALUES(?,?)',totals)
        db.commit();db.close();os.replace(temp,destination)
    finally:
        db.close()
        if os.path.exists(temp):os.unlink(temp)

def snapshot_files(r):
    import sqlite3
    require_admin();repo=config('repositories',r['repository_id']);snapshot=r.get('snapshot','latest')
    if not isinstance(snapshot,str) or not (snapshot=='latest' or re.fullmatch('[a-fA-F0-9]{4,64}',snapshot)):raise ValueError('Неверный ID копии')
    if not re.fullmatch('[a-fA-F0-9]{64}',snapshot):
        found=restic(repo,['snapshots','--json',snapshot],timeout=300)
        if found.returncode:raise RuntimeError('Не удалось найти копию')
        values=json.loads(found.stdout)
        if len(values)!=1:raise ValueError('Выберите одну конкретную копию')
        snapshot=values[0]['id']
        if not re.fullmatch('[a-fA-F0-9]{64}',snapshot):raise ValueError('Неверный ID найденной копии')
    snapshot=snapshot.lower();path=r.get('path','/');query=r.get('query','')
    if not isinstance(path,str) or not path.startswith('/') or '\x00' in path or '..' in pathlib.PurePosixPath(path).parts:raise ValueError('Неверный путь')
    path=str(pathlib.PurePosixPath(path))
    if not isinstance(query,str) or len(query)>500 or '\x00' in query:raise ValueError('Неверный поиск')
    offset=max(0,int(r.get('offset',0)));limit=min(500,max(1,int(r.get('limit',250))))
    cache=ROOT/'snapshot-index'/hashlib.sha256(repo['repository'].encode()).hexdigest()[:24];cache.mkdir(mode=0o700,parents=True,exist_ok=True)
    database=cache/(snapshot+'.sqlite')
    with open(cache/(snapshot+'.lock'),'a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        if not database.exists():
            build_snapshot_index(repo,snapshot,database)
            # Retain three indexes per repository; all can be rebuilt from Restic.
            others=sorted(cache.glob('*.sqlite'),key=lambda p:p.stat().st_mtime,reverse=True)
            for old in others[3:]:
                with open(old.with_suffix('.lock'),'a') as old_lock:
                    try:fcntl.flock(old_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    except BlockingIOError:continue
                    old.unlink(missing_ok=True)
        def pattern(text):return text.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')
        where='parent=?';params=[path]
        if query:
            where="search_path LIKE ? ESCAPE '\\'";params=['%'+pattern(query.casefold())+'%']
            if path!='/':prefix=path.rstrip('/')+'/';where+=" AND substr(path,1,?)=?";params.extend([len(prefix),prefix])
        with sqlite3.connect(database) as db:
            total=db.execute('SELECT COUNT(*) FROM nodes WHERE '+where,params).fetchone()[0]
            rows=db.execute('SELECT payload FROM nodes WHERE '+where+' ORDER BY folder DESC,sort_name,path LIMIT ? OFFSET ?',params+[limit,offset]).fetchall()
            size,files=db.execute('SELECT size,files FROM metadata').fetchone()
        return {'snapshot':snapshot,'path':path,'entries':[json.loads(row[0]) for row in rows],'total':total,'offset':offset,'limit':limit,'has_more':offset+len(rows)<total,'summary':{'total_size':size,'total_file_count':files}}

def snapshot_compare(r):
    # Compare one directory at a time: never restore data or follow directory symlinks.
    page=snapshot_files({**r,'query':'','offset':0,'limit':500});directory=page['path']
    target=r.get('target',directory)
    if not isinstance(target,str) or not target.startswith('/') or '\x00' in target or '..' in pathlib.PurePosixPath(target).parts:raise ValueError('Неверный каталог сервера')
    target=str(pathlib.PurePosixPath(target));saved={}
    for offset in range(0,page['total'],500):
        batch=page if offset==0 else snapshot_files({**r,'snapshot':page['snapshot'],'query':'','offset':offset,'limit':500})
        for node in batch['entries']:saved[pathlib.PurePosixPath(node['path']).name]=node
    live={};directory_error=None
    try:
        if not stat.S_ISDIR(os.lstat(target).st_mode):raise ValueError('Назначение должно быть каталогом, а не ссылкой или файлом')
        with os.scandir(target) as items:
            for item in items:live[item.name]=item.path
    except FileNotFoundError:pass
    except (PermissionError,OSError) as error:directory_error=str(error)
    if directory_error:raise ValueError('Каталог недоступен: '+directory_error)
    rows=[];counts={}
    for name in sorted(saved.keys()|live.keys(),key=str.casefold):
        node=saved.get(name);status='server_only' if node is None else 'missing' if name not in live else 'same_metadata';reason=[];folder=bool(node and node.get('type')=='dir')
        if name in live:
            try:
                info=os.lstat(live[name]);kind='dir' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else 'symlink' if stat.S_ISLNK(info.st_mode) else 'other';folder=kind=='dir'
                if node:
                    if kind!=node.get('type'):reason.append('Тип')
                    if kind=='file':
                        if info.st_size!=node.get('size'):reason.append('Размер')
                        date=parse_time(node.get('mtime'))
                        if date is None or abs(date.timestamp()-info.st_mtime)>0.00001:reason.append('Время изменения')
                    if not node.get('synthetic'):
                        if stat.S_IMODE(info.st_mode)!=(node.get('mode',0)&0o7777):reason.append('Права')
                        if info.st_uid!=node.get('uid') or info.st_gid!=node.get('gid'):reason.append('Владелец')
                    if kind=='symlink' and os.readlink(live[name])!=node.get('linktarget'):reason.append('Цель ссылки')
                    if reason:status='changed'
            except (OSError,ValueError) as error:status='unavailable';reason=[str(error)]
        counts[status]=counts.get(status,0)+1
        rows.append({'path':str(pathlib.PurePosixPath(directory)/name),'target':str(pathlib.PurePosixPath(target)/name),'name':name,'folder':folder,'snapshot_folder':bool(node and node.get('type')=='dir'),'status':status,'reason':', '.join(reason)})
    offset=max(0,int(r.get('offset',0)));limit=min(500,max(1,int(r.get('limit',250))));only=r.get('differences',False)
    if only:rows=[x for x in rows if x['status']!='same_metadata']
    return {'entries':rows[offset:offset+limit],'total':len(rows),'counts':counts,'path':directory,'target':target,'offset':offset,'limit':limit,'updated':now(),'method':'metadata'}

def dispatch(r):
    a = r["action"]
    if a == "stream":return stream(r)
    if a in ('job_toggle','job_duplicate'):return job_manage(r)
    if a == 'job_versions':return job_versions(r)
    if a == 'error_center':return error_center()
    if a == 'snapshot_file_history':return snapshot_file_history(r)
    if a == 'snapshot_content':return snapshot_content(r)
    file_actions={'files_list':files_list,'files_stat':files_stat,'files_read':files_read,'files_write':files_write,'files_versions':files_versions,'files_version':files_version,'files_rollback':files_rollback,'files_mkdir':files_mkdir,'files_rename':files_rename,'files_move':files_move,'files_chmod':files_chmod,'files_ensure_directory':files_ensure_directory,'files_trash':files_trash,'files_untrash':files_untrash,'upload_begin':upload_begin,'upload_chunk':upload_chunk,'upload_commit':upload_commit,'upload_abort':upload_abort,'files_download':files_download}
    if a in file_actions:return file_actions[a](r)
    if a=='files_trash_list':return files_trash_list()
    if a == "verification_results": return {"records":[r for r in history_records() if r.get("operation")=="verify-restore"]+[read(p) for p in (ROOT/"verifications").glob("*.json")]}
    if a == "health": return health()
    if a == "fleet_health":
        value=health()
        try:value["metrics"]=metrics(light=True)
        except Exception:value["metrics_error"]="Метрики временно недоступны"
        return value
    if a == "calendar": return calendar_data()
    if a == "snapshot_files": return snapshot_files(r)
    if a == "snapshot_compare": return snapshot_compare(r)
    if a == "capacity": return capacity(r)
    if a == "capacity_status":
        require_admin();config("repositories",r["repository_id"]);return activity_status("capacity",r["repository_id"])
    if a == "capacity_start":
        require_admin();config("repositories",r["repository_id"]);install_helper_source()
        return start_operation({"command":"capacity","repository_id":r["repository_id"]})
    if a == "config_versions": return config_versions(r)
    if a == "config_version": return config_version(r)
    if a == "rollback_config": return rollback_config(r)
    if a == "external_key": return external_key()
    if a == "allow_monitor": return allow_monitor(r)
    if a == "external_setup": return external_setup(r)
    if a == "external_status": return external_status()
    if a == "external_test":
        require_admin();install_helper_source()
        return start_operation({"command":"external-test"})
    if a == "verification_schedule": return verification_schedule(r)
    if a == "verify_restore":
        require_admin();install_helper_source()
        return start_operation({"command":"verify-restore","repository_id":r["repository_id"],"snapshot":r.get("snapshot","latest"),"full":bool(r.get("full"))})
    if a == "install_rclone": return install_rclone()
    if a == "yandex_check": return yandex_check(r["repository"])
    if a == "log_files": return log_files()
    if a == "server_log": return server_log(r)
    if a == "package_search":return package_search(r)
    if a == "package_plan":return package_plan(r["name"])
    if a == "package_install":
        require_admin()
        if not r.get("confirmed"):raise ValueError("Подтвердите установку программы")
        name=package_name(r["name"])
        if not isinstance(r.get("plan_hash"),str) or not re.fullmatch(r"[0-9a-f]{64}",r["plan_hash"]):raise ValueError("Сначала проверьте план установки")
        if probe()["os"].get("ID") not in ("ubuntu","debian"):raise ValueError("Установка поддерживается на Ubuntu и Debian")
        install_helper_source()
        return start_operation({"command":"package-install","name":name,"plan_hash":r["plan_hash"],"confirmed":True})
    if a == "programs": return installed_programs()
    if a == "program_journal": return program_journal(r)
    if a == "program_config": return program_config(r)
    if a == "save_program_config": return save_program_config(r)
    if a == "service_action": return service_action(r)
    if a == "cron": return cron_inventory()
    if a == "cron_read": return cron_read(r)
    if a == "cron_save": return cron_save(r)
    if a == "probe": return probe()
    if a == "overview":
        result = probe()
        for kind in ["repositories", "jobs", "databases", "states", "history"]:
            paths = sorted((ROOT / kind).glob("*.json"), key=lambda p:p.stat().st_mtime, reverse=True)
            result[kind] = [redacted(read(p)) for p in paths[:100]]
        return result
    if a == "install": return install()
    if a == "browse": return list_dir(r.get("path", "/"))
    if a == "metrics": return metrics()
    if a == "logs": return logs(r)
    if a == "docker": return docker()
    if a == "database_chain_reset":
        require_admin()
        if not r.get("confirmed"):raise ValueError("Подтвердите новую базовую копию")
        with database_lock(r['database_id']) as folder:shutil.rmtree(folder,ignore_errors=True)
        return {"reset":True,"message":"При следующем запуске задания будет создана новая базовая копия. Существующие снимки не изменены"}
    if a == "database_chain_status":
        state=read(ROOT/'database-chains'/ident(r['database_id'])/'state.json',{})
        return {"state":redacted(state)}
    if a == "db_discover": return journal_preflight(r["database"]) if r["database"].get("backup_mode")=="journal" else db_discover(r["database"])
    if a == "list":
        kind = r["kind"]
        if kind not in ["repositories", "jobs", "databases", "states", "history"]: raise ValueError("Неизвестная коллекция")
        values = [redacted(read(p)) for p in sorted((ROOT / kind).glob("*.json"), key=lambda p:p.stat().st_mtime, reverse=True)]
        return values[:200] if kind == "history" else values
    require_admin()
    if a == "save_repository":
        repo = r["repository"]; ident(repo["id"])
        if repo["type"] == "yandex":
            path,token,alias=yandex_repository(repo);repo.update(path=path,token=token,repository="rclone:"+alias+":"+path)
        if repo["type"] not in ["disk", "sftp", "s3", "yandex"]: raise ValueError("Неизвестный тип хранилища")
        if repo["type"] == "sftp": repo["repository"] = "sftp:sb-" + repo["id"] + ":" + repo["path"]
        with repo_lock(repo):
            if r.get("initialize"):
                if not r.get("confirmed"): raise ValueError("Подтвердите создание репозитория")
                p = restic(repo, ["init"])
                if p.returncode: raise RuntimeError("Создание не выполнено: " + p.stderr[-1500:])
            metadata = inspect_repo(repo)
            write(ROOT / "repositories" / (repo["id"] + ".json"), repo)
        return {"saved": repo["id"], "metadata": metadata}
    if a == "authorize_storage_key":
        if not r.get("confirmed"): raise ValueError("Подтвердите установку ключа")
        import pwd
        user = r["user"]
        if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user): raise ValueError("Неверный пользователь хранилища")
        key = r["public_key"].strip()
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]+)?", key): raise ValueError("Неверный публичный ключ")
        try: account = pwd.getpwnam(user)
        except KeyError:
            run(["useradd", "--create-home", "--shell", "/bin/bash", user])
            account = pwd.getpwnam(user)
        sshdir = pathlib.Path(account.pw_dir) / ".ssh"
        sshdir.mkdir(mode=0o700, exist_ok=True); sshdir.chmod(0o700); os.chown(sshdir, account.pw_uid, account.pw_gid)
        authorized = sshdir / "authorized_keys"
        existing = authorized.read_text() if authorized.exists() else ""
        if key not in existing.splitlines():
            with open(authorized, "a") as f: f.write(("\n" if existing and not existing.endswith("\n") else "") + key + "\n")
        authorized.chmod(0o600); os.chown(authorized, account.pw_uid, account.pw_gid)
        target = pathlib.Path(r["path"])
        if not target.is_absolute() or str(target) == "/": raise ValueError("Укажите отдельный каталог хранилища")
        if target.exists() and any(target.iterdir()): raise ValueError("Каталог уже содержит данные; права автоматически не меняются")
        target.mkdir(parents=True, exist_ok=True, mode=0o700); os.chown(target, account.pw_uid, account.pw_gid)
        return {"authorized": True, "user": user, "path": str(target)}
    if a == "sftp_key":
        alias = "sb-" + ident(r["repository_id"]); directory = ROOT / "sftp"; directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        key = directory / (alias + ".key")
        if not key.exists(): run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
        return {"public_key": pathlib.Path(str(key) + ".pub").read_text()}
    if a == "sftp_scan":
        host = r["host"]
        if not re.fullmatch(r"[A-Za-z0-9.:-]+", host): raise ValueError("Неверный адрес")
        scan = run(["ssh-keyscan", "-T", "10", "-p", str(int(r.get("port",22))), host], check=False).stdout
        if not scan.strip(): raise ValueError("Ключ сервера не получен")
        return {"known_hosts": scan, "fingerprints": run(["ssh-keygen", "-lf", "-"], data=scan).stdout}
    if a == "sftp_trust":
        if not r.get("confirmed"): raise ValueError("Подтвердите отпечаток")
        path = ROOT / "sftp" / ("sb-" + ident(r["repository_id"]) + ".known_hosts")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700); path.write_text(r["known_hosts"]); path.chmod(0o600)
        return {"trusted": True}
    if a == "save_database":
        db = r["database"]; ident(db["id"]); info = journal_preflight(db) if db.get("backup_mode")=="journal" else db_discover(db)
        write(ROOT / "databases" / (db["id"] + ".json"), db); return info
    if a == "install_db_clients":
        packages = {"mysql":"default-mysql-client", "mariadb":"mariadb-client", "postgres":"postgresql-client"}
        if r.get("engine") not in packages: raise ValueError("Неизвестная СУБД")
        if not r.get("confirmed"): raise ValueError("Подтвердите установку клиентских пакетов")
        run(["apt-get","update"], timeout=900)
        selected=[packages[r['engine']]]
        if r.get('journal') and r['engine']=='mysql' and probe()['os'].get('ID')=='ubuntu':
            # Core contains mysqlbinlog on Ubuntu; it does not install/start a server service.
            choices=run(['apt-cache','pkgnames','mysql-server-core']).stdout.splitlines()
            candidates=sorted((p for p in choices if re.fullmatch(r'mysql-server-core-\d+(?:\.\d+)*',p)),key=lambda p:[int(n) for n in re.findall(r'\d+',p)])
            if not candidates:raise ValueError('В apt нет пакета с mysqlbinlog; установите подходящий клиент вручную')
            selected.append(candidates[-1])
        run(['apt-get','install','-y']+selected,timeout=900)
        return probe()
    if a == "update_restic":
        if not r.get("confirmed"): raise ValueError("Подтвердите обновление Restic")
        run(["restic","self-update"],timeout=600)
        require_dry_run()
        return install()
    if a == "save_job":
        j = r["job"]; j.setdefault("created", now()); return save_job(j)
    if a == "start_job":
        j = ident(r["job_id"]); config("jobs",j)
        if r.get("dry_run"):
            require_dry_run()
            return start_operation({"repository_id":config("jobs",j)["repository_id"], "command":"job-dry", "job_id":j})
        run(["systemctl", "start", "--no-block", "server-backup-job-" + j + ".service"]); return {"job_id":j}
    if a == "cancel":
        name = ident(r["id"])
        run(["systemctl", "stop", "server-backup-" + name + ".service" if name.startswith("op-") else "server-backup-job-" + name + ".service"])
        state = read(state_path(name), {}); state.update(status="cancelled", finished=now()); write(state_path(name), state)
        return state
    if a == "state": return read(state_path(r["id"]), {"status":"waiting"})
    if a == "telegram":
        write(ROOT / "telegram.json", r["settings"])
        return telegram_notify("Server Backup: тестовое сообщение") if r.get("test") else {"saved":True}
    if a == "email":
        validate_email(r["settings"]); write(ROOT / "email.json", r["settings"])
        return email_notify("Server Backup: тестовое сообщение") if r.get("test") else {"saved": True}
    if a == "restore":
        if not r.get("confirmed"): raise ValueError("Подтвердите восстановление")
        repo = config("repositories", r["repository_id"])
        inspect_repo(repo)
        space = restore_preflight(repo, r)
        return {**start_operation({**r, "command":"restore"}), **space}
    if a == "command":
        args = command_args(r)
        if r["command"] in MUTATING or r["command"] in ["check", "mount", "recover", "self-update"]: return start_operation(r)
        p = restic(config("repositories",r["repository_id"]), args)
        return {"exit_code":p.returncode, "output":p.stdout, "error":p.stderr}
    if a == "restore_database":
        if not r.get("confirmed"): raise ValueError("Подтвердите импорт БД")
        return start_operation({**r,"command":"database-import"})
    if a == "restore_docker":
        if not r.get("confirmed"): raise ValueError("Подтвердите восстановление Docker")
        return start_operation({**r,"command":"docker-import"})
    if a == "watchdog": return watchdog()
    raise ValueError("Неизвестное действие")

def restored_manifest(root):
    p = pathlib.Path(root)
    if not p.is_absolute() or str(p)=="/": raise ValueError("Нужен отдельный каталог восстановления")
    manifests = list(p.glob("**/manifest.json"))
    matches = [x for x in manifests if "/server-backup/dumps/" in str(x)]
    if len(matches)!=1: raise ValueError("Восстановите ровно один манифест задания вместе с дампами")
    return matches[0], read(matches[0])

def restore_database(r):
    if not r.get("confirmed"): raise ValueError("Подтвердите импорт и перезапись БД")
    manifest_path, manifest = restored_manifest(r["target"])
    entry = next((d for d in manifest["databases"] if d["id"]==r["database_id"]),None)
    if not entry: raise ValueError("Дамп БД не найден")
    if entry.get("backup_mode")=="journal":return restore_journal(r,entry,manifest_path.parent/ident(entry["id"]))
    db = r["database"]; current = db_discover(db)
    def major(version):
        match = re.search(r"(?:PostgreSQL\s+)?(\d+)(?:\.(\d+))?",version)
        if not match: raise ValueError("Не удалось определить версию БД")
        return int(match.group(1))
    if db["engine"] != entry["engine"] or major(current["version"]) != major(entry["version"]): raise ValueError("Требуются одинаковые СУБД и основные версии")
    folder = manifest_path.parent / ident(entry["id"])
    with db_command(db) as (prefix,opts,env):
        if db["engine"]=="postgres":
            if r.get("restore_roles"):
                with open(folder/"roles.sql","rb") as f: p=subprocess.run(prefix+["psql"]+opts+["-d","postgres","-v","ON_ERROR_STOP=1"],stdin=f,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
                if p.returncode: raise RuntimeError("Ошибка импорта ролей")
            for i,name in enumerate(entry["databases"]):
                with open(folder/("database-%d.dump"%i),"rb") as f: p=subprocess.run(prefix+["pg_restore"]+opts+["--clean","--if-exists","--create","--exit-on-error","-d",db.get("maintenance_db","postgres")],stdin=f,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
                if p.returncode: raise RuntimeError("Ошибка импорта PostgreSQL; операция могла частично изменить БД")
        else:
            with open(folder/"database.sql","rb") as f: p=subprocess.run(prefix+[("mariadb" if db["engine"]=="mariadb" else "mysql")]+opts,stdin=f,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            if p.returncode: raise RuntimeError("Ошибка импорта MySQL/MariaDB; операция могла частично изменить БД")
    return {"restored":entry["id"]}

def restore_docker(r):
    if not r.get("confirmed"): raise ValueError("Подтвердите восстановление Docker")
    root = pathlib.Path(r["target"]); _, manifest = restored_manifest(str(root))
    selected = r.get("containers",[])
    if not selected or not set(selected).issubset({c["name"] for c in manifest["docker"]}): raise ValueError("Выберите контейнеры, присутствующие в манифесте копии")
    existing = docker()
    for c in manifest["docker"]:
        if c["name"] not in selected: continue
        target_container = next((x for x in existing if x["name"]==c["name"]),None)
        if target_container and target_container["running"]: raise ValueError("Сначала остановите целевой контейнер: " + c["name"])
        for m in c["mounts"]:
            source = root / m["Source"].lstrip("/")
            if not source.exists(): raise ValueError("Данные тома отсутствуют в копии; для режима дампа сначала импортируйте БД")
            if m["Type"]=="volume":
                name=m["Name"]; run(["docker","volume","create",name]); destination=pathlib.Path(json.loads(run(["docker","volume","inspect",name]).stdout)[0]["Mountpoint"])
            else:
                destination=pathlib.Path(r.get("bind_paths",{}).get(m["Source"],m["Source"]))
                if not destination.is_absolute() or str(destination)=="/": raise ValueError("Неверный целевой путь bind mount")
            if destination.exists() and (not destination.is_dir() or any(destination.iterdir())) and not r.get("overwrite"): raise ValueError("Целевой том не пуст: требуется подтверждение перезаписи")
            destination.parent.mkdir(parents=True,exist_ok=True)
            # cp -a preserves ownership and permissions, including symlinks.
            if source.is_dir():
                destination.mkdir(parents=True,exist_ok=True); run(["cp","-a",str(source)+"/.",str(destination)],timeout=86400)
            else: run(["cp","-a",str(source),str(destination)],timeout=86400)
    if r.get("start"):
        compose_files=r.get("compose_files",[])
        if not compose_files: raise ValueError("Укажите восстановленные и проверенные Compose-файлы")
        for file in compose_files:
            p=pathlib.Path(file)
            if not within(p, root): raise ValueError("Compose должен находиться в каталоге восстановления")
        command=["docker","compose"]
        for file in compose_files: command += ["-f",file]
        run(command+["config","--quiet"])
        run(command+["up","-d"],timeout=900)
    return {"restored":selected,"started":bool(r.get("start"))}

# Native incremental database chains. Every snapshot contains an independent baseline + journals.
def db_fingerprint(db):
    fields={k:db.get(k) for k in ('engine','host','port','user','container','peer','wal_archive')}
    return hashlib.sha256(json.dumps(fields,sort_keys=True).encode()).hexdigest()

@contextlib.contextmanager
def database_lock(name):
    directory=ROOT/'database-chains';directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (directory/(ident(name)+'.lock')).open('a') as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        yield directory/ident(name)

def pg_native_tool(tool,major):
    candidates=[pathlib.Path('/usr/lib/postgresql')/str(major)/'bin'/tool]
    available=shutil.which(tool)
    if available:candidates.append(pathlib.Path(available))
    for path in candidates:
        if path.is_file() and os.access(path,os.X_OK) and re.search(r'\b'+str(major)+r'\.',run([str(path),'--version']).stdout):return str(path)
    raise ValueError('Нужна утилита '+tool+' основной версии '+str(major))

def journal_preflight(db):
    if db.get('container') or db.get('peer'):raise ValueError('Журналы: используйте прямое TCP-подключение, в том числе к опубликованному порту Docker. Peer и docker exec поддерживают обычные дампы')
    if db.get('databases'):raise ValueError('Журналы сохраняют весь сервер БД. Для отдельных баз выберите обычный дамп')
    info=db_discover(db)
    if db['engine']=='postgres':
        for tool in ('pg_basebackup','psql'):
            if not shutil.which(tool):raise ValueError('Не установлена утилита '+tool)
        version=db_query(db,'SHOW server_version_num;').strip();major=int(version)//10000
        basebackup_tool=pg_native_tool('pg_basebackup',major)
        settings=db_query(db,"SELECT current_setting('wal_level'),current_setting('archive_mode'),current_setting('full_page_writes');").strip().split('|')
        if len(settings)!=3 or settings[0]=='minimal' or settings[1]!='on' or settings[2]!='on':raise ValueError('Нужны wal_level=replica, archive_mode=on и full_page_writes=on. Настройки СУБД приложение автоматически не меняет')
        if db_query(db,"SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global');").strip()!='0':raise ValueError('Для этого режима пока поддерживается кластер без внешних tablespace')
        archive=pathlib.Path(db.get('wal_archive',''))
        if not archive.is_absolute() or not archive.is_dir() or archive.is_symlink() or str(archive)=='/':raise ValueError('Укажите существующий отдельный каталог WAL-архива, заполненный archive_command')
        identity=db_query(db,'SELECT system_identifier FROM pg_control_system();').strip()
        timeline=db_query(db,'SELECT timeline_id FROM pg_control_checkpoint();').strip()
        return {**info,'identity':identity,'timeline':timeline,'major':major,'mode':'wal','basebackup_tool':basebackup_tool}
    exe='mariadb-binlog' if db['engine']=='mariadb' else 'mysqlbinlog'
    if not shutil.which(exe):raise ValueError('Не установлена утилита '+exe)
    if db['engine']=='mysql':
        server_version=re.search(r'(\d+)\.(\d+)',info['version']).groups()
        for tool in ('mysqlbinlog','mysqldump'):
            client_version=run([tool,'--version']).stdout
            if 'MariaDB' in client_version or not re.search(r'\b'+re.escape('.'.join(server_version))+r'\.',client_version):raise ValueError('Для журналов нужна '+tool+' версии '+'.'.join(server_version)+'; установите клиентские утилиты той же ветки, что и MySQL')
    if db_query(db,'SELECT @@log_bin;').strip()!='1':raise ValueError('На сервере БД выключен binlog. Включите его в конфигурации СУБД; приложение не перезапускает БД')
    if db_query(db,'SELECT @@binlog_format;').strip().upper()!='ROW':raise ValueError('Для журналов нужен binlog_format=ROW')
    if any(x.upper()!='INNODB' for x in info['table_engines']) and db.get('consistency')!='lock':raise ValueError('Нетранзакционные таблицы: выберите блокировку для базового дампа')
    identity=db_query(db,'SELECT @@server_uuid;' if db['engine']=='mysql' else 'SELECT @@server_id,@@hostname;').strip()
    return {**info,'identity':identity,'mode':'binlog'}

def binlog_coordinate(sql):
    match=re.search(r"(?:MASTER|SOURCE)_LOG_FILE\s*=\s*'([^']+)'\s*,\s*(?:MASTER|SOURCE)_LOG_POS\s*=\s*(\d+)",sql)
    if not match or not re.fullmatch(r'[A-Za-z0-9_.-]+\.\d+',match[1]):raise ValueError('В базовом дампе отсутствует корректная позиция binlog')
    return match[1],int(match[2])

def binlog_sequence(names,start):
    match=re.fullmatch(r'(.+)\.(\d+)',start)
    if not match:raise ValueError('Недопустимое имя binlog')
    prefix=match[1];number=int(match[2]);result=[]
    for name in names:
        m=re.fullmatch(re.escape(prefix)+r'\.(\d+)',name)
        if not m:raise ValueError('Изменился префикс binlog: создайте новую базовую копию')
        n=int(m[1])
        if n<number:continue
        if n!=number:raise ValueError('Разрыв цепочки binlog: отсутствует журнал '+str(number))
        result.append(name);number+=1
    if not result or result[0]!=start:raise ValueError('Исходный binlog удалён до сохранения; нужна новая базовая копия')
    return result

def journal_hash(path):
    digest=hashlib.sha256()
    with pathlib.Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):digest.update(chunk)
    return digest.hexdigest()

def wal_number(name,segment_size):
    if not re.fullmatch(r'[0-9A-F]{24}',name):raise ValueError('Недопустимое имя WAL')
    return int(name[8:16],16)*(0x100000000//segment_size)+int(name[16:],16)

def validate_wal_chain(names,start,end,segment_size):
    if start[:8]!=end[:8]:raise ValueError('Изменилась timeline PostgreSQL: нужна новая базовая копия')
    found={wal_number(n,segment_size) for n in names if re.fullmatch(r'[0-9A-F]{24}',n) and n[:8]==start[:8]}
    a=wal_number(start,segment_size);b=wal_number(end,segment_size)
    if b<a:raise ValueError('WAL завершения раньше базовой копии')
    for n in range(a,b+1):
        if n not in found:raise ValueError('Разрыв цепочки WAL: не все сегменты доступны в архиве')

def database_chain(db,folder):
    info=journal_preflight(db)
    with database_lock(db['id']) as root:
        state=read(root/'state.json')
        if state and (state['fingerprint']!=db_fingerprint(db) or state['identity']!=info['identity'] or state.get('timeline')!=info.get('timeline')):raise ValueError('Изменился источник БД или timeline: явно создайте новую базовую копию')
        if not state:
            root.mkdir(parents=True,exist_ok=True,mode=0o700)
            staging=root/'new-base';shutil.rmtree(staging,ignore_errors=True);staging.mkdir(mode=0o700)
            with db_command(db) as (prefix,opts,env):
                if db['engine']=='postgres':
                    run([info['basebackup_tool']]+opts+['-D',str(staging),'-Ft','-X','stream','--checkpoint='+('fast' if db.get('checkpoint')=='fast' else 'spread')],env=env,timeout=86400)
                    import tarfile
                    with tarfile.open(staging/'pg_wal.tar') as tar:names=sorted(pathlib.PurePosixPath(n).name for n in tar.getnames() if re.fullmatch(r'[0-9A-F]{24}',pathlib.PurePosixPath(n).name))
                    if not names:raise ValueError('Базовая копия не содержит WAL')
                    start=names[-1]
                    segment_size=int(db_query(db,"SELECT pg_size_bytes(current_setting('wal_segment_size'));").strip())
                    coordinate={'first_log':start,'segment_size':segment_size}
                else:
                    dump_db({**db,'_journal_baseline':True,'backup_mode':'dump'},staging)
                    with (staging/'database.sql').open() as f:header=f.read(2*1024*1024)
                    log,position=binlog_coordinate(header);coordinate={'first_log':log,'position':position}
            base=root/'base';shutil.rmtree(base,ignore_errors=True);os.replace(staging,base)
            state={**coordinate,'created':now(),'fingerprint':db_fingerprint(db),'identity':info['identity'],'timeline':info.get('timeline'),'version':info['version'],'engine':db['engine'],'mode':info['mode'],'checksums':{'base/'+str(p.relative_to(base)):journal_hash(p) for p in base.rglob('*') if p.is_file()}}
            write(root/'state.json',state)
        logs=root/'logs';logs.mkdir(mode=0o700,exist_ok=True)
        safe_through=db_query(db,"SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US')" if db['engine']=='postgres' else 'SELECT UTC_TIMESTAMP(6);').strip().replace(' ','T')+'+00:00'
        if db['engine']=='postgres':
            end=db_query(db,'SELECT pg_walfile_name(pg_switch_wal());').strip()
            archive=pathlib.Path(db['wal_archive']);deadline=time.monotonic()+90
            while True:
                archived=db_query(db,'SELECT last_archived_wal FROM pg_stat_archiver;').strip()
                if (archive/end).is_file() and (archive/end).stat().st_size==state['segment_size'] and archived[:24]>=end:break
                if time.monotonic()>deadline:raise RuntimeError('archive_command не подтвердил полный закрытый WAL за 90 секунд; проверьте pg_stat_archiver')
                time.sleep(1)
            candidates=sorted(p for p in archive.iterdir() if re.fullmatch(r'[0-9A-F]{24}',p.name) and state['first_log']<=p.name<=end)
            validate_wal_chain([p.name for p in candidates]+[p.name for p in logs.iterdir()],state['first_log'],end,state['segment_size'])
            for source in candidates:
                if source.is_symlink() or source.stat().st_size!=state['segment_size']:raise ValueError('WAL должен быть полным обычным файлом')
                dest=logs/source.name
                if not dest.exists():shutil.copy2(source,dest);dest.chmod(0o600)
            ordered=sorted(p.name for p in logs.iterdir() if state['first_log']<=p.name<=end)
        else:
            db_query(db,'FLUSH BINARY LOGS;')
            inventory=[line.split('\t') for line in db_query(db,'SHOW BINARY LOGS;').splitlines()]
            if len(inventory)<2:raise ValueError('Нет закрытого binlog после ротации')
            # Already archived logs survive purge on the database server.
            available={p.name for p in logs.iterdir()};sizes={r[0]:int(r[1]) for r in inventory[:-1]}
            if available and max(available)>=inventory[-1][0]:raise ValueError('Сервер откатил номера binlog: нужна новая базовая копия')
            for name in available & set(sizes):
                if (logs/name).stat().st_size!=sizes[name]:raise ValueError('Сохранённый binlog заменён на сервере: нужна новая базовая копия')
            ordered=binlog_sequence(sorted(available|set(sizes)),state['first_log'])
            with db_command(db) as (_,opts,env):
                exe='mariadb-binlog' if db['engine']=='mariadb' else 'mysqlbinlog'
                for name in ordered:
                    if (logs/name).exists():continue
                    with tempfile.TemporaryDirectory(dir=root) as tmp:
                        run([exe]+opts+['--read-from-remote-server','--raw','--result-file='+tmp+'/',name],env=env,timeout=3600)
                        source=pathlib.Path(tmp)/name
                        if not source.is_file() or source.stat().st_size!=sizes[name] or source.open('rb').read(4)!=b'\xfebin':raise ValueError('Binlog скачан не полностью')
                        source.chmod(0o600);os.replace(source,logs/name)
        # All parts sealed before Restic runs; no password is included in the manifest.
        shutil.copytree(root/'base',folder/'base',copy_function=os.link)
        (folder/'logs').mkdir(mode=0o700)
        for name in ordered:os.link(logs/name,folder/'logs'/name)
        files={}
        for p in folder.rglob('*'):
            if not p.is_file():continue
            key=str(p.relative_to(folder))
            digest=state.setdefault('checksums',{}).get(key)
            if not digest:digest=journal_hash(p);state['checksums'][key]=digest
            files[key]=digest
        write(root/'state.json',state)
        result={'id':db['id'],'engine':db['engine'],'version':state['version'],'databases':info['databases'],'backup_mode':'journal','chain':{**{k:v for k,v in state.items() if k not in ('fingerprint','checksums')},'through':safe_through,'logs':ordered,'checksums':files},'files':list(files)}
        write(folder/'chain.json',result['chain']);return result

def safe_extract_tar(source,destination):
    import tarfile
    with tarfile.open(source) as tar:
        entries=tar.getmembers()
        for entry in entries:
            p=pathlib.PurePosixPath(entry.name)
            if p.is_absolute() or '..' in p.parts or entry.issym() or entry.islnk() or entry.isdev() or entry.isfifo():raise ValueError('Архив содержит небезопасный путь или ссылку')
        tar.extractall(destination,members=entries)

def restore_journal(r,entry,folder):
    chain=entry['chain'];db=r['database'];target_time=r.get('recovery_time')
    if db.get('engine')!=entry['engine']:raise ValueError('СУБД назначения отличается от копии')
    if target_time:
        if not re.search(r'(Z|[+-]\d{2}:\d{2})$',target_time):raise ValueError('Укажите время с часовым поясом, например 2026-10-09T12:30:00Z')
        date=parse_time(target_time)
        if not date or not parse_time(chain['created'])<=date<=parse_time(chain['through']):raise ValueError('Время должно попадать в интервал сохранённой цепочки')
        target_time=date.astimezone(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S+00')
    for path,digest in chain['checksums'].items():
        p=folder/path
        if not within(p,folder) or not p.is_file() or p.is_symlink() or journal_hash(p)!=digest:raise ValueError('Повреждена часть цепочки: '+path)
    if entry['engine']=='postgres':
        target=pathlib.Path(r.get('pgdata',''))
        if not target.is_absolute() or str(target)=='/' or target.is_symlink() or target.exists() and any(target.iterdir()):raise ValueError('PGDATA должен быть отдельным пустым каталогом')
        major=re.search(r'(\d+)\.',entry['version'])[1]
        pg_native_tool('postgres',major)
        target.parent.mkdir(parents=True,exist_ok=True)
        username=db.get('system_user','postgres');account=pwd.getpwnam(username)
        if run(['runuser','-u',username,'--','test','-x',str(target.parent)],check=False).returncode:raise ValueError('Пользователь PostgreSQL не может открыть родительский каталог PGDATA')
        target.mkdir(parents=True,exist_ok=True,mode=0o700)
        safe_extract_tar(folder/'base'/'base.tar',target)
        (target/'pg_wal').mkdir(exist_ok=True);safe_extract_tar(folder/'base'/'pg_wal.tar',target/'pg_wal')
        archive=target/'sb-wal-archive';shutil.copytree(folder/'logs',archive)
        # Server-specific replication, SSL and archive commands must not execute on the target.
        (target/'postgresql.auto.conf').write_text('')
        restore_command=shlex.join(['cp','--',str(archive/'%f'),'%p'])
        config_text="\narchive_mode = off\nprimary_conninfo = ''\nprimary_slot_name = ''\nrestore_command = '"+restore_command.replace("'","''")+"'\n"
        if target_time:config_text+="recovery_target_time = '"+target_time+"'\nrecovery_target_action = 'pause'\n"
        (target/'sb-recovery.conf').write_text(config_text)
        with (target/'postgresql.conf').open('a') as f:f.write("\ninclude = 'sb-recovery.conf'\n")
        (target/'recovery.signal').touch()
        account=pwd.getpwnam(db.get('system_user','postgres'))
        for p in [target]+list(target.rglob('*')):os.chown(p,account.pw_uid,account.pw_gid)
        return {'prepared':str(target),'started':False,'recovery_time':target_time,'message':'PGDATA подготовлен. Запуск отдельного PostgreSQL и подтверждение достижения recovery target выполняются отдельно; рабочий кластер не изменён'}
    info=db_discover(db)
    if db['engine']!=entry['engine'] or re.search(r'(\d+)\.',entry['version'])[1]!=re.search(r'(\d+)\.',info['version'])[1]:raise ValueError('СУБД и основная версия должны совпадать')
    with db_command(db) as (prefix,opts,env):
        exe='mariadb-binlog' if db['engine']=='mariadb' else 'mysqlbinlog';client='mariadb' if db['engine']=='mariadb' else 'mysql'
        with tempfile.TemporaryFile() as sql:
            args=[exe,'--start-position='+str(chain['position'])]
            if target_time:args+=['--stop-datetime='+target_time[:19]]
            args+=[str(folder/'logs'/name) for name in chain['logs']]
            env['TZ']='UTC'
            p=subprocess.run(args,env=env,stdout=sql,stderr=subprocess.PIPE,timeout=86400)
            if p.returncode:raise RuntimeError('Не удалось декодировать binlog; импорт не начинался')
            with tempfile.TemporaryFile() as complete:
                with (folder/'base'/'database.sql').open('rb') as baseline:shutil.copyfileobj(baseline,complete)
                complete.write(b'\n');sql.seek(0);shutil.copyfileobj(sql,complete);complete.seek(0)
                # One connection preserves session/transaction state and survives restored account changes.
                p=subprocess.run(prefix+[client]+opts,env=env,stdin=complete,stderr=subprocess.PIPE,stdout=subprocess.DEVNULL,timeout=86400)
            if p.returncode:raise RuntimeError('Ошибка импорта базовой копии или binlog; целевая БД могла измениться')
    return {'restored':entry['id'],'recovery_time':target_time,'mode':'binlog'}


def copy_snapshot(source,destination,snapshot):
    if source['repository']==destination['repository']:raise ValueError('Источник и назначение совпадают')
    with contextlib.ExitStack() as stack:
        for repo in sorted([source,destination],key=lambda x:x['repository']):stack.enter_context(repo_lock(repo))
        env=stack.enter_context(repository_env(destination));source_env=stack.enter_context(repository_env(source))
        env['RESTIC_FROM_REPOSITORY']=source_env['RESTIC_REPOSITORY'];env['RESTIC_FROM_PASSWORD_FILE']=source_env['RESTIC_PASSWORD_FILE']
        if source_env.get('SB_SFTP_CONFIG'):
            if env.get('SB_SFTP_CONFIG'):
                with open(env['SB_SFTP_CONFIG'],'a') as f:f.write(pathlib.Path(source_env['SB_SFTP_CONFIG']).read_text())
            else:env['SB_SFTP_CONFIG']=source_env['SB_SFTP_CONFIG']
        for key,value in source_env.items():
            if key.startswith('RCLONE_CONFIG_'):
                if key in env and env[key]!=value:raise ValueError('Конфликт конфигураций rclone')
                env[key]=value
        if source['type']=='yandex':env['RCLONE_CONFIG']='/dev/null'
        if source['type']=='s3':
            if destination['type']=='s3' and source.get('access_key')!=destination.get('access_key'):raise ValueError('Restic copy между S3 требует ключ с доступом к обоим хранилищам')
            if destination['type']!='s3':
                for key in ('AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_DEFAULT_REGION'):env[key]=source_env[key]
        result=run(restic_args(env)+['copy',snapshot],env=env,check=False,timeout=604800)
        if result.returncode:raise RuntimeError(result.stderr[-2000:])
        return {'repository_id':destination['id'],'status':'success','source_snapshot':snapshot,'finished':now()}

def job_manage(r):
    require_admin();job=config('jobs',r['job_id'])
    if r['action']=='job_toggle':job['enabled']=bool(r['enabled'])
    elif r['action']=='job_duplicate':
        if (ROOT/'jobs'/(ident(r['new_id'])+'.json')).exists():raise ValueError('ID нового задания уже существует')
        job.update(id=ident(r['new_id']),name=r.get('name',job.get('name',job['id'])+' · копия'),enabled=False);job.pop('created',None)
    return save_job(job)

def job_versions(r):
    name=ident(r['job_id'])
    versions=[redacted(read(p)) for p in sorted((ROOT/'job-versions'/name).glob('*.json'),reverse=True)]
    result=run(['systemctl','show','server-backup-job-'+name+'.timer','--property=NextElapseUSecRealtime','--value'],check=False) if shutil.which('systemctl') else None
    return {'versions':versions[:100],'next_run':result.stdout.strip() if result and result.returncode==0 else None}

def error_center():
    rows=[]
    categories=[('error','backup','Ошибка операции','Проверьте доступ к хранилищу, свободное место и журнал задания'),('maintenance_error','maintenance','Ошибка очистки или проверки','Откройте копии и повторите проверку хранилища'),('verification_error','verification','Ошибка восстановления','Откройте проверку копий и повторите тест на отдельном сервере'),('container_recovery_error','docker','Не запущен остановленный контейнер','Проверьте Docker и состояние контейнера'),('replication_errors','replication','Ошибка дополнительного хранилища','Проверьте доступы дополнительного направления и повторите копирование')]
    for item in history_records(500):
        for field,category,title,hint in categories:
            if item.get(field):rows.append({'id':item.get('id'),'job_id':item.get('job_id') or (item.get('id') if item.get('operation','backup')=='backup' else None),'name':item.get('name') or item.get('id'),'repository_id':item.get('repository_id'),'time':item.get('finished') or item.get('started'),'category':category,'title':title,'message':str(item[field]),'hint':hint,'retry_action':'start_job' if category=='backup' and item.get('operation','backup')=='backup' else None})
    for file,channel in [('notification-error.json','Telegram'),('email-error.json','Почта')]:
        record=read(ROOT/file,{})
        if record:rows.append({'category':'notification','title':'Ошибка уведомления · '+channel,'message':record.get('error'),'time':record.get('time'),'hint':'Проверьте настройки канала и отправьте тестовое сообщение'})
    return {'entries':sorted(rows,key=lambda x:x.get('time') or '',reverse=True)}

def snapshot_file_history(r):
    repo=config('repositories',r['repository_id']);path=snapshot_literal_path(r['path'])
    result=restic(repo,['snapshots','--json'],timeout=300)
    if result.returncode:raise RuntimeError('Не удалось получить версии копий')
    snapshots=sorted(json.loads(result.stdout),key=lambda x:x['time'],reverse=True);offset=max(0,int(r.get('offset',0)));limit=min(20,max(1,int(r.get('limit',20))));versions=[]
    for snap in snapshots[offset:offset+limit]:
        p=restic(repo,['ls','--json',snap['id'],path],timeout=300)
        if p.returncode:raise RuntimeError('Не удалось прочитать копию '+snap['id'][:8])
        node=next((n for n in (json.loads(line) for line in p.stdout.splitlines() if line.strip()) if n.get('path')==path),None)
        versions.append({'snapshot':snap['id'],'time':snap['time'],'present':node is not None,'node':node})
    return {'versions':versions,'total':len(snapshots),'offset':offset,'path':path,'method':'size and mtime; use content comparison for exact equality'}

def snapshot_literal_path(value):
    if not isinstance(value,str) or not value.startswith('/') or '..' in pathlib.PurePosixPath(value).parts or '\x00' in value:raise ValueError('Нужен абсолютный путь без .. и NUL')
    return str(pathlib.PurePosixPath(value))

def snapshot_content(r):
    require_admin();repo=config('repositories',r['repository_id']);source=snapshot_literal_path(r['path']);target=pathlib.Path(snapshot_literal_path(r.get('target',source)))
    # A bounded, explicitly selected regular file; hash/read through one FD to detect live changes.
    listing=restic(repo,['ls','--json',r['snapshot'],source],timeout=300)
    if listing.returncode:raise ValueError('Не удалось прочитать сведения файла')
    node=next((n for n in (json.loads(line) for line in listing.stdout.splitlines() if line.strip()) if n.get('path')==source),{})
    if node.get('type')!='file' or int(node.get('size',0))>64*1024**2:raise ValueError('Выберите обычный файл копии до 64 МБ')
    descriptor=os.open(target,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):raise ValueError('Выберите обычный файл')
        if before.st_size>64*1024*1024:raise ValueError('Сравнение содержимого ограничено 64 МБ на файл')
        with repository_env(repo) as env,tempfile.TemporaryFile() as output:
            p=subprocess.run(restic_args(env)+['dump',r['snapshot'],source],env=env,stdout=output,stderr=subprocess.PIPE,timeout=900)
            if p.returncode:raise RuntimeError('Не удалось прочитать файл из копии')
            if output.tell()>64*1024*1024:raise ValueError('Файл копии больше 64 МБ')
            output.seek(0);saved=output.read()
            with os.fdopen(os.dup(descriptor),'rb') as live_stream:live=live_stream.read(64*1024*1024+1)
        after=os.fstat(descriptor)
        if (before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_size,after.st_mtime_ns,after.st_ctime_ns):raise RuntimeError('Файл менялся во время чтения; повторите сравнение')
    finally:os.close(descriptor)
    result={'same':saved==live,'snapshot_sha256':hashlib.sha256(saved).hexdigest(),'server_sha256':hashlib.sha256(live).hexdigest(),'snapshot_size':len(saved),'server_size':len(live),'diff':None}
    if max(len(saved),len(live))<=1024*1024 and b'\x00' not in saved+live:
        try:
            import difflib
            result['diff']=''.join(difflib.unified_diff(saved.decode('utf-8').splitlines(True),live.decode('utf-8').splitlines(True),fromfile='Копия: '+source,tofile='Сервер: '+str(target)))[:200000]
        except UnicodeDecodeError:pass
    return result


def verify_full_restore(repo,snapshot='latest',jobid=None):
    require_admin()
    snapshots=restic(repo,['snapshots','--json',snapshot],timeout=300)
    if snapshots.returncode:raise RuntimeError('Не удалось найти снимок')
    copies=json.loads(snapshots.stdout)
    if len(copies)!=1:raise ValueError('Выберите одну копию')
    snapshot=copies[0]['id'];summary=copies[0].get('summary',{})
    required=int(summary.get('total_bytes_processed',0))
    if not required:
        size=restic(repo,['stats',snapshot,'--mode','restore-size','--json'],timeout=900)
        if size.returncode:raise RuntimeError('Не удалось проверить требуемый объём')
        required=int(json.loads(size.stdout)['total_size'])
    root=ROOT/'verification-temp';root.mkdir(mode=0o700,parents=True,exist_ok=True)
    if shutil.disk_usage(root).free<required*2+1024**3:raise RuntimeError('Недостаточно места для отдельной проверки всей копии и БД')
    result={'operation':'verify-restore','repository_id':repo['id'],'snapshot':snapshot,'started':now(),'sample_only':False,'scope':'files + isolated databases + Docker volumes','checks':[],'status':'running'}
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        restored=restic(repo,['restore',snapshot,'--target',tmp,'--verify'],timeout=604800)
        if restored.returncode:raise RuntimeError('Не пройдена полная проверка восстановленных файлов')
        result['checks'].append({'kind':'files','status':'success','bytes':required})
        try:manifest_path,manifest=restored_manifest(tmp)
        except ValueError:
            if any('/server-backup/dumps/' in p for p in copies[0].get('paths',[])):raise
            manifest={'databases':[],'docker':[]};manifest_path=None
        for entry in manifest.get('databases',[]):
            verify_isolated_database(entry,manifest_path.parent/ident(entry['id']))
            result['checks'].append({'kind':'database','id':entry['id'],'status':'success','version':entry['version']})
        for container in manifest.get('docker',[]):
            checked=[]
            for mount in container.get('mounts',[]):
                source=pathlib.Path(tmp)/mount.get('Source','').lstrip('/')
                # Dump-only databases have no raw volumes in the snapshot.
                if not source.exists():
                    if any(db.get('id') for db in manifest.get('databases',[])) and container.get('database'):continue
                    raise ValueError('В копии отсутствует том '+mount.get('Source',''))
                if not within(source,pathlib.Path(tmp)):raise ValueError('Том выходит за каталог проверки')
                scratch=pathlib.Path(tmp)/('sb-volume-test-'+uuid.uuid4().hex)
                if source.is_dir():shutil.copytree(source,scratch,symlinks=True)
                else:shutil.copy2(source,scratch)
                checked.append(mount.get('Name') or mount.get('Source'))
            labels=container.get('labels',{});workdir=labels.get('com.docker.compose.project.working_dir','')
            files=[x for x in labels.get('com.docker.compose.project.config_files','').split(',') if x]
            if files:
                command=['docker','compose']
                for path in files:
                    original=path if path.startswith('/') else str(pathlib.Path(workdir)/path)
                    restored_file=pathlib.Path(tmp)/original.lstrip('/')
                    if not within(restored_file,pathlib.Path(tmp)) or not restored_file.is_file():raise ValueError('Compose-файл отсутствует в копии')
                    command+=['-f',str(restored_file)]
                checked_config=run(command+['config','--no-interpolate','--quiet'],check=False)
                if checked_config.returncode:raise ValueError('Не пройдена проверка восстановленной конфигурации Compose')
            result['checks'].append({'kind':'docker-volumes','id':container['name'],'status':'success','volumes':checked,'started':False})
    result.update(status='success',finished=now());write(ROOT/'verification-latest.json',result)
    if jobid:write(ROOT/'verifications'/('job-'+ident(jobid)+'.json'),result)
    return result

def verify_isolated_database(entry,folder):
    engine=entry['engine'];major=re.search(r'(\d+)\.',entry['version'])[1]
    image={'postgres':'postgres','mysql':'mysql','mariadb':'mariadb'}[engine]+':'+(re.search(r'(\d+\.\d+)',entry['version'])[1] if engine=='mysql' else major)
    if not shutil.which('docker'):raise ValueError('Для изолированного восстановления БД нужен Docker')
    # Never silently pull images or share volumes/networks with existing workloads.
    if run(['docker','image','inspect',image],check=False).returncode:raise ValueError('На тестовом сервере заранее установите Docker-образ '+image)
    name='sb-verify-'+uuid.uuid4().hex
    try:
        if engine=='postgres' and entry.get('backup_mode')=='journal':
            for path,digest in entry['chain']['checksums'].items():
                source=folder/path
                if not within(source,folder) or source.is_symlink() or journal_hash(source)!=digest:raise ValueError('Повреждена цепочка PostgreSQL')
            with tempfile.TemporaryDirectory() as tmp:
                data=pathlib.Path(tmp)/'data';data.mkdir(mode=0o700)
                safe_extract_tar(folder/'base'/'base.tar',data);(data/'pg_wal').mkdir(exist_ok=True);safe_extract_tar(folder/'base'/'pg_wal.tar',data/'pg_wal')
                shutil.copytree(folder/'logs',data/'sb-wal-archive')
                (data/'postgresql.auto.conf').write_text('')
                (data/'postgresql.conf').write_text("listen_addresses=''\nunix_socket_directories='/tmp'\nport=55432\narchive_mode=off\nrestore_command='cp /tmp/recovery/sb-wal-archive/%f %p'\n")
                (data/'pg_hba.conf').write_text('local all all trust\n');(data/'recovery.signal').touch()
                run(['docker','run','-d','--name',name,'--network','none','--memory','2g','--pids-limit','256','--entrypoint','sleep',image,'3600'])
                run(['docker','cp',str(data),name+':/tmp/recovery']);run(['docker','exec',name,'chown','-R','postgres:postgres','/tmp/recovery'])
            run(['docker','exec','-u','postgres',name,'pg_ctl','-D','/tmp/recovery','-l','/tmp/recovery.log','-w','-t','120','start'],timeout=150)
            run(['docker','exec','-u','postgres',name,'psql','-h','/tmp','-p','55432','-d','postgres','-At','-c','SELECT count(*) FROM pg_database;'])
            return
        env=['-e','POSTGRES_HOST_AUTH_METHOD=trust'] if engine=='postgres' else ['-e','MYSQL_ALLOW_EMPTY_PASSWORD=yes']
        initial=name if engine=='postgres' else name+'-init'
        run(['docker','run','-d','--name',initial,'--network','none','--memory','2g','--pids-limit','256']+env+[image])
        def ready(container):
            deadline=time.monotonic()+120
            while True:
                command=['docker','exec',container]+(['pg_isready','-U','postgres'] if engine=='postgres' else [('mariadb-admin' if engine=='mariadb' else 'mysqladmin'),'-uroot','ping'])
                if run(command,check=False).returncode==0:return
                if time.monotonic()>deadline:raise ValueError('Тестовая СУБД не запустилась за 120 секунд')
                time.sleep(1)
        ready(initial)
        if engine!='postgres':
            run(['docker','stop',initial])
            # Only a newly-created fixture volume is shared; no existing server volume is mounted.
            run(['docker','run','-d','--name',name,'--network','none','--memory','2g','--pids-limit','256','--volumes-from',initial,image,'--skip-grant-tables','--skip-networking'])
            ready(name)
        database={'engine':engine,'container':name,'user':'postgres' if engine=='postgres' else 'root','host':'localhost','port':5432 if engine=='postgres' else 3306,'password':''}
        if entry.get('backup_mode')=='journal':restore_journal({'database':database},entry,folder)
        else:
            with db_command(database) as (prefix,opts,env):
                if engine=='postgres':
                    commands=[('roles.sql',['psql']+opts+['-d','postgres','-v','ON_ERROR_STOP=1'])]
                    commands += [('database-%d.dump'%i,['pg_restore']+opts+['--clean','--if-exists','--create','--exit-on-error','-d','template1']) for i,_ in enumerate(entry['databases'])]
                    # The initial postgres role exists in a new cluster; restoring roles is deliberately separate.
                    roles=(folder/'roles.sql').read_text()
                    roles=re.sub(r'^CREATE ROLE \"?postgres\"?;\s*$', '',roles,flags=re.M)
                    p=run(prefix+commands[0][1],env=env,data=roles,check=False,timeout=900)
                    if p.returncode:raise ValueError('Не удалось восстановить роли в тестовой СУБД')
                    commands=commands[1:]
                else:commands=[('database.sql',[('mariadb' if engine=='mariadb' else 'mysql')]+opts)]
                for filename,args in commands:
                    with (folder/filename).open('rb') as stream:p=subprocess.run(prefix+args,env=env,stdin=stream,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=86400)
                    if p.returncode:raise RuntimeError('Не прошёл импорт БД в изолированную СУБД '+entry['id'])
                if engine!='postgres':run(['docker','restart',name]);ready(name)
                database_names=db_discover(database)['databases']
                if not set(entry['databases']).issubset(set(database_names)|{'information_schema','performance_schema','sys'}):raise ValueError('После импорта найдены не все базы')
    finally:
        run(['docker','rm','-f','-v',name],check=False,timeout=120)
        if engine!='postgres':run(['docker','rm','-f','-v',name+'-init'],check=False,timeout=120)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--job"); parser.add_argument("--operation"); parser.add_argument("--watchdog",action="store_true"); parser.add_argument("--recover",action="store_true"); parser.add_argument("--job-id");parser.add_argument("--health",action="store_true");parser.add_argument("--external-watchdog",action="store_true")
    args=parser.parse_args()
    def terminate(signum,frame): raise RuntimeError("Операция прервана")
    signal.signal(signal.SIGTERM,terminate)
    try:
        if args.health: result=health()
        elif args.external_watchdog: result=external_watchdog()
        elif args.recover: result=recover(args.job_id)
        elif args.watchdog: result=watchdog()
        elif args.job: result=execute_job(ident(args.job))
        elif args.operation:
            r=config("operations",args.operation)
            if r["command"]=="job-dry":
                result=execute_job(r["job_id"],True,state_id=args.operation); write(state_path(args.operation),result)
            else: result=operation(args.operation)
        else: result=dispatch(json.load(sys.stdin))
        print(json.dumps({"ok":True,"result":result},ensure_ascii=False))
        if (args.job or args.operation) and isinstance(result,dict) and result.get("status") in ["failed","incomplete"]: sys.exit(1)
    except Exception as e:
        print(json.dumps({"ok":False,"error":str(e)},ensure_ascii=False)); sys.exit(1)

if __name__=="__main__": main()
