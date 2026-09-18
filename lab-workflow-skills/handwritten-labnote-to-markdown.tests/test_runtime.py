import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]/'handwritten-labnote-to-markdown'
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    obj=importlib.util.module_from_spec(spec); spec.loader.exec_module(obj)
    return obj
v=module('validate_outputs')
p=module('prepare_pages')

T='# <Title>\n- 日期：\n## A\n- 目的：\n| 时间 | 操作 |\n| --- | --- |\n## B\n- 结论：\n'
F=T.replace('<Title>','Synthetic').replace('- 目的：','- 目的：test').replace('## B','| now | observed |\n## B')
TRACE='# Traceability\n- Source: synthetic.pdf\n- Pages inspected: 1\n- Template: template.md\n'

class Structure(unittest.TestCase):
    def check(self,f=F,q='# Queue\nEmpty.',trace=TRACE,e=None,t=T):
        return v.validate(t,f,q,trace,e)
    def test_valid_and_unfamiliar_template(self):
        self.assertEqual([],self.check())
        self.assertEqual([],self.check(t='# <Name>\n## Different\n- Specimen:\n',f='# Run\n## Different\n- Specimen:\n'))
    def test_missing_prompt(self):
        self.assertTrue(self.check(f=F.replace('- 目的：test\n','')))
    def test_moved_prompt(self):
        self.assertTrue(self.check(f=F.replace('- 目的：test\n','').replace('## B','## B\n- 目的：test')))
    def test_changed_table(self):
        self.assertTrue(self.check(f=F.replace('| 时间 | 操作 |','| 时间 | 结果 |')))
    def test_bad_row_width(self):
        self.assertTrue(self.check(f=F.replace('| now | observed |','| now | observed | extra |')))
    def test_missing_heading(self):
        self.assertTrue(self.check(f=F.replace('## A','## Other')))
    def test_trace_only_uncertainty_is_valid(self):
        self.assertEqual([],self.check(q='| U001 | margin |',trace=TRACE+'\nmargin ⟦U001⟧'))
    def test_orphan_queue(self):
        self.assertTrue(self.check(q='| U001 | margin |'))
    def test_missing_queue(self):
        self.assertTrue(self.check(f=F+'\n⟦U001⟧'))
    def test_duplicate_queue(self):
        self.assertTrue(self.check(q='| U001 | x |\n| U001 | y |',trace=TRACE+'⟦U001⟧'))
    def test_html_is_not_placeholder(self):
        self.assertEqual([],self.check(f=F+'\n<br> a < b and c > d'))
        self.assertTrue(self.check(f=T))
    def test_ledger_page_coverage(self):
        e={'page_count':2,'inspected_pages':[1,2],'evidence':[{'id':'E001','page':1,'region':'top','status':'confirmed','text':'x','destination':'A'}]}
        self.assertTrue(self.check(e=e))
        e['evidence'].append({'id':'E002','page':2,'region':'all','status':'blank','text':'Visually blank','destination':'traceability.md'})
        self.assertEqual([],self.check(e=e))
        e['inspected_pages']=[1,1,2]
        self.assertTrue(self.check(e=e))
    def test_invalid_ledger(self):
        self.assertTrue(self.check(e={}))
        self.assertTrue(self.check(e={'page_count':True,'inspected_pages':[1],'evidence':[]}))

class Cache(unittest.TestCase):
    def test_cache_invalidation_and_corruption(self):
        from pypdf import PdfWriter
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); src=root/'source.pdf'; out=root/'out'
            writer=PdfWriter(); writer.add_blank_page(width=72,height=72)
            with src.open('wb') as f: writer.write(f)
            source_hash=p.digest(src)
            first=p.prepare([src],out)
            second=p.prepare([src],out)
            self.assertFalse(first['sources'][0]['pages'][0]['cache_hit'])
            self.assertTrue(second['sources'][0]['pages'][0]['cache_hit'])
            image=out/second['sources'][0]['pages'][0]['image']
            image.write_bytes(b'corrupt')
            repaired=p.prepare([src],out)
            self.assertFalse(repaired['sources'][0]['pages'][0]['cache_hit'])
            image.with_suffix('.json').write_text('[]',encoding='utf-8')
            self.assertFalse(p.prepare([src],out)['sources'][0]['pages'][0]['cache_hit'])
            changed=p.prepare([src],out,dpi=180)
            self.assertFalse(changed['sources'][0]['pages'][0]['cache_hit'])
            crop=p.prepare([src],out,dpi=144,page_number=1,box=(0,0,.5,.5))
            self.assertEqual(72,crop['sources'][0]['pages'][0]['width'])
            self.assertEqual(source_hash,p.digest(src))
            with self.assertRaises(ValueError): p.prepare([src],out,page_number=2,box=(0,0,.5,.5))
            writer=PdfWriter(); writer.add_blank_page(width=100,height=72)
            with src.open('wb') as f: writer.write(f)
            self.assertFalse(p.prepare([src],out)['sources'][0]['pages'][0]['cache_hit'])
    def test_invalid_crop(self):
        for box in ('0,0,2,1','0,0,0,1','nan,0,1,1','0,1,2'):
            with self.assertRaises(Exception): p.crop_box(box)

class GuidedContract(unittest.TestCase):
    T='<!-- labnote:mode=guided -->\n<!-- labnote:run-date-field=整理日期 -->\n# <Title>\n- 整理日期：\n## Plan\n<!-- labnote:guide\n### Optional sample\n- Lot:\n| a | b |\n| --- | --- |\n-->\n## Analysis\n'
    F='# Trial\n- 整理日期：2026-01-02\n## Plan\n- P1: completed today\n## Analysis\n### Hypotheses\nPossible leak?\n'
    def test_flexible_bodies_not_empty_form(self):
        self.assertEqual([],v.validate(self.T,self.F,'Empty',TRACE,run_date='2026-01-02'))
    def test_required_headings_still_checked(self):
        self.assertTrue(v.validate(self.T,self.F.replace('## Analysis','## Other'),'Empty',TRACE))
    def test_guidance_leak_rejected(self):
        self.assertTrue(v.validate(self.T,self.F+'<!-- labnote:guide Lot -->','Empty',TRACE))
    def test_conversion_date(self):
        for value in ('','2026-02-30','2026-1-2','2025-01-02'):
            self.assertTrue(v.validate(self.T,self.F.replace('2026-01-02',value),'Empty',TRACE,run_date='2026-01-02'))
    def test_mode_override_and_invalid_directive(self):
        self.assertEqual([],v.validate(self.T.replace('<!-- labnote:mode=guided -->',''),self.F,'Empty',TRACE,template_mode='guided'))
        self.assertTrue(v.validate(self.T.replace('mode=guided','mode=guess'),self.F,'Empty',TRACE))
    def ledger(self):
        return {'page_count':1,'inspected_pages':[1],'evidence':[
            {'id':'E001','page':1,'region':'middle','status':'confirmed','role':'object','text':'material A','destination':'2'},
            {'id':'E002','page':1,'region':'indented','status':'confirmed','role':'parameter','parent_id':'E001','text':'D: 2','destination':'2','required_in_final':True},
            {'id':'E003','page':1,'region':'bottom red','status':'confirmed','role':'hypothesis','text':'possible leak?','links':['E002'],'destination':'5','required_in_final':True}]}
    def test_required_analysis_not_omitted(self):
        e=self.ledger()
        self.assertTrue(v.validate(self.T,self.F,'Empty',TRACE,e))
        f=self.F+'<!-- evidence:E002 -->\n<!-- evidence:E003 -->'
        self.assertEqual([],v.validate(self.T,f,'Empty',TRACE,e))
    def test_parent_and_link_errors(self):
        e=self.ledger(); f=self.F+'<!-- evidence:E002 --><!-- evidence:E003 -->'
        e['evidence'][0]['parent_id']='E002'
        self.assertTrue(v.validate(self.T,f,'Empty',TRACE,e))
        e=self.ledger();e['evidence'][1]['parent_id']='missing'
        self.assertTrue(v.validate(self.T,f,'Empty',TRACE,e))
        e=self.ledger();e['evidence'][2]['links']='E002'
        self.assertTrue(v.validate(self.T,f,'Empty',TRACE,e))

if __name__=='__main__': unittest.main(verbosity=2)
