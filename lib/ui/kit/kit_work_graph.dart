/// KitWorkGraph (docs/ux-system/kit-api/KitWorkGraph.md): the dependency
/// graph of a team task's work items, readable on a phone.
///
/// On a compact window, `rows` lists one item per row with the `needs`
/// links drawn as lanes in a start-side gutter and each row saying its
/// state in words. From a medium window up, `layers` draws the graph in a
/// zoomable canvas ([KitZoom]) with the critical path and blocked chain
/// picked out, fitted on open.
///
/// The part is model-free: the host maps its own work items to
/// [KitWorkGraphNode]s. [KitWorkGraphGeometry] is the pure, deterministic
/// layout the widget paints — tests assert its positions directly.
///
/// Nodes are [KitTappable]s holding a [KitTaskMark] and [KitText]; only the
/// links and their arrow heads are painted.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import 'kit_bidi.dart';
import 'kit_image.dart';
import 'kit_layout.dart';
import 'kit_state_view.dart';
import 'kit_surface.dart';
import 'kit_tappable.dart';
import 'kit_task_mark.dart';
import 'kit_text.dart';
import 'kit_tokens.dart';

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// One work item. The host maps its own model; the kit knows no WorkState.
@immutable
class KitWorkGraphNode {
  const KitWorkGraphNode({
    required this.id,
    required this.title,
    required this.mark,
    this.paused = false,
    this.word,
    this.dependsOn = const [],
    this.stuck = false,
    this.open = true,
  });

  final String id;

  /// The item's title as written (COPY-2).
  final String title;

  /// The leading mark and its tone.
  final KitTaskState mark;

  /// Only meaningful with [KitTaskState.waiting] or [KitTaskState.working]
  /// (KitTaskMark's own rule).
  final bool paused;

  /// The state word; null takes [KitTaskMark.wordFor].
  final String? word;

  /// Ids this item needs; ids outside the graph are ignored.
  final List<String> dependsOn;

  /// Blocked, needs input or failed: seeds the blocked chain.
  final bool stuck;

  /// Not finished yet: something stuck may be waiting on it.
  final bool open;
}

/// Where [KitWorkGraph] draws its graph.
enum KitWorkGraphLayout {
  /// Rows on compact, layers from medium (the default).
  auto,

  /// One item per row, links in a start-side gutter; scrolls with its host.
  rows,

  /// The layered graph in a zoomable canvas, fitted on open.
  layers,
}

/// One `needs` link. In `layers` it is a cubic curve through [control1] and
/// [control2] (UNCHANGED geometry from the retired `WorkGraphEdge`); in
/// `rows` it is a straight run through its [lane] in the start-side gutter.
@immutable
class KitWorkGraphEdge {
  const KitWorkGraphEdge({
    required this.from,
    required this.to,
    required this.start,
    required this.control1,
    required this.control2,
    required this.end,
    required this.critical,
    required this.blocked,
    this.lane = -1,
  });

  /// The needed item (upstream).
  final String from;

  /// The item that needs it (downstream).
  final String to;
  final Offset start;
  final Offset control1;
  final Offset control2;
  final Offset end;

  /// On the critical path: drawn thicker.
  final bool critical;

  /// Both ends in the blocked chain: drawn dashed in `text1` (LOOK-4:
  /// never the attention tone).
  final bool blocked;

  /// Rows only; -1 in layers.
  final int lane;

  Path toPath() => Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(
      control1.dx,
      control1.dy,
      control2.dx,
      control2.dy,
      end.dx,
      end.dy,
    );
}

/// A row/layer graph analysis shared by [KitWorkGraphGeometry.layers] and
/// [KitWorkGraphGeometry.rows]: unique nodes, the DAG of dependencies (a
/// dependency that would close a cycle is dropped), rows by longest-path
/// layer with a barycenter sweep, the critical path and the blocked chain.
/// Identical for both forms so their node order always agrees (KitWorkGraph.md
/// "the same order as layers read top to bottom, start to end").
class _Analysis {
  _Analysis({
    required this.nodes,
    required this.deps,
    required this.dependents,
    required this.rows,
    required this.criticalPath,
    required this.blockedChain,
  });

  final List<KitWorkGraphNode> nodes;
  final List<List<int>> deps;
  final List<List<int>> dependents;

  /// Row (layer) index → node indices, left/start to right/end.
  final List<List<int>> rows;
  final List<String> criticalPath;
  final Set<String> blockedChain;

  static _Analysis of(List<KitWorkGraphNode> input) {
    // 1. Unique nodes in input order; edges to known, other nodes only.
    final nodes = <KitWorkGraphNode>[];
    final index = <String, int>{};
    for (final node in input) {
      if (index.containsKey(node.id)) continue;
      index[node.id] = nodes.length;
      nodes.add(node);
    }
    final n = nodes.length;
    final deps = <List<int>>[
      for (final node in nodes)
        [
          for (final id in {...node.dependsOn})
            if (index[id] case final i? when i != index[node.id]) i,
        ],
    ];

    // 2. Longest-path layering with cycle breaking: a dependency that
    //    closes a cycle is dropped so the graph stays a DAG.
    final layer = List<int?>.filled(n, null);
    final visiting = List<bool>.filled(n, false);
    int layerOf(int i) {
      if (layer[i] case final done?) return done;
      visiting[i] = true;
      var depth = 0;
      final kept = <int>[];
      for (final dep in deps[i]) {
        if (visiting[dep]) continue;
        kept.add(dep);
        depth = math.max(depth, layerOf(dep) + 1);
      }
      deps[i] = kept;
      visiting[i] = false;
      return layer[i] = depth;
    }

    for (var i = 0; i < n; i++) {
      layerOf(i);
    }
    final dependents = List<List<int>>.generate(n, (_) => []);
    for (var i = 0; i < n; i++) {
      for (final dep in deps[i]) {
        dependents[dep].add(i);
      }
    }

    // 3. Rows in input order, then three barycenter sweeps (down, up,
    //    down) pulling every node under the mean of its neighbours.
    final depth = n == 0 ? 0 : layer.cast<int>().reduce(math.max) + 1;
    final rows = List<List<int>>.generate(depth, (_) => []);
    for (var i = 0; i < n; i++) {
      rows[layer[i]!].add(i);
    }
    final column = List<double>.filled(n, 0);
    void place() {
      for (final row in rows) {
        for (final (position, i) in row.indexed) {
          column[i] = position - (row.length - 1) / 2;
        }
      }
    }

    void sweep(List<List<int>> neighbours, {bool upward = false}) {
      for (final row in upward ? rows.reversed : rows) {
        final key = <int, double>{};
        for (final i in row) {
          final near = neighbours[i];
          key[i] = near.isEmpty
              ? column[i]
              : near.map((j) => column[j]).reduce((a, b) => a + b) /
                    near.length;
        }
        final before = {for (final (p, i) in row.indexed) i: p};
        row.sort((a, b) {
          final byKey = key[a]!.compareTo(key[b]!);
          return byKey != 0 ? byKey : before[a]!.compareTo(before[b]!);
        });
        place();
      }
    }

    place();
    sweep(deps);
    sweep(dependents, upward: true);
    sweep(deps);

    // 4. Critical path: the longest chain by node count; ties go to the
    //    earliest input node so the answer never flickers.
    final chain = List<int>.filled(n, 1);
    final via = List<int?>.filled(n, null);
    for (var r = 0; r < depth; r++) {
      for (final i in rows[r]) {
        for (final dep in deps[i]) {
          final length = chain[dep] + 1;
          if (length > chain[i] || (length == chain[i] && dep < via[i]!)) {
            chain[i] = length;
            via[i] = dep;
          }
        }
      }
    }
    final criticalPath = <String>[];
    if (n > 0) {
      var end = 0;
      for (var i = 1; i < n; i++) {
        if (chain[i] > chain[end]) end = i;
      }
      for (int? i = end; i != null; i = via[i]) {
        criticalPath.insert(0, nodes[i].id);
      }
    }

    // 5. Blocked chain: stuck items, everything downstream of them and the
    //    open items they wait on.
    final blocked = <int>{};
    final queue = <int>[
      for (var i = 0; i < n; i++)
        if (nodes[i].stuck) i,
    ];
    for (final i in queue) {
      for (final dep in deps[i]) {
        if (nodes[dep].open) blocked.add(dep);
      }
    }
    while (queue.isNotEmpty) {
      final i = queue.removeLast();
      if (!blocked.add(i)) continue;
      queue.addAll(dependents[i]);
    }

    return _Analysis(
      nodes: nodes,
      deps: deps,
      dependents: dependents,
      rows: rows,
      criticalPath: criticalPath,
      blockedChain: {for (final i in blocked) nodes[i].id},
    );
  }
}

/// The pure, deterministic geometry (moved unchanged from the retired
/// `WorkGraphLayout`, plus the `rows` form). No widgets; tests assert
/// positions.
class KitWorkGraphGeometry {
  KitWorkGraphGeometry._({
    required this.nodes,
    required this.rects,
    required this.layerRows,
    required this.edges,
    required this.criticalPath,
    required this.blockedChain,
    required this.size,
    required this.gutter,
  });

  /// The canvas padding around `layers`, in logical pixels.
  ///
  /// [KitTokens.space4]'s value. The geometry is pure Dart with no
  /// BuildContext, and its `layers` output must stay exactly the retired
  /// `WorkGraphLayout`'s for the same node size (KitWorkGraph.md Notes,
  /// KIT-43), so it takes the token's fixed value here.
  static const double _canvasPadding = 16;

  /// One `rows` lane's width in the pure geometry: [KitTokens.space3]'s
  /// value, for the same reason as [_canvasPadding]. The widget draws the
  /// gutter from the live token (lanes × `space3`).
  static const double _laneWidth = 12;

  /// The nodes in input order, duplicates (by id) dropped.
  final List<KitWorkGraphNode> nodes;

  /// Where each node sits, by id.
  final Map<String, Rect> rects;

  /// Node ids per row, top row first, start to end.
  ///
  /// Contract problem (PROC-20, this unit's QA record): the frozen spec
  /// names this field `layers`, the same as the static factory
  /// [KitWorkGraphGeometry.layers] on the same class — Dart refuses a
  /// static member and an instance member sharing a name
  /// (`conflicting_static_and_instance`). Kept as `layerRows` instead; the
  /// factory keeps its spec name since call sites read it as a verb.
  final List<List<String>> layerRows;
  final List<KitWorkGraphEdge> edges;

  /// The longest chain of `needs` links, upstream first. One id when no
  /// edge exists; empty when the graph is empty.
  final List<String> criticalPath;

  /// Stuck items (blocked, needs input, failed), everything downstream of
  /// them and the open items they wait on.
  final Set<String> blockedChain;

  /// The painted area, padding included.
  final Size size;

  /// `rows`: the links' gutter width; `layers`: 0.
  final double gutter;

  /// Consecutive pairs of [criticalPath] as (from, to).
  Set<(String, String)> get criticalEdges => {
    for (var i = 0; i + 1 < criticalPath.length; i++)
      (criticalPath[i], criticalPath[i + 1]),
  };

  KitWorkGraphNode? nodeAt(Offset point) {
    for (final node in nodes) {
      if (rects[node.id]!.contains(point)) return node;
    }
    return null;
  }

  /// Longest-path layering, then a barycenter sweep, fixed node size, rows
  /// centred. UNCHANGED algorithm and output for the same inputs.
  static KitWorkGraphGeometry layers(
    List<KitWorkGraphNode> nodes, {
    required Size nodeSize,
  }) {
    final a = _Analysis.of(nodes);
    final n = a.nodes.length;
    final depth = a.rows.length;

    final widest = a.rows.fold(0, (w, row) => math.max(w, row.length));
    final width = widest == 0
        ? 0.0
        : widest * nodeSize.width + (widest - 1) * KitTokens.graphColumnGap;
    final rects = <String, Rect>{};
    for (final (r, row) in a.rows.indexed) {
      final rowWidth =
          row.length * nodeSize.width +
          (row.length - 1) * KitTokens.graphColumnGap;
      final left = _canvasPadding + (width - rowWidth) / 2;
      final top =
          _canvasPadding + r * (nodeSize.height + KitTokens.graphRowGap);
      for (final (p, i) in row.indexed) {
        rects[a.nodes[i].id] = Rect.fromLTWH(
          left + p * (nodeSize.width + KitTokens.graphColumnGap),
          top,
          nodeSize.width,
          nodeSize.height,
        );
      }
    }
    final size = Size(
      width + 2 * _canvasPadding,
      depth == 0
          ? 2 * _canvasPadding
          : depth * nodeSize.height +
                (depth - 1) * KitTokens.graphRowGap +
                2 * _canvasPadding,
    );

    final critical = <(int, int)>{
      for (var i = 0; i < n; i++)
        if (_via(a, i) case final dep?
            when a.criticalPath.contains(a.nodes[i].id))
          (dep, i),
    };
    final edges = <KitWorkGraphEdge>[
      for (var i = 0; i < n; i++)
        for (final dep in a.deps[i])
          () {
            final start = rects[a.nodes[dep].id]!.bottomCenter;
            final end = rects[a.nodes[i].id]!.topCenter;
            return KitWorkGraphEdge(
              from: a.nodes[dep].id,
              to: a.nodes[i].id,
              start: start,
              control1: start + Offset(0, KitTokens.graphRowGap / 2),
              control2: end - Offset(0, KitTokens.graphRowGap / 2),
              end: end,
              critical: critical.contains((dep, i)),
              blocked:
                  a.blockedChain.contains(a.nodes[dep].id) &&
                  a.blockedChain.contains(a.nodes[i].id),
            );
          }(),
    ];

    return KitWorkGraphGeometry._(
      nodes: a.nodes,
      rects: rects,
      layerRows: [
        for (final row in a.rows) [for (final i in row) a.nodes[i].id],
      ],
      edges: edges,
      criticalPath: a.criticalPath,
      blockedChain: a.blockedChain,
      size: size,
      gutter: 0,
    );
  }

  /// NEW. The same order as [layers] read top to bottom, start to end, one
  /// node per row; each link gets a lane in the gutter (greedy interval
  /// assignment, at most [KitTokens.graphMaxLanes] lanes; extra links share
  /// the last lane).
  static KitWorkGraphGeometry rows(
    List<KitWorkGraphNode> nodes, {
    required double width,
    required double Function(KitWorkGraphNode) rowHeight,
  }) {
    final a = _Analysis.of(nodes);
    final order = <int>[for (final row in a.rows) ...row];
    final position = <String, int>{
      for (final (p, i) in order.indexed) a.nodes[i].id: p,
    };

    // Lane assignment: sort spans by start then length, place each in the
    // first lane whose last use ends at or before this span's start.
    final spans =
        <(int from, int to, int start, int end)>[
          for (var i = 0; i < a.nodes.length; i++)
            for (final dep in a.deps[i])
              (
                dep,
                i,
                math.min(position[a.nodes[dep].id]!, position[a.nodes[i].id]!),
                math.max(position[a.nodes[dep].id]!, position[a.nodes[i].id]!),
              ),
        ]..sort((x, y) {
          final byStart = x.$3.compareTo(y.$3);
          return byStart != 0 ? byStart : x.$4.compareTo(y.$4);
        });
    final laneEnd = <int, int>{};
    final laneOf = <(int, int), int>{};
    for (final s in spans) {
      var chosen = KitTokens.graphMaxLanes - 1;
      for (var lane = 0; lane < KitTokens.graphMaxLanes; lane++) {
        final end = laneEnd[lane];
        if (end == null || end <= s.$3) {
          chosen = lane;
          break;
        }
      }
      laneEnd[chosen] = math.max(laneEnd[chosen] ?? 0, s.$4);
      laneOf[(s.$1, s.$2)] = chosen;
    }
    final laneCount = laneOf.isEmpty ? 0 : laneOf.values.reduce(math.max) + 1;
    final gutter = laneCount == 0 ? 0.0 : laneCount * _laneWidth;

    final rects = <String, Rect>{};
    var y = 0.0;
    final rowWidth = math.max(0.0, width - gutter);
    for (final i in order) {
      final h = rowHeight(a.nodes[i]);
      rects[a.nodes[i].id] = Rect.fromLTWH(gutter, y, rowWidth, h);
      y += h;
    }
    final size = Size(width, y);

    final critical = <(int, int)>{
      for (var i = 0; i < a.nodes.length; i++)
        if (_via(a, i) case final dep?
            when a.criticalPath.contains(a.nodes[i].id))
          (dep, i),
    };
    final edges = <KitWorkGraphEdge>[
      for (var i = 0; i < a.nodes.length; i++)
        for (final dep in a.deps[i])
          () {
            final lane = laneOf[(dep, i)]!;
            final x = lane * _laneWidth + _laneWidth / 2;
            final start = Offset(x, rects[a.nodes[dep].id]!.center.dy);
            final end = Offset(x, rects[a.nodes[i].id]!.center.dy);
            return KitWorkGraphEdge(
              from: a.nodes[dep].id,
              to: a.nodes[i].id,
              start: start,
              control1: start,
              control2: end,
              end: end,
              critical: critical.contains((dep, i)),
              blocked:
                  a.blockedChain.contains(a.nodes[dep].id) &&
                  a.blockedChain.contains(a.nodes[i].id),
              lane: lane,
            );
          }(),
    ];

    return KitWorkGraphGeometry._(
      nodes: a.nodes,
      rects: rects,
      layerRows: [
        for (final row in a.rows) [for (final i in row) a.nodes[i].id],
      ],
      edges: edges,
      criticalPath: a.criticalPath,
      blockedChain: a.blockedChain,
      size: size,
      gutter: gutter,
    );
  }

  static int? _via(_Analysis a, int i) {
    // Recomputed from criticalPath's adjacency rather than kept as state:
    // the node just upstream of [i] on the critical path, if [i] is on it.
    final id = a.nodes[i].id;
    final at = a.criticalPath.indexOf(id);
    if (at <= 0) return null;
    final fromId = a.criticalPath[at - 1];
    for (final dep in a.deps[i]) {
      if (a.nodes[dep].id == fromId) return dep;
    }
    return null;
  }
}

/// States: laid out, empty, one item (no links), blocked chain, needs you.
/// KIT-12: laid out, empty (+ blocked chain, needs you).
class KitWorkGraph extends StatefulWidget {
  const KitWorkGraph({
    super.key,
    required this.nodes,
    required this.onOpen,
    this.layout = KitWorkGraphLayout.auto,
    this.emptyText,
    this.zoomController,
    this.viewerKey,
    this.canvasKey,
    this.fitKey,
    this.nodeKey,
  });

  final List<KitWorkGraphNode> nodes;

  /// The node's id.
  final ValueChanged<String> onOpen;
  final KitWorkGraphLayout layout;

  /// Shown when [nodes] is empty; null takes `kitWorkGraphEmpty`.
  final String? emptyText;

  /// Layers only; wraps the host's own [TransformationController] when it
  /// has one. Tests read `.value`.
  final KitZoomController? zoomController;
  final Key? viewerKey;
  final Key? canvasKey;

  /// Passed to [KitZoom]'s `resetControlKey`.
  final Key? fitKey;

  /// A test handle on each node's [KitTappable] (its `tappableKey`).
  final Key Function(String id)? nodeKey;

  static const _viewerKey = ValueKey('kit-work-graph-viewer');
  static const _canvasKey = ValueKey('kit-work-graph-canvas');
  static const _fitKey = ValueKey('kit-work-graph-fit');

  @override
  State<KitWorkGraph> createState() => _KitWorkGraphState();
}

class _KitWorkGraphState extends State<KitWorkGraph> {
  KitZoomController? _owned;
  KitZoomController get _zoom =>
      widget.zoomController ?? (_owned ??= KitZoomController());

  @override
  void didUpdateWidget(KitWorkGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoomController != oldWidget.zoomController &&
        oldWidget.zoomController == null) {
      _owned?.dispose();
      _owned = null;
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  KitWorkGraphLayout _resolve(BuildContext context) {
    if (widget.layout != KitWorkGraphLayout.auto) return widget.layout;
    final window = KitLayout.windowOf(context);
    if (window == KitWindow.compact) return KitWorkGraphLayout.rows;
    if (KitLayout.isShort(context)) return KitWorkGraphLayout.rows;
    return KitWorkGraphLayout.layers;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    if (widget.nodes.isEmpty) {
      return KitStateView(
        size: KitStateSize.inline,
        icon: AppIconography.checklist,
        title: widget.emptyText ?? l10n.kitWorkGraphEmpty,
      );
    }
    return switch (_resolve(context)) {
      KitWorkGraphLayout.rows => _RowsGraph(
        nodes: widget.nodes,
        onOpen: widget.onOpen,
        nodeKey: widget.nodeKey,
      ),
      KitWorkGraphLayout.auto || KitWorkGraphLayout.layers => _LayersGraph(
        nodes: widget.nodes,
        onOpen: widget.onOpen,
        nodeKey: widget.nodeKey,
        zoomController: _zoom,
        viewerKey: widget.viewerKey ?? KitWorkGraph._viewerKey,
        canvasKey: widget.canvasKey ?? KitWorkGraph._canvasKey,
        fitKey: widget.fitKey ?? KitWorkGraph._fitKey,
      ),
    };
  }
}

/// A node's word, in one place so `rows` and `layers` (and the graph's
/// data-safety rule, ARCH-8) read it the same way.
String _wordOf(BuildContext context, KitWorkGraphNode node) =>
    node.word ?? KitTaskMark.wordFor(context, node.mark, paused: node.paused);

/// One line of [role] at this context's text scale, in logical pixels:
/// KitText's own size × line height (never a guessed metric).
double _lineOf(TextScaler scaler, KitTextRole role) {
  final style = KitText.styleFor(role);
  return scaler.scale(style.fontSize!) * style.height!;
}

/// [value] rounded up to the next physical pixel, so stacked boxes start on
/// whole device pixels (no soft edges at DPR 3).
double _ceilToPixel(double value, double dpr) =>
    (value * dpr).ceilToDouble() / dpr;

/// A stroke's centre line snapped to the physical grid: on a pixel's centre
/// for an odd physical width (a 1 px hairline), on a pixel edge for an even
/// one (the 2 px critical link), so neither straddles two pixels.
double _snapStroke(double value, double strokeWidth, double dpr) {
  final physical = (strokeWidth * dpr).round();
  if (physical.isOdd) return ((value * dpr).floorToDouble() + .5) / dpr;
  return (value * dpr).roundToDouble() / dpr;
}

/// A node's title: [KitTextRole.rowTitle], isolated (COPY-30), semibold in
/// the blocked chain (KitWorkGraph.md States, "blocked chain").
Widget _titleText(
  KitWorkGraphNode node, {
  required bool inChain,
  required int maxLines,
}) {
  final title = KitBidi.auto(node.title);
  if (!inChain) {
    return KitText(
      title,
      role: KitTextRole.rowTitle,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
  return KitText.rich(
    TextSpan(
      text: title,
      style: const TextStyle(fontWeight: _chainWeight),
    ),
    role: KitTextRole.rowTitle,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
  );
}

/// `rowTitle` semibold: the blocked chain's titles (KitWorkGraph.md States).
const FontWeight _chainWeight = FontWeight.w600;

/// The arrow head's half width and length, in logical pixels, at every
/// link width (KitWorkGraph.md Tokens: "arrow heads the same as their
/// link").
const double _arrowHalfWidth = 5;
const double _arrowLength = 7;

/// The paint for [edge]: critical 2 physical px in `text2`, others 1
/// physical px in `text3`, blocked in `text1` (LOOK-4: never the attention
/// colour; KitWorkGraph.md States).
Paint _linkPaint(
  ThemeRoles roles,
  KitWorkGraphEdge edge, {
  required double hairline,
  required double focusWidth,
}) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.butt
  ..strokeJoin = StrokeJoin.miter
  ..strokeWidth = edge.critical ? focusWidth : hairline
  ..color = edge.blocked
      ? roles.text1
      : edge.critical
      ? roles.text2
      : roles.text3;

/// Dashes [path] with [dash]-long segments and equal gaps.
Path _dashed(Path path, double dash) {
  final result = Path();
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    var draw = true;
    while (distance < metric.length) {
      final next = math.min(distance + dash, metric.length);
      if (draw) {
        result.addPath(metric.extractPath(distance, next), Offset.zero);
      }
      distance = next;
      draw = !draw;
    }
  }
  return result;
}

/// Paints the `layers` links of [geometry]: each curve, then its arrow head
/// pointing down into the node that needs it, in the same tone, width and
/// dash as the link. No nodes: they are widgets. Mirrored in RTL
/// (KitWorkGraph.md RTL, `x → width − x`).
///
/// Shared by `KitWorkGraph` and the retired `WorkGraphPainter` only
/// (KitWorkGraph.md Notes: the painter "stays exported (retired), painting
/// the links only"). Not part of the frozen API: new code uses
/// [KitWorkGraph]; the kit barrel should not export it.
void kitWorkGraphPaintLinks(
  Canvas canvas,
  Size size,
  KitWorkGraphGeometry geometry,
  ThemeRoles roles, {
  required double hairline,
  required double focusWidth,
  TextDirection textDirection = TextDirection.ltr,
}) {
  canvas.save();
  if (textDirection == TextDirection.rtl) {
    canvas
      ..translate(size.width, 0)
      ..scale(-1, 1);
  }
  // Plain links under critical ones, blocked on top: the stronger reading
  // is never hidden under a hairline.
  int rank(KitWorkGraphEdge e) => e.blocked ? 2 : (e.critical ? 1 : 0);
  final edges = [...geometry.edges]..sort((a, b) => rank(a).compareTo(rank(b)));
  for (final edge in edges) {
    final paint = _linkPaint(
      roles,
      edge,
      hairline: hairline,
      focusWidth: focusWidth,
    );
    final path = edge.toPath();
    canvas.drawPath(
      edge.blocked ? _dashed(path, KitTokens.graphDash) : path,
      paint,
    );
    final tip = edge.end;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx - _arrowHalfWidth, tip.dy - _arrowLength)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(tip.dx + _arrowHalfWidth, tip.dy - _arrowLength),
      paint,
    );
  }
  canvas.restore();
}

/// Where a row sits on one link's lane in the `rows` gutter.
enum _RunPart {
  /// The needed item's row: a stub out of the row, then down.
  from,

  /// A row the link passes: the lane runs its full height.
  through,

  /// The row that needs it: down to a stub into the row, with the arrow.
  to,
}

@immutable
class _LaneRun {
  const _LaneRun(this.edge, this.part);

  final KitWorkGraphEdge edge;
  final _RunPart part;
}

/// `rows`: one item per row — mark, title (up to 2 lines), a supporting
/// line naming the state word and first dependency — in a column whose rows
/// grow with their text. Each row paints its own slice of the start-side
/// gutter, so the links follow the rows' real heights (no fixed row
/// height, nothing to overflow).
class _RowsGraph extends StatelessWidget {
  const _RowsGraph({required this.nodes, required this.onOpen, this.nodeKey});

  final List<KitWorkGraphNode> nodes;
  final ValueChanged<String> onOpen;
  final Key Function(String id)? nodeKey;

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 2 * KitTokens.graphNodeWidth;
        // The geometry gives the order, lanes, critical path and blocked
        // chain; the rows' real heights come from their own layout, with
        // the two-line row token as the floor.
        final geometry = KitWorkGraphGeometry.rows(
          nodes,
          width: width,
          rowHeight: (_) => tokens.rowHeightTwoLine,
        );
        final order = [for (final row in geometry.layerRows) ...row];
        final position = {for (final (i, id) in order.indexed) id: i};
        final runs = <String, List<_LaneRun>>{for (final id in order) id: []};
        var lanes = 0;
        for (final edge in geometry.edges) {
          lanes = math.max(lanes, edge.lane + 1);
          final from = position[edge.from]!;
          final to = position[edge.to]!;
          runs[edge.from]!.add(_LaneRun(edge, _RunPart.from));
          for (var k = from + 1; k < to; k++) {
            runs[order[k]]!.add(_LaneRun(edge, _RunPart.through));
          }
          runs[edge.to]!.add(_LaneRun(edge, _RunPart.to));
        }
        final gutter = lanes * tokens.space3;
        final byId = {for (final n in geometry.nodes) n.id: n};
        return Semantics(
          container: true,
          label: l10n.kitWorkGraph,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final id in order)
                _RowNode(
                  node: byId[id]!,
                  word: _wordOf(context, byId[id]!),
                  inChain: geometry.blockedChain.contains(id),
                  dependencyTitles: [
                    for (final dep in byId[id]!.dependsOn)
                      if (dep != id) ?byId[dep]?.title,
                  ],
                  runs: runs[id]!,
                  gutter: gutter,
                  l10n: l10n,
                  onOpen: () => onOpen(id),
                  nodeKey: nodeKey?.call(id),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RowNode extends StatelessWidget {
  const _RowNode({
    required this.node,
    required this.word,
    required this.inChain,
    required this.dependencyTitles,
    required this.runs,
    required this.gutter,
    required this.l10n,
    required this.onOpen,
    this.nodeKey,
  });

  final KitWorkGraphNode node;
  final String word;
  final bool inChain;
  final List<String> dependencyTitles;
  final List<_LaneRun> runs;
  final double gutter;
  final AppLocalizations l10n;
  final VoidCallback onOpen;
  final Key? nodeKey;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final hint = dependencyTitles.isEmpty
        ? null
        : dependencyTitles.length == 1
        ? l10n.kitWorkGraphNeeds(dependencyTitles.first)
        : l10n.kitWorkGraphNeedsMore(
            dependencyTitles.first,
            dependencyTitles.length - 1,
          );
    final supporting = dependencyTitles.isEmpty
        ? word
        : '$word · ${l10n.kitWorkGraphNeeds(dependencyTitles.first)}';
    // No fill and no radius of its own: the row sits on the host's panel
    // and shows only KitTappable's hover and pressed fills (KitWorkGraph.md
    // Tokens, "rows sit on the host's panel").
    final Widget row = KitTappable(
      label: l10n.kitWorkGraphNode(node.title, word),
      onTap: onOpen,
      tappableKey: nodeKey,
      shape: KitShape.square,
      surface: KitSurfaceLevel.surface1,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: tokens.rowHeightTwoLine),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          heightFactor: 1,
          child: Padding(
            padding: EdgeInsetsDirectional.symmetric(
              horizontal: tokens.space3,
              vertical: tokens.space2,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KitTaskMark(state: node.mark, paused: node.paused, label: word),
                SizedBox(width: tokens.space2),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _titleText(node, inChain: inChain, maxLines: 2),
                      KitText(
                        supporting,
                        role: KitTextRole.secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // The supporting line is read as the node's hint (KitWorkGraph.md
    // Accessibility), merged into KitTappable's own button node.
    final Widget named = hint == null
        ? row
        : MergeSemantics(
            child: Semantics(hint: hint, child: row),
          );
    if (gutter == 0) return named;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsetsDirectional.only(start: gutter),
          child: named,
        ),
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width: gutter,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RowGutterPainter(
                runs: runs,
                laneWidth: tokens.space3,
                stubOffset: tokens.space1,
                roles: tokens.roles,
                hairline: KitTokens.hairlineWidth(context),
                focusWidth: KitTokens.focusRingWidth(context),
                dpr: MediaQuery.devicePixelRatioOf(context),
                textDirection: Directionality.of(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints one row's slice of the `rows` gutter: for each link through the
/// row, its lane (snapped to the physical pixel grid) and, at either end, a
/// stub between the lane and the row's start edge — the needed item's stub
/// leaves just below the row's centre, the dependent's arrives just above
/// it with an arrow head pointing into the row — all in the link's tone,
/// width and dash (KitWorkGraph.md Tokens).
class _RowGutterPainter extends CustomPainter {
  _RowGutterPainter({
    required this.runs,
    required this.laneWidth,
    required this.stubOffset,
    required this.roles,
    required this.hairline,
    required this.focusWidth,
    required this.dpr,
    required this.textDirection,
  });

  final List<_LaneRun> runs;
  final double laneWidth;
  final double stubOffset;
  final ThemeRoles roles;
  final double hairline;
  final double focusWidth;
  final double dpr;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (textDirection == TextDirection.rtl) {
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    int rank(_LaneRun r) => r.edge.blocked ? 2 : (r.edge.critical ? 1 : 0);
    final ordered = [...runs]..sort((a, b) => rank(a).compareTo(rank(b)));
    final centre = size.height / 2;
    for (final run in ordered) {
      final edge = run.edge;
      final paint = _linkPaint(
        roles,
        edge,
        hairline: hairline,
        focusWidth: focusWidth,
      );
      final width = paint.strokeWidth;
      final x = _snapStroke((edge.lane + .5) * laneWidth, width, dpr);
      final path = Path();
      switch (run.part) {
        case _RunPart.from:
          final y = _snapStroke(centre + stubOffset, width, dpr);
          path
            ..moveTo(size.width, y)
            ..lineTo(x, y)
            ..lineTo(x, size.height);
        case _RunPart.through:
          path
            ..moveTo(x, 0)
            ..lineTo(x, size.height);
        case _RunPart.to:
          final y = _snapStroke(centre - stubOffset, width, dpr);
          path
            ..moveTo(x, 0)
            ..lineTo(x, y)
            ..lineTo(size.width, y);
      }
      canvas.drawPath(
        edge.blocked ? _dashed(path, KitTokens.graphDash) : path,
        paint,
      );
      if (run.part == _RunPart.to) {
        final y = _snapStroke(centre - stubOffset, width, dpr);
        canvas.drawPath(
          Path()
            ..moveTo(size.width - _arrowLength, y - _arrowHalfWidth)
            ..lineTo(size.width, y)
            ..lineTo(size.width - _arrowLength, y + _arrowHalfWidth),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RowGutterPainter oldDelegate) =>
      !listEquals(oldDelegate.runs, runs) ||
      oldDelegate.laneWidth != laneWidth ||
      oldDelegate.stubOffset != stubOffset ||
      oldDelegate.roles != roles ||
      oldDelegate.hairline != hairline ||
      oldDelegate.focusWidth != focusWidth ||
      oldDelegate.dpr != dpr ||
      oldDelegate.textDirection != textDirection;
}

/// `layers`: the layered graph in a zoomable canvas, fitted on open.
class _LayersGraph extends StatelessWidget {
  const _LayersGraph({
    required this.nodes,
    required this.onOpen,
    required this.zoomController,
    required this.viewerKey,
    required this.canvasKey,
    required this.fitKey,
    this.nodeKey,
  });

  final List<KitWorkGraphNode> nodes;
  final ValueChanged<String> onOpen;
  final KitZoomController zoomController;
  final Key viewerKey;
  final Key canvasKey;
  final Key fitKey;
  final Key Function(String id)? nodeKey;

  /// Every chip's size here: [KitTokens.graphNodeWidth] grown with the text,
  /// and the chip's insides (`space2` above and below) around one
  /// `rowTitle` line — plus one `secondary` line for the state word when
  /// any item is stuck — never under [KitTokens.minTarget] (LAY-9), rounded
  /// up to the physical pixel.
  Size _nodeSize(BuildContext context, {required bool withWord}) {
    final scaler = MediaQuery.textScalerOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tokens = KitTokens.of(context);
    final text =
        _lineOf(scaler, KitTextRole.rowTitle) +
        (withWord ? _lineOf(scaler, KitTextRole.secondary) : 0);
    return Size(
      _ceilToPixel(
        math.max(
          KitTokens.graphNodeWidth,
          scaler.scale(KitTokens.graphNodeWidth),
        ),
        dpr,
      ),
      _ceilToPixel(math.max(tokens.minTarget, 2 * tokens.space2 + text), dpr),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tokens = KitTokens.of(context);
    final withWord = nodes.any((n) => n.stuck);
    final geometry = KitWorkGraphGeometry.layers(
      nodes,
      nodeSize: _nodeSize(context, withWord: withWord),
    );
    final direction = Directionality.of(context);
    final byId = {for (final n in geometry.nodes) n.id: n};
    final order = [for (final row in geometry.layerRows) ...row];
    return KitZoom(
      key: viewerKey,
      mode: KitZoomMode.canvas,
      label: l10n.kitWorkGraph,
      controller: zoomController,
      resetControlKey: fitKey,
      child: SizedBox.fromSize(
        key: canvasKey,
        size: geometry.size,
        // Tab order (LAY-10): nodes in geometry order, layer by layer and
        // start to end, before the zoom pill that follows the canvas.
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Stack(
            children: [
              PositionedDirectional(
                start: 0,
                end: 0,
                top: 0,
                bottom: 0,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _LayerEdgePainter(
                      geometry: geometry,
                      roles: tokens.roles,
                      hairline: KitTokens.hairlineWidth(context),
                      focusWidth: KitTokens.focusRingWidth(context),
                      textDirection: direction,
                    ),
                  ),
                ),
              ),
              for (final (index, id) in order.indexed)
                if ((geometry.rects[id], byId[id]) case (
                  final rect?,
                  final node?,
                ))
                  // Start-relative: mirrored in RTL like the painter above
                  // (KitWorkGraph.md RTL, `x → width − x`).
                  PositionedDirectional(
                    start: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(index.toDouble()),
                      child: _LayerChip(
                        node: node,
                        word: _wordOf(context, node),
                        inChain: geometry.blockedChain.contains(id),
                        l10n: l10n,
                        onOpen: () => onOpen(id),
                        nodeKey: nodeKey?.call(id),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A `layers` chip: `surface1` with a 1-physical-px `hairline` border
/// (`text1` in the blocked chain), the panel radius, KitTappable's hover,
/// pressed and focus treatments, the mark and a one-line title. A stuck
/// item also shows its state word on a second line, so a blocked item
/// never reads as the waiting mark it borrows (KitTaskState has no
/// blocked value; this unit's QA record, contract problem).
class _LayerChip extends StatelessWidget {
  const _LayerChip({
    required this.node,
    required this.word,
    required this.inChain,
    required this.l10n,
    required this.onOpen,
    this.nodeKey,
  });

  final KitWorkGraphNode node;
  final String word;
  final bool inChain;
  final AppLocalizations l10n;
  final VoidCallback onOpen;
  final Key? nodeKey;

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final roles = tokens.roles;
    Widget chip = KitSurface(
      level: KitSurfaceLevel.surface1,
      shape: KitShape.panel,
      padding: KitSurfacePadding.none,
      outlined: !inChain,
      child: KitTappable(
        label: l10n.kitWorkGraphNode(node.title, word),
        // A layers title may cut to one line: the tooltip repeats it
        // (A11Y-8, LAY-11).
        tooltip: KitBidi.auto(node.title),
        onTap: onOpen,
        tappableKey: nodeKey,
        shape: KitShape.panel,
        surface: KitSurfaceLevel.surface1,
        child: Padding(
          padding: EdgeInsetsDirectional.symmetric(
            horizontal: tokens.space3,
            vertical: tokens.space2,
          ),
          child: Row(
            children: [
              KitTaskMark(state: node.mark, paused: node.paused, label: word),
              SizedBox(width: tokens.space2),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _titleText(node, inChain: inChain, maxLines: 1),
                    if (node.stuck)
                      KitText(
                        word,
                        role: KitTextRole.secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (inChain) {
      final shape = tokens.shapeOf(KitShape.panel);
      chip = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: shape is OutlinedBorder
              ? shape.copyWith(
                  side: BorderSide(
                    color: roles.text1,
                    width: KitTokens.hairlineWidth(context),
                  ),
                )
              : shape,
        ),
        child: chip,
      );
    }
    return chip;
  }
}

/// Paints [KitWorkGraphGeometry.layers]'s links through
/// [kitWorkGraphPaintLinks].
class _LayerEdgePainter extends CustomPainter {
  _LayerEdgePainter({
    required this.geometry,
    required this.roles,
    required this.hairline,
    required this.focusWidth,
    required this.textDirection,
  });

  final KitWorkGraphGeometry geometry;
  final ThemeRoles roles;
  final double hairline;
  final double focusWidth;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) => kitWorkGraphPaintLinks(
    canvas,
    size,
    geometry,
    roles,
    hairline: hairline,
    focusWidth: focusWidth,
    textDirection: textDirection,
  );

  @override
  bool shouldRepaint(_LayerEdgePainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.roles != roles ||
      oldDelegate.hairline != hairline ||
      oldDelegate.focusWidth != focusWidth ||
      oldDelegate.textDirection != textDirection;
}
