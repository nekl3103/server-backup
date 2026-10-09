import importlib.util,pathlib,tempfile,unittest,subprocess,os,datetime
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_cron_edit',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class CronEditTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.folder=pathlib.Path(self.tmp.name);self.admin=patch.object(h,'require_admin');self.admin.start();self.root=patch.object(h,'ROOT',self.folder/'state');self.root.start();self.etc=patch.object(h,'CRON_ETC',self.folder/'etc');self.etc.start();(h.CRON_ETC/'cron.d').mkdir(parents=True);self.path=h.CRON_ETC/'cron.d/website';self.path.write_text('# original\n0 4 * * * root /bin/true\n');self.path.chmod(0o640)
    def tearDown(self):self.etc.stop();self.root.stop();self.admin.stop();self.tmp.cleanup()
    def request(self):return {'kind':'system','source':str(self.path),'hash':h.cron_read({'kind':'system','source':str(self.path)})['hash'],'confirmed':True,'content':'# preserved\n*/15 * * * * root /bin/true\n'}
    def test_save_preserves_permissions_and_backup(self):
        result=h.cron_save(self.request());self.assertEqual(self.path.stat().st_mode&0o777,0o640);self.assertIn('# preserved',self.path.read_text());backup=h.read(h.ROOT/'cron-backups'/(result['backup_id']+'.json'));self.assertIn('# original',backup['content'])
    def test_conflict_prevents_overwriting_external_edit(self):
        request=self.request();self.path.write_text('# external\n')
        with self.assertRaisesRegex(ValueError,'изменилось'):h.cron_save(request)
        self.assertEqual(self.path.read_text(),'# external\n')
    def test_invalid_schedule_and_unconfirmed_do_not_write(self):
        for value in ['60 3 * * * root /bin/true','0 25 * * * root /bin/true','*/0 * * * * root /bin/true','0 3 * * * root','@unsupported root /bin/true']:
            request=self.request();request['content']=value
            with self.assertRaises(ValueError):h.cron_save(request)
        request=self.request();request['confirmed']=False
        with self.assertRaises(ValueError):h.cron_save(request)
        self.assertIn('# original',self.path.read_text())
    def test_rejects_arbitrary_paths_and_symlinks(self):
        for source in ['/etc/shadow',str(h.CRON_ETC/'cron.d/../outside')]:
            with self.assertRaises(ValueError):h.cron_read({'kind':'system','source':source})
        link=h.CRON_ETC/'cron.d/link';link.symlink_to(self.path)
        with self.assertRaises(ValueError):h.cron_read({'kind':'system','source':str(link)})
    def test_user_crontab_uses_stdin_and_preserves_other_lines(self):
        content='MAILTO=""\n0 3 * * * /bin/true\n';result=subprocess.CompletedProcess([],0,content,'')
        with patch.object(h,'run',return_value=result) as run:
            old=h.cron_read({'kind':'user','user':'root'});h.cron_save({'kind':'user','user':'root','hash':old['hash'],'confirmed':True,'content':content+'@daily /bin/echo "a; b"\n'})
            self.assertEqual(run.call_args.args[0],['crontab','-u','root','-']);self.assertIn('MAILTO',run.call_args.kwargs['data'])
    def test_inventory_and_editor_share_crontab_line_numbers(self):
        spool=self.folder/'spool';spool.mkdir();(spool/'root').write_text('# generated header\n# installed header\n# version header\n0 4 * * * /bin/true\n')
        result=subprocess.CompletedProcess([],0,'0 4 * * * /bin/true\n','')
        with patch.object(h,'CRON_SPOOL',spool),patch.object(h.shutil,'which',side_effect=lambda name: '/usr/bin/crontab' if name=='crontab' else None),patch.object(h,'run',return_value=result):
            rows=[x for x in h.cron_inventory()['entries'] if x['kind']=='user'];self.assertEqual(rows[0]['line'],1);self.assertEqual(h.cron_read({'kind':'user','user':'root'})['content'].splitlines()[0],'0 4 * * * /bin/true')
    def test_valid_ranges_and_names(self):h.validate_cron('0 3 * JAN-MAR MON-FRI /bin/true\n@reboot /bin/true\n')

class CompareTests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.folder=pathlib.Path(self.tmp.name);self.file=self.folder/'hello "world".txt';self.file.write_text('one');self.info=self.file.stat();self.node={'path':'/saved/'+self.file.name,'type':'file','size':3,'mode':self.info.st_mode&0o7777,'uid':self.info.st_uid,'gid':self.info.st_gid,'mtime':datetime.datetime.fromtimestamp(self.info.st_mtime,datetime.timezone.utc).isoformat()}
    def tearDown(self):self.tmp.cleanup()
    def compare(self,nodes,**kwargs):
        def pages(request):return {'entries':nodes,'total':len(nodes),'path':'/saved','snapshot':'a'*64}
        with patch.object(h,'snapshot_files',side_effect=pages):return h.snapshot_compare({'target':str(self.folder),**kwargs})
    def test_detects_metadata_missing_and_added(self):
        result=self.compare([self.node,{'path':'/saved/missing','type':'file'}]);self.assertEqual(result['counts'],{'same_metadata':1,'missing':1});self.file.write_text('changed');(self.folder/'added').write_text('new');result=self.compare([self.node]);self.assertEqual(result['counts'],{'changed':1,'server_only':1});self.assertIn('Размер',next(x for x in result['entries'] if x['status']=='changed')['reason'])
    def test_symlink_never_followed(self):
        link=self.folder/'link';link.symlink_to('/etc/shadow');result=self.compare([{'path':'/saved/link','type':'symlink','linktarget':'/etc/shadow','mode':link.lstat().st_mode&0o7777,'uid':link.lstat().st_uid,'gid':link.lstat().st_gid}]);self.assertEqual(next(x for x in result['entries'] if x['name']=='link')['status'],'same_metadata')
    def test_pagination_and_differences(self):
        for i in range(300):(self.folder/str(i)).touch()
        result=self.compare([self.node],offset=250,differences=True);self.assertEqual(result['total'],300);self.assertEqual(len(result['entries']),50)
    def test_missing_target_and_invalid_target(self):
        result=self.compare([self.node],target=str(self.folder/'missing'));self.assertEqual(result['counts'],{'missing':1})
        with self.assertRaises(ValueError):self.compare([],target='/a/../b')
        with self.assertRaises(ValueError):self.compare([],target=str(self.file))
