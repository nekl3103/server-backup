import importlib.util,pathlib,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_logs',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class ServerLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.tmp.name).resolve();self.logs=self.root/'logs';self.logs.mkdir()
        self.admin=patch.object(h,'require_admin');self.admin.start();self.loc=patch.object(h,'LOG_ROOT',self.logs);self.loc.start()
    def tearDown(self):self.loc.stop();self.admin.stop();self.tmp.cleanup()
    def test_outside_and_symlink_rejected(self):
        other=self.root/'private';other.write_text('secret');link=self.logs/'link.log';link.symlink_to(other)
        for path in [other,link,self.logs]:
            with self.assertRaises(ValueError):h.server_log({'path':str(path)})
    def test_tail_preserves_special_names_and_commands(self):
        p=self.logs/'site " ; $.log';p.write_text('\n'.join(str(i) for i in range(600)))
        r=h.server_log({'path':str(p)});self.assertEqual(r['text'].splitlines(),[str(i) for i in range(100,600)]);self.assertTrue(r['truncated'])
    def test_binary_and_compressed_rejected(self):
        for name,data in [('binary.log',b'a\x00b'),('app.log.gz',b'compressed')]:
            p=self.logs/name;p.write_bytes(data)
            with self.assertRaises(ValueError):h.server_log({'path':str(p)})
    def test_read_size_bounded(self):
        p=self.logs/'large.log';p.write_text('x'*600000);r=h.server_log({'path':str(p)});self.assertLessEqual(len(r['text']),512000);self.assertTrue(r['truncated'])
    def test_inventory_ignores_symlink_and_binary_archives(self):
        (self.logs/'nginx').mkdir();(self.logs/'nginx/error.log').write_text('error');(self.logs/'wtmp').write_bytes(b'fixture');(self.logs/'old.gz').write_bytes(b'fixture');(self.logs/'alias').symlink_to(self.logs/'nginx',target_is_directory=True)
        self.assertEqual([x['path'] for x in h.log_files()['files']],[str(self.logs/'nginx/error.log')])
    def test_journal_unavailable_is_error(self):
        with patch.object(h.shutil,'which',return_value=None):
            with self.assertRaises(ValueError):h.server_log({'source':'journal'})
