import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'sections.dart';

const sectionPalette = <Color>[
  Colors.blue,
  Colors.teal,
  Colors.purple,
  Colors.orange,
  Colors.pink,
  Colors.green,
  Colors.red,
  Colors.amber,
];

Color sectionPaletteColor(int index) =>
    sectionPalette[index % sectionPalette.length];

class SectionTimeline extends StatefulWidget {
  const SectionTimeline(
      {super.key,
      required this.sections,
      required this.duration,
      this.onSectionTap,
      this.onSplitAt,
      this.onCreateSectionInGap,
      this.onGapTapMs,
      this.onHoverProgress,
      this.onMergeSections,
      this.onAutoAssignSectionColors,
      this.onSectionResizeStart,
      this.onSectionResizeEnd,
      this.onSectionResizePreviewMs,
      this.onSectionResize,
      this.onSectionEdit,
      this.onSectionAdjust,
      this.onSectionDelete,
      this.onDebugLog,
      this.selectedSection});

  final List<SongSection> sections;
  final Duration duration;
  final ValueChanged<SongSection>? onSectionTap;
  final ValueChanged<int>? onSplitAt;
  final void Function(int startMs, int endMs)? onCreateSectionInGap;
  final ValueChanged<int>? onGapTapMs;
  final ValueChanged<double?>? onHoverProgress;
  final void Function(SongSection first, SongSection second)? onMergeSections;
  final Future<void> Function()? onAutoAssignSectionColors;
  final VoidCallback? onSectionResizeStart;
  final VoidCallback? onSectionResizeEnd;
  final ValueChanged<int?>? onSectionResizePreviewMs;
  final void Function(SongSection section, int startMs, int endMs)?
      onSectionResize;
  final ValueChanged<SongSection>? onSectionEdit;
  final ValueChanged<SongSection>? onSectionAdjust;
  final ValueChanged<SongSection>? onSectionDelete;
  final ValueChanged<String>? onDebugLog;
  final SongSection? selectedSection;

  @override
  State<SectionTimeline> createState() => _SectionTimelineState();
}

class _SectionTimelineState extends State<SectionTimeline> {
  SongSection? _mergeAnchor;
  DateTime? _lastResizeLogAt;
  _TimelineGap? _selectedGap;
  SongSection? _resizeAnchorSection;
  bool? _resizeAnchorIsStart;
  int? _resizeAnchorStartMs;
  int? _resizeAnchorEndMs;
  double _resizeAccumulatedDx = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.duration == Duration.zero) {
      return const SizedBox.shrink();
    }
    final sections = widget.sections;
    final duration = widget.duration;
    return SizedBox(
      height: 34,
      child: LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          cursor: SystemMouseCursors.precise,
          onExit: (_) => widget.onHoverProgress?.call(null),
          onHover: (event) {
            if (constraints.maxWidth <= 0) return;
            widget.onHoverProgress?.call(
              (event.localPosition.dx / constraints.maxWidth)
                  .clamp(0, 1)
                  .toDouble(),
            );
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest),
                  for (final gap in _gaps())
                    Positioned(
                      left: (gap.startMs /
                              duration.inMilliseconds *
                              constraints.maxWidth)
                          .clamp(0, constraints.maxWidth),
                      width: ((gap.endMs - gap.startMs) /
                              duration.inMilliseconds *
                              constraints.maxWidth)
                          .clamp(0, constraints.maxWidth),
                      top: 3,
                      bottom: 3,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) => _handleGapPointerDown(
                          gap,
                          event,
                          ((gap.endMs - gap.startMs) /
                                  duration.inMilliseconds *
                                  constraints.maxWidth)
                              .toDouble(),
                        ),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: widget.onCreateSectionInGap == null
                              ? null
                              : (_) {
                                  widget.onDebugLog?.call(
                                      'double-click create section from Extra ${_time(gap.startMs)}-${_time(gap.endMs)}');
                                  widget.onCreateSectionInGap!(
                                      gap.startMs, gap.endMs);
                                },
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                .withValues(
                                  alpha: _selectedGap == gap ? .8 : .68),
                              border: Border.all(
                                color: _selectedGap == gap
                                  ? Colors.white
                                  : Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: .35),
                                width: _selectedGap == gap ? 2 : 1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Text(
                                sections.isEmpty
                                    ? 'Drag to create section'
                                    : 'Extra',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color:
                                        Theme.of(context).colorScheme.outline),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (var index = 0; index < sections.length; index += 1)
                    _buildSectionBlock(
                      context: context,
                      section: sections[index],
                      color: sectionPaletteColor(sections[index].colorIndex),
                      width:
                          ((sections[index].endMs - sections[index].startMs) /
                                  duration.inMilliseconds *
                                  constraints.maxWidth)
                              .clamp(12, constraints.maxWidth)
                              .toDouble(),
                      left: (sections[index].startMs /
                              duration.inMilliseconds *
                              constraints.maxWidth)
                          .clamp(0, constraints.maxWidth)
                          .toDouble(),
                      timelineWidth: constraints.maxWidth,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _time(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    return '${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  Widget _buildSectionBlock({
    required BuildContext context,
    required SongSection section,
    required Color color,
    required double left,
    required double width,
    required double timelineWidth,
  }) {
    final selected = widget.selectedSection == section;
    final showLabel = width >= 42;
    final showHandles = widget.onSectionResize != null && width >= 5;
    const horizontalPadding = 4.0;
    return Positioned(
      left: left,
      width: width,
      top: 3,
      bottom: 3,
      child: Tooltip(
        message:
            '${section.label}: ${_time(section.startMs)} – ${_time(section.endMs)}',
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _handleSectionPointerDown(
            context,
            section,
            event,
            left,
            timelineWidth,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: widget.onSectionEdit == null
                ? null
                : (_) {
                    widget.onDebugLog
                        ?.call('double-click edit "${section.label}"');
                    widget.onSectionEdit!(section);
                  },
            child: Container(
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .72),
                border: Border.all(
                  color: selected ? Colors.white : color,
                  width: selected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (showLabel)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: horizontalPadding),
                        child: Text(
                          section.label,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  else
                    Center(
                      child: Container(
                        width: 3,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .9),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  if (showHandles) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _SectionResizeHandle(
                        cursor: SystemMouseCursors.resizeColumn,
                        onDragStart: () =>
                            _startResizeGesture(section, resizeStart: true),
                        onDragEnd: _endResizeGesture,
                        onDrag: (delta) => _resize(
                          section,
                          delta,
                          timelineWidth,
                          resizeStart: true,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _SectionResizeHandle(
                        cursor: SystemMouseCursors.resizeColumn,
                        onDragStart: () =>
                            _startResizeGesture(section, resizeStart: false),
                        onDragEnd: _endResizeGesture,
                        onDrag: (delta) => _resize(
                          section,
                          delta,
                          timelineWidth,
                          resizeStart: false,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _hitsSection(int milliseconds) => widget.sections.any((section) =>
      milliseconds >= section.startMs && milliseconds <= section.endMs);

  void _handleSectionPointerDown(
    BuildContext context,
    SongSection section,
    PointerDownEvent event,
    double left,
    double timelineWidth,
  ) {
    widget.onDebugLog?.call(
      'pointer down "${section.label}" buttons=${event.buttons} '
      'localX=${event.localPosition.dx.toStringAsFixed(1)}',
    );
    if ((event.buttons & kSecondaryMouseButton) != 0) {
      widget.onDebugLog?.call('right-click menu "${section.label}"');
      _showSectionMenu(context, event.position, section: section);
      return;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final isShift = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    if (isCtrl && widget.onSplitAt != null && timelineWidth > 0) {
      final absoluteDx = (left + event.localPosition.dx).clamp(0, timelineWidth);
      final clickedMs =
        (absoluteDx / timelineWidth * widget.duration.inMilliseconds).round();
      widget.onDebugLog?.call('ctrl-click split "${section.label}" at '
          '${_time(clickedMs)}');
      widget.onSplitAt!(clickedMs);
      return;
    }
    if (isShift && widget.onMergeSections != null) {
      final anchor = _mergeAnchor;
      if (anchor != null && _areAdjacent(anchor, section)) {
        widget.onDebugLog
            ?.call('shift-click merge "${anchor.label}" + "${section.label}"');
        widget.onMergeSections!(anchor, section);
        setState(() => _mergeAnchor = null);
      } else {
        widget.onDebugLog
            ?.call('shift-click selected merge anchor "${section.label}"');
        setState(() => _mergeAnchor = section);
        widget.onSectionTap?.call(section);
      }
      return;
    }
    setState(() {
      _mergeAnchor = null;
      _selectedGap = null;
    });
    widget.onSectionTap?.call(section);
  }

  void _handleGapPointerDown(
    _TimelineGap gap,
    PointerDownEvent event,
    double width,
  ) {
    setState(() {
      _mergeAnchor = null;
      _selectedGap = gap;
    });
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final clickedMs = width <= 0
        ? gap.startMs
        : (gap.startMs +
                ((event.localPosition.dx / width).clamp(0, 1) *
                    (gap.endMs - gap.startMs)))
            .round();
    if (!isCtrl) {
      widget.onGapTapMs?.call(clickedMs);
    }
    if (isCtrl && widget.onSplitAt != null && width > 0) {
      widget.onDebugLog?.call(
          'ctrl-click split Extra at ${_time(clickedMs)} (${_time(gap.startMs)}-${_time(gap.endMs)})');
      widget.onSplitAt!(clickedMs);
    }
  }

  bool _areAdjacent(SongSection left, SongSection right) {
    final sorted = widget.sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final leftIndex = sorted.indexOf(left);
    final rightIndex = sorted.indexOf(right);
    return leftIndex != -1 &&
        rightIndex != -1 &&
        (leftIndex - rightIndex).abs() == 1;
  }

  int _millisecondsFor(double dx, BoxConstraints constraints) =>
      (widget.duration.inMilliseconds *
              (dx / constraints.maxWidth).clamp(0, 1).toDouble())
          .round();

  List<_TimelineGap> _gaps() {
    final sorted = widget.sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final gaps = <_TimelineGap>[];
    var cursor = 0;
    for (final section in sorted) {
      if (section.startMs > cursor) {
        gaps.add(_TimelineGap(cursor, section.startMs));
      }
      if (section.endMs > cursor) cursor = section.endMs;
    }
    final end = widget.duration.inMilliseconds;
    if (cursor < end) gaps.add(_TimelineGap(cursor, end));
    return gaps.where((gap) => gap.endMs - gap.startMs >= 250).toList();
  }

  _TimelineGap? _gapFor(int milliseconds) {
    for (final gap in _gaps()) {
      if (milliseconds >= gap.startMs && milliseconds <= gap.endMs) return gap;
    }
    return null;
  }

  Future<void> _showSectionMenu(
    BuildContext context,
    Offset globalPosition, {
    required SongSection section,
  }) async {
    final action = await showMenu<_SectionTimelineAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: _SectionTimelineAction.edit,
          child: Row(
            children: [
              Icon(Icons.edit_note_outlined),
              SizedBox(width: 8),
              Text('Rename / edit section'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _SectionTimelineAction.adjust,
          child: Row(
            children: [
              Icon(Icons.tune_outlined),
              SizedBox(width: 8),
              Text('Adjust section…'),
            ],
          ),
        ),
        if (widget.onAutoAssignSectionColors != null)
          PopupMenuItem(
            value: _SectionTimelineAction.autoAssignColors,
            child: Row(
              children: [
                Icon(Icons.palette_outlined),
                SizedBox(width: 8),
                Text('Auto assign colors'),
              ],
            ),
          ),
        PopupMenuItem(
          value: _SectionTimelineAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 8),
              Text('Delete section'),
            ],
          ),
        ),
      ],
    );
    switch (action) {
      case _SectionTimelineAction.edit:
        widget.onSectionEdit?.call(section);
      case _SectionTimelineAction.adjust:
        widget.onSectionAdjust?.call(section);
      case _SectionTimelineAction.autoAssignColors:
        await widget.onAutoAssignSectionColors?.call();
      case _SectionTimelineAction.delete:
        widget.onSectionDelete?.call(section);
      case null:
    }
  }

  void _resize(SongSection section, double deltaDx, double width,
      {required bool resizeStart}) {
    if (widget.onSectionResize == null || width <= 0) return;
    _ensureResizeAnchor(section, resizeStart: resizeStart);
    _resizeAccumulatedDx += deltaDx;
    final anchorStart = _resizeAnchorStartMs ?? section.startMs;
    final anchorEnd = _resizeAnchorEndMs ?? section.endMs;
    final deltaMs =
        (_resizeAccumulatedDx / width * widget.duration.inMilliseconds).round();
    final startMs = resizeStart
        ? (anchorStart + deltaMs).clamp(0, anchorEnd - 250).toInt()
        : anchorStart;
    final endMs = resizeStart
        ? anchorEnd
        : (anchorEnd + deltaMs)
            .clamp(anchorStart + 250, widget.duration.inMilliseconds)
            .toInt();
    if (_shouldLogResize()) {
      widget.onDebugLog?.call(
        '${resizeStart ? 'left' : 'right'} drag "${section.label}" '
        'delta=${_resizeAccumulatedDx.toStringAsFixed(1)}px -> ${_time(startMs)}-${_time(endMs)}',
      );
    }
    widget.onSectionResizePreviewMs?.call(resizeStart ? startMs : endMs);
    widget.onSectionResize!(section, startMs, endMs);
  }

  void _startResizeGesture(SongSection section, {required bool resizeStart}) {
    widget.onSectionResizeStart?.call();
    _resizeAnchorSection = section;
    _resizeAnchorIsStart = resizeStart;
    _resizeAnchorStartMs = section.startMs;
    _resizeAnchorEndMs = section.endMs;
    _resizeAccumulatedDx = 0;
    widget.onSectionResizePreviewMs
      ?.call(resizeStart ? section.startMs : section.endMs);
  }

  void _ensureResizeAnchor(SongSection section, {required bool resizeStart}) {
    if (_resizeAnchorSection == section && _resizeAnchorIsStart == resizeStart) {
      return;
    }
    _startResizeGesture(section, resizeStart: resizeStart);
  }

  void _endResizeGesture() {
    widget.onSectionResizeEnd?.call();
    widget.onSectionResizePreviewMs?.call(null);
    _resizeAnchorSection = null;
    _resizeAnchorIsStart = null;
    _resizeAnchorStartMs = null;
    _resizeAnchorEndMs = null;
    _resizeAccumulatedDx = 0;
  }

  bool _shouldLogResize() {
    final now = DateTime.now();
    final last = _lastResizeLogAt;
    if (last != null && now.difference(last).inMilliseconds < 250) {
      return false;
    }
    _lastResizeLogAt = now;
    return true;
  }
}

enum _SectionTimelineAction { edit, adjust, autoAssignColors, delete }

class _TimelineGap {
  const _TimelineGap(this.startMs, this.endMs);

  final int startMs;
  final int endMs;
}

class _SectionResizeHandle extends StatefulWidget {
  const _SectionResizeHandle({
    required this.cursor,
    required this.onDrag,
    this.onDragStart,
    this.onDragEnd,
  });

  final MouseCursor cursor;
  final ValueChanged<double> onDrag;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  @override
  State<_SectionResizeHandle> createState() => _SectionResizeHandleState();
}

class _SectionResizeHandleState extends State<_SectionResizeHandle> {
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => widget.onDragStart?.call(),
          onHorizontalDragUpdate: (details) {
            widget.onDrag(details.delta.dx);
          },
          onHorizontalDragEnd: (_) => widget.onDragEnd?.call(),
          onHorizontalDragCancel: () => widget.onDragEnd?.call(),
          child: Container(width: 5),
        ),
      );
}

class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.peaks,
    required this.progress,
    required this.onSeekProgress,
    required this.onHoverProgress,
    this.rangeStartProgress,
    this.hoverProgress,
    this.hoverTimeLabel,
    this.dragProgress,
    this.dragTimeLabel,
    this.highlightStartProgress,
    this.highlightEndProgress,
  });

  final List<double> peaks;
  final double progress;
  final ValueChanged<double> onSeekProgress;
  final ValueChanged<double?> onHoverProgress;
  final double? rangeStartProgress;
  final double? hoverProgress;
  final String? hoverTimeLabel;
  final double? dragProgress;
  final String? dragTimeLabel;
  final double? highlightStartProgress;
  final double? highlightEndProgress;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => Semantics(
          label: 'Audio waveform. Click to seek.',
          button: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onExit: (_) => onHoverProgress(null),
            onHover: (event) {
              if (constraints.maxWidth > 0) {
                onHoverProgress((event.localPosition.dx / constraints.maxWidth)
                    .clamp(0, 1)
                    .toDouble());
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                if (constraints.maxWidth > 0) {
                  onSeekProgress(
                      (details.localPosition.dx / constraints.maxWidth)
                          .clamp(0, 1)
                          .toDouble());
                }
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CustomPaint(
                    painter: _WaveformPainter(
                      peaks: peaks,
                      progress: progress.clamp(0, 1).toDouble(),
                      rangeStartProgress: rangeStartProgress,
                      hoverProgress: hoverProgress,
                      dragProgress: dragProgress,
                      highlightStartProgress: highlightStartProgress,
                      highlightEndProgress: highlightEndProgress,
                      playedColor: Theme.of(context).colorScheme.primary,
                      unplayedColor:
                          Theme.of(context).colorScheme.outlineVariant,
                      playheadColor: Theme.of(context).colorScheme.secondary,
                    ),
                    child: const SizedBox(height: 100, width: double.infinity),
                  ),
                  if ((dragProgress != null && dragTimeLabel != null) ||
                      (hoverProgress != null && hoverTimeLabel != null))
                    Positioned(
                      left: (((dragProgress ?? hoverProgress!) *
                                  (constraints.maxWidth - 50))
                              .clamp(0, constraints.maxWidth - 50))
                          .toDouble(),
                      top: 4,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: dragProgress == null
                                  ? Colors.black87
                                  : Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(3)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            child: Text(dragTimeLabel ?? hoverTimeLabel!,
                                style: const TextStyle(fontSize: 11)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.rangeStartProgress,
    required this.hoverProgress,
    required this.dragProgress,
    required this.highlightStartProgress,
    required this.highlightEndProgress,
    required this.playedColor,
    required this.unplayedColor,
    required this.playheadColor,
  });

  final List<double> peaks;
  final double progress;
  final double? rangeStartProgress;
  final double? hoverProgress;
  final double? dragProgress;
  final double? highlightStartProgress;
  final double? highlightEndProgress;
  final Color playedColor;
  final Color unplayedColor;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final center = size.height / 2;
    if (highlightStartProgress case final start?) {
      final end = (highlightEndProgress ?? start).clamp(start, 1);
      final left = size.width * start.clamp(0, 1);
      final width = (size.width * end) - left;
      canvas.drawRect(Rect.fromLTWH(left - 1, 0, width + 2, size.height),
          Paint()..color = Colors.amber.withValues(alpha: .28));
    }
    final played = Paint()
      ..color = playedColor
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final unplayed = Paint()
      ..color = unplayedColor
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < peaks.length; index += 1) {
      final x = index * size.width / (peaks.length - 1).clamp(1, peaks.length);
      // The viewport is exactly 100 px high, so peak-to-peak height tops out
      // at exactly 75 px (37.5 px above and below the centre line).
      final height =
          peaks[index].clamp(0.025, 1).toDouble() * (size.height * .375);
      canvas.drawLine(Offset(x, center - height), Offset(x, center + height),
          x / size.width <= progress ? played : unplayed);
    }
    if (rangeStartProgress case final start?) {
      final markerX = size.width * start.clamp(0, 1);
      canvas.drawLine(
          Offset(markerX, 2),
          Offset(markerX, size.height - 2),
          Paint()
            ..color = Colors.amber
            ..strokeWidth = 2);
    }
    if (hoverProgress case final hover?) {
      final hoverX = size.width * hover.clamp(0, 1);
      canvas.drawLine(
          Offset(hoverX, 0),
          Offset(hoverX, size.height),
          Paint()
            ..color = Colors.white70
            ..strokeWidth = 1);
    }
    if (dragProgress case final drag?) {
      final dragX = size.width * drag.clamp(0, 1);
      canvas.drawRect(
          Rect.fromLTWH(dragX - 1.5, 0, 3, size.height),
          Paint()..color = Colors.amber.withValues(alpha: .95));
    }
    final playheadX = size.width * progress;
    canvas.drawLine(
        Offset(playheadX, 4),
        Offset(playheadX, size.height - 4),
        Paint()
          ..color = playheadColor
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.peaks != peaks ||
      oldDelegate.progress != progress ||
      oldDelegate.rangeStartProgress != rangeStartProgress ||
      oldDelegate.hoverProgress != hoverProgress ||
      oldDelegate.dragProgress != dragProgress ||
      oldDelegate.highlightStartProgress != highlightStartProgress ||
      oldDelegate.highlightEndProgress != highlightEndProgress ||
      oldDelegate.playedColor != playedColor ||
      oldDelegate.unplayedColor != unplayedColor;
}
