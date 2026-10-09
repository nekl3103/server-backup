import importlib.util, json, pathlib, subprocess, tempfile, unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_programs',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

class ProgramsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.folder=pathlib.Path(self.tmp.name).resolve();self.old=h.ROOT;h.ROOT=self.folder/'state'
        self.admin=patch.object(h,'require_admin');self.admin.start()
        self.service=patch.object(h,'require_service',return_value={'manageable':True});self.service.start()
        self.conf=self.folder/'etc';self.conf.mkdir();self.file=self.conf/'main.conf';self.file.write_text('original\n');self.file.chmod(0o640)
    def tearDown(self):self.service.stop();self.admin.stop();h.ROOT=self.old;self.tmp.cleanup()
    def specification(self,validator=None):return {'root':str(self.conf),'files':['main.conf'],'validate':validator}
    def request(self,content='changed\n'):
        return {'unit':'nginx.service','path':str(self.file),'content':content,'hash':h.hashlib.sha256(self.file.read_bytes()).hexdigest(),'confirmed':True}
    def test_unsupported_service_and_injection(self):
        self.service.stop()
        for unit in ['ssh.service','nginx.service;reboot','../../nginx.service']:
            with patch.object(h,'service_inventory',return_value=([{'unit':'ssh.service','manageable':False}],'')):
                with self.assertRaises(ValueError):h.require_service(unit)
        self.service.start()
    def test_config_path_whitelist(self):
        with patch.object(h,'program_spec',return_value=self.specification()):
            with self.assertRaises(ValueError):h.program_config({'unit':'nginx.service','path':'/etc/shadow'})
    def test_symlink_escape(self):
        outside=self.folder/'secret.conf';outside.write_text('secret');self.file.unlink();self.file.symlink_to(outside)
        with patch.object(h,'program_spec',return_value=self.specification()):self.assertEqual(h.editable_configs('nginx.service'),[])
    def test_stale_config_never_overwrites(self):
        r=self.request();self.file.write_text('other edit\n')
        with patch.object(h,'program_spec',return_value=self.specification()):
            with self.assertRaisesRegex(ValueError,'изменён'):h.save_program_config(r)
        self.assertEqual(self.file.read_text(),'other edit\n')
    def test_validator_failure_rolls_back_and_preserves_mode(self):
        with patch.object(h,'program_spec',return_value=self.specification(['nginx','-t'])),patch.object(h.shutil,'which',return_value='/usr/sbin/nginx'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],1,'','sentinel-secret')):
            with self.assertRaisesRegex(RuntimeError,'отменены'):h.save_program_config(self.request())
        self.assertEqual(self.file.read_text(),'original\n');self.assertEqual(self.file.stat().st_mode&0o777,0o640)
    def test_save_without_validator_never_restarts(self):
        with patch.object(h,'program_spec',return_value=self.specification()),patch.object(h,'run') as run:
            result=h.save_program_config(self.request('password=sentinel-secret\n'));run.assert_not_called()
        self.assertFalse(result['syntax_checked']);self.assertTrue(result['restart_required']);self.assertEqual(self.file.stat().st_mode&0o777,0o640)
        history=next((h.ROOT/'history').glob('*.json'));self.assertNotIn('sentinel-secret',history.read_text())
        backup=next((h.ROOT/'program-backups').glob('*.json'));self.assertEqual(backup.stat().st_mode&0o777,0o600)
    def test_config_save_requires_confirmation(self):
        r=self.request();r['confirmed']=False
        with self.assertRaises(ValueError):h.save_program_config(r)
        self.assertEqual(self.file.read_text(),'original\n')
    def test_json_validation_before_write(self):
        configuration=self.specification();configuration['json']=True
        with patch.object(h,'program_spec',return_value=configuration):
            with self.assertRaisesRegex(ValueError,'JSON'):h.save_program_config(self.request('invalid'))
        self.assertEqual(self.file.read_text(),'original\n')
    def test_service_operation_whitelist(self):
        with patch.object(h,'run') as run:
            with self.assertRaises(ValueError):h.service_action({'unit':'nginx.service','operation':'reboot','confirmed':True})
            with self.assertRaises(ValueError):h.service_action({'unit':'nginx.service','operation':'restart'})
            run.assert_not_called()
    def test_installed_and_held_packages(self):
        text='ii \tnginx\t1.2.3\tamd64\t500\nhi \tpostgresql\t16\tamd64\t700\nrc \tremoved\t1\tamd64\t0\n'
        with patch.object(h.shutil,'which',return_value='/usr/bin/dpkg-query'),patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,text,'')),patch.object(h,'service_inventory',return_value=([],'')):
            result=h.installed_programs()
        self.assertEqual([x['name'] for x in result['packages']],['nginx','postgresql'])
    def test_cron_users_special_schedule_and_environment(self):
        text='PATH=/usr/bin\nCRON_TZ="Europe/Samara"\n# ignore\n0 3 * * * echo "quote; $HOME"\n@reboot /srv/start --flag\n'
        records=h.parse_cron(text,'user-file','alice')
        self.assertEqual(len(records),2);self.assertEqual(records[0]['schedule'],'0 3 * * *');self.assertEqual(records[0]['command'],'echo "quote; $HOME"');self.assertEqual(records[0]['user'],'alice');self.assertEqual(records[0]['timezone'],'Europe/Samara');self.assertEqual(records[1]['schedule'],'@reboot')
    def test_system_cron_user_column(self):
        records=h.parse_cron('*/5 * * * * www-data /srv/job one two\n@daily root /srv/daily\n','/etc/crontab')
        self.assertEqual(records[0]['user'],'www-data');self.assertEqual(records[0]['command'],'/srv/job one two');self.assertEqual(records[1]['user'],'root')
    def test_inventory_all_cron_sources_and_unavailable_timers(self):
        etc=self.folder/'cron-etc';spool=self.folder/'cron-spool';etc.mkdir();spool.mkdir();(etc/'cron.d').mkdir();(etc/'cron.daily').mkdir()
        (etc/'crontab').write_text('0 1 * * * root /srv/system\n');(etc/'cron.d/site').write_text('0 2 * * * www-data /srv/site\n')
        (spool/'alice').write_text('0 3 * * * /srv/alice\n');(spool/'bob').write_text('@reboot /srv/bob\n')
        script=etc/'cron.daily/maintenance';script.write_text('#!/bin/sh\n');script.chmod(0o755)
        (etc/'anacrontab').write_text('7 5 weekly /srv/week\n')
        with patch.object(h,'CRON_ETC',etc),patch.object(h,'CRON_SPOOL',spool),patch.object(h.shutil,'which',return_value=None):result=h.cron_inventory()
        self.assertEqual(len(result['entries']),6);self.assertEqual(result['issues'],[]);self.assertTrue(result['timer_error']);self.assertEqual({x['user'] for x in result['entries']},{'root','alice','bob','www-data'})

if __name__=='__main__':unittest.main()
