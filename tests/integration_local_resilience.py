"""Real Restic + SSH in an isolated Docker network. No production servers/ports."""
import json, pathlib, subprocess, tempfile, time, uuid
from integration_database_journals import command,python,PROJECT

def test():
    suffix=uuid.uuid4().hex[:10];network='sb-validation-net-'+suffix;observer='sb-validation-observer-'+suffix;target='sb-validation-watch-'+suffix
    containers=[]
    try:
        command('docker','network','create',network)
        for name in (observer,target):
            command('docker','run','-d','--name',name,'--network',network,'--tmpfs','/work/full:rw,size=1m','sb-validation-linux:local');containers.append(name)
            command('docker','cp',str(PROJECT/'backend/helper.py'),name+':/helper.py')
            command('docker','exec',name,'sh','-c','mkdir -p /usr/local/lib/server-backup /run/sshd /root/.ssh; cp /helper.py /usr/local/lib/server-backup/helper.py; chmod 700 /usr/local/lib/server-backup/helper.py /root/.ssh; ssh-keygen -A; /usr/sbin/sshd')
        prefix="import sys,json,pathlib,datetime,os;sys.path.insert(0,'/');import helper as h;h.ROOT=pathlib.Path('/var/lib/server-backup');h.ROOT.mkdir(parents=True,exist_ok=True)\n"
        key=json.loads(python(observer,prefix+"print(json.dumps(h.external_key()))"))['public_key']
        python(target,prefix+"os.environ['SB_HELPER_SOURCE']=pathlib.Path('/helper.py').read_text();h.allow_monitor({'confirmed':True,'user':'root','public_key':"+repr(key)+"});h.write(h.ROOT/'jobs/daily.json',{'id':'daily','repository_id':'repo','sources':['/data'],'created':h.now()});h.write(h.ROOT/'history/good.json',{'id':'daily','operation':'backup','status':'success','finished':h.now()})")
        # The fixture owns both ends: pin the exact server public key, rather than trusting an unknown scan.
        host_key=command('docker','exec',target,'cat','/etc/ssh/ssh_host_ed25519_key.pub').split()
        known=target+' '+host_key[0]+' '+host_key[1]+'\n'
        setup="folder=h.ROOT/'external';(folder/'known_hosts').write_text("+repr(known)+");h.write(folder/'settings.json',{'enabled':True,'targets':[{'id':'target','name':'Fixture','host':"+repr(target)+",'port':22,'user':'root'}]})\n"
        result=json.loads(python(observer,prefix+setup+"print(json.dumps(h.external_watchdog()))"));assert result['servers'][0].get('issue') is None,result
        print('EXTERNAL_SSH_HEALTH_OK',flush=True)
        # Forced command rejects arbitrary shell commands; it always returns only health JSON.
        cmd=['docker','exec',observer,'ssh','-n','-i','/var/lib/server-backup/external/id_ed25519','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile=/var/lib/server-backup/external/known_hosts','root@'+target,'touch /tmp/should-not-exist']
        response=json.loads(command(*cmd));assert response['ok'];assert 'absent'==command('docker','exec',target,'sh','-c','test ! -e /tmp/should-not-exist && echo absent').strip()
        print('EXTERNAL_RESTRICTED_KEY_OK',flush=True)
        command('docker','stop',target)
        result=json.loads(python(observer,prefix+"print(json.dumps(h.external_watchdog()))"));assert result['servers'][0]['issue'],result
        print('EXTERNAL_OFFLINE_DETECTED_OK',flush=True)
        command('docker','start',target);command('docker','exec',target,'/usr/sbin/sshd')
        result=json.loads(python(observer,prefix+"print(json.dumps(h.external_watchdog()))"));assert result['servers'][0].get('issue') is None,result
        print('EXTERNAL_RECOVERY_OK',flush=True)
        # Real Restic: two deduplicated versions, target copy, exact restore and repository-unavailable failure.
        source='''
import tempfile,contextlib,subprocess,hashlib
folder=pathlib.Path('/work');folder.mkdir(exist_ok=True);data=folder/'data';data.mkdir();(data/'file.txt').write_text('one')
repo={'id':'main','type':'fixture','repository':'/work/repo','password':'fixture-only'}
other={**repo,'id':'extra','repository':'/work/extra'}
# Only fixture repository_env branch bypasses disk UUID validation: these are Docker scratch directories.
for r in (repo,other):
    p=h.restic(r,['init']);assert p.returncode==0,p.stderr
p=h.restic(repo,['backup','--json',str(data)]);assert p.returncode==0,p.stderr
one=json.loads(p.stdout.splitlines()[-1]);assert one['snapshot_id']
(data/'file.txt').write_text('two');(data/'added.txt').write_text('new')
p=h.restic(repo,['backup','--json',str(data)]);assert p.returncode==0,p.stderr
two=json.loads(p.stdout.splitlines()[-1]);assert two['files_unmodified']>=0
h.copy_snapshot(repo,other,two['snapshot_id'])
for snapshot,expected in [(one['snapshot_id'],'one'),(two['snapshot_id'],'two')]:
    with tempfile.TemporaryDirectory(dir=folder) as dest:
        p=h.restic(repo,['restore',snapshot,'--target',dest,'--verify']);assert p.returncode==0,p.stderr
        assert (pathlib.Path(dest)/str(data/'file.txt').lstrip('/')).read_text()==expected
h.write(h.ROOT/'repositories/main.json',repo)
history=h.snapshot_file_history({'repository_id':'main','path':str(data/'file.txt')});assert len(history['versions'])==2 and all(v['present'] for v in history['versions'])
content=h.snapshot_content({'repository_id':'main','path':str(data/'file.txt'),'snapshot':one['snapshot_id']});assert not content['same'] and '-one' in content['diff']
result=h.verify_full_restore(repo,two['snapshot_id']);assert result['status']=='success' and not result['sample_only']
bad={**repo,'repository':'/work/missing'};assert h.restic(bad,['snapshots']).returncode!=0
full={**repo,'id':'full','repository':'/work/full/repo'};assert h.restic(full,['init']).returncode==0
large=folder/'full-source';large.mkdir();(large/'random.bin').write_bytes(os.urandom(4*1024**2));failed=h.restic(full,['backup',str(large)]);assert failed.returncode!=0 and ('space' in failed.stderr.lower() or 'write' in failed.stderr.lower()),failed.stderr
print('RESTIC_TWO_VERSIONS_HISTORY_CONTENT_COPY_FULL_VERIFY_OK');print('REAL_FULL_DISK_FAILURE_OK')
'''
        print(python(observer,prefix+source).strip(),flush=True)
        storage_key=json.loads(python(observer,prefix+"folder=h.ROOT/'sftp';folder.mkdir(mode=0o700);key=folder/'sb-storage.key';h.run(['ssh-keygen','-t','ed25519','-N','','-f',str(key)]);(folder/'sb-storage.known_hosts').write_text("+repr(known)+");print(json.dumps(pathlib.Path(str(key)+'.pub').read_text()))"))
        python(target,prefix+"with open('/root/.ssh/authorized_keys','a') as f:f.write('restrict '+"+repr(storage_key)+")")
        storage={'id':'storage','type':'sftp','repository':'sftp:fixture:/work/storage','host':target,'user':'root','port':22,'path':'/work/storage','password':'fixture-only'}
        python(observer,prefix+"repo="+repr(storage)+";h.write(h.ROOT/'repositories/storage.json',repo);assert h.restic(repo,['init']).returncode==0;source=h.config('repositories','main');snapshot=json.loads(h.restic(source,['snapshots','--json']).stdout)[-1]['id'];h.copy_snapshot(source,repo,snapshot);assert h.restic(repo,['snapshots']).returncode==0;print('SFTP_COPY_OK')")
        print('SFTP_REAL_COPY_OK',flush=True)
        replicated_job=prefix+"h.write(h.ROOT/'jobs/replicated.json',{'id':'replicated','name':'Fixture replicas','repository_id':'main','replica_ids':['storage'],'sources':['/work/data'],'daily':14,'weekly':4});result=h.execute_job('replicated');assert result['status']=='success' and [x['status'] for x in result['destinations']]==['success','success'],result;print('REAL_MULTI_DESTINATION_JOB_OK')"
        print(python(observer,replicated_job).strip(),flush=True)
        job_source=prefix+"folder=pathlib.Path('/work/interruption');folder.mkdir();(folder/'random.bin').write_bytes(os.urandom(32*1024**2));h.write(h.ROOT/'jobs/interrupted.json',{'id':'interrupted','repository_id':'storage','sources':[str(folder)],'limit_upload':128,'daily':14,'weekly':4});print(json.dumps(h.execute_job('interrupted')['status']))"
        process=subprocess.Popen(['docker','exec','-i',observer,'python3','-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        process.stdin.write(job_source);process.stdin.close();process.stdin=None
        time.sleep(2);command('docker','stop',target)
        output,error=process.communicate(timeout=90);assert process.returncode==0 and json.loads(output)=='failed',(output,error)
        result=json.loads(python(observer,prefix+"print(json.dumps(h.read(h.state_path('interrupted'))))"));assert result['status']=='failed' and result.get('error')
        print('REAL_SFTP_INTERRUPTION_PERSISTS_FAILED_RESULT_OK',flush=True)
        result=json.loads(python(observer,prefix+"print(json.dumps(h.execute_job('replicated')))"));assert result['status']=='success' and result['replication_errors'] and result['destinations'][-1]['status']=='failed',result
        print('REAL_PRIMARY_SUCCESS_SECONDARY_FAILURE_SEPARATE_RESULTS_OK',flush=True)

    finally:
        for name in containers:command('docker','rm','-f','-v',name,check=False)
        command('docker','network','rm',network,check=False)
if __name__=='__main__':test()
