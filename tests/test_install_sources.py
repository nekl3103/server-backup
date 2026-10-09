import importlib.util,pathlib,subprocess,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('install_helper',pathlib.Path(__file__).parents[1]/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
class InstallSourcesTests(unittest.TestCase):
    def test_signed_ubuntu_sources_for_correct_architecture(self):
        with patch.object(pathlib.Path,'is_file',return_value=True):
            amd=h.official_apt_sources({'ID':'ubuntu','VERSION_CODENAME':'jammy'},'amd64');arm=h.official_apt_sources({'ID':'ubuntu','VERSION_CODENAME':'jammy'},'arm64')
        self.assertIn('jammy-security',amd);self.assertIn('main universe',amd);self.assertIn('signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg',amd)
        self.assertIn('ports.ubuntu.com',arm);self.assertNotIn('archive.ubuntu.com',arm);self.assertNotIn('trusted=yes',amd)
    def test_debian_and_invalid_suite(self):
        with patch.object(pathlib.Path,'is_file',return_value=True):
            self.assertIn('bookworm-security',h.official_apt_sources({'ID':'debian','VERSION_CODENAME':'bookworm'},'amd64'))
            with self.assertRaises(ValueError):h.official_apt_sources({'ID':'ubuntu','VERSION_CODENAME':'jammy\ntrusted=yes'},'amd64')
        with patch.object(pathlib.Path,'is_file',return_value=False):
            with self.assertRaises(ValueError):h.official_apt_sources({'ID':'ubuntu','VERSION_CODENAME':'jammy'},'amd64')
    def test_separate_sources_indexes_preserve_configuration_and_signatures(self):
        commands=[];folders=[]
        def run(args,**kwargs):
            commands.append(args)
            if args[0]=='dpkg':return subprocess.CompletedProcess(args,0,'amd64\n','')
            source=next(arg for arg in args if arg.startswith('Dir::Etc::sourcelist=')).split('=',1)[1];folders.append(pathlib.Path(source).parent)
            self.assertIn('signed-by=',pathlib.Path(source).read_text());self.assertIn('Dir::Etc::sourceparts=-',args);self.assertIn('Acquire::AllowInsecureRepositories=false',args);self.assertIn('APT::Get::AllowUnauthenticated=false',args)
            return subprocess.CompletedProcess(args,0,'','')
        constructor=tempfile.TemporaryDirectory
        with patch.object(h.tempfile,'TemporaryDirectory',side_effect=lambda **kwargs:constructor(prefix=kwargs['prefix'])),patch.object(h,'require_admin'),patch.object(h,'official_apt_sources',return_value='deb [signed-by=/key] https://fixture jammy main\n'),patch.object(h,'run',side_effect=run):h.install_backup_packages(['restic'],{'ID':'ubuntu'})
        self.assertIn('--no-remove',commands[-1]);self.assertIn('--force-confold',' '.join(commands[-1]));self.assertTrue(all(not p.exists() for p in folders))
