"""Offline OAuth transport regression: no real token and no Yandex requests."""
import importlib.util,json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('helper',root/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
repo={'id':'fixture','path':'test','token':json.dumps({'access_token':'fixture-access-token','refresh_token':'1:fixture-id:fixture-refresh-token:fixture-signature==','token_type':'OAuth','expiry':'2030-01-01T00:00:00Z'})}
env=os.environ.copy();env.update(h.yandex_environment(repo))
env.update(HTTPS_PROXY='http://127.0.0.1:9',HTTP_PROXY='http://127.0.0.1:9',NO_PROXY='',no_proxy='')
_,_,alias=h.yandex_repository(repo)
args=['rclone','about',alias+':','--json','--retries','1','--low-level-retries','1','--contimeout','1s','--timeout','1s']
old=env.copy();old['RCLONE_CONFIG_'+alias.upper()+'_TOKEN']=json.dumps({'access_token':'fixture-access-token','token_type':'OAuth'})
a=subprocess.run(args,env=old,capture_output=True,text=True,timeout=15)
b=subprocess.run(args,env=env,capture_output=True,text=True,timeout=15)
assert 'RefreshToken' in a.stderr,'Old rclone must reproduce the missing RefreshToken failure'
assert 'RefreshToken' not in b.stderr,'Complete token must pass OAuth initialization'
assert '127.0.0.1:9' in b.stderr,'All network requests must use the blocked local proxy'
print('REAL RCLONE MISSING REFRESHTOKEN REPRODUCED')
print('FULL OAUTH JSON INITIALIZATION PASSED')
print('OFFLINE TEST; NO REAL YANDEX ACCOUNT USED')
