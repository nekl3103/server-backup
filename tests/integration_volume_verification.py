"""A new local volume + Compose fixture. Never uses existing server containers."""
import importlib.util,json,os,pathlib,subprocess,tempfile,time,uuid
from integration_database_journals import command,PROJECT

def test():
    suffix=uuid.uuid4().hex[:10];name='sb-validation-volume-'+suffix;destination=name+'-restored';database=name+'-pg';volume=name+'-data';restored_volume=name+'-restored-data'
    with tempfile.TemporaryDirectory(prefix='sb-volume-',dir='/private/tmp') as folder:
        root=pathlib.Path(folder);spec=importlib.util.spec_from_file_location('volume_helper',PROJECT/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
        h.ROOT=root/'server-backup';h.ROOT.mkdir();os.environ['SERVER_BACKUP_ROOT']=str(h.ROOT)
        repo={'id':'fixture','repository':str(root/'repo'),'password':'fixture-only'}
        def restic(repository,args,timeout=120):
            return subprocess.run(['docker','exec',name,'env','RESTIC_PASSWORD='+repository['password'],'restic','-r',repository['repository'],*args],capture_output=True,text=True,timeout=timeout)
        h.restic=restic
        try:
            command('docker','volume','create',volume);command('docker','volume','create',restored_volume)
            command('docker','run','-d','--name',name,'--network','none','-v',str(root)+':'+str(root),'-v',volume+':/work/named','sb-validation-linux:local')
            command('docker','exec',name,'sh','-c',"printf 'volume original' > /work/named/example.txt")
            compose=root/'compose.yaml';compose.write_text('services:\n  fixture:\n    image: sb-validation-linux:local\n    volumes:\n      - fixture:/work/named\nvolumes:\n  fixture: {}\n')
            dump=h.ROOT/'dumps/fixture';dump.mkdir(parents=True)
            command('docker','run','-d','--name',database,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16')
            db={'id':'postgres-fixture','engine':'postgres','container':database,'user':'postgres','host':'localhost','databases':['example'],'backup_mode':'dump'}
            deadline=time.monotonic()+120
            while True:
                try:h.db_query(db,'SELECT 1;');break
                except RuntimeError:
                    if time.monotonic()>deadline:raise
                    time.sleep(1)
            h.db_query(db,'CREATE DATABASE example;')
            h.db_query({**db,'maintenance_db':'example'},"CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO items VALUES(1,'fixture');")
            dbfolder=dump/db['id'];dbfolder.mkdir();entry=h.dump_db(db,dbfolder)
            h.write(dump/'manifest.json',{'databases':[entry],'docker':[{'name':'fixture','mounts':[{'Source':'/work/named','Name':volume,'Type':'volume'}],'labels':{'com.docker.compose.project.config_files':str(compose),'com.docker.compose.project.working_dir':str(root)}}]})
            assert restic(repo,['init']).returncode==0
            backup=restic(repo,['backup','--json','/work/named',str(compose),str(dump)]);assert backup.returncode==0,backup.stderr
            snapshot=json.loads(backup.stdout.splitlines()[-1])['snapshot_id']
            verified=h.verify_full_restore(repo,snapshot);assert verified['status']=='success' and [x['kind'] for x in verified['checks']]==['files','database','docker-volumes'],verified
            target=root/'restore';restore=restic(repo,['restore',snapshot,'--target',str(target),'--verify']);assert restore.returncode==0,restore.stderr
            command('docker','run','-d','--name',destination,'--network','none','-v',restored_volume+':/work/named','sb-validation-linux:local')
            command('docker','cp',str(target/'work/named')+'/.',destination+':/work/named')
            assert command('docker','exec',destination,'cat','/work/named/example.txt')=='volume original'
            print('REAL_FILES_POSTGRES_VOLUME_COMPOSE_FULL_VERIFICATION_OK',flush=True)
        finally:
            for container in (name,destination,database):command('docker','rm','-f','-v',container,check=False)
            for item in (volume,restored_volume):command('docker','volume','rm',item,check=False)
            os.environ.pop('SERVER_BACKUP_ROOT',None)

if __name__=='__main__':test()
