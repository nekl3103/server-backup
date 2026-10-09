import importlib.util,json,os,pathlib,subprocess,types,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('disk_helper',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class DiskSummaryTests(unittest.TestCase):
    def summarize(self,devices,mounts,ids):
        result=subprocess.CompletedProcess([],0,json.dumps({'blockdevices':devices}),'')
        fs=types.SimpleNamespace(f_blocks=100,f_frsize=10,f_bavail=40)
        with patch.object(h.shutil,'which',return_value='/bin/lsblk'),patch.object(h,'run',return_value=result),patch.object(h.os,'stat',side_effect=lambda path:types.SimpleNamespace(st_dev=os.makedev(*ids[path]))),patch.object(h.os,'statvfs',return_value=fs):
            return h.physical_disk_summary([{'target':p} for p in mounts])
    def test_one_disk_ignores_virtual_mounts_and_duplicate_bind_mounts(self):
        devices=[{'name':'vda','type':'disk','size':2000,'maj:min':'252:0','children':[{'name':'vda1','type':'part','maj:min':'252:1'}]}]
        result=self.summarize(devices,['/','/var/lib/docker/bind','/proc','/run'],{'/':(252,1),'/var/lib/docker/bind':(252,1),'/proc':(0,5),'/run':(0,6)})
        self.assertEqual(len(result),1);self.assertEqual(result[0]['used_bytes'],600);self.assertEqual(result[0]['free_bytes'],400);self.assertEqual(result[0]['total_bytes'],1000)
    def test_two_disks_produce_two_summaries(self):
        devices=[{'name':'vda','type':'disk','size':1000,'maj:min':'252:0'},{'name':'vdb','type':'disk','size':1000,'maj:min':'252:16'}]
        result=self.summarize(devices,['/','/mnt/data'],{'/':(252,0),'/mnt/data':(252,16)})
        self.assertEqual([v['name'] for v in result],['vda','vdb']);self.assertEqual([v['free_bytes'] for v in result],[400,400])
    def test_unmounted_disk_does_not_claim_free_space(self):
        result=self.summarize([{'name':'vdb','type':'disk','size':1000,'maj:min':'252:16'}],[],{})
        self.assertIsNone(result[0]['free_bytes']);self.assertFalse(result[0]['mounted'])
    def test_spanning_lvm_does_not_count_whole_volume_on_each_disk(self):
        devices=[{'name':name,'type':'disk','size':1000,'maj:min':number,'children':[{'name':'vg-data','type':'lvm','maj:min':'253:0'}]} for name,number in [('sda','8:0'),('sdb','8:16')]]
        result=self.summarize(devices,['/'],{'/':(253,0)})
        self.assertTrue(all(v['shared'] and v['used_bytes'] is None for v in result))
