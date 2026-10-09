import base64,hashlib,importlib.util,json,pathlib,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('files_stream',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class StopStream(Exception):pass
class FilesStreamTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.folder=pathlib.Path(self.tmp.name);self.root=self.folder/'state';self.root.mkdir();self.work=self.folder/'files';self.work.mkdir()
        self.patchers=[patch.object(h,'ROOT',self.root),patch.object(h,'require_admin'),patch.object(h,'service_inventory',return_value=([],''))]
        for p in self.patchers:p.start()
    def tearDown(self):
        for p in self.patchers:p.stop()
        self.tmp.cleanup()
    def test_stat_directory_for_bulk_move(self):
        result=h.files_stat({"path":str(self.work)})
        self.assertTrue(result["directory"]);self.assertTrue(result["exists"]);self.assertIsNone(result["hash"])
    def test_browse_names_and_modes(self):
        p=self.work/'quotes " space \\ файл';p.write_text('пример');p.chmod(0o640)
        entry=h.files_list({'path':str(self.work)})['entries'][0]
        self.assertEqual(entry['path'],str(p.resolve()));self.assertEqual(entry['mode'],'0640')
    def test_invalid_and_virtual_paths(self):
        for p in ['relative','/tmp/a\0b','/proc/self/status','/dev/zero']:
            with self.assertRaises(ValueError):h.file_path(p)
        with self.assertRaises(ValueError):h.file_path(str(self.root/'secret'),True)
    def test_edit_backup_stale_and_permissions(self):
        p=self.work/'config';p.write_text('old');p.chmod(0o640);before=h.files_read({'path':str(p)})
        result=h.files_write({'path':str(p),'content':'new','hash':before['hash'],'confirmed':True})
        self.assertEqual(p.read_text(),'new');self.assertEqual(p.stat().st_mode&0o777,0o640)
        version=h.files_version({'path':str(p),'version_id':result['version_id']});self.assertEqual(version['content'],'old')
        with self.assertRaises(ValueError):h.files_write({'path':str(p),'content':'bad','hash':before['hash'],'confirmed':True})
        h.files_rollback({'path':str(p),'version_id':result['version_id'],'hash':result['hash'],'confirmed':True});self.assertEqual(p.read_text(),'old')
    def test_write_requires_confirmation_and_utf8_text(self):
        p=self.work/'new'
        for r in [{'confirmed':False,'content':'data'},{'confirmed':True,'content':'x\0y'}]:
            with self.assertRaises(ValueError):h.files_write({'path':str(p),'hash':'absent',**r})
        h.files_write({'path':str(p),'hash':'absent','content':'','confirmed':True});self.assertEqual(p.read_bytes(),b'')
    def test_versions_are_bound_to_file(self):
        p=self.work/'a';q=self.work/'b';p.write_text('old');v=h.file_backup(p)
        with self.assertRaises(ValueError):h.files_version({'path':str(q),'version_id':v})
    def test_binary_and_large_editor_rejected(self):
        p=self.work/'binary';p.write_bytes(b'a\0b')
        with self.assertRaises(ValueError):h.files_read({'path':str(p)})
        p.write_bytes(b'a'*(h.TEXT_LIMIT+1))
        with self.assertRaises(ValueError):h.files_read({'path':str(p)})
    def test_move_no_overwrite_and_trash_undo(self):
        p=self.work/'a';q=self.work/'b';p.write_text('a');q.write_text('b')
        with self.assertRaises(ValueError):h.files_rename({'path':str(p),'destination':str(q),'confirmed':True})
        result=h.files_trash({'path':str(p),'confirmed':True});self.assertFalse(p.exists());self.assertEqual(len(h.files_trash_list()['items']),1)
        h.files_untrash({'id':result['id'],'confirmed':True});self.assertEqual(p.read_text(),'a');self.assertEqual(h.files_trash_list()['items'],[])
    def test_upload_chunks_checksum_and_cancel(self):
        p=self.work/'upload " \\ файл';data=b'new\0binary';start=h.upload_begin({'path':str(p),'size':len(data),'hash':'absent','confirmed':True});key=start['id']
        with self.assertRaises(ValueError):h.upload_chunk({'id':key,'offset':1,'data':base64.b64encode(data).decode()})
        h.upload_chunk({'id':key,'offset':0,'data':base64.b64encode(data).decode()})
        with self.assertRaises(ValueError):h.upload_commit({'id':key,'sha256':'wrong'})
        self.assertFalse(p.exists());h.upload_commit({'id':key,'sha256':hashlib.sha256(data).hexdigest()});self.assertEqual(p.read_bytes(),data)
        start=h.upload_begin({'path':str(p),'size':0,'hash':h.file_hash(p),'confirmed':True});h.upload_abort({'id':start['id']});self.assertEqual(p.read_bytes(),data);self.assertFalse(list(self.work.glob('.server-backup-upload-*')))
    def test_upload_does_not_overwrite_concurrent_change(self):
        p=self.work/'x';p.write_text('old');key=h.upload_begin({'path':str(p),'size':0,'hash':h.file_hash(p),'confirmed':True})['id'];p.write_text('changed')
        with self.assertRaises(ValueError):h.upload_commit({'id':key,'sha256':hashlib.sha256(b'').hexdigest()})
        self.assertEqual(p.read_text(),'changed');h.upload_abort({'id':key})
    def test_download_incremental_checksum(self):
        p=self.work/'binary';data=bytes(range(256))*5000;p.write_bytes(data);events=[]
        with patch.object(h,'stream_emit',side_effect=lambda event,result,**kwargs:events.append((event,result))):h.files_download({'path':str(p)})
        self.assertEqual(b''.join(base64.b64decode(r['data']) for e,r in events if e=='file_data'),data)
        self.assertEqual(events[-1][1]['sha256'],hashlib.sha256(data).hexdigest());self.assertEqual(len([e for e,r in events if e=='file_data']),2)
    def test_stream_appends_and_follows_rotation(self):
        log=self.work/'test.log';log.write_text('first\n');events=[]
        def emit(event,result=None,**kwargs):
            if event=='logs':
                events.append((result['text'],kwargs['mode']))
                if len(events)==1:log.write_text('first\nsecond\n')
                elif len(events)==2:log.rename(self.work/'rotated');log.write_text('third\n')
                elif len(events)==3:raise StopStream()
        with patch.object(h,'LOG_ROOT',self.work),patch.object(h,'stream_emit',side_effect=emit):
            with self.assertRaises(StopStream):h.stream_file({'path':str(log)})
        self.assertEqual(events,[('first\n','replace'),('second\n','append'),('third\n','append')])
    def test_stream_blocks_symlink_on_rotation(self):
        log=self.work/'test.log';log.write_text('first\n');outside=self.folder/'secret';outside.write_text('secret')
        def emit(*args,**kwargs):log.unlink();log.symlink_to(outside)
        with patch.object(h,'LOG_ROOT',self.work),patch.object(h,'stream_emit',side_effect=emit):
            with self.assertRaises(ValueError):h.stream_file({'path':str(log)})
    def test_compressed_helper_install_source(self):
        import zlib
        source='print("test")';encoded=base64.b64encode(zlib.compress(source.encode())).decode()
        with patch.dict(h.os.environ,{'SB_HELPER_SOURCE_ZLIB':encoded}):self.assertEqual(h.helper_source(),source)
    def test_invalid_stream_interval(self):
        with self.assertRaises(ValueError):h.stream({'kind':'metrics','interval':1})

    def test_move_no_overwrite_and_no_recursive_destination(self):
        source=self.work/'source';source.mkdir();(source/'file').write_text('data');target=self.work/'target'
        with self.assertRaises(ValueError):h.files_move({'path':str(source),'destination':str(target)})
        with self.assertRaises(ValueError):h.files_move({'path':str(source),'destination':str(source/'nested'),'confirmed':True})
        h.files_move({'path':str(source),'destination':str(target),'confirmed':True});self.assertFalse(source.exists());self.assertEqual((target/'file').read_text(),'data')
        source.write_text('other')
        with self.assertRaises(ValueError):h.files_move({'path':str(source),'destination':str(target),'confirmed':True})
        self.assertEqual(source.read_text(),'other')
    def test_permissions_confirmation_octal_and_symlink(self):
        p=self.work/'file';p.write_text('content');p.chmod(0o644)
        with self.assertRaises(ValueError):h.files_chmod({'path':str(p),'mode':'600'})
        result=h.files_chmod({'path':str(p),'mode':'0600','confirmed':True});self.assertEqual(result['previous_mode'],'0644');self.assertEqual(p.stat().st_mode&0o777,0o600)
        for mode in ('7777','888','-1','644; command'):
            with self.assertRaises(ValueError):h.files_chmod({'path':str(p),'mode':mode,'confirmed':True})
        link=self.work/'link';link.symlink_to(p)
        with self.assertRaises(ValueError):h.files_chmod({'path':str(link),'mode':'777','confirmed':True})
        self.assertEqual(p.stat().st_mode&0o777,0o600)
    def test_upload_directory_merge_and_symlink_protection(self):
        folder=self.work/'folder'
        h.files_ensure_directory({'path':str(folder),'confirmed':True});(folder/'existing').write_text('keep')
        h.files_ensure_directory({'path':str(folder),'confirmed':True});self.assertEqual((folder/'existing').read_text(),'keep')
        link=self.work/'link';link.symlink_to(folder)
        with self.assertRaises(ValueError):h.files_ensure_directory({'path':str(link),'confirmed':True})
