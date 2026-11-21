"""Deterministic layered positions and cubic edge paths, in integer pixels."""

from collections import defaultdict

NODE_W, NODE_H = 220, 88
COLUMN, ROW, PAD, GAP = 400, 128, 32, 48


def columns(ids, edges):
    outgoing = {ident: [] for ident in ids}
    for edge in sorted(edges, key=lambda e: (e['to'], e['id'])):
        outgoing[edge['from']].append(edge)
    state, back = {}, set()
    for ident in ids:
        if ident in state:
            continue
        state[ident] = 1
        stack = [(ident, iter(outgoing[ident]))]
        while stack:
            current, iterator = stack[-1]
            edge = next(iterator, None)
            if edge is None:
                state[current] = 2
                stack.pop()
            elif state.get(edge['to']) == 1:
                back.add(edge['id'])
            elif edge['to'] not in state:
                state[edge['to']] = 1
                stack.append((edge['to'], iter(outgoing[edge['to']])))
    incoming = {ident: 0 for ident in ids}
    for edge in edges:
        if edge['id'] not in back:
            incoming[edge['to']] += 1
    ready = sorted(ident for ident in ids if incoming[ident] == 0)
    ranks = {ident: 0 for ident in ids}
    while ready:
        current = ready.pop(0)
        for edge in outgoing[current]:
            if edge['id'] in back:
                continue
            target = edge['to']
            ranks[target] = max(ranks[target], ranks[current] + 1)
            incoming[target] -= 1
            if incoming[target] == 0:
                ready.append(target)
                ready.sort()
    return ranks, back


def ordered_columns(members, ranks, neighbours):
    buckets = defaultdict(list)
    for ident in sorted(members):
        buckets[ranks[ident]].append(ident)
    keys = sorted(buckets)
    positions = {ident: i for key in keys for i, ident in enumerate(buckets[key])}
    for sweep in range(4):
        for key in (keys if sweep % 2 == 0 else list(reversed(keys))):
            def score(ident):
                adjacent = neighbours[ident]
                values = [positions[n] for n in adjacent if n in positions]
                return (sum(values) / len(values) if values else positions[ident], ident)
            buckets[key].sort(key=score)
            for i, ident in enumerate(buckets[key]):
                positions[ident] = i
    return buckets


def frame(boxes, fallback_x, y):
    if not boxes:
        return dict(x=fallback_x, y=y, width=NODE_W + 2 * PAD, height=NODE_H + 2 * PAD)
    left = min(b['x'] for b in boxes) - PAD
    top = min(b['y'] for b in boxes) - PAD
    right = max(b['x'] + b['width'] for b in boxes) + PAD
    bottom = max(b['y'] + b['height'] for b in boxes) + PAD
    return dict(x=left, y=top, width=right - left, height=bottom - top)


class Placement:
    """Keep graph state local to one layout run."""

    def __init__(self, model):
        self.model = model
        self.nodes = {node['id']: node for node in model['nodes']}
        self.groups = {group['id']: group for group in model['groups']}
        self.edges = sorted(model['edges'], key=lambda e: e['id'])
        ids = sorted(list(self.nodes) + list(self.groups))
        self.ranks, self.back = columns(ids, self.edges)
        self.neighbours = {ident: [] for ident in ids}
        for edge in self.edges:
            self.neighbours[edge['from']].append(edge['to'])
            self.neighbours[edge['to']].append(edge['from'])
        self.roots = sorted(g for g in self.groups if self.groups[g].get('parent') is None)
        self.feature = model['diagram']['type'] == 'feature'
        self.node_boxes, self.group_boxes = {}, {}
        self.above, self.below = [], []
        if self.feature:
            self.feature_ranks()

    def root(self, ident):
        while ident is not None and self.groups[ident].get('parent') is not None:
            ident = self.groups[ident]['parent']
        return ident

    def feature_ranks(self):
        layer_order = {'screens': 0, 'routes': 1, 'jobs': 2, 'models': 3}
        self.roots.sort(key=lambda g: (self.ranks[g], layer_order.get(self.groups[g]['label'].lower(), 4), g))
        for index, ident in enumerate(self.roots):
            self.ranks[ident] = index
        for ident in sorted(self.groups):
            self.ranks[ident] = self.ranks[self.root(ident)]
        for ident in sorted(self.nodes):
            group = self.nodes[ident].get('group')
            if group is not None:
                self.ranks[ident] = self.ranks[group]

    def members(self, members, y):
        buckets = ordered_columns(members, self.ranks, self.neighbours)
        bottom = y
        for col in sorted(buckets):
            for row, ident in enumerate(buckets[col]):
                self.node_boxes[ident] = dict(x=96 + col * COLUMN, y=y + row * ROW,
                                              width=NODE_W, height=NODE_H)
                bottom = max(bottom, y + row * ROW + NODE_H)
        return bottom

    def group(self, ident, y):
        direct = sorted(n for n in self.nodes if self.nodes[n].get('group') == ident)
        start = y + PAD
        bottom = self.members(direct, start)
        children = sorted(g for g in self.groups if self.groups[g].get('parent') == ident)
        boxes = [self.node_boxes[n] for n in direct]
        for child in children:
            child_y = bottom + GAP if boxes else start
            self.group(child, child_y)
            boxes.append(self.group_boxes[child])
            bottom = self.group_boxes[child]['y'] + self.group_boxes[child]['height']
        self.group_boxes[ident] = frame(boxes, 64 + self.ranks[ident] * COLUMN, y)
        return self.group_boxes[ident]['y'] + self.group_boxes[ident]['height']

    def mean_rank(self, ident):
        members = [self.ranks[n] for n in sorted(self.nodes)
                   if self.root(self.nodes[n].get('group')) == ident]
        return sum(members) / len(members) if members else self.ranks[ident]

    def bands(self):
        self.roots.sort(key=lambda g: (self.mean_rank(g), g))
        ungrouped = sorted(n for n in self.nodes if self.nodes[n].get('group') is None)
        pivot = sum(self.mean_rank(g) for g in self.roots) / len(self.roots) if self.roots else 0
        self.above = [n for n in ungrouped if self.ranks[n] <= pivot]
        self.below = [n for n in ungrouped if self.ranks[n] > pivot]
        y = self.members(self.above, 96) + GAP
        if self.feature:
            bottoms = [self.group(g, y) for g in self.roots]
            y = max(bottoms, default=y) + GAP
        else:
            for ident in self.roots:
                y = self.group(ident, y) + GAP
        self.members(self.below, y)

    def band_top(self, ident):
        group = ident if ident in self.groups else self.nodes[ident].get('group')
        if group is not None:
            return self.group_boxes[self.root(group)]['y']
        members = self.above if ident in self.above else self.below
        return min(self.node_boxes[n]['y'] for n in members)

    def curves(self):
        boxes = dict(self.group_boxes)
        boxes.update(self.node_boxes)
        curves, parallels = {}, defaultdict(int)
        for edge in self.edges:
            source, target = boxes[edge['from']], boxes[edge['to']]
            pair = (edge['from'], edge['to'])
            offset = parallels[pair] * 16
            parallels[pair] += 1
            x1, y1 = source['x'] + source['width'], source['y'] + source['height'] // 2
            x2, y2 = target['x'], target['y'] + target['height'] // 2
            is_back = edge['id'] in self.back or x2 <= x1
            if is_back:
                top = min(self.band_top(edge['from']), self.band_top(edge['to'])) - 64 - offset
                points = [[x1, y1], [x1 + 64, top], [x2 - 64, top], [x2, y2]]
            else:
                mid = (x1 + x2) // 2
                points = [[x1, y1], [mid, y1 + offset], [mid, y2 + offset], [x2, y2]]
            curves[edge['id']] = dict(points=points, back=is_back, offset=offset)
        return curves


def layout(model):
    placement = Placement(model)
    placement.bands()
    return finish(placement.node_boxes, placement.group_boxes,
                  placement.curves(), model['diagram']['direction'])


def finish(node_boxes, group_boxes, curves, direction):
    boxes = list(node_boxes.values()) + list(group_boxes.values())
    points = [p for curve in curves.values() for p in curve['points']]
    min_x = min([b['x'] for b in boxes] + [p[0] for p in points] + [32])
    min_y = min([b['y'] for b in boxes] + [p[1] for p in points] + [32])
    shift_x, shift_y = max(0, 32 - min_x), max(0, 32 - min_y)
    for box in boxes:
        box['x'] += shift_x
        box['y'] += shift_y
    for point in points:
        point[0] += shift_x
        point[1] += shift_y
    if direction == 'TB':
        for box in boxes:
            box['x'], box['y'] = box['y'], box['x']
            box['width'], box['height'] = box['height'], box['width']
        for point in points:
            point[0], point[1] = point[1], point[0]
    all_x = [b['x'] + b['width'] for b in boxes] + [p[0] for p in points]
    all_y = [b['y'] + b['height'] for b in boxes] + [p[1] for p in points]
    return dict(nodes=node_boxes, groups=group_boxes, edges=curves,
                width=max(all_x, default=0) + 32, height=max(all_y, default=0) + 32)
