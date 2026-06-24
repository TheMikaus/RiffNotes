import 'package:flutter/material.dart';

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
                onHoverProgress((event.localPosition.dx / constraints.maxWidth).clamp(0, 1).toDouble());
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                if (constraints.maxWidth > 0) {
                  onSeekProgress((details.localPosition.dx / constraints.maxWidth).clamp(0, 1).toDouble());
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
                      unplayedColor: Theme.of(context).colorScheme.outlineVariant,
                      playheadColor: Theme.of(context).colorScheme.secondary,
                    ),
                    child: const SizedBox(height: 100, width: double.infinity),
                  ),
                  if (hoverProgress != null && hoverTimeLabel != null)
                    Positioned(
                      left: (hoverProgress! * (constraints.maxWidth - 50)).clamp(0, constraints.maxWidth - 50),
                      top: 4,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(3)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            child: Text(hoverTimeLabel!, style: const TextStyle(fontSize: 11)),
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
      canvas.drawRect(Rect.fromLTWH(left - 1, 0, width + 2, size.height), Paint()..color = Colors.amber.withValues(alpha: .28));
    }
    final played = Paint()..color = playedColor..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    final unplayed = Paint()..color = unplayedColor..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    for (var index = 0; index < peaks.length; index += 1) {
      final x = index * size.width / (peaks.length - 1).clamp(1, peaks.length);
      // The viewport is exactly 100 px high, so peak-to-peak height tops out
      // at exactly 75 px (37.5 px above and below the centre line).
      final height = peaks[index].clamp(0.025, 1).toDouble() * (size.height * .375);
      canvas.drawLine(Offset(x, center - height), Offset(x, center + height), x / size.width <= progress ? played : unplayed);
    }
    if (rangeStartProgress case final start?) {
      final markerX = size.width * start.clamp(0, 1);
      canvas.drawLine(Offset(markerX, 2), Offset(markerX, size.height - 2), Paint()..color = Colors.amber..strokeWidth = 2);
    }
    if (hoverProgress case final hover?) {
      final hoverX = size.width * hover.clamp(0, 1);
      canvas.drawLine(Offset(hoverX, 0), Offset(hoverX, size.height), Paint()..color = Colors.white70..strokeWidth = 1);
    }
    final playheadX = size.width * progress;
    canvas.drawLine(Offset(playheadX, 4), Offset(playheadX, size.height - 4), Paint()..color = playheadColor..strokeWidth = 2);
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
