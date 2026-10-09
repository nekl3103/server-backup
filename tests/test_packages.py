import importlib.util,pathlib,tempfile,subprocess,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('helper_packages',pathlib.Path(__file__).parents[1]/'backend/helper.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class PackageTests(unittest.TestCase):
    def test_rejects_options_shell_and_multiple_packages(self):
        for name in ['-y','nginx php','nginx;id','$(id)','/tmp/file.deb','nginx=1.0','a\nnginx',None]:
            with self.assertRaises(ValueError):h.package_name(name)
        self.assertEqual(h.package_name('libstdc++6:amd64'),'libstdc++6:amd64')
    def test_search_escapes_regular_expression(self):
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,'libstdc++6 - runtime\n','')) as run:
            self.assertEqual(h.package_search({'query':'libstdc++'})['packages'][0]['name'],'libstdc++6')
            self.assertIn(r'libstdc\+\+',run.call_args.args[0])
    def test_plan_blocks_removals_and_checks_errors(self):
        with patch.object(h,'run',return_value=subprocess.CompletedProcess([],100,'','')) as run:
            with self.assertRaises(RuntimeError):h.package_plan('nginx')
            self.assertIn('--no-remove',run.call_args.args[0]);self.assertIn('-s',run.call_args.args[0])
    def test_install_rejects_changed_plan_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(h,'ROOT',pathlib.Path(tmp)),patch.object(h,'require_admin'),patch.object(h,'package_plan',return_value={'plan_hash':'changed'}),patch.object(h,'run') as run:
            with self.assertRaises(ValueError):h.install_package({'name':'nginx','confirmed':True,'plan_hash':'old'})
            run.assert_not_called()
    def test_install_preserves_configs_and_prevents_removals(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(h,'ROOT',pathlib.Path(tmp)),patch.object(h,'require_admin'),patch.object(h,'package_plan',return_value={'plan_hash':'same'}),patch.object(h,'run',return_value=subprocess.CompletedProcess([],0,'done','')) as run:
            h.install_package({'name':'nginx','confirmed':True,'plan_hash':'same'})
            cmd=run.call_args.args[0];self.assertIn('--no-remove',cmd);self.assertIn('Dpkg::Options::=--force-confold',cmd);self.assertEqual(cmd[-2:],['--','nginx'])
    def test_category_keeps_system_even_if_marked_manual(self):
        text='ii \tbash\t5\tamd64\t123\tyes\trequired\nii \tnginx\t1\tamd64\t99\tno\toptional\nii \tlibfoo\t1\tamd64\t99\tno\toptional\n'
        def run(args,**kwargs):return subprocess.CompletedProcess([],0,'bash\nnginx\n' if args[0]=='apt-mark' else text,'')
        with patch.object(h.shutil,'which',return_value='/tool'),patch.object(h,'run',side_effect=run),patch.object(h,'service_inventory',return_value=([],'')):
            items=h.installed_programs()['packages']
        self.assertEqual({p['name']:p['category'] for p in items},{'bash':'system','nginx':'manual','libfoo':'dependency'})
    def test_dispatch_requires_confirmation_before_helper_update(self):
        with patch.object(h,'require_admin'),patch.object(h,'install_helper_source') as update:
            with self.assertRaises(ValueError):h.dispatch({'action':'package_install','name':'nginx'})
            update.assert_not_called()
