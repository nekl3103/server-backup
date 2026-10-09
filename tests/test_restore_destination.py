import importlib.util,json,pathlib,subprocess,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('restore_destination',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class RestoreDestinationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.folder=pathlib.Path(self.tmp.name);self.state=self.folder/'state';self.state.mkdir();self.work=self.folder/'work';self.work.mkdir();self.old=h.ROOT;h.ROOT=self.state;self.admin=patch.object(h,"require_admin");self.admin.start()
    def tearDown(self):self.admin.stop();h.ROOT=self.old;self.tmp.cleanup()
    def request(self):return {'target':str(self.work),'target_file':str(self.work/'renamed.conf'),'snapshot':'abc','includes':['/etc/file [1].conf'],'confirmed':True}
    def fake(self,repo,args,**kwargs):
        if args[0]=='ls':return subprocess.CompletedProcess([],0,json.dumps({'path':'/etc/file [1].conf','type':'file','size':4})+'\n','')
        if args[0]=='stats':return subprocess.CompletedProcess([],0,'{"total_size":4}','')
        if args[0]=='restore':
            self.assertIn('\\[',args[args.index('--include')+1]);path=pathlib.Path(args[args.index('--target')+1])/'etc/file [1].conf';path.parent.mkdir();path.write_text('data');path.chmod(0o640);return subprocess.CompletedProcess([],0,'verified','')
        self.fail(args)
    def test_restore_to_named_file_and_preserve_mode(self):
        with patch.object(h,'restic',side_effect=self.fake):result=h.execute_restore({},self.request())
        target=self.work/'renamed.conf';self.assertEqual(result.returncode,0);self.assertEqual(target.read_text(),'data');self.assertEqual(target.stat().st_mode&0o777,0o640);self.assertFalse(list(self.work.glob('.server-backup-restore-*')))
    def test_existing_file_requires_explicit_overwrite(self):
        target=self.work/'renamed.conf';target.write_text('old')
        with patch.object(h,'restic',side_effect=self.fake):
            with self.assertRaisesRegex(ValueError,'подтвердите'):h.execute_restore({},self.request())
            h.execute_restore({},dict(self.request(),overwrite=True))
        self.assertEqual(target.read_text(),'data')
    def test_failed_restore_keeps_destination(self):
        target=self.work/'renamed.conf';target.write_text('old')
        def fail(repo,args,**kw):return subprocess.CompletedProcess([],5,'','offline') if args[0]=='restore' else self.fake(repo,args,**kw)
        with patch.object(h,'restic',side_effect=fail):self.assertEqual(h.execute_restore({},dict(self.request(),overwrite=True)).returncode,5)
        self.assertEqual(target.read_text(),'old')
    def test_file_target_rejects_folder_or_multiple_sources(self):
        with patch.object(h,'restic',return_value=subprocess.CompletedProcess([],0,'{"path":"/etc","type":"dir"}\n','')):
            with self.assertRaisesRegex(ValueError,'обычный файл'):h.restore_preflight({},dict(self.request(),includes=['/etc']))
            with self.assertRaisesRegex(ValueError,'один файл'):h.restore_preflight({},dict(self.request(),includes=['/etc/a','/etc/b']))
    def test_root_requires_confirmation_and_overwrite(self):
        for r in [{'target':'/'},{'target':'/','allow_root':True,'confirmed':True}]:
            with self.assertRaisesRegex(ValueError,'корень'):h.restore_preflight({},r)
        with patch.object(h,'restic',side_effect=self.fake):result=h.restore_preflight({},{'target':'/','snapshot':'abc','allow_root':True,'overwrite':True,'confirmed':True})
        self.assertEqual(result['required_bytes'],4)
