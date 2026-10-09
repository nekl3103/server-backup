import importlib.util, pathlib, tempfile, unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('snapshot_helper',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class SnapshotFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name);self.old=h.ROOT;h.ROOT=self.root
        self.admin=patch.object(h,'require_admin');self.admin.start();h.write(self.root/'repositories/repo.json',{'id':'repo','repository':'/backup','type':'disk'})
        self.request={'repository_id':'repo','snapshot':'a'*64,'path':'/'}
    def tearDown(self):self.admin.stop();h.ROOT=self.old;self.tmp.cleanup()
    def call(self,**kwargs):return h.snapshot_files(dict(self.request,**kwargs))
    def test_pagination_and_cache_do_not_repeat_restic_scan(self):
        nodes=[{'path':'/folder/f%03d'%i,'type':'file','size':i,'mode':420,'uid':33} for i in range(620)]
        with patch.object(h,'snapshot_nodes',return_value=iter(nodes)) as scan:
            root=self.call();self.assertEqual(root['entries'][0]['path'],'/folder')
            first=self.call(path='/folder');second=self.call(path='/folder',offset=250);last=self.call(path='/folder',offset=500)
            self.assertEqual([len(x['entries']) for x in [first,second,last]],[250,250,120]);self.assertEqual(first['total'],620)
            self.assertEqual(first['summary']['total_size'],sum(range(620)));scan.assert_called_once();self.assertEqual(first['entries'][0]['uid'],33)
    def test_search_special_characters_are_literal(self):
        nodes=[{'path':"/a/100%_file 'q'.txt",'type':'file','size':4},{'path':'/b/100XXfile.txt','type':'file','size':7}]
        with patch.object(h,'snapshot_nodes',return_value=iter(nodes)):
            self.assertEqual(self.call(query='%_')['total'],1);self.assertEqual(self.call(path='/b',query='%_')['total'],0);self.assertEqual(self.call(query="'q'")['total'],1)
    def test_invalid_paths_and_ids_rejected(self):
        for changes in [{'path':'/a/../b'},{'path':'relative'},{'snapshot':'--foo'},{'query':'a\0b'}]:
            with self.assertRaises(ValueError):self.call(**changes)
    def test_failed_scan_is_not_cached(self):
        def failed(*args):
            yield {'path':'/partial','type':'file','size':5}
            raise RuntimeError('network lost')
        with patch.object(h,'snapshot_nodes',side_effect=failed),self.assertRaises(RuntimeError):self.call()
        self.assertEqual(list(self.root.rglob('*.sqlite')),[]);self.assertEqual(list(self.root.rglob('*.tmp')),[])
    def test_only_regular_files_count_towards_total(self):
        nodes=[{'path':'/a','type':'dir','size':4096},{'path':'/a/link','type':'symlink','size':99},{'path':'/a/file','type':'file','size':12}]
        with patch.object(h,'snapshot_nodes',return_value=iter(nodes)):
            self.assertEqual(self.call()['summary'],{'total_size':12,'total_file_count':1})
    def test_capacity_start_is_systemd_managed(self):
        with patch.object(h,'install_helper_source'),patch.object(h,'start_operation',return_value={'operation_id':'op-x'}) as start:
            self.assertEqual(h.dispatch({'action':'capacity_start','repository_id':'repo'})['operation_id'],'op-x');self.assertEqual(start.call_args.args[0],{'command':'capacity','repository_id':'repo'})
    def test_capacity_does_not_acquire_repository_lock_twice(self):
        h.write(self.root/'operations/op-x.json',{'command':'capacity','repository_id':'repo'})
        with patch.object(h,'capacity',return_value={'bytes':12}),patch.object(h,'repo_lock',side_effect=AssertionError('outer lock')):
            value=h.operation('op-x');self.assertEqual(value['status'],'success');self.assertEqual(value['repository_id'],'repo')
    def test_search_scope_respects_case_of_linux_paths(self):
        nodes=[{'path':'/ABC/report.txt','type':'file','size':1},{'path':'/abc/report.txt','type':'file','size':2}]
        with patch.object(h,'snapshot_nodes',return_value=iter(nodes)):
            entries=self.call(path='/ABC',query='report')['entries'];self.assertEqual([v['path'] for v in entries],['/ABC/report.txt'])
    def test_activity_status_recovers_active_id_and_latest_result(self):
        h.write(self.root/'states/op-old.json',{'id':'op-old','operation':'capacity','repository_id':'repo','started':'2026-10-08','status':'success','output':'{"bytes":42}'})
        h.write(self.root/'states/op-new.json',{'id':'op-new','operation':'capacity','repository_id':'repo','started':'2026-10-09','status':'running'})
        value=h.activity_status('capacity','repo');self.assertEqual(value['active']['id'],'op-new');self.assertEqual(value['data']['bytes'],42)
    def test_activity_status_keeps_repositories_separate(self):
        h.write(self.root/'states/op-other.json',{'id':'op-other','operation':'capacity','repository_id':'other','started':'2026-10-09','status':'running'})
        self.assertIsNone(h.activity_status('capacity','repo')['active'])
