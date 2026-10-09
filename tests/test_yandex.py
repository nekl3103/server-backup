import importlib.util,json,pathlib,tempfile,subprocess,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_yandex',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class YandexTests(unittest.TestCase):
    def setUp(self):self.admin=patch.object(h,"require_admin");self.admin.start()
    def tearDown(self):self.admin.stop()
    def repo(self):return {'id':'disk-01','type':'yandex','path':'Server Backup/сервер " one','token':json.dumps({'access_token':'fixture-token-value','refresh_token':'fixture-refresh-value','token_type':'OAuth','expiry':'2030-01-01T00:00:00Z'}),'password':'fixture-password','repository':'unused'}
    def test_full_json_token_preserved(self):
        r=self.repo();_,token,_=h.yandex_repository(r);self.assertEqual(json.loads(token),json.loads(r['token']))
    def test_missing_refresh_requires_new_login(self):
        for token in ['fixture-token-value',json.dumps({'access_token':'fixture-token-value'}),json.dumps({'access_token':'fixture-token-value','refresh_token':''})]:
            r=self.repo();r['token']=token
            with self.assertRaisesRegex(ValueError,'refresh_token'):h.yandex_repository(r)
    def test_path_and_token_validation(self):
        for value in ['','/','../repo','a/../b','a\nb']:
            r=self.repo();r['path']=value
            with self.assertRaises(ValueError):h.yandex_repository(r)
        for token in ['', 'x\nTOKEN=secret','{}','{"access_token":[]}']:
            r=self.repo();r['token']=token
            with self.assertRaises(ValueError):h.yandex_repository(r)
    def test_environment_credentials_not_in_repository_or_arguments(self):
        r=self.repo()
        with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),h.repository_env(r) as env:
            _,token,alias=h.yandex_repository(r);self.assertEqual(env['RESTIC_REPOSITORY'],'rclone:'+alias+':'+r['path']);self.assertNotIn(token,env['RESTIC_REPOSITORY']);self.assertNotIn(token,' '.join(h.restic_args(env)));self.assertEqual(json.loads(env['RCLONE_CONFIG_'+alias.upper()+'_TOKEN']),json.loads(r['token']));self.assertEqual(pathlib.Path(env['RESTIC_PASSWORD_FILE']).stat().st_mode&0o777,0o600)
    def test_no_rclone_has_explicit_error(self):
        with patch.object(h.shutil,'which',return_value=None):
            with self.assertRaisesRegex(ValueError,'установите rclone'):h.yandex_environment(self.repo())
    def test_access_error_never_initializes_or_exposes_token(self):
        with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],1,'','fixture-token-value')) as run:
            with self.assertRaises(RuntimeError) as err:h.yandex_check(self.repo())
            self.assertNotIn('fixture-token-value',str(err.exception));self.assertEqual(run.call_args.args[0][:2],['rclone','about'])
    def test_access_quota(self):
        with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,'{"free":123}','')):
            self.assertEqual(h.yandex_check(self.repo())['quota']['free'],123)
    def test_save_checks_before_writing_and_normalizes(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(h,'ROOT',pathlib.Path(tmp)),patch.object(h,'inspect_repo',side_effect=RuntimeError('access denied')):
            with self.assertRaises(RuntimeError):h.dispatch({'action':'save_repository','repository':self.repo()})
            self.assertFalse((h.ROOT/'repositories/disk-01.json').exists())
        with tempfile.TemporaryDirectory() as tmp,patch.object(h,'ROOT',pathlib.Path(tmp)),patch.object(h,'inspect_repo',return_value={'id':'fixture'}):
            h.dispatch({'action':'save_repository','repository':self.repo()});r=h.read(h.ROOT/'repositories/disk-01.json');self.assertTrue(r['repository'].startswith('rclone:sby'));self.assertEqual(h.redacted(r)['token'],'••••••');self.assertEqual(json.loads(r['token'])['refresh_token'],'fixture-refresh-value');self.assertEqual(json.loads(r['token'])['expiry'],'2030-01-01T00:00:00Z')

    def test_prepare_updates_helper_without_touching_jobs(self):
        with tempfile.TemporaryDirectory() as tmp:
            target=pathlib.Path(tmp)/'helper.py';target.write_text('previous');jobs=pathlib.Path(tmp)/'jobs.json';jobs.write_text('existing settings')
            with patch.object(h,'HELPER',str(target)),patch.object(h,'probe',return_value={'os':{'ID':'ubuntu'}}),patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),patch.dict(h.os.environ,{'SB_HELPER_SOURCE':'updated helper'}),patch.object(h,'tool_version',return_value='rclone fixture'),patch.object(h,'run') as run:
                h.install_rclone();run.assert_not_called()
            self.assertEqual(target.read_text(),'updated helper');self.assertEqual(target.stat().st_mode&0o777,0o700);self.assertEqual(jobs.read_text(),'existing settings')

    def test_auth_network_errors_and_timeout_have_safe_diagnostics(self):
        for error,expected in [('401 Unauthorized fixture-token-value','отклонил'),('403 Forbidden fixture-refresh-value','запретил'),('dial tcp connection refused','API'),('Unable to get RefreshToken','обновить')]:
            with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],1,'',error)):
                with self.assertRaises(RuntimeError) as caught:h.yandex_check(self.repo())
                self.assertIn(expected,str(caught.exception));self.assertNotIn('fixture-token-value',str(caught.exception));self.assertNotIn('fixture-refresh-value',str(caught.exception))
        with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'),patch.object(h,'run',side_effect=subprocess.TimeoutExpired('rclone',90)):
            with self.assertRaisesRegex(RuntimeError,'90 секунд'):h.yandex_check(self.repo())

    def test_opaque_refresh_token_with_yandex_colons_and_padding(self):
        r=self.repo();value=json.loads(r['token']);value['refresh_token']='1:fixture-id:fixture_body-abc_123:fixture-signature=='
        r['token']=json.dumps(value)
        _,normalized,alias=h.yandex_repository(r);self.assertEqual(json.loads(normalized),value)
        with patch.object(h.shutil,'which',return_value='/usr/bin/rclone'):
            env=h.yandex_environment(r)
        self.assertEqual(json.loads(env['RCLONE_CONFIG_'+alias.upper()+'_TOKEN'])['refresh_token'],value['refresh_token'])
        with tempfile.TemporaryDirectory() as tmp,patch.object(h,'ROOT',pathlib.Path(tmp)),patch.object(h,'inspect_repo',return_value={'id':'fixture'}):
            h.dispatch({'action':'save_repository','repository':r})
            self.assertEqual(json.loads(h.read(h.ROOT/'repositories/disk-01.json')['token']),value)
    def test_token_control_characters_and_oversized_values_rejected(self):
        for field in ('access_token','refresh_token'):
            for invalid in ('abc\ndef','abc\x00def','abc def','x'*4097,[],None):
                r=self.repo();value=json.loads(r['token']);value[field]=invalid;r['token']=json.dumps(value)
                with self.assertRaises(ValueError):h.yandex_repository(r)
