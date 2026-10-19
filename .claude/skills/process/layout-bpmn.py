#!/usr/bin/env python3
"""Add deterministic BPMN DI without third-party layout dependencies."""

import sys
import xml.etree.ElementTree as ET
from collections import defaultdict, deque

NS = {
    'bpmn': 'http://www.omg.org/spec/BPMN/20100524/MODEL',
    'bpmndi': 'http://www.omg.org/spec/BPMN/20100524/DI',
    'dc': 'http://www.omg.org/spec/DD/20100524/DC',
    'di': 'http://www.omg.org/spec/DD/20100524/DI',
    'xsi': 'http://www.w3.org/2001/XMLSchema-instance',
}
for prefix, uri in NS.items():
    ET.register_namespace(prefix, uri)


def add(parent, tag, **attrs):
    prefix, name = tag.split(':')
    return ET.SubElement(parent, f'{{{NS[prefix]}}}{name}',
                         {key: str(value) for key, value in attrs.items()})


def layout(source, destination):
    tree = ET.parse(source)
    root = tree.getroot()
    process = root.find('bpmn:process', NS)
    flows = list(process.findall('bpmn:sequenceFlow', NS))
    collaboration = root.find('bpmn:collaboration', NS)
    if collaboration is not None:
        flows += collaboration.findall('bpmn:messageFlow', NS)
    nodes = {node.get('id'): node for node in process
             if node.find('bpmn:incoming', NS) is not None
             or node.find('bpmn:outgoing', NS) is not None
             or node.tag.split('}')[-1] in {
                 'task', 'serviceTask', 'userTask', 'sendTask', 'receiveTask',
                 'subProcess', 'startEvent', 'endEvent', 'intermediateCatchEvent',
                 'exclusiveGateway', 'parallelGateway'}}
    for flow in flows:
        for attr in ('sourceRef', 'targetRef'):
            if flow.get(attr) not in nodes:
                sys.exit(f"layout-bpmn.py: flow {flow.get('id')} has {attr} "
                         f"'{flow.get(attr)}', which is not a node in the model")
    outgoing = defaultdict(list)
    for flow in flows:
        outgoing[flow.get('sourceRef')].append(flow)

    # Iterative DFS identifies back edges, including self loops. Removing them
    # gives a DAG. Kahn's traversal then computes longest-path columns.
    state = {}
    back = set()
    for node_id in nodes:
        if node_id in state:
            continue
        state[node_id] = 1
        stack = [(node_id, iter(outgoing[node_id]))]
        while stack:
            current, edges = stack[-1]
            flow = next(edges, None)
            if flow is None:
                state[current] = 2
                stack.pop()
                continue
            target = flow.get('targetRef')
            if target not in nodes:
                continue
            if state.get(target) == 1:
                back.add(flow.get('id'))
            elif target not in state:
                state[target] = 1
                stack.append((target, iter(outgoing[target])))
    indegree = dict.fromkeys(nodes, 0)
    for flow in flows:
        if flow.get('id') not in back:
            indegree[flow.get('targetRef')] += 1
    queue = deque(n for n in nodes if indegree[n] == 0)
    column = dict.fromkeys(nodes, 0)
    while queue:
        current = queue.popleft()
        for flow in outgoing[current]:
            if flow.get('id') in back:
                continue
            target = flow.get('targetRef')
            column[target] = max(column[target], column[current] + 1)
            indegree[target] -= 1
            if indegree[target] == 0:
                queue.append(target)

    lanes = process.findall('bpmn:laneSet/bpmn:lane', NS)
    lane_for = {ref.text: lane.get('id') for lane in lanes
                for ref in lane.findall('bpmn:flowNodeRef', NS)}
    bands = [lane.get('id') for lane in lanes] or ['unassigned']
    for node_id in nodes:
        lane_for.setdefault(node_id, bands[0])
    rows = {}
    occupied = defaultdict(int)
    for node_id in nodes:
        cell = (lane_for[node_id], column[node_id])
        rows[node_id] = occupied[cell]
        occupied[cell] += 1
    # Reserve one corridor per loop above all shapes in its source lane.
    loop_index = {}
    loop_count = defaultdict(int)
    for flow in flows:
        if column[flow.get('targetRef')] <= column[flow.get('sourceRef')]:
            lane = lane_for[flow.get('sourceRef')]
            loop_index[flow.get('id')] = loop_count[lane]
            loop_count[lane] += 1
    top, height = {}, {}
    y = 60
    for lane in bands:
        top[lane] = y
        count = max((value for (band, _), value in occupied.items()
                     if band == lane), default=1)
        height[lane] = 100 + 24 * loop_count[lane] + 150 * count
        y += height[lane]
    width = 160 + 240 * (max(column.values(), default=0) + 1)
    diagram = add(root, 'bpmndi:BPMNDiagram', id='Diagram_grid')
    plane = add(diagram, 'bpmndi:BPMNPlane', id='Plane_grid',
                bpmnElement=(collaboration if collaboration is not None else process).get('id'))

    def shape(element_id, bounds, **attrs):
        element = add(plane, 'bpmndi:BPMNShape', id=f'{element_id}_di',
                      bpmnElement=element_id, **attrs)
        x, y, w, h = bounds
        add(element, 'dc:Bounds', x=x, y=y, width=w, height=h)
        return element

    if collaboration is not None:
        for participant in collaboration.findall('bpmn:participant', NS):
            shape(participant.get('id'), (60, 60, width, y - 60), isHorizontal='true')
    for lane in lanes:
        lane_id = lane.get('id')
        shape(lane_id, (90, top[lane_id], width - 30, height[lane_id]), isHorizontal='true')
    bounds = {}
    for node_id, node in nodes.items():
        kind = node.tag.split('}')[-1]
        w, h = (50, 50) if 'Gateway' in kind else ((36, 36) if 'Event' in kind else (120, 80))
        lane = lane_for[node_id]
        x = 160 + 240 * column[node_id] + (120 - w) / 2
        y = top[lane] + 80 + 24 * loop_count[lane] + 150 * rows[node_id] + (80 - h) / 2
        bounds[node_id] = (x, y, w, h)
        element = shape(node_id, bounds[node_id])
        if 'Gateway' in kind or 'Event' in kind:
            label = add(element, 'bpmndi:BPMNLabel')
            # Gateway labels sit beside diamonds, away from branch labels.
            lx, ly = (x + w + 8, y - 25) if 'Gateway' in kind else (x - 32, y + h + 8)
            add(label, 'dc:Bounds', x=lx, y=ly, width=100, height=30)
    for flow in flows:
        source_id, target_id = flow.get('sourceRef'), flow.get('targetRef')
        sx, sy, sw, sh = bounds[source_id]
        tx, ty, tw, th = bounds[target_id]
        start, end = (sx + sw, sy + sh / 2), (tx, ty + th / 2)
        if flow.get('id') in loop_index:
            corridor = top[lane_for[source_id]] + 20 + 24 * loop_index[flow.get('id')]
            # Both vertical legs use column gaps, even for cross-lane loops.
            right = 160 + 240 * column[source_id] + 150
            left = 160 + 240 * column[target_id] - 30
            points = [start, (right, start[1]), (right, corridor),
                      (left, corridor), (left, end[1]), end]
        else:
            middle = 160 + 240 * column[source_id] + 180
            points = [start, (middle, start[1]), (middle, end[1]), end]
        edge = add(plane, 'bpmndi:BPMNEdge', id=f"{flow.get('id')}_di", bpmnElement=flow.get('id'))
        for x, y in points:
            add(edge, 'di:waypoint', x=x, y=y)
        if flow.get('name') and 'Gateway' in nodes[source_id].tag:
            label = add(edge, 'bpmndi:BPMNLabel')
            add(label, 'dc:Bounds', x=start[0] + 10, y=start[1] + 8, width=100, height=30)
    ET.indent(tree, space='  ')
    tree.write(destination, encoding='UTF-8', xml_declaration=True)


if __name__ == '__main__':
    layout(*sys.argv[1:])
