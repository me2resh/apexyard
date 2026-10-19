#!/usr/bin/env bash
# Regression tests for #1726: grid layout and truthful lint status.
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d -t process-grid-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/model.json" <<'PY'
import json, sys
nodes = [dict(id=f's{i}', type='event-start', label=f'Start {i}', lane='lane0') for i in range(3)]
nodes += [dict(id=name, type=kind, label=label, lane=f'lane{i}')
          for i, name, kind, label in [
              (1, 'join', 'gateway-parallel', 'Join requests'),
              (2, 'task', 'task', 'Review request'),
              (3, 'decision', 'gateway-exclusive', 'Approved?'),
              (4, 'end', 'event-end', 'Complete')]]
edges = [dict(from_=f's{i}', to='join') for i in range(3)]
edges += [dict(from_='join', to='task'), dict(from_='task', to='decision', label='Hide this'),
          dict(from_='decision', to='task', label='Retry'),
          dict(from_='decision', to='end', label='Approved')]
for edge in edges:
    edge['from'] = edge.pop('from_')
json.dump(dict(slug='grid', lanes=[dict(id=f'lane{i}', name=f'Team {i}') for i in range(5)],
               nodes=nodes, edges=edges), open(sys.argv[1], 'w'))
# Recommended rules reject multiple blank start events. Use a separate,
# semantically clean model for the default-rules lint success check.
clean = dict(slug='clean', lanes=[dict(id=f'lane{i}', name=f'Team {i}') for i in range(5)],
             nodes=[dict(id=f'n{i}', type=('event-start' if i == 0 else 'event-end' if i == 4 else 'gateway-exclusive' if i in (1, 3) else 'task'),
                         label=f'Step {i}', lane=f'lane{i}') for i in range(5)],
             edges=[{'from': f'n{i}', 'to': f'n{i+1}', 'label': 'Continue'} for i in range(4)]
                   + [{'from': 'n3', 'to': 'n1', 'label': 'Retry'}])
json.dump(clean, open(sys.argv[1].replace('model.json', 'clean.json'), 'w'))
PY

"$SKILL_DIR/generate-bpmn.sh" --slug=clean --model="$WORK/clean.json" -o "$WORK/clean.bpmn"
"$SKILL_DIR/generate-bpmn.sh" --slug=grid --model="$WORK/model.json" -o "$WORK/grid.bpmn"
"$SKILL_DIR/generate-bpmn.sh" --slug=grid --model="$WORK/model.json" -o "$WORK/repeat.bpmn"
cmp "$WORK/grid.bpmn" "$WORK/repeat.bpmn"
"$SKILL_DIR/generate-bpmn.sh" --slug=grid --model="$WORK/model.json" -o "$WORK/bare.bpmn" --skip-layout
python3 - "$WORK" <<'PY'
import json, sys
import xml.etree.ElementTree as ET
from pathlib import Path
work = Path(sys.argv[1])
ns = dict(bpmn='http://www.omg.org/spec/BPMN/20100524/MODEL',
          bpmndi='http://www.omg.org/spec/BPMN/20100524/DI',
          dc='http://www.omg.org/spec/DD/20100524/DC', di='http://www.omg.org/spec/DD/20100524/DI')
root = ET.parse(work / 'grid.bpmn')
model = json.loads((work / 'model.json').read_text())
plane = root.find('.//bpmndi:BPMNPlane', ns)
assert plane.get('bpmnElement') == 'Collaboration_grid'
shapes = {s.get('bpmnElement'): s for s in plane.findall('bpmndi:BPMNShape', ns)}
assert set(shapes) == {n['id'] for n in model['nodes']} | {f'lane{i}' for i in range(5)} | {'Participant_grid'}
def bounds(shape):
    b = shape.find('dc:Bounds', ns)
    return tuple(float(b.get(k)) for k in ('x', 'y', 'width', 'height'))
boxes = {n['id']: bounds(shapes[n['id']]) for n in model['nodes']}
assert len({boxes[f's{i}'][1] for i in range(3)}) == 3
assert boxes['join'][0] < boxes['task'][0] < boxes['decision'][0] < boxes['end'][0]
for node in model['nodes']:
    x, y, w, h = boxes[node['id']]
    lx, ly, lw, lh = bounds(shapes[node['lane']])
    assert lx <= x and x + w <= lx + lw and ly <= y and y + h <= ly + lh
edges = {e.get('bpmnElement'): e for e in plane.findall('bpmndi:BPMNEdge', ns)}
assert len(edges) == len(model['edges'])
assert root.find('.//bpmn:sequenceFlow[@id="flow_task_decision"]', ns).get('name') is None
loop = edges['flow_decision_task']
points = [(float(p.get('x')), float(p.get('y'))) for p in loop.findall('di:waypoint', ns)]
assert len(points) == 6
for (x1, y1), (x2, y2) in zip(points, points[1:]):
    assert x1 == x2 or y1 == y2
    for x, y, w, h in boxes.values():
        if x1 == x2:
            assert not (x < x1 < x + w and max(min(y1, y2), y) < min(max(y1, y2), y + h))
        else:
            assert not (y < y1 < y + h and max(min(x1, x2), x) < min(max(x1, x2), x + w))
assert shapes['decision'].find('bpmndi:BPMNLabel/dc:Bounds', ns) is not None
for edge in model['edges']:
    label = edges[f"flow_{edge['from']}_{edge['to']}"].find('bpmndi:BPMNLabel', ns)
    assert (label is not None) == (edge['from'] == 'decision')
assert ET.parse(work / 'bare.bpmn').find('.//bpmndi:BPMNDiagram', ns) is None
# A missing task label is a known label-required error.
root = ET.parse(work / 'clean.bpmn')
root.find('.//bpmn:task', ns).attrib.pop('name')
root.write(work / 'invalid.bpmn', encoding='UTF-8', xml_declaration=True)
print('PASS: complete, deterministic layout; parallel rows; loop clearance; labels; --skip-layout')
PY

# Exercise actual bpmnlint when available. Fail if npm or bpmnlint fails.
if command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
  if ! "$SKILL_DIR/lint.sh" "$WORK/clean.bpmn" > "$WORK/clean.log" 2>&1; then
    cat "$WORK/clean.log"
    exit 1
  fi
  cat "$WORK/clean.log"
  status=0
  "$SKILL_DIR/lint.sh" "$WORK/invalid.bpmn" > "$WORK/error.log" 2>&1 || status=$?
  cat "$WORK/error.log"
  [ "$status" -eq 1 ]
  grep -q 'label-required' "$WORK/error.log"
  if grep -q 'bpmnlint clean\|integer expression expected' "$WORK/error.log"; then
    echo 'FAIL: invalid file reported clean or broke numeric comparison'
    exit 1
  fi
  echo 'PASS: actual bpmnlint clean file exits 0; known error exits 1'
else
  echo 'SKIP: node/npx unavailable; real bpmnlint checks not run'
fi

# Unexpected failures without a summary must also fail closed.
mkdir "$WORK/bin"
cat > "$WORK/bin/npx" <<'MOCK'
#!/usr/bin/env bash
case "${LINT_SCENARIO:-failure}" in
  errors) echo '✖ 62 problems (59 errors, 3 warnings)'; exit 1 ;;
  warnings) echo '✖ 1 problem (0 errors, 1 warning)'; exit 0 ;;
  *) echo 'npm failed without a summary'; exit 42 ;;
esac
MOCK
chmod +x "$WORK/bin/npx"
status=0
PATH="$WORK/bin:$PATH" "$SKILL_DIR/lint.sh" "$WORK/grid.bpmn" > "$WORK/failure.log" 2>&1 || status=$?
[ "$status" -eq 1 ]
echo 'PASS: nonzero exit without a summary never reports clean'

status=0
LINT_SCENARIO=errors PATH="$WORK/bin:$PATH" "$SKILL_DIR/lint.sh" "$WORK/grid.bpmn" > "$WORK/summary.log" 2>&1 || status=$?
[ "$status" -eq 1 ]
grep -q '59 error(s), 3 warning(s)' "$WORK/summary.log"
status=0
LINT_SCENARIO=warnings PATH="$WORK/bin:$PATH" "$SKILL_DIR/lint.sh" "$WORK/grid.bpmn" > "$WORK/warnings.log" 2>&1 || status=$?
[ "$status" -eq 1 ]
LINT_SCENARIO=warnings PATH="$WORK/bin:$PATH" "$SKILL_DIR/lint.sh" "$WORK/grid.bpmn" --max-warnings=1 > /dev/null
echo 'PASS: plural summary counts and warning thresholds'

# An edge that names a missing node gives one clear error, not a traceback.
python3 - "$WORK/ghost.json" <<'PY'
import json, sys
json.dump(dict(slug='ghost', lanes=[dict(id='l0', name='Team')],
               nodes=[dict(id='a', type='event-start', label='Start', lane='l0')],
               edges=[{'from': 'a', 'to': 'ghost'}]), open(sys.argv[1], 'w'))
PY
status=0
"$SKILL_DIR/generate-bpmn.sh" --slug=ghost --model="$WORK/ghost.json" -o "$WORK/ghost.bpmn" > "$WORK/ghost.log" 2>&1 || status=$?
[ "$status" -ne 0 ]
grep -q "'ghost'" "$WORK/ghost.log"
if grep -q Traceback "$WORK/ghost.log"; then
  echo 'FAIL: missing edge target printed a traceback'
  exit 1
fi
echo 'PASS: missing edge target gives one clear error'

# Without python3 the layout step warns and emits bare BPMN.
mkdir "$WORK/nopy"
for tool in bash env jq awk sed cat cp mkdir mktemp rm dirname grep tr sort head tail cut date xmllint; do
  p=$(command -v "$tool" 2>/dev/null) && ln -s "$p" "$WORK/nopy/$tool"
done
PATH="$WORK/nopy" "$SKILL_DIR/generate-bpmn.sh" --slug=grid --model="$WORK/model.json" -o "$WORK/nopy.bpmn" 2> "$WORK/nopy.log"
grep -q 'WARNING' "$WORK/nopy.log"
! grep -q 'BPMNDiagram' "$WORK/nopy.bpmn"
echo 'PASS: missing python3 falls back to bare BPMN with a warning'
