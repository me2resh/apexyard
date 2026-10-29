'use strict';
// Execute only the marked pure functions. Compile the full inline script too.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const template = fs.readFileSync(path.join(__dirname, '../view.html'), 'ascii');
const script = template.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script);
const pure = script.split('/* ay:graph:start */')[1].split('/* ay:graph:end */')[0];
const context = vm.createContext({});
vm.runInContext(pure, context);
const sorted = values => Array.from(values).sort();
function equal(result, nodes, edges) {
  assert.deepStrictEqual(sorted(result.nodes), nodes.slice().sort());
  assert.deepStrictEqual(sorted(result.edges), edges.slice().sort());
}
function graph(ids, pairs, groups) {
  return context.makeGraph({nodes: ids.map(id => ({id})), groups: groups || [],
    edges: pairs.map(([from, to], i) => ({from, to, id: 'e' + i}))});
}
let checks = 0;
function test(name, run) { run(); checks++; process.stdout.write('PASS: ' + name + '\n'); }
test('diamond: every directed branch, parallel edges, unrelated nodes', () => {
  const g = graph(['a', 'b', 'c', 'd', 'x'], [['a', 'b'], ['a', 'c'], ['b', 'd'], ['c', 'd'], ['a', 'b']]);
  equal(context.pathBetween(g, 'a', 'd'), ['a', 'b', 'c', 'd'], ['e0', 'e1', 'e2', 'e3', 'e4']);
  equal(context.trace(g, 'b', false), ['b', 'd'], ['e2']);
  equal(context.trace(g, 'b', true), ['a', 'b'], ['e0', 'e4']);
  equal(context.pathBetween(g, 'd', 'a'), ['a', 'b', 'c', 'd'], ['e0', 'e1', 'e2', 'e3', 'e4']);
  equal(context.pathBetween(g, 'x', 'a'), [], []);
});
test('cycles and self loops terminate, same-node path', () => {
  const g = graph(['a', 'b', 'c', 'x'], [['a', 'b'], ['b', 'c'], ['c', 'a'], ['b', 'b']]);
  equal(context.trace(g, 'a', false), ['a', 'b', 'c'], ['e0', 'e1', 'e2', 'e3']);
  equal(context.trace(g, 'a', true), ['a', 'b', 'c'], ['e0', 'e1', 'e2', 'e3']);
  equal(context.pathBetween(g, 'x', 'x'), ['x'], []);
});
test('converging branches do not create a path between siblings', () => {
  const g = graph(['a', 'b', 'c'], [['a', 'c'], ['b', 'c']]);
  equal(context.pathBetween(g, 'a', 'b'), [], []);
});
test('nested and empty layer endpoints expand without invented sibling edges', () => {
  const model = {groups: [{id: 'G'}, {id: 'child', parent: 'G'}, {id: 'H'}, {id: 'empty'}],
    nodes: [{id: 'a', group: 'G'}, {id: 'b', group: 'child'}, {id: 'c', group: 'H'}, {id: 'x'}],
    edges: [{id: 'layer', from: 'G', to: 'H'}, {id: 'leaf', from: 'c', to: 'empty'}]};
  const g = context.makeGraph(model);
  equal(context.trace(g, 'a', false), ['a', 'c', 'empty'], ['layer', 'leaf']);
  equal(context.trace(g, 'c', true), ['a', 'b', 'c'], ['layer']);
  equal(context.pathBetween(g, 'b', 'c'), ['b', 'c'], ['layer']);
  equal(context.pathBetween(g, 'G', 'empty'), ['a', 'b', 'c', 'empty'], ['layer', 'leaf']);
  equal(context.pathBetween(g, 'a', 'b'), [], []);
});
// Independent closure oracle on expanded fixture edges, in both directions.
function closure(arcs, start, reverse) {
  const seen = new Set(start);
  let changed = true;
  while (changed) {
    changed = false;
    arcs.forEach(arc => {
      const from = reverse ? arc.to : arc.from, to = reverse ? arc.from : arc.to;
      if (seen.has(from) && !seen.has(to)) { seen.add(to); changed = true; }
    });
  }
  return seen;
}
for (const name of ['c4-context', 'c4-container', 'dfd', 'feature', 'nested-cycle', 'stress-300']) {
  test('fixture ' + name + ': arrow direction and path intersection', () => {
    const model = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', name + '.diagram.json'), 'ascii'));
    model.edges.forEach((e, i) => { if (!e.id) e.id = 'edge' + i; });
    const g = context.makeGraph(model);
    for (const start of model.nodes.slice(0, 6)) {
      for (const reverse of [false, true]) {
        const expected = closure(g.arcs, [start.id], reverse);
        const edges = new Set(g.arcs.filter(a => expected.has(a.from) && expected.has(a.to)).map(a => a.id));
        equal(context.trace(g, start.id, reverse), sorted(expected), sorted(edges));
      }
      for (const end of model.nodes.slice(-4)) {
        function intersection(from, to) {
          const forward = closure(g.arcs, [from], false), backward = closure(g.arcs, [to], true);
          return new Set(sorted(forward).filter(id => backward.has(id)));
        }
        let expected = intersection(start.id, end.id);
        if (!expected.size) expected = intersection(end.id, start.id);
        const edges = new Set(g.arcs.filter(a => expected.has(a.from) && expected.has(a.to)).map(a => a.id));
        equal(context.pathBetween(g, start.id, end.id), sorted(expected), sorted(edges));
      }
    }
  });
}
process.stdout.write('PASS: ' + checks + ' graph logic groups; full inline script parses.\n');
