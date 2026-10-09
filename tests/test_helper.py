import contextlib, importlib.util, json, pathlib, subprocess, tempfile, unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.old=h.ROOT;h.ROOT=pathlib.Path(self.tmp.name)
    def tearDown(self): h.ROOT=self.old;self.tmp.cleanup()
    def repository(self): return {'id':'repo','type':'s3','repository':'s3:https://test/bucket','password':'sentinel-secret','access_key':'ak','secret_key':'sk'}
    def job(self):
        repo=self.repository();h.write(h.ROOT/'repositories/repo.json',repo)
        h.write(h.ROOT/'jobs/job.json',{'id':'job','repository_id':'repo','sources':['/data'],'containers':[],'database_ids':[],'daily':14,'weekly':4})
        return repo
    def test_id_injection(self):
        for value in ['../escape','a;touch /tmp/x','-bad\n','', 'x'*81]:
            with self.assertRaises(ValueError): h.ident(value)
    def test_secure_atomic_config(self):
        p=h.ROOT/'repositories/repo.json';h.write(p,{'password':'secret'});self.assertEqual(p.stat().st_mode&0o777,0o600);self.assertEqual(h.read(p)['password'],'secret')
    def test_redaction_nested(self):
        text=json.dumps(h.redacted({'password':'sentinel','items':[{'secret_key':'sentinel','token':'sentinel'}]}));self.assertNotIn('sentinel',text)
    def test_repo_lock_collision(self):
        with h.repo_lock(self.repository()):
            with self.assertRaises(RuntimeError):
                with h.repo_lock(self.repository()): pass
    def test_disk_missing(self):
        repo={'id':'disk','type':'disk','repository':'/mnt/backup/repo','mount':'/mnt/backup','uuid':'expected','password':'secret'}
        with patch.object(h,'run',side_effect=RuntimeError('missing')):
            with self.assertRaises(RuntimeError):
                with h.repository_env(repo): pass
    def test_disk_wrong_uuid(self):
        def command(args,**kwargs): return subprocess.CompletedProcess(args,0,'wrong\n','')
        repo={'id':'disk','type':'disk','repository':'/mnt/backup/repo','mount':'/mnt/backup','uuid':'expected','password':'secret'}
        with patch.object(h,'run',side_effect=command):
            with self.assertRaisesRegex(RuntimeError,'UUID'):
                with h.repository_env(repo): pass
    def test_unselected_mounts(self):
        with patch.object(h,'disks',return_value=[{'target':'/'},{'target':'/data'},{'target':'/other'}]):
            self.assertEqual(h.excluded_mounts(['/','/data/sites']),['/other'])
    def test_destructive_confirmation(self):
        with self.assertRaises(ValueError):h.command_args({'command':'prune','args':[]})
        self.assertEqual(h.command_args({'command':'prune','args':[],'confirmed':True}),['prune'])
    def test_override_rejected(self):
        with self.assertRaises(ValueError):h.command_args({'command':'snapshots','args':['--password-command=bad']})
    def test_nontransactional_refused(self):
        with patch.object(h,'db_discover',return_value={'table_engines':['MyISAM'],'version':'8.0','databases':['test']}):
            with self.assertRaisesRegex(RuntimeError,'нетранзакционные'):h.dump_db({'id':'db','engine':'mysql'},h.ROOT)
    def test_restore_root_refused(self):
        with self.assertRaises(ValueError): h.restored_manifest('/')
    def test_nonexistent_repo_not_initialized(self):
        with patch.object(h,'require_admin'), patch.object(h,'restic',return_value=subprocess.CompletedProcess([],12,'','bad password')) as call:
            with self.assertRaises(RuntimeError): h.dispatch({'action':'save_repository','repository':self.repository(),'initialize':False})
            self.assertEqual(call.call_args[0][1],['cat','config'])
    def test_recover_only_recorded_containers(self):
        h.write(h.stopped_path('job'),['container-a'])
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,'','')) as call:
            h.recover('job');self.assertEqual(call.call_args[0][0],['docker','start','container-a'])
        self.assertFalse(h.stopped_path('job').exists())
    def test_restart_failure_remains_recorded(self):
        h.write(h.stopped_path('job'),['container-a'])
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],1,'','failed')):
            with self.assertRaises(RuntimeError):h.recover('job')
        self.assertEqual(h.read(h.stopped_path('job')),['container-a'])
    def test_backup_failure_persists_and_no_prune(self):
        self.job()
        with patch.object(h,'require_admin'),patch.object(h,'recover'),patch.object(h,'disks',return_value=[]),patch.object(h,'repository_env',side_effect=RuntimeError('offline')),patch.object(h,'notify',return_value={'sent':False}),patch.object(h,'restic') as restic:
            state=h.execute_job('job');self.assertEqual(state['status'],'failed');self.assertEqual(h.read(h.state_path('job'))['status'],'failed');restic.assert_not_called();self.assertEqual(state['stages'][-1]['status'],'failed')
        self.assertEqual(len(list((h.ROOT/'history').glob('*.json'))),1)
    def test_backup_stages_stay_running_during_maintenance(self):
        self.job()
        class Sunday(h.datetime.datetime):
            @classmethod
            def now(cls, tz=None): return cls(2026,10,11,3,0,tzinfo=tz)
        class FakeProcess:
            stdout=iter(['{"message_type":"status","percent_done":0.5}\n','{"message_type":"summary","snapshot_id":"abc"}\n'])
            def wait(self,**kwargs):return 0
            def poll(self):return 0
        observed=[]
        def maintenance(*args,**kwargs):
            current=h.read(h.state_path('job'))
            observed.append((current['status'],current['stage'],current['stages'][-1]['status']))
            return subprocess.CompletedProcess([],0,'','')
        with patch.object(h,'require_admin'),patch.object(h,'recover'),patch.object(h,'disks',return_value=[]),patch.object(h,'repository_env',return_value=contextlib.nullcontext({})),patch.object(h.subprocess,'Popen',return_value=FakeProcess()),patch.object(h,'restic',side_effect=maintenance),patch.object(h.datetime,'datetime',Sunday):
            state=h.execute_job('job')
        self.assertEqual(observed,[('running','cleanup','running'),('running','check','running')])
        self.assertEqual(state['status'],'success')
        self.assertEqual([x['id'] for x in state['stages']],['prepare','backup','cleanup','check'])
        self.assertTrue(all(x['status']=='done' for x in state['stages']))
        self.assertIn('finished',state)
    def test_read_concurrency_compatibility(self):
        self.job();j=h.read(h.ROOT/'jobs/job.json');j['read_concurrency']=2;h.write(h.ROOT/'jobs/job.json',j)
        for supported in [False,True]:
            class FakeProcess:
                stdout=iter([])
                def wait(self,**kwargs):return 0
                def poll(self):return 0
            with patch.object(h,'require_admin'),patch.object(h,'require_dry_run'),patch.object(h,'disks',return_value=[]),patch.object(h,'restic_backup_supports',return_value=supported),patch.object(h,'repository_env',return_value=contextlib.nullcontext({})),patch.object(h.subprocess,'Popen',return_value=FakeProcess()) as process:
                state=h.execute_job('job',dry=True,state_id='op-dry')
            self.assertEqual(state['status'],'success')
            self.assertEqual('--read-concurrency' in process.call_args.args[0],supported)
            self.assertEqual(bool(state.get('warnings')),not supported)
            self.assertEqual(h.read(h.state_path('op-dry'))['status'],'success')
            self.assertTrue(h.read(h.state_path('op-dry'))['stages'])
    def test_job_schedule_validation(self):
        with self.assertRaises(ValueError):h.validate_job({'id':'job','repository_id':'repo','sources':['/data'],'time':'03:00\nExecStart=bad'})
        with self.assertRaises(ValueError):h.validate_job({'id':'job','repository_id':'repo','sources':['/data'],'daily':0,'weekly':0})
    def test_telegram_error_does_not_leak_token(self):
        h.write(h.ROOT/'telegram.json',{'token':'private-token','chat_id':'1'})
        with patch.object(h.urllib.request,'urlopen',side_effect=RuntimeError('URL includes private-token')):
            result=h.notify('test')
        self.assertFalse(result['sent']);self.assertNotIn('private-token',json.dumps(h.read(h.ROOT/'notification-error.json')))
    def test_incomplete_snapshot_no_cleanup(self):
        self.job()
        class FakeProcess:
            stdout=iter(['{"message_type":"summary","data_added":42}\n'])
            def wait(self,**kwargs):return 3
            def poll(self):return 3
        with patch.object(h,'require_admin'),patch.object(h,'recover'),patch.object(h,'disks',return_value=[]),patch.object(h,'repository_env',return_value=contextlib.nullcontext({})),patch.object(h.subprocess,'Popen',return_value=FakeProcess()),patch.object(h,'notify',return_value={'sent':False}),patch.object(h,'restic') as maintenance:
            state=h.execute_job('job');self.assertEqual(state['status'],'incomplete');maintenance.assert_not_called()
    def test_restore_space_checked(self):
        repo=self.repository()
        with patch.object(h,'restic',return_value=subprocess.CompletedProcess([],0,'{"total_size":1000000}','')),patch.object(h.shutil,'disk_usage',return_value=type('Usage',(),{'free':10})()):
            with self.assertRaisesRegex(ValueError,'Недостаточно'):h.restore_preflight(repo,{'target':str(h.ROOT/'restore'),'snapshot':'latest'})
    def test_watchdog_deduplicates_and_resets(self):
        created=(h.datetime.datetime.now(h.datetime.timezone.utc)-h.datetime.timedelta(hours=27)).isoformat()
        h.write(h.ROOT/'jobs/stale.json',{'id':'stale','enabled':True,'created':created})
        with patch.object(h,'notify',return_value={'sent':True}) as send:
            h.watchdog();h.watchdog();self.assertEqual(send.call_count,1)
            h.write(h.ROOT/'history/success.json',{'id':'stale','status':'success','finished':h.now(),'dry_run':False})
            h.watchdog();self.assertFalse((h.ROOT/'alerts/stale.json').exists());self.assertEqual(send.call_count,1)
    def test_schedule_edit_preserves_creation(self):
        self.job();j=h.read(h.ROOT/'jobs/job.json');j['created']='2020-01-01T00:00:00+00:00';h.write(h.ROOT/'jobs/job.json',j)
        j['created']=h.now();j['time']='04:30'
        with patch.object(h,'require_admin'),patch.object(h,'run'),patch.object(h,'UNITDIR',h.ROOT/'units'):
            h.save_job(j)
        self.assertEqual(h.read(h.ROOT/'jobs/job.json')['created'],'2020-01-01T00:00:00+00:00')
        self.assertIn('OnCalendar=*-*-* 04:30:00',(h.ROOT/'units/server-backup-job-job.timer').read_text())
        self.assertIn('ExecStopPost=',(h.ROOT/'units/server-backup-job-job.service').read_text())
    def test_dry_run_does_not_restart_containers(self):
        self.job()
        class FakeProcess:
            stdout=iter(['{"message_type":"summary","data_added":0}\n'])
            def wait(self,**kwargs):return 0
            def poll(self):return 0
        with patch.object(h,'require_dry_run'),patch.object(h,'require_admin'),patch.object(h,'recover') as recovery,patch.object(h,'disks',return_value=[]),patch.object(h,'repository_env',return_value=contextlib.nullcontext({})),patch.object(h.subprocess,'Popen',return_value=FakeProcess()),patch.object(h,'restic') as maintenance:
            state=h.execute_job('job',dry=True);self.assertTrue(state['dry_run']);recovery.assert_not_called();maintenance.assert_not_called()
    def test_own_operation_secrets_excluded(self):
        self.job();h.write(h.ROOT/'operations/import.json',{'database':{'password':'secret'}})
        class FakeProcess:
            stdout=iter([])
            def wait(self,**kwargs):return 3
            def poll(self):return 3
        with patch.object(h,'require_admin'),patch.object(h,'recover'),patch.object(h,'disks',return_value=[]),patch.object(h,'repository_env',return_value=contextlib.nullcontext({})),patch.object(h.subprocess,'Popen',return_value=FakeProcess()) as process,patch.object(h,'notify',return_value={'sent':False}):
            h.execute_job('job');args=process.call_args[0][0]
            self.assertIn(str(h.ROOT/'operations'),args)
            self.assertEqual(args[args.index(str(h.ROOT/'operations'))-1],'--exclude')
    def test_notifications_optional(self):
        with patch.object(h,'telegram_notify') as telegram, patch.object(h,'email_notify') as email:
            self.assertFalse(h.notify('test')['sent']);telegram.assert_not_called();email.assert_not_called()
    def test_disabled_telegram_preserves_credentials(self):
        h.write(h.ROOT/'telegram.json',{'enabled':False,'token':'sentinel','chat_id':'123'})
        with patch.object(h.urllib.request,'urlopen') as request:
            self.assertFalse(h.telegram_notify('test')['sent']);request.assert_not_called()
    def test_email_starttls(self):
        c={'enabled':True,'host':'smtp.example.com','port':587,'tls':'starttls','username':'u','password':'sentinel','sender':'backup@example.com','recipients':'a@example.com, b@example.com'}
        h.write(h.ROOT/'email.json',c)
        with patch.object(h.smtplib,'SMTP') as factory:
            smtp=factory.return_value.__enter__.return_value;smtp.send_message.return_value={}
            self.assertTrue(h.email_notify('hello')['sent']);smtp.starttls.assert_called_once();smtp.login.assert_called_once_with('u','sentinel')
            self.assertEqual(smtp.send_message.call_args.kwargs['to_addrs'],['a@example.com','b@example.com'])
    def test_email_error_isolated(self):
        h.write(h.ROOT/'email.json',{'enabled':True,'host':'smtp.example.com','port':465,'tls':'ssl','sender':'a@example.com','recipients':'b@example.com'})
        h.write(h.ROOT/'telegram.json',{'enabled':True,'token':'sentinel'})
        with patch.object(h.smtplib,'SMTP_SSL',side_effect=RuntimeError('sentinel')),patch.object(h,'telegram_notify',return_value={'sent':True}):
            result=h.notify('test');self.assertTrue(result['sent']);self.assertFalse(result['channels']['email']['sent']);self.assertNotIn('sentinel',(h.ROOT/'email-error.json').read_text())
    def test_success_preferences_per_channel(self):
        h.write(h.ROOT/'telegram.json',{'enabled':True,'success':False});h.write(h.ROOT/'email.json',{'enabled':True,'success':True})
        with patch.object(h,'telegram_notify') as telegram,patch.object(h,'email_notify',return_value={'sent':True}) as email:
            self.assertTrue(h.notify('success',success_only=True)['sent']);telegram.assert_not_called();email.assert_called_once()
    def test_email_header_injection(self):
        c={'enabled':True,'host':'smtp.example.com','sender':'a@example.com','recipients':'b@example.com\r\nBcc: stolen@example.com'}
        with self.assertRaises(ValueError):h.validate_email(c)
    def test_logs_reject_unit_injection(self):
        with patch.object(h,'require_admin'), self.assertRaises(ValueError):h.logs({'id':'x;cat /etc/shadow'})
    def test_logs_history_redacted(self):
        h.write(h.ROOT/'history/a.json',{'id':'job','status':'failed','password':'sentinel'})
        with patch.object(h,'require_admin'), patch.object(h.shutil,'which',return_value=None):
            result=h.logs({});self.assertEqual(result['records'][0]['password'],'••••••');self.assertIn('journalctl',result['journal'])
    def test_overview_reports_saved_state_without_credentials(self):
        h.write(h.ROOT/'repositories/a.json',{'id':'a','password':'sentinel','secret_key':'sentinel'})
        h.write(h.ROOT/'jobs/j.json',{'id':'j','enabled':True})
        h.write(h.ROOT/'history/j.json',{'id':'j','operation':'backup','status':'success'})
        with patch.object(h,'probe',return_value={'installed':True,'tools':{'restic':'restic test'}}):
            result=h.dispatch({'action':'overview'})
        self.assertTrue(result['installed']);self.assertEqual(result['jobs'][0]['id'],'j');self.assertEqual(result['history'][0]['status'],'success');self.assertNotIn('sentinel',json.dumps(result))
    def test_overview_does_not_invent_completed_steps(self):
        with patch.object(h,'probe',return_value={'installed':False,'tools':{}}):
            result=h.dispatch({'action':'overview'})
        self.assertFalse(result['installed']);self.assertEqual(result['repositories'],[]);self.assertEqual(result['jobs'],[]);self.assertEqual(result['history'],[])

    def test_old_restic_dry_run_rejected_before_job_or_container_changes(self):
        self.job()
        with patch.object(h,'require_admin'),patch.object(h,'restic_backup_supports',return_value=False),patch.object(h,'recover') as recovery,patch.object(h.subprocess,'Popen') as process,patch.object(h,'notify'):
            state=h.execute_job('job',dry=True)
            self.assertEqual(state['status'],'failed');self.assertIn('Обновить Restic',state['error']);process.assert_not_called();recovery.assert_not_called()
        with patch.object(h,'require_admin'),patch.object(h,'restic_backup_supports',return_value=False),patch.object(h,'start_operation') as start:
            with self.assertRaisesRegex(ValueError,'Обновить Restic'):h.dispatch({'action':'start_job','job_id':'job','dry_run':True})
            start.assert_not_called()
    def test_backup_flag_detection_uses_backup_help(self):
        with patch.object(h.shutil,'which',return_value='/usr/bin/restic'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,'  -n, --dry-run    no writes','')) as run:
            self.assertTrue(h.restic_backup_supports('--dry-run'));self.assertFalse(h.restic_backup_supports('--dry'));self.assertEqual(run.call_args.args[0],['restic','backup','--help'])

    def test_restic_update_requires_confirmation_and_supported_result(self):
        with patch.object(h,'require_admin'),patch.object(h,'run') as run,patch.object(h,'require_dry_run') as check,patch.object(h,'install',return_value={'updated':True}) as install:
            with self.assertRaisesRegex(ValueError,'Подтвердите'):h.dispatch({'action':'update_restic'})
            run.assert_not_called()
            self.assertTrue(h.dispatch({'action':'update_restic','confirmed':True})['updated'])
            self.assertEqual(run.call_args.args[0],['restic','self-update']);check.assert_called_once();install.assert_called_once()

if __name__=='__main__':unittest.main(verbosity=2)
