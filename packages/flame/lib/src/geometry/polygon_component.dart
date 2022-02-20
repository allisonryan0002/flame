import 'dart:ui' hide Canvas;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../cache.dart';
import '../../components.dart';
import '../../extensions.dart';
import '../../geometry.dart';

class PolygonComponent extends ShapeComponent {
  final List<Vector2> _vertices;
  UnmodifiableListView<Vector2> get vertices => UnmodifiableListView(_vertices);
  // These lists are used to minimize the amount of objects that are created,
  // and only change the contained object if the corresponding `ValueCache` is
  // deemed outdated.
  late final List<Vector2> _globalVertices;
  late final List<LineSegment> _lineSegments;
  final Path _path = Path();
  final bool _manuallySized;

  final _cachedGlobalVertices = ValueCache<List<Vector2>>();

  /// With this constructor you create your [PolygonComponent] from positions in
  /// anywhere in the 2d-space. It will automatically calculate the [size] of
  /// the Polygon (the bounding box) if no size it given.
  /// NOTE: Always define your polygon in a counter-clockwise fashion (in the
  /// screen coordinate system).
  PolygonComponent(
    this._vertices, {
    Vector2? position,
    Vector2? size,
    Vector2? scale,
    double? angle,
    Anchor? anchor,
    int? priority,
    Paint? paint,
  })  : assert(
          _vertices.length > 2,
          'Number of vertices are too few to create a polygon',
        ),
        _manuallySized = size != null,
        super(
          position: position,
          size: size,
          scale: scale,
          angle: angle,
          anchor: anchor,
          priority: priority,
          paint: paint,
        ) {
    refreshVertices();

    final verticesLength = vertices.length;
    _globalVertices = List.generate(
      verticesLength,
      (_) => Vector2.zero(),
      growable: false,
    );
    _lineSegments = List.generate(
      verticesLength,
      (_) => LineSegment.zero(),
      growable: false,
    );
  }

  /// With this constructor you define the [PolygonComponent] in relation to the
  /// [size] of the shape.
  ///
  /// Example: `[[1.0, 0.0], [0.0, -1.0], [-1.0, 0.0], [0.0, 1.0]]`
  /// This will form a diamond shape within the bounding size box.
  /// NOTE: Always define your shape in a counter-clockwise fashion (in the
  /// screen coordinate system).
  PolygonComponent.fromNormals(
    List<Vector2> normals, {
    required Vector2 size,
    Vector2? position,
    Vector2? scale,
    double? angle,
    Anchor? anchor,
    int? priority,
    Paint? paint,
  }) : this(
          normalsToVertices(normals, size),
          position: position,
          size: size,
          angle: angle,
          anchor: anchor,
          scale: scale,
          priority: priority,
          paint: paint,
        );

  @internal
  static List<Vector2> normalsToVertices(
    List<Vector2> normals,
    Vector2 size,
  ) {
    final halfSize = size / 2;
    return normals
        .map(
          (v) => v.clone()
            ..multiply(halfSize)
            ..add(halfSize),
        )
        .toList(growable: false);
  }

  @protected
  void refreshVertices({List<Vector2>? newVertices}) {
    assert(
      newVertices == null || newVertices.length == _vertices.length,
      'A polygon can not change their number of vertices',
    );
    newVertices?.forEachIndexed((i, vertex) {
      _vertices[i].setFrom(newVertices[i]);
    });
    _path
      ..reset()
      ..addPolygon(
        vertices.map((p) => p.toOffset()).toList(growable: false),
        true,
      );
    final bounds = _path.getBounds();
    if (!_manuallySized) {
      size.setValues(bounds.width, bounds.height);
    }
    final topLeftBounds = bounds.topLeft;
    if (topLeftBounds.dx != 0 || topLeftBounds.dy != 0) {
      position.setValues(
        position.x + topLeftBounds.dx + anchor.x * size.x,
        position.y + topLeftBounds.dy + anchor.y * size.y,
      );
      _vertices.forEach((p) {
        p.setValues(
          p.x - topLeftBounds.dx,
          p.y - topLeftBounds.dy,
        );
      });
    }
  }

  /// Gives back the shape vectors multiplied by the size and scale
  List<Vector2> globalVertices() {
    final scale = absoluteScale;
    final angle = absoluteAngle;
    final position = absoluteTopLeftPosition;
    final center = absoluteCenter;
    // TODO(spydon): Is the parent size needed here
    if (!_cachedGlobalVertices.isCacheValid<dynamic>(<dynamic>[
      position,
      scale,
      angle,
    ])) {
      var i = 0;
      for (final vertex in vertices) {
        _globalVertices[i]
          ..setFrom(vertex)
          ..multiply(scale)
          ..add(position)
          ..rotate(angle, center: position);
        i++;
      }
      if (scale.y.isNegative || scale.x.isNegative) {
        // Since the list will be clockwise we have to reverse it for it to
        // become counterclockwise.
        _reverseList(_globalVertices);
      }
      _cachedGlobalVertices.updateCache<dynamic>(
        _globalVertices,
        <dynamic>[position.clone(), scale.clone(), angle],
      );
    }
    return _cachedGlobalVertices.value!;
  }

  @override
  void render(Canvas canvas) {
    if (renderShape) {
      canvas.drawPath(_path, paint);
    }
  }

  /// Checks whether the polygon contains the [point].
  /// Note: The polygon needs to be convex for this to work.
  @override
  bool containsPoint(Vector2 point) {
    // If the size is 0 then it can't contain any points
    if (size.x == 0 || size.y == 0) {
      return false;
    }

    final vertices = globalVertices();
    for (var i = 0; i < vertices.length; i++) {
      final edge = getEdge(i, vertices: vertices);
      final isOutside = (edge.to.x - edge.from.x) * (point.y - edge.from.y) -
              (point.x - edge.from.x) * (edge.to.y - edge.from.y) >
          0;
      if (isOutside) {
        // Point is outside of convex polygon
        return false;
      }
    }
    return true;
  }

  /// Return all vertices as [LineSegment]s that intersect [rect], if [rect]
  /// is null return all vertices as [LineSegment]s.
  List<LineSegment> possibleIntersectionVertices(Rect? rect) {
    final rectIntersections = <LineSegment>[];
    if ((rect?.width == 0 || false) ||
        (rect?.height == 0 || false) ||
        width == 0 ||
        height == 0) {
      return rectIntersections;
    }
    final vertices = globalVertices();
    for (var i = 0; i < vertices.length; i++) {
      final edge = getEdge(i, vertices: vertices);
      if (rect?.intersectsSegment(edge.from, edge.to) ?? true) {
        rectIntersections.add(edge);
      }
    }
    return rectIntersections;
  }

  LineSegment getEdge(int i, {required List<Vector2> vertices}) {
    _lineSegments[i].from.setFrom(getVertex(i, vertices: vertices));
    _lineSegments[i].to.setFrom(getVertex(i + 1, vertices: vertices));
    return _lineSegments[i];
  }

  Vector2 getVertex(int i, {List<Vector2>? vertices}) {
    vertices ??= globalVertices();
    return vertices[i % vertices.length];
  }

  void _reverseList(List<Object> list) {
    for (var i = 0; i < list.length / 2; i++) {
      final temp = list[i];
      list[i] = list[list.length - 1 - i];
      list[list.length - 1 - i] = temp;
    }
  }
}