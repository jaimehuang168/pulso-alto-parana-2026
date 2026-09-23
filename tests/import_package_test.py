"""僅測試本機 ZIP 安全匯入，不呼叫 GitHub 或 Supabase。"""
import hashlib
import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('importer',Path(__file__).parents[1]/'scripts/import-package.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ImportTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.dest=self.root/'repo';self.dest.mkdir();self.z=self.root/'package.zip'
 def tearDown(self):self.temp.cleanup()
 def package(self,extra=None):
  with zipfile.ZipFile(self.z,'w') as z:
   for p in sorted(m.REQUIRED):z.writestr(m.ROOT_NAME+'/'+p,"supabaseUrl: '', supabasePublishableKey: ''" if p=='web/config.js' else 'source')
   for p,data in (extra or {}).items():z.writestr(p,data)
  return hashlib.sha256(self.z.read_bytes()).hexdigest()
 def test_valid_and_idempotent(self):
  sha=self.package();self.assertEqual(m.apply_package(self.z,self.dest,sha),len(m.REQUIRED));self.assertEqual(m.apply_package(self.z,self.dest,sha),0)
 def test_wrong_hash_no_writes(self):
  self.package()
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,'0'*64)
  self.assertEqual(list(self.dest.iterdir()),[])
 def test_traversal(self):
  sha=self.package({m.ROOT_NAME+'/../escape':'bad'})
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,sha)
 def test_existing_modified_file_not_overwritten(self):
  sha=self.package();(self.dest/'web').mkdir();p=self.dest/'web/app.js';p.write_text('user edit')
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,sha)
  self.assertEqual(p.read_text(),'user edit');self.assertFalse((self.dest/'web/core.js').exists())
 def test_reject_unexpected_root_file(self):
  sha=self.package({m.ROOT_NAME+'/staff-passwords.csv':'private'})
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,sha)
 def test_workflows_cannot_be_replaced(self):
  sha=self.package({m.ROOT_NAME+'/.github/workflows/other.yml':'not to be installed'})
  m.apply_package(self.z,self.dest,sha);self.assertFalse((self.dest/'.github').exists())
 def test_symlink(self):
  self.package()
  with zipfile.ZipFile(self.z,'a') as z:
   i=zipfile.ZipInfo(m.ROOT_NAME+'/web/link');i.create_system=3;i.external_attr=0o120777<<16;z.writestr(i,'/tmp/target')
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,hashlib.sha256(self.z.read_bytes()).hexdigest())
 def test_reject_incomplete_package(self):
  with zipfile.ZipFile(self.z,'w') as z:z.writestr(m.ROOT_NAME+'/web/app.js','source')
  with self.assertRaises(ValueError):m.apply_package(self.z,self.dest,hashlib.sha256(self.z.read_bytes()).hexdigest())
if __name__=='__main__':unittest.main()
