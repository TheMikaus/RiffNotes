import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  const WaveformView({super.key, required this.peaks, required this.progress});

  final List<double> peaks;
  final double progress;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Audio waveform',
        child: CustomPaint(
          painter: _WaveformPainter(
            peaks: peaks,
            progress: progress.clamp(0, 1),
            playedColor: Theme.of(context).colorScheme.primary,
            unplayedColor: Theme.of(context).colorScheme.outlineVariant,
            playheadColor: Theme.of(context).colorScheme.secondary,
          ),
          child: const SizedBox(height: 100, width: double.infinity),
        ),
      );
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
    required this.playheadColor,
  });

  final List<double> peaks;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final center = size.height / 2;
    final played = Paint()..color = playedColor..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    final unplayed = Paint()..color = unplayedColor..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    for (var index = 0; index < peaks.length; index += 1) {
      final x = index * size.width / (peaks.length - 1).clamp(1, peaks.length);
      final height = (peaks[index].clamp(0.025, 1) * (size.height * .44));
      canvas.drawLine(Offset(x, center - height), Offset(x, center + height), x / size.width <= progress ? played : unplayed);
    }
    final playheadX = size.width * progress;
    canvas.drawLine(Offset(playheadX, 4), Offset(playheadX, size.height - 4), Paint()..color = playheadColor..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.peaks != peaks || oldDelegate.progress != progress || oldDelegate.playedColor != playedColor || oldDelegate.unplayedColor != unplayedColor;
}
