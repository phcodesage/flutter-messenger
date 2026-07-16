import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Full-screen avatar cropper: pan + pinch-zoom the image under a fixed
/// square viewport with a circular guide, then `Navigator.pop`s the cropped
/// 512x512 PNG bytes (or null on cancel). Pure Dart — no native crop deps.
class AvatarCropScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const AvatarCropScreen({super.key, required this.imageBytes});

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  ui.Image? _image;
  bool _decodeFailed = false;
  bool _exporting = false;

  // Transform state: image drawn at _offset, scaled by _scale, origin top-left.
  double _scale = 1;
  double _minScale = 1;
  Offset _offset = Offset.zero;
  double _viewport = 0;

  // Gesture bookkeeping
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromList(widget.imageBytes, (img) {
      if (!mounted) return;
      setState(() => _image = img);
    });
    // decodeImageFromList never calls back on failure in some engines, so
    // guard with a timeout that flips to an error state.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && _image == null) setState(() => _decodeFailed = true);
    });
  }

  void _initTransform(double viewport) {
    if (_viewport == viewport || _image == null) return;
    _viewport = viewport;
    final w = _image!.width.toDouble();
    final h = _image!.height.toDouble();
    _minScale = math.max(viewport / w, viewport / h); // cover
    _scale = _minScale;
    _offset = Offset(
      (viewport - w * _scale) / 2,
      (viewport - h * _scale) / 2,
    );
  }

  void _clampOffset() {
    if (_image == null) return;
    final w = _image!.width * _scale;
    final h = _image!.height * _scale;
    _offset = Offset(
      _offset.dx.clamp(math.min(_viewport - w, 0.0), 0.0).toDouble(),
      _offset.dy.clamp(math.min(_viewport - h, 0.0), 0.0).toDouble(),
    );
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final next =
        (_startScale * d.scale).clamp(_minScale, _minScale * 5).toDouble();
    // The image point under the initial focal must stay under the current
    // focal — this makes pinch-zoom-around-finger and pan one formula.
    final imagePoint = (_startFocal - _startOffset) / _startScale;
    setState(() {
      _scale = next;
      _offset = d.localFocalPoint - imagePoint * next;
      _clampOffset();
    });
  }

  void _setZoomSlider(double t) {
    final next = _minScale + t * (_minScale * 4);
    final center = Offset(_viewport / 2, _viewport / 2);
    final imagePoint = (center - _offset) / _scale;
    setState(() {
      _scale = next;
      _offset = center - imagePoint * next;
      _clampOffset();
    });
  }

  Future<void> _apply() async {
    if (_image == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      const out = 512;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final k = out / _viewport;
      canvas.scale(k);
      canvas.translate(_offset.dx, _offset.dy);
      canvas.scale(_scale);
      canvas.drawImage(
        _image!,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(out, out);
      final bytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.of(context).pop(bytes?.buffer.asUint8List());
    } catch (_) {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        foregroundColor: Colors.white,
        title: const Text('Crop your photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _decodeFailed
          ? const Center(
              child: Text(
                'Could not read that image',
                style: TextStyle(color: Colors.white70),
              ),
            )
          : _image == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final viewport = math.min(
                      math.min(constraints.maxWidth - 32,
                          constraints.maxHeight - 160),
                      360.0,
                    );
                    _initTransform(viewport);
                    final zoomT = _minScale > 0
                        ? ((_scale - _minScale) / (_minScale * 4))
                            .clamp(0.0, 1.0)
                        : 0.0;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: viewport,
                            height: viewport,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: _onScaleStart,
                              onScaleUpdate: _onScaleUpdate,
                              child: CustomPaint(
                                painter: _CropPainter(
                                  image: _image!,
                                  scale: _scale,
                                  offset: _offset,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: viewport,
                          child: Row(
                            children: [
                              const Icon(Icons.zoom_out,
                                  color: Colors.white54, size: 20),
                              Expanded(
                                child: Slider(
                                  value: zoomT.toDouble(),
                                  onChanged: _setZoomSlider,
                                  activeColor: const Color(0xFF0F766E),
                                ),
                              ),
                              const Icon(Icons.zoom_in,
                                  color: Colors.white54, size: 20),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: _exporting
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: Color(0xFF4B5563)),
                              ),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: _exporting ? null : _apply,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F766E),
                                foregroundColor: Colors.white,
                              ),
                              child: Text(_exporting ? 'Cropping…' : 'Apply'),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final Offset offset;

  _CropPainter({
    required this.image,
    required this.scale,
    required this.offset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    // Dim everything outside the circular guide.
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(1));
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      circle,
    );
    canvas.drawPath(outside, Paint()..color = const Color(0x8C111827));
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.scale != scale || old.offset != offset;
}
