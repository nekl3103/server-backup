"""Explicit local Docker test. Uses only new sb-validation-* containers, no host ports.
Requires locally built sb-validation-{pg,mysql,maria}:local images with Python3.
"""
import importlib.util, json, pathlib, subprocess, tempfile, time, uuid
PROJECT=pathlib.Path(__file__).parents[1]
def command(*argv,check=True,data=None):
    result=subprocess.run(list(argv),input=data,text=True,capture_output=True)
    if check and result.returncode:raise RuntimeError(result.stderr[-2000:] or result.stdout[-2000:])
    return result.stdout

def python(name,source):return command('docker','exec','-i',name,'python3','-',data=source)

def test(engine):
    image=('sb-validation-mysqlfull:local' if engine=='mysql' else 'sb-validation-'+engine+':local');suffix=uuid.uuid4().hex[:10];source='sb-validation-source-'+suffix;targets=[]
    kind={'pg':'postgres','maria':'mariadb','mysql':'mysql'}[engine]
    password='isolated-fixture'
    if engine=='pg':
        args=['-e','POSTGRES_PASSWORD='+password,'--entrypoint','bash',image,'-c',"mkdir -p /wal; chown postgres:postgres /wal; exec docker-entrypoint.sh postgres -c archive_mode=on -c wal_level=replica -c full_page_writes=on -c 'archive_command=test ! -f /wal/%f && cp %p /wal/%f'"]
    else:args=['-e','MYSQL_ROOT_PASSWORD='+password,('sb-validation-mysql:local' if engine=='mysql' else image),'--log-bin=sb-bin','--binlog-format=ROW','--server-id=45']
    db={'id':'fixture','engine':kind,'host':'127.0.0.1','port':5432 if engine=='pg' else 3306,'user':'postgres' if engine=='pg' else 'root','password':password,'databases':[],'backup_mode':'journal','consistency':'transaction','wal_archive':'/wal','checkpoint':'fast'}
    prefix="import sys,json,pathlib,time;sys.path.insert(0,'/');import helper as h;h.ROOT=pathlib.Path('/work/state');h.ROOT.mkdir(parents=True,exist_ok=True);db="+repr(db)+"\n"
    try:
        if engine=='mysql':
            dbname=source+'-db';targets.append(dbname)
            command('docker','run','-d','--name',dbname,'--network','none',*args)
            command('docker','run','-d','--name',source,'--network','container:'+dbname,image)
        else:command('docker','run','-d','--name',source,'--network','none',*args)
        command('docker','cp',str(PROJECT/'backend/helper.py'),source+':/helper.py')
        deadline=time.monotonic()+120
        while True:
            try:python(source,prefix+"h.db_query(db,'SELECT 1;')");break
            except RuntimeError:
                if time.monotonic()>deadline:raise
                time.sleep(1)
        statements="CREATE DATABASE example;" if engine!='pg' else 'CREATE DATABASE example;'
        python(source,prefix+"h.db_query(db,"+repr(statements)+")")
        sql='CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO items VALUES(1,\'before\');'
        if engine=='pg':python(source,prefix+"db['maintenance_db']='example';h.db_query(db,"+repr(sql)+")")
        else:python(source,prefix+"h.db_query(db,"+repr('USE example;'+sql)+")")
        python(source,prefix+"folder=pathlib.Path('/work/one');folder.mkdir();entry=h.dump_db(db,folder);h.write('/work/entry-one.json',entry);print('BASELINE_OK')")
        time.sleep(2)
        sql="UPDATE items SET value='after' WHERE id=1; INSERT INTO items VALUES(2,'new');"
        python(source,prefix+("db['maintenance_db']='example';" if engine=='pg' else '')+"h.db_query(db,"+repr(sql if engine=='pg' else 'USE example;'+sql)+")")
        python(source,prefix+"folder=pathlib.Path('/work/two');folder.mkdir();entry=h.dump_db(db,folder);h.write('/work/entry-two.json',entry);one=h.read('/work/entry-one.json');assert one['chain']['created']==entry['chain']['created'];assert one['chain']['checksums']['base/'+('base.tar' if db['engine']=='postgres' else 'database.sql')]==entry['chain']['checksums']['base/'+('base.tar' if db['engine']=='postgres' else 'database.sql')];print('INCREMENTAL_REUSES_BASE_OK')")
        python(source,prefix+"folder=pathlib.Path('/work/logical');folder.mkdir();entry=h.dump_db({**db,'backup_mode':'dump'},folder);h.write('/work/entry-logical.json',entry)")
        with tempfile.TemporaryDirectory() as export:
            command('docker','cp',source+':/work/.',export)
            spec=importlib.util.spec_from_file_location('fixture_helper',PROJECT/'backend/helper.py');host_helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(host_helper)
            host_helper.verify_isolated_database(json.loads(pathlib.Path(export,'entry-logical.json').read_text()),pathlib.Path(export,'logical'))
            print(engine,'ISOLATED_LOGICAL_IMPORT_OK',flush=True)
            if engine=='pg':
                host_helper.verify_isolated_database(json.loads(pathlib.Path(export,'entry-two.json').read_text()),pathlib.Path(export,'two'))
                print(engine,'ISOLATED_WAL_IMPORT_OK',flush=True)
            for version,expected in [('one','1|before' if engine=='pg' else '1\tbefore'),('two','1|after\n2|new' if engine=='pg' else '1\tafter\n2\tnew'),('pitr','1|before' if engine=='pg' else '1\tbefore')]:
                restore_version='two' if version=='pitr' else version
                recovery="'recovery_time':h.read('/work/entry-one.json')['chain']['through']," if version=='pitr' else ''
                target='sb-validation-target-'+version+'-'+suffix;targets.append(target)
                if engine=='pg':command('docker','run','-d','--name',target,'--network','none','--entrypoint','sleep',image,'3600')
                elif engine=='mysql':
                    dbname=target+'-db';targets.append(dbname)
                    command('docker','run','-d','--name',dbname,'--network','none','-e','MYSQL_ROOT_PASSWORD='+password,'sb-validation-mysql:local','--server-id=99')
                    command('docker','run','-d','--name',target,'--network','container:'+dbname,image)
                else:command('docker','run','-d','--name',target,'--network','none','-e','MYSQL_ROOT_PASSWORD='+password,image,'--server-id=99')
                command('docker','cp',str(PROJECT/'backend/helper.py'),target+':/helper.py');command('docker','cp',export+'/.',target+':/work');command('docker','exec',target,'chmod','711','/work')
                if engine=='pg':
                    result=python(target,prefix+"entry=h.read('/work/entry-"+restore_version+".json');h.restore_journal({"+recovery+"'database':db,'pgdata':'/work/recovered'},entry,pathlib.Path('/work/"+restore_version+"'));print('PREPARED')")
                    command('docker','exec','-u','postgres',target,'pg_ctl','-D','/work/recovered','-o',"-c listen_addresses='' -c unix_socket_directories=/tmp -c port=55432",'-l','/tmp/restore.log','-w','start')
                    result=command('docker','exec','-u','postgres',target,'psql','-h','/tmp','-p','55432','-d','example','-At','-c','SELECT id,value FROM items ORDER BY id;').strip()
                else:
                    deadline=time.monotonic()+120
                    while True:
                        try:python(target,prefix+"h.db_query(db,'SELECT 1;')");break
                        except RuntimeError:
                            if time.monotonic()>deadline:raise
                            time.sleep(1)
                    python(target,prefix+"entry=h.read('/work/entry-"+restore_version+".json');h.restore_journal({"+recovery+"'database':db},entry,pathlib.Path('/work/"+restore_version+"'))")
                    result=python(target,prefix+"print(h.db_query(db,'SELECT id,value FROM example.items ORDER BY id;').strip())").strip()
                assert result==expected,(engine,version,result,expected)
                print(engine,version,'RESTORED_OK',flush=True)
    finally:
        for name in [source]+targets:command('docker','rm','-f','-v',name,check=False)

if __name__=='__main__':
    import sys
    for engine in sys.argv[1:] or ['pg','mysql','maria']:test(engine)
