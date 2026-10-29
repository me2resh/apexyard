"""Layout invariants, cycle handling and cross-process determinism."""

import copy
import json
import os
from pathlib import Path
import time
import unittest

from common import FIXTURES, cli, fixture
from layout import layout
from model import normalise


def overlaps(a, b):
    return (a['x'] < b['x']+b['width'] and b['x'] < a['x']+a['width']
            and a['y'] < b['y']+b['height'] and b['y'] < a['y']+a['height'])


def contains(a, b):
    return (a['x'] <= b['x'] and a['y'] <= b['y']
            and a['x']+a['width'] >= b['x']+b['width']
            and a['y']+a['height'] >= b['y']+b['height'])


class LayoutTests(unittest.TestCase):
    def invariants(self, model, positions):
        boxes = positions['nodes']
        ids = sorted(boxes)
        for i, ident in enumerate(ids):
            for other in ids[i+1:]:
                self.assertFalse(overlaps(boxes[ident], boxes[other]), (ident,other))
        frames = positions['groups']
        for node in model['nodes']:
            if node.get('group'):
                self.assertTrue(contains(frames[node['group']], boxes[node['id']]))
        for group in model['groups']:
            if group.get('parent'):
                self.assertTrue(contains(frames[group['parent']],frames[group['id']]))
        for i, group in enumerate(model['groups']):
            for other in model['groups'][i+1:]:
                if group.get('parent') == other.get('parent'):
                    self.assertFalse(overlaps(frames[group['id']],frames[other['id']]), (group,other))
        for node in model['nodes']:
            for group in model['groups']:
                ancestors = []
                parent = node.get('group')
                by_id = {g['id']:g for g in model['groups']}
                while parent:
                    ancestors.append(parent)
                    parent = by_id[parent].get('parent')
                if group['id'] not in ancestors:
                    self.assertFalse(overlaps(boxes[node['id']], frames[group['id']]))
        def integers(value):
            if isinstance(value, dict):
                for v in value.values(): integers(v)
            elif isinstance(value, list):
                for v in value: integers(v)
            elif not isinstance(value, bool):
                self.assertIs(type(value),int)
        integers(positions)

    def test_fixture_invariants_lr_and_tb(self):
        for name in ('dfd','c4-context','c4-container','feature','nested-cycle','stress-300'):
            for direction in ('LR','TB'):
                with self.subTest(name=name,direction=direction):
                    model = normalise(fixture(name))
                    model['diagram']['direction']=direction
                    self.invariants(model, layout(model))

    def test_cycles_self_loops_parallel(self):
        model = normalise(fixture('nested-cycle'))
        positions = layout(model)
        loop = next(e for e in model['edges'] if e['from']==e['to'])
        self.assertTrue(positions['edges'][loop['id']]['back'])
        self.assertTrue(any(e['back'] for e in positions['edges'].values()))
        parallel = [positions['edges'][e['id']]['points'] for e in model['edges'] if e['from']=='api' and e['to']=='db']
        self.assertNotEqual(parallel[0],parallel[1])

    def test_longest_path(self):
        model = normalise(fixture())
        pos = layout(model)['nodes']
        self.assertLess(pos['actor']['x'],pos['api']['x'])
        self.assertLess(pos['api']['x'],pos['db']['x'])

    def test_feature_layer_order(self):
        pos = layout(normalise(fixture('feature')))['groups']
        xs = [pos[g]['x'] for g in ('Screens','Routes','Jobs','Models')]
        self.assertEqual(xs, sorted(xs))
        self.assertEqual(len(set(xs)),4)

    def test_nested_feature(self):
        model = fixture('feature')
        model['groups'].append(dict(id='nested',kind='layer',label='Nested',parent='Screens'))
        model['nodes'][0]['group']='nested'
        model = normalise(model)
        self.invariants(model, layout(model))

    def test_empty_groups(self):
        model = fixture()
        model['nodes']=[]
        model['edges']=[]
        self.invariants(model,layout(model))
        self.assertEqual(len(layout(model)['groups']),1)

    def test_ungrouped_bands(self):
        model=fixture()
        model['nodes'][2]['group']=None
        pos=layout(normalise(model))
        self.assertLess(pos['nodes']['actor']['y'],pos['groups']['zone']['y'])
        self.assertGreater(pos['nodes']['db']['y'],pos['groups']['zone']['y']+pos['groups']['zone']['height'])

    def test_empty_graph(self):
        model=fixture()
        model['nodes']=[]
        model['groups']=[]
        model['edges']=[]
        self.assertEqual(layout(model),dict(nodes={},groups={},edges={},width=32,height=32))

    def test_hashseed_subprocess_bytes(self):
        for name in ('nested-cycle','feature','stress-300'):
            with self.subTest(name=name):
                first=cli('layout',FIXTURES/(name+'.diagram.json'),env=dict(os.environ,PYTHONHASHSEED='1'))
                second=cli('layout',FIXTURES/(name+'.diagram.json'),env=dict(os.environ,PYTHONHASHSEED='8675309'))
                self.assertEqual(first.returncode,0,first.stderr)
                self.assertEqual(second.returncode,0,second.stderr)
                self.assertEqual(first.stdout,second.stdout)

    def test_reordered_input(self):
        model=normalise(fixture('nested-cycle'))
        before=layout(model)
        for key in ('nodes','groups','edges'): model[key].reverse()
        self.assertEqual(layout(model),before)

    def test_tb_rotation(self):
        model=normalise(fixture('nested-cycle'))
        lr=layout(model)
        model['diagram']['direction']='TB'
        tb=layout(model)
        for ident,box in lr['nodes'].items():
            other=tb['nodes'][ident]
            self.assertEqual((box['x'],box['y'],box['width'],box['height']), (other['y'],other['x'],other['height'],other['width']))

    def test_stress_time(self):
        model=normalise(fixture('stress-300'))
        start=time.perf_counter()
        layout(model)
        elapsed=time.perf_counter()-start
        print('300-node layout: %.6f seconds' % elapsed)
        self.assertLess(elapsed,2.0)


if __name__ == '__main__':
    unittest.main()
