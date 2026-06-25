import 'package:flutter/material.dart';

import 'sections.dart';

class SectionTimeline extends StatelessWidget {
  const SectionTimeline(
      {super.key,
      required this.sections,
      required this.duration,
      this.onSectionTap,
      this.onEmptyTapProgress,
      this.onSectionResize,
      this.selectedSection});

  final List<SongSection> sections;
  final Duration duration;
  final ValueChanged<SongSection>? onSectionTap;
  final ValueChanged<double>? onEmptyTapProgress;
  final void Function(SongSection section, int startMs, int endMs)?
      onSectionResize;
  final SongSection? selectedSection;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) {
      return const SizedBox.shrink();
    }
    final colors = <Color>[
      Colors.blue,
      Colors.teal,
      Colors.deepPurple,
      Colors.orange,
      Colors.pink,
      Colors.green
    ];
    return SizedBox(
      height: 30,
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onEmptyTapProgress == null
              ? null
              : (details) => onEmptyTapProgress!(
                  (details.localPosition.dx / constraints.maxWidth)
                      .clamp(0, 1)
                      .toDouble()),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest),
                if (sections.isEmpty)
                  const Center(
                    child: Text('Click here to add song sections',
                        style: TextStyle(fontSize: 12)),
                  ),
                for (var index = 0; index < sections.length; index += 1)
                  Positioned(
                    left: (sections[index].startMs /
                            duration.inMilliseconds *
                            constraints.maxWidth)
                        .clamp(0, constraints.maxWidth),
                    width: ((sections[index].endMs - sections[index].startMs) /
                            duration.inMilliseconds *
                            constraints.maxWidth)
                        .clamp(12, constraints.maxWidth),
                    top: 3,
                    bottom: 3,
                    child: Tooltip(
                      message:
                          '${sections[index].label}: ${_time(sections[index].startMs)} – ${_time(sections[index].endMs)}',
                      child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onSectionTap == null
                              ? null
                              : () => onSectionTap!(sections[index]),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: colors[index % colors.length]
                                  .withValues(alpha: .72),
                              border: Border.all(
                                  color: selectedSection == sections[index]
                                      ? Colors.white
                                      : colors[index % colors.length],
                                  width: selectedSection == sections[index]
                                      ? 2
                                      : 1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(sections[index].label,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ),
                                if (onSectionResize != null) ...[
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: _SectionResizeHandle(
                                      cursor: SystemMouseCursors.resizeColumn,
                                      onDrag: (delta) => _resize(
                                          sections[index],
                                          delta,
                                          constraints.maxWidth,
                                          resizeStart: true),
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: _SectionResizeHandle(
                                      cursor: SystemMouseCursors.resizeColumn,
                                      onDrag: (delta) => _resize(
                                          sections[index],
                                          delta,
                                          constraints.maxWidth,
                                          resizeStart: false),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )),
                    ),
                  ),
              ],
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

  void _resize(SongSection section, double deltaDx, double width,
      {required bool resizeStart}) {
    if (onSectionResize == null || width <= 0) return;
    final deltaMs = (deltaDx / width * duration.inMilliseconds).round();
    final startMs = resizeStart
        ? (section.startMs + deltaMs).clamp(0, section.endMs - 250).toInt()
        : section.startMs;
    final endMs = resizeStart
        ? section.endMs
        : (section.endMs + deltaMs)
            .clamp(section.startMs + 250, duration.inMilliseconds)
            .toInt();
    onSectionResize!(section, startMs, endMs);
  }
}

class _SectionResizeHandle extends StatelessWidget {
  const _SectionResizeHandle({required this.cursor, required this.onDrag});

  final MouseCursor cursor;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
          child: Container(
            width: 10,
            alignment: Alignment.center,
            child: Container(
              width: 2,
              height: 18,
              color: Colors.white.withValues(alpha: .8),
            ),
          ),
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
                      highlightStartProgress: highlightStartProgress,
                      highlightEndProgress: highlightEndProgress,
                      playedColor: Theme.of(context).colorScheme.primary,
                      unplayedColor:
                          Theme.of(context).colorScheme.outlineVariant,
                      playheadColor: Theme.of(context).colorScheme.secondary,
                    ),
                    child: const SizedBox(height: 100, width: double.infinity),
                  ),
                  if (hoverProgress != null && hoverTimeLabel != null)
                    Positioned(
                      left: (hoverProgress! * (constraints.maxWidth - 50))
                          .clamp(0, constraints.maxWidth - 50),
                      top: 4,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(3)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            child: Text(hoverTimeLabel!,
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
      oldDelegate.highlightStartProgress != highlightStartProgress ||
      oldDelegate.highlightEndProgress != highlightEndProgress ||
      oldDelegate.playedColor != playedColor ||
      oldDelegate.unplayedColor != unplayedColor;
}
