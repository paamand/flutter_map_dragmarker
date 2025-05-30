import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'drag_marker.dart';

class DragMarkerWidget extends StatefulWidget {
  const DragMarkerWidget({
    super.key,
    required this.marker,
    required this.mapCamera,
    required this.mapController,
    this.alignment = Alignment.center,
  });

  /// The marker that is to be displayed on the map.
  final DragMarker marker;

  /// The controller of the map that is used to move the map on pan events.
  final MapController mapController;

  /// The camera of the map that provides the current map state.
  final MapCamera mapCamera;

  /// Alignment of each marker relative to its normal center at [DragMarker.point].
  ///
  /// For example, [Alignment.topCenter] will mean the entire marker widget is
  /// located above the [DragMarker.point].
  ///
  /// The center of rotation (anchor) will be opposite this.
  ///
  /// Defaults to [Alignment.center]. Overriden by [DragMarker.alignment] if set.
  final Alignment alignment;

  @override
  State<DragMarkerWidget> createState() => DragMarkerWidgetState();
}

class DragMarkerWidgetState extends State<DragMarkerWidget> {
  var offsetPosition = const Offset(0, 0);
  late LatLng _dragPosStart;
  late LatLng _markerPointStart;
  bool _isDragging = false;

  /// this marker scrolls the map if [marker.scrollMapNearEdge] is set to true
  /// and gets dragged near to an edge. It needs to be static because only one
  static Timer? _mapScrollTimer;

  LatLng get markerPoint => widget.marker.point;

  @override
  Widget build(BuildContext context) {
    final marker = widget.marker;
    _updatePixelPos(markerPoint);

    final displayMarker = marker.builder(context, marker.point, _isDragging);

    return MobileLayerTransformer(
      child: GestureDetector(
        // drag detectors
        onVerticalDragStart: (marker.useLongPress) ? null : _onPanStart,
        onVerticalDragUpdate: (marker.useLongPress) ? null : _onPanUpdate,
        onVerticalDragEnd: (marker.useLongPress) ? null : _onPanEnd,
        onHorizontalDragStart: (marker.useLongPress) ? null : _onPanStart,
        onHorizontalDragUpdate: (marker.useLongPress) ? null : _onPanUpdate,
        onHorizontalDragEnd: (marker.useLongPress) ? null : _onPanEnd,
        // long press detectors
        onLongPressStart: (marker.useLongPress) ? _onLongPanStart : null,
        onLongPressMoveUpdate: (marker.useLongPress) ? _onLongPanUpdate : null,
        onLongPressEnd: (marker.useLongPress) ? _onLongPanEnd : null,
        // user callbacks
        onTap: () => marker.onTap?.call(markerPoint),
        onLongPress: () => marker.onLongPress?.call(markerPoint),
        // child widget
        /* using Stack while the layer widget MarkerWidgets already
            introduces a Stack to the widget tree, try to use decrease the amount
            of Stack widgets in the future. */
        child: Stack(
          children: [
            Positioned(
              width: marker.size.width,
              height: marker.size.height,
              left: offsetPosition.dx,
              top: offsetPosition.dy,
              child: marker.rotateMarker
                  ? Transform.rotate(
                      angle: -widget.mapCamera.rotationRad,
                      alignment: (marker.alignment ?? widget.alignment) * -1,
                      child: displayMarker,
                    )
                  : displayMarker,
            )
          ],
        ),
      ),
    );
  }

  void _updatePixelPos(point) {
    final marker = widget.marker;
    final mapCamera = widget.mapCamera;

    var pxPoint = mapCamera.projectAtZoom(point);

    final left = 0.5 *
        marker.size.width *
        ((marker.alignment ?? widget.alignment).x + 1);
    final top = 0.5 *
        marker.size.height *
        ((marker.alignment ?? widget.alignment).y + 1);
    final right = marker.size.width - left;
    final bottom = marker.size.height - top;

    final offset = Offset(pxPoint.dx - mapCamera.pixelOrigin.dx,
        pxPoint.dy - mapCamera.pixelOrigin.dy);
    offsetPosition = Offset(offset.dx - right, offset.dy - bottom);
  }

  bool _start(Offset localPosition) {
    if (widget.marker.disableDrag) { return false; }
    _isDragging = true;
    _dragPosStart = _offsetToCrs(localPosition);
    _markerPointStart = LatLng(markerPoint.latitude, markerPoint.longitude);
    return true;
  }

  void _onPanStart(DragStartDetails details) {
    if (_start(details.localPosition)) {
      widget.marker.onDragStart?.call(details, markerPoint);
    }
  }

  void _onLongPanStart(LongPressStartDetails details) {
    if (_start(details.localPosition)) {
      widget.marker.onLongDragStart?.call(details, markerPoint);
    }
  }

  void _pan(Offset localPosition) {
    if (!_isDragging) { return; }
    final dragPos = _offsetToCrs(localPosition);

    final deltaLat = dragPos.latitude - _dragPosStart.latitude;
    final deltaLon = dragPos.longitude - _dragPosStart.longitude;

    // If we're near an edge, move the map to compensate
    if (widget.marker.scrollMapNearEdge) {
      final scrollOffset = _getMapScrollOffset();
      // start the scroll timer if scrollOffset is not zero
      if (scrollOffset != Offset.zero) {
        _mapScrollTimer ??= Timer.periodic(
          const Duration(milliseconds: 20),
          _mapScrollTimerCallback,
        );
      }
    }

    setState(() {
      widget.marker.point = LatLng(
        _markerPointStart.latitude + deltaLat,
        _markerPointStart.longitude + deltaLon,
      );
      _updatePixelPos(markerPoint);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _pan(details.localPosition);
    widget.marker.onDragUpdate?.call(details, markerPoint);
  }

  void _onLongPanUpdate(LongPressMoveUpdateDetails details) {
    _pan(details.localPosition);
    widget.marker.onLongDragUpdate?.call(details, markerPoint);
  }

  void _onPanEnd(details) {
    _end();
    widget.marker.onDragEnd?.call(details, markerPoint);
  }

  void _onLongPanEnd(details) {
    _end();
    widget.marker.onLongDragEnd?.call(details, markerPoint);
  }

  void _end() {
    // setState is needed if using a different widget while dragging
    setState(() {
      _isDragging = false;
    });
  }

  /// If dragging near edge of the screen, adjust the map so we keep dragging
  void _mapScrollTimerCallback(Timer timer) {
    final mapState = widget.mapCamera;
    final scrollOffset = _getMapScrollOffset();

    // cancel conditions
    if (!_isDragging ||
        timer != _mapScrollTimer ||
        scrollOffset == Offset.zero ||
        !widget.marker.inMapBounds(
          mapCamera: mapState,
          markerWidgetAlignment: widget.alignment,
        )) {
      timer.cancel();
      _mapScrollTimer = null;
      return;
    }

    // update marker position
    final oldMarkerPoint = mapState.projectAtZoom(markerPoint);
    widget.marker.point = mapState.unprojectAtZoom(Offset(
      oldMarkerPoint.dx + scrollOffset.dx,
      oldMarkerPoint.dy + scrollOffset.dy,
    ));

    // scroll map
    final oldMapPos = mapState.projectAtZoom(mapState.center);
    final newMapLatLng = mapState.unprojectAtZoom(Offset(
      oldMapPos.dx + scrollOffset.dx,
      oldMapPos.dy + scrollOffset.dy,
    ));
    widget.mapController.move(newMapLatLng, mapState.zoom);
  }

  /// this method is used for [marker.scrollMapNearEdge]. It checks if the
  /// marker is near an edge and returns the offset that the map should get
  /// scrolled.
  Offset _getMapScrollOffset() {
    final marker = widget.marker;
    final mapState = widget.mapCamera;

    final pixelB = widget.mapCamera.pixelBounds;
    final pixelPoint = mapState.projectAtZoom(markerPoint);
    // How much we'll move the map by to compensate
    var scrollMapX = 0.0;
    if (pixelPoint.dx + marker.size.width * marker.scrollNearEdgeRatio >=
        pixelB.topRight.dx) {
      scrollMapX = marker.scrollNearEdgeSpeed;
    } else if (pixelPoint.dx - marker.size.width * marker.scrollNearEdgeRatio <=
        pixelB.bottomLeft.dx) {
      scrollMapX = -marker.scrollNearEdgeSpeed;
    }
    var scrollMapY = 0.0;
    if (pixelPoint.dy - marker.size.height * marker.scrollNearEdgeRatio <=
        pixelB.topRight.dy) {
      scrollMapY = -marker.scrollNearEdgeSpeed;
    } else if (pixelPoint.dy +
            marker.size.height * marker.scrollNearEdgeRatio >=
        pixelB.bottomLeft.dy) {
      scrollMapY = marker.scrollNearEdgeSpeed;
    }
    return Offset(scrollMapX, scrollMapY);
  }

  // This is distinct from mapCamera.offsetToCrs as that version will cause
  // this plugin to break on dragging a marker on a rotated map.
  LatLng _offsetToCrs(Offset offset) {
    // Get the widget's offset
    final renderObject = context.findRenderObject() as RenderBox;
    final width = renderObject.size.width;
    final height = renderObject.size.height;
    final mapState = widget.mapCamera;

    // convert the point to global coordinates
    final localPointCenterDistance =
        Offset((width / 2) - offset.dx, (height / 2) - offset.dy);
    final mapCenter = mapState.projectAtZoom(mapState.center);
    final point = mapCenter - localPointCenterDistance;
    return mapState.unprojectAtZoom(point);
  }
}
