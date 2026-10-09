import importlib.util,json,pathlib,shutil
spec=importlib.util.spec_from_file_location('helper','/test/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.ROOT=pathlib.Path('/test/new-server-state');shutil.rmtree(h.ROOT,ignore_errors=True)
repo=json.loads(pathlib.Path('/test/source-s3-profile.json').read_text())
h.dispatch({'action':'save_repository','repository':repo,'initialize':False})
p=h.restic(repo,['snapshots','--json']);assert p.returncode==0,p.stderr
snapshots=json.loads(p.stdout);snapshot=next(x for x in reversed(snapshots) if 'sb-job-daily' in x.get('tags',[]))['id']
request={'command':'restore','repository_id':repo['id'],'snapshot':snapshot,'target':'/test/new-server-restore','includes':['/test/source'],'confirmed':True}
shutil.rmtree(request['target'],ignore_errors=True);h.restore_preflight(repo,request)
h.write(h.ROOT/'operations/restore-test.json',request)
state=h.operation('restore-test');assert state['status']=='success',state
assert pathlib.Path('/test/new-server-restore/test/source/with spaces.txt').read_text()=='second version'
print('PASS: independent second Linux server restores snapshot with exported S3 access')
