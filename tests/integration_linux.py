"""Executed inside the isolated Ubuntu test container. No production hosts."""
import importlib.util,json,os,pathlib,subprocess,time,shutil
spec=importlib.util.spec_from_file_location('helper','/test/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.ROOT=pathlib.Path('/test/server-backup');
for item in ['/test/server-backup','/test/repository','/test/source','/test/restore-1','/test/restore-2','/test/s3-restore','/test/db-restore']: shutil.rmtree(item,ignore_errors=True)
h.ROOT.mkdir(exist_ok=True)
def report(name):print('PASS:',name,flush=True)
def restic(repo,args):
 p=h.restic(repo,args,timeout=300)
 assert p.returncode==0,(p.returncode,p.stderr)
 return p
# SFTP: a real SSH/SFTP endpoint, a dedicated key and strict host-key verification.
r={'id':'ssh','type':'sftp','host':'localhost','port':22,'user':'root','path':'/test/repository','repository':'sftp:sb-ssh:/test/repository','password':'integration-restic-password'}
h.dispatch({'action':'sftp_key','repository_id':'ssh'})
pub=(h.ROOT/'sftp/sb-ssh.key.pub').read_text();pathlib.Path('/root/.ssh').mkdir(mode=0o700,exist_ok=True);pathlib.Path('/root/.ssh/authorized_keys').write_text(pub)
scan=h.dispatch({'action':'sftp_scan','host':'localhost','port':22});h.dispatch({'action':'sftp_trust','repository_id':'ssh','known_hosts':scan['known_hosts'],'confirmed':True})
h.dispatch({'action':'save_repository','repository':r,'initialize':True,'confirmed':True});report('SFTP init, key authentication and host pinning')
source=pathlib.Path('/test/source');source.mkdir(exist_ok=True)
(source/'with spaces.txt').write_text('first version');(source/"quotes' $() ;.txt").write_text('no shell interpretation')
(source/'unchanged.bin').write_bytes(os.urandom(1024*1024));(source/'excluded').write_text('exclude me')
j={'id':'daily','repository_id':'ssh','sources':[str(source)],'excludes':[str(source/'excluded')],'daily':14,'weekly':4,'read_concurrency':2,'containers':[],'database_ids':[]}
h.write(h.ROOT/'jobs/daily.json',j)
state=h.execute_job('daily');assert state['status']=='success',state
first=json.loads(restic(r,['snapshots','--json']).stdout)[-1]['id']
(source/'with spaces.txt').write_text('second version');time.sleep(1)
state=h.execute_job('daily');assert state['status']=='success',state
second=json.loads(restic(r,['snapshots','--json']).stdout)[-1]['id'];assert first!=second
assert state['summary'].get('data_added_packed',state['summary']['data_added'])<100_000,state['summary'];report('two snapshots, deduplication, excludes and special characters')
for snapshot,expected,folder in [(first,'first version','restore-1'),(second,'second version','restore-2')]:
 target='/test/'+folder;restic(r,['restore',snapshot,'--target',target,'--verify']);assert pathlib.Path(target,'test/source/with spaces.txt').read_text()==expected;assert not pathlib.Path(target,'test/source/excluded').exists()
report('both snapshot versions restore correctly')
restic(r,['check','--read-data']);report('full repository data check')
bad={**r,'password':'incorrect'}
try:h.inspect_repo(bad);raise AssertionError('wrong password accepted')
except RuntimeError:pass
report('wrong repository password rejected')
# Replace stored host key with another valid key; repository must stop, not trust silently.
key=h.ROOT/'sftp/bad';subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
known=h.ROOT/'sftp/sb-ssh.known_hosts';old=known.read_text();known.write_text('localhost '+pathlib.Path(str(key)+'.pub').read_text())
assert h.restic(r,['snapshots']).returncode!=0;known.write_text(old);report('changed SFTP host key rejected')
# S3 is a separate test MinIO instance; Restic can create the test bucket.
s3={'id':'s3','type':'s3','repository':'s3:http://server-backup-test-s3:5000/restic-tests/run-'+__import__('uuid').uuid4().hex,'password':'integration-restic-password','access_key':'sbtestuser','secret_key':'sbtestpassword','region':'us-east-1'}
h.dispatch({'action':'save_repository','repository':s3,'initialize':True,'confirmed':True})
restic(s3,['backup','--json',str(source)]);restic(s3,['restore','latest','--target','/test/s3-restore','--verify']);assert pathlib.Path('/test/s3-restore/test/source/with spaces.txt').read_text()=='second version';report('S3 backup and verified restore')
# Copy between SFTP and S3 using stored source and destination profiles.
h.write(h.ROOT/'operations/copy-test.json',{'command':'copy','repository_id':'s3','from_repository_id':'ssh','args':[],'confirmed':True})
state=h.operation('copy-test');assert state['status']=='success',state;report('repository copy SFTP to S3')
# Databases: local client tools connect to isolated database containers.
for engine,host,port,user in [('postgres','server-backup-test-pg',5432,'postgres'),('mariadb','server-backup-test-maria',3306,'root'),('mysql','server-backup-test-mysql',3306,'root')]:
 db={'id':engine,'engine':engine,'host':host,'port':port,'user':user,'password':'sbtestpassword','databases':['sb_test'],'consistency':'transaction'}
 for attempt in range(60):
  try:h.db_discover(db);break
  except Exception:time.sleep(1)
 else:raise RuntimeError('DB did not start: '+engine)
 if engine=='postgres':
  h.db_query(db,'DROP DATABASE IF EXISTS sb_test;');h.db_query(db,'CREATE DATABASE sb_test;');db['maintenance_db']='sb_test';h.db_query(db,'CREATE TABLE example (id integer, value text); INSERT INTO example VALUES (1,\'original\');')
 else:h.db_query(db,"DROP DATABASE IF EXISTS sb_test; CREATE DATABASE sb_test; CREATE TABLE sb_test.example (id INT, value TEXT) ENGINE=InnoDB; INSERT INTO sb_test.example VALUES (1,'original');")
 folder=h.ROOT/'dumps/db-job'/engine;folder.mkdir(parents=True,exist_ok=True);entry=h.dump_db(db,folder)
 h.write(h.ROOT/'dumps/db-job/manifest.json',{'databases':[entry],'docker':[]})
 restore=pathlib.Path('/test/db-restore');import shutil;shutil.rmtree(restore,ignore_errors=True)
 destination=restore/pathlib.Path(str(h.ROOT/'dumps/db-job')).relative_to('/');destination.parent.mkdir(parents=True,exist_ok=True);shutil.copytree(h.ROOT/'dumps/db-job',destination)
 if engine=='postgres':h.db_query(db,'DROP TABLE example;');db['maintenance_db']='postgres'
 else:h.db_query(db,'DROP TABLE sb_test.example;')
 h.restore_database({'target':str(restore),'database_id':engine,'database':db,'confirmed':True})
 if engine=='postgres':db['maintenance_db']='sb_test';value=h.db_query(db,'SELECT value FROM example;')
 else:value=h.db_query(db,'SELECT value FROM sb_test.example;')
 assert value.strip()=='original',(engine,value);report(engine+' dump and import')
report('all live integration scenarios completed')
