"""Actual Restic dry run must leave an empty repository empty."""
import importlib.util,json,pathlib,tempfile,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('helper',root/'backend/helper.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
with tempfile.TemporaryDirectory(prefix='sb-dry-') as temp:
    base=pathlib.Path(temp);h.ROOT=base/'state';h.ROOT.mkdir();source=base/'source';source.mkdir();(source/'file with spaces.txt').write_text('test content')
    repo={'id':'repo','type':'local-test-fixture','repository':str(base/'repository'),'password':'fixture-only-password'}
    h.write(h.ROOT/'repositories/repo.json',repo)
    job={'id':'job','repository_id':'repo','sources':[str(source)],'excludes':[],'containers':[],'database_ids':[]}
    h.write(h.ROOT/'jobs/job.json',job)
    assert h.restic(repo,['init']).returncode==0
    assert h.restic_backup_supports('--dry-run')
    state=h.execute_job('job',dry=True)
    assert state['status']=='success',state.get('error')
    assert state['dry_run'] is True
    assert json.loads(h.restic(repo,['snapshots','--json']).stdout)==[]
    assert not (h.ROOT/'dumps').exists()
    print('ACTUAL RESTIC DRY RUN PASSED; NO SNAPSHOT OR DUMP WRITTEN')
