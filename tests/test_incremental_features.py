import contextlib, importlib.util, io, json, os, pathlib, subprocess, tarfile, tempfile, unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_incremental',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

class IncrementalTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.old=h.ROOT;h.ROOT=pathlib.Path(self.tmp.name);self.admin=patch.object(h,'require_admin');self.admin.start()
    def tearDown(self):self.admin.stop();h.ROOT=self.old;self.tmp.cleanup()
    def test_binlog_coordinate_mysql_and_maria(self):
        for prefix in ('MASTER','SOURCE'):
            self.assertEqual(h.binlog_coordinate("-- CHANGE %s TO %s_LOG_FILE='bin.000007', %s_LOG_POS=345;"%(prefix,prefix,prefix)),('bin.000007',345))
        for invalid in ('no coordinates',"MASTER_LOG_FILE='../bad.001', MASTER_LOG_POS=2"):
            with self.assertRaises(ValueError):h.binlog_coordinate(invalid)
    def test_binlog_gap_or_purged_baseline_cannot_claim_success(self):
        self.assertEqual(h.binlog_sequence(['bin.000001','bin.000002','bin.000003'],'bin.000002'),['bin.000002','bin.000003'])
        for logs in (['bin.000003'],['bin.000002','bin.000004'],['new.000002']):
            with self.assertRaises(ValueError):h.binlog_sequence(logs,'bin.000002')
    def test_wal_sequence_at_segment_rollover(self):
        names=['0000000100000000000000FF','000000010000000100000000','000000010000000100000001']
        h.validate_wal_chain(names,names[0],names[-1],16*1024**2)
        with self.assertRaises(ValueError):h.validate_wal_chain([names[0],names[2]],names[0],names[2],16*1024**2)
        with self.assertRaises(ValueError):h.validate_wal_chain(names,names[0],'000000020000000100000001',16*1024**2)
    def test_native_mode_refuses_partial_or_docker_exec_connections(self):
        for db in ({'container':'db'},{'peer':True},{'databases':['only_one']}):
            with self.assertRaises(ValueError):h.journal_preflight({'engine':'mysql',**db})
    def test_fingerprint_ignores_password_rotation_but_detects_source(self):
        db={'engine':'mysql','host':'db','port':3306,'user':'backup','password':'secret'}
        self.assertEqual(h.db_fingerprint(db),h.db_fingerprint({**db,'password':'rotated'}))
        self.assertNotEqual(h.db_fingerprint(db),h.db_fingerprint({**db,'host':'other'}))
    def test_archive_extract_refuses_escape_links_and_devices(self):
        for name,kind in (('../escape',tarfile.REGTYPE),('/escape',tarfile.REGTYPE),('link',tarfile.SYMTYPE),('dev',tarfile.CHRTYPE)):
            source=h.ROOT/'base.tar'
            with tarfile.open(source,'w') as tar:
                entry=tarfile.TarInfo(name);entry.type=kind;entry.linkname='/etc/passwd';tar.addfile(entry)
            with self.assertRaises(ValueError):h.safe_extract_tar(source,h.ROOT/'out')
    def test_corrupt_chain_refuses_before_import(self):
        p=h.ROOT/'base';p.write_text('changed')
        entry={'engine':'mysql','id':'db','chain':{'checksums':{'base':'bad'}}}
        with patch.object(h,'db_discover') as discover:
            with self.assertRaises(ValueError):h.restore_journal({'database':{'engine':'mysql'}},entry,h.ROOT)
            discover.assert_not_called()
    def test_restore_time_requires_timezone_and_range(self):
        entry={'engine':'mysql','chain':{'created':'2026-10-09T10:00:00Z','through':'2026-10-09T12:00:00Z','checksums':{}}}
        for time in ('2026-10-09T11:00:00','2026-10-09T09:59:59Z','2026-10-09T12:00:01Z'):
            with self.assertRaises(ValueError):h.restore_journal({'database':{'engine':'mysql'},'recovery_time':time},entry,h.ROOT)
    def test_snapshot_paths_preserve_deleted_and_symlink_source_names(self):
        self.assertEqual(h.snapshot_literal_path('/missing/file [x]'),'/'+'missing/file [x]')
        for path in ('relative','/dir/../file','/dir\0/file'):
            with self.assertRaises(ValueError):h.snapshot_literal_path(path)
    def test_history_reads_only_requested_page(self):
        snapshots=[{'id':str(i),'time':'2026-10-%02dT03:00:00Z'%(i+1)} for i in range(12)]
        def restic(repo,args,**kwargs):
            if args[0]=='snapshots':return subprocess.CompletedProcess(args,0,json.dumps(snapshots),'')
            return subprocess.CompletedProcess(args,0,json.dumps({'path':'/file.txt','size':12}),'')
        with patch.object(h,'config',return_value={}),patch.object(h,'restic',side_effect=restic) as calls:
            result=h.snapshot_file_history({'repository_id':'repo','path':'/file.txt','limit':5,'offset':5})
        self.assertEqual(result['total'],12);self.assertEqual([row['snapshot'] for row in result['versions']],['6','5','4','3','2']);self.assertEqual(calls.call_count,6)
    def test_content_detects_identical_metadata_changed_bytes(self):
        target=h.ROOT/'file';target.write_bytes(b'BBBB')
        node={'type':'file','path':str(target),'size':4}
        @contextlib.contextmanager
        def env(repo):yield {}
        def dumped(argv,**kwargs):kwargs['stdout'].write(b'AAAA');return subprocess.CompletedProcess(argv,0,b'',b'')
        with patch.object(h,'config',return_value={}),patch.object(h,'restic',return_value=subprocess.CompletedProcess([],0,json.dumps(node),'') ),patch.object(h,'repository_env',env),patch.object(h.subprocess,'run',side_effect=dumped):
            result=h.snapshot_content({'repository_id':'r','snapshot':'snap','path':str(target)})
            self.assertFalse(result['same']);self.assertIn('-AAAA',result['diff']);self.assertIn('+BBBB',result['diff'])
    def test_content_symlink_refused(self):
        target=h.ROOT/'link';target.symlink_to(h.ROOT/'real');(h.ROOT/'real').write_bytes(b'data')
        with patch.object(h,'config',return_value={}),patch.object(h,'restic',return_value=subprocess.CompletedProcess([],0,json.dumps({'type':'file','path':str(target),'size':4}),'')):
            with self.assertRaises(OSError):h.snapshot_content({'repository_id':'r','snapshot':'snap','path':str(target)})
    def test_content_rejects_large_snapshot_before_dump(self):
        target=h.ROOT/'file';target.write_bytes(b'')
        with patch.object(h,'config',return_value={}),patch.object(h,'restic',return_value=subprocess.CompletedProcess([],0,json.dumps({'type':'file','path':str(target),'size':65*1024**2}),'')):
            with self.assertRaises(ValueError):h.snapshot_content({'repository_id':'r','snapshot':'snap','path':str(target)})
    def test_duplicate_does_not_start_new_schedule(self):
        with patch.object(h,'config',return_value={'id':'old','name':'Сайты','enabled':True}),patch.object(h,'save_job',side_effect=lambda j:j):
            result=h.job_manage({'action':'job_duplicate','job_id':'old','new_id':'new'})
            self.assertFalse(result['enabled']);self.assertEqual(result['name'],'Сайты · копия')
    def test_errors_separate_maintenance_backup_replication_notification(self):
        h.write(h.ROOT/'email-error.json',{'error':'SMTP failed','time':h.now()})
        with patch.object(h,'history_records',return_value=[{'id':'daily','operation':'backup','error':'network','maintenance_error':'prune','replication_errors':[{'repository_id':'r2','error':'full'}]}]):
            rows=h.error_center()['entries'];self.assertEqual({x['category'] for x in rows},{'backup','maintenance','replication','notification'})
    def test_full_verification_low_space_refuses_before_restore(self):
        response=subprocess.CompletedProcess([],0,json.dumps([{'id':'s','summary':{'total_bytes_processed':4*1024**3}}]),'')
        with patch.object(h,'restic',return_value=response) as restic,patch.object(h.shutil,'disk_usage',return_value=type('Disk',(),{'free':1024**3})()):
            with self.assertRaises(RuntimeError):h.verify_full_restore({'id':'r'})
            self.assertEqual(restic.call_count,1)
    def test_no_test_image_pull_and_no_shared_network(self):
        commands=[]
        def command(argv,**kwargs):commands.append(argv);return subprocess.CompletedProcess(argv,1,'','')
        with patch.object(h.shutil,'which',return_value='/bin/docker'),patch.object(h,'run',side_effect=command):
            with self.assertRaises(ValueError):h.verify_isolated_database({'engine':'postgres','version':'PostgreSQL 16.4'},h.ROOT)
        self.assertEqual(commands[0],['docker','image','inspect','postgres:16']);self.assertNotIn('pull',str(commands))
