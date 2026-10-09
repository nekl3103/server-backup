import importlib.util,json,pathlib,tempfile,datetime,subprocess,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('resilience',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class ResilienceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name).resolve();self.old=h.ROOT;h.ROOT=self.root
        self.admin=patch.object(h,'require_admin');self.admin.start()
    def tearDown(self):self.admin.stop();h.ROOT=self.old;self.tmp.cleanup()
    def job(self,**kwargs):
        value={'id':'daily','repository_id':'repo','enabled':True,'created':(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=2)).isoformat()};value.update(kwargs);h.write(self.root/'jobs/daily.json',value);return value
    def history(self,**kwargs):
        value={'id':'daily','operation':'backup','status':'success','finished':h.now(),'summary':{'snapshot_id':'abc'}};value.update(kwargs);h.write(self.root/'history/record.json',value)
    def test_health_never_marks_absent_backup_as_fresh(self):
        self.job();self.assertTrue(h.health()['jobs'][0]['stale']);self.history();self.assertFalse(h.health()['jobs'][0]['stale'])
    def test_disabled_job_not_stale(self):
        self.job(enabled=False);self.assertFalse(h.health()['jobs'][0]['stale'])
    def test_failed_result_and_old_success_are_visible(self):
        self.job();self.history(status='failed');r=h.health()['jobs'][0];self.assertEqual(r['last_status'],'failed');self.assertTrue(r['stale']);self.assertIsNone(r['last_success'])
    def test_sample_rejects_traversal_symlink_and_big_files(self):
        nodes=[{'type':'file','path':'/a/../secret','size':1},{'type':'symlink','path':'/link','size':1},{'type':'file','path':'/large','size':20*1024*1024},{'type':'file','path':'/valid','size':10}];self.assertEqual(h.sample_candidates(nodes),[{'path':'/valid','size':10}])
    def test_sample_has_file_and_total_limits(self):
        nodes=[{'type':'file','path':'/'+str(i),'size':16*1024*1024} for i in range(10)];self.assertEqual(len(h.sample_candidates(nodes)),2)
    def test_forecast_requires_time_and_valid_free_space(self):
        self.assertIsNone(h.capacity_forecast([{'time':'2026-10-01T00:00:00Z','bytes':100}],100)['days_remaining'])
        points=[{'time':'2026-10-01T00:00:00Z','bytes':100},{'time':'2026-10-03T00:00:00Z','bytes':300}];self.assertEqual(h.capacity_forecast(points,500)['days_remaining'],5);self.assertIsNone(h.capacity_forecast(points,None)['days_remaining'])
    def test_forecast_negative_growth_no_false_exhaustion(self):
        points=[{'time':'2026-10-01T00:00:00Z','bytes':300},{'time':'2026-10-03T00:00:00Z','bytes':100}];r=h.capacity_forecast(points,100);self.assertEqual(r['bytes_per_day'],-100);self.assertIsNone(r['days_remaining'])
    def test_calendar_uses_server_day_and_ignores_dry_run(self):
        self.job();self.history(finished='2026-10-08T12:00:00Z');rows=h.calendar_data()['records'];self.assertEqual(len(rows),1);self.assertEqual(rows[0]['repository_id'],'repo');self.history(dry_run=True);self.assertEqual(h.calendar_data()['records'],[])
    def test_configuration_version_belongs_to_exact_file(self):
        h.write(self.root/'program-backups/version.json',{'unit':'nginx.service','path':'/etc/nginx/nginx.conf','exists':True,'data':h.base64.b64encode(b'old').decode()})
        with patch.object(h,'config_versions',return_value={}):
            with self.assertRaises(ValueError):h.config_version({'unit':'nginx.service','path':'/etc/nginx/other.conf','version_id':'version'})
            self.assertEqual(h.config_version({'unit':'nginx.service','path':'/etc/nginx/nginx.conf','version_id':'version'})['content'],'old')
    def test_rollback_requires_confirmation(self):
        with self.assertRaises(ValueError):h.rollback_config({})
    def test_external_setup_requires_confirmation(self):
        with self.assertRaises(ValueError):h.external_setup({})
    def setup_external(self):
        folder=self.root/'external';folder.mkdir();h.write(folder/'settings.json',{'enabled':True,'targets':[{'id':'web','name':'Web','host':'127.0.0.1','port':22,'user':'root'}]});return folder
    def test_external_strict_key_and_readonly_command(self):
        self.setup_external();response=json.dumps({'ok':True,'result':{'jobs':[{'id':'daily','enabled':True,'stale':False,'last_status':'success'}]}})
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,response,'')) as run:
            self.assertIsNone(h.external_watchdog()['servers'][0]['issue']);argv=run.call_args.args[0];self.assertIn('StrictHostKeyChecking=yes',argv);self.assertIn('BatchMode=yes',argv);self.assertEqual(argv[-1],'root@127.0.0.1');self.assertNotIn('accept-new',argv)
    def test_external_without_targets_or_disabled_is_not_success(self):
        folder=self.setup_external()
        for settings in [{'enabled':False,'targets':[]},{'enabled':True,'targets':[]}]:
            h.write(folder/'settings.json',settings)
            with self.assertRaises(ValueError):h.external_watchdog()
    def test_external_reports_specific_ssh_errors(self):
        self.setup_external()
        for message,expected in [('Permission denied (publickey)','SSH-доступ'),('Host key verification failed','SSH-ключ'),('Connection refused','отклонил подключение')]:
            with patch.object(h,'run',return_value=subprocess.CompletedProcess([],255,'',message)),patch.object(h,'notify',return_value={'sent':False}):
                self.assertIn(expected,h.external_watchdog()['servers'][0]['issue'])
    def test_external_empty_jobs_requires_attention(self):
        self.setup_external()
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,json.dumps({'ok':True,'result':{'jobs':[]}}),'')),patch.object(h,'notify',return_value={'sent':False}):
            self.assertIn('не настроены',h.external_watchdog()['servers'][0]['issue'])
    def test_external_reports_current_target(self):
        self.setup_external();progress=[]
        response=json.dumps({'ok':True,'result':{'jobs':[{'id':'daily','enabled':True,'stale':False,'last_status':'success'}]}})
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,response,'')):
            result=h.external_watchdog(lambda name,done,total:progress.append((name,done,total)))
        self.assertEqual(progress,[('Web',0,1)])
        self.assertEqual(len(result['servers']),1)
    def test_external_offline_notifies_and_does_not_claim_healthy(self):
        folder=self.setup_external()
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],255,'','fixture')),patch.object(h,'notify',return_value={'sent':True}) as notify:
            result=h.external_watchdog();self.assertTrue(result['servers'][0]['issue']);notify.assert_called_once();self.assertIsNotNone(h.read(folder/'state-web.json').get('notified'))
            h.external_watchdog();notify.assert_called_once()
    def test_notification_failure_does_not_hide_server_error(self):
        folder=self.setup_external()
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],255,'','')),patch.object(h,'notify',return_value={'sent':False}):
            h.external_watchdog();state=h.read(folder/'state-web.json');self.assertTrue(state['issue']);self.assertNotIn('notified',state)
    def test_verify_operation_is_server_managed(self):
        with patch.object(h,'install_helper_source'),patch.object(h,'start_operation',return_value={'operation_id':'op-test'}) as start:
            r=h.dispatch({'action':'verify_restore','repository_id':'repo','snapshot':'abc'});self.assertEqual(r['operation_id'],'op-test');self.assertEqual(start.call_args.args[0]['command'],'verify-restore')
