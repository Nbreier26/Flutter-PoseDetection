import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PoseDetectorApp());
}

class PoseDetectorApp extends StatelessWidget {
  const PoseDetectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());
  List<Pose> _poses = [];
  bool _isProcessing = false;
  bool _isCameraReady = false;
  Size _previewSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    await Permission.camera.request();
    final cameras = await availableCameras();
    _controller = CameraController(
      cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back),
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    if (!mounted) return;

    _previewSize = _controller!.value.previewSize!;
    _controller!.startImageStream(_processImageStream);
    setState(() => _isCameraReady = true);
  }

  Future<void> _processImageStream(CameraImage image) async {
    if (_isProcessing || !mounted) return;
    _isProcessing = true;

    try {
      final inputImage = _convertToInputImage(image);
      if (inputImage == null) return;

      final poses = await _poseDetector.processImage(inputImage);
      if (mounted) setState(() => _poses = poses);
    } catch (e) {
      print('Processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _convertToInputImage(CameraImage image) {
    try {
      final yPlane = image.planes[0].bytes;
      final uvPlane = image.planes[1].bytes;
      final vuPlane = image.planes[2].bytes;

      final nv21Buffer =
          Uint8List(yPlane.length + uvPlane.length + vuPlane.length);
      nv21Buffer.setRange(0, yPlane.length, yPlane);
      nv21Buffer.setRange(yPlane.length, yPlane.length + vuPlane.length, vuPlane);
      nv21Buffer.setRange(yPlane.length + vuPlane.length, nv21Buffer.length, uvPlane);

      return InputImage.fromBytes(
        bytes: nv21Buffer,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: _getRotation(),
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      print('Conversion error: $e');
      return null;
    }
  }

  InputImageRotation _getRotation() {
    final orientation = _controller?.description.sensorOrientation ?? 0;
    return InputImageRotationValue.fromRawValue(orientation) ??
        InputImageRotation.rotation0deg;
  }

  String _classifyPose() {
    if (_poses.isEmpty) return "Nenhuma pose detectada";

    final pose = _poses.first;
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];

    if (leftWrist != null &&
        rightWrist != null &&
        leftShoulder != null &&
        rightShoulder != null) {
      if (leftWrist.y < leftShoulder.y && rightWrist.y < rightShoulder.y) {
        return "Mãos para cima";
      } else {
        return "Pose normal";
      }
    }
    return "Pose detectada";
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraReady || _controller == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Detector de Pose em Tempo Real')),
      body: Stack(
        children: [
          _buildCameraPreview(),
          _buildPoseOverlay(),
          Positioned(
            top: 30,
            left: 16,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.black45,
              child: Text(
                _classifyPose(),
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

Widget _buildCameraPreview() {
  final screenSize = MediaQuery.of(context).size;
  final aspectRatio = _previewSize.width / _previewSize.height;

  // Usar AspectRatio para garantir que a imagem da câmera seja exibida corretamente
  return Container(
    width: screenSize.width,
    height: screenSize.height,
    child: AspectRatio(
      aspectRatio: aspectRatio,
      child: CameraPreview(_controller!),
    ),
  );
}

  Widget _buildPoseOverlay() {
    return CustomPaint(
      painter: PosePainter(
        poses: _poses,
        previewSize: _previewSize,
        screenSize: MediaQuery.of(context).size,
        rotation: _getRotationAngle(),
      ),
      child: Container(),
    );
  }

  double _getRotationAngle() {
    final orientation = _controller?.description.sensorOrientation ?? 0;
    if (orientation == 90) {
      return 0; // Rotação de 90 graus
    } else if (orientation == 270) {
      return 0; // Rotação de 270 graus
    }
    return 0; // Sem rotação
  }

}


class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size previewSize;
  final double rotation;
  final Size screenSize;

  PosePainter({
    required this.poses,
    required this.previewSize,
    required this.rotation,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Obter a matriz de transformação para ajustar os pontos conforme o tamanho da tela
    final matrix = _getTransformationMatrix();
    canvas.transform(matrix.storage);

    final pointPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 8
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    for (final pose in poses) {
      // Desenhar os pontos dos landmarks
      for (final landmark in pose.landmarks.values) {
        final offset = Offset(landmark.x, landmark.y);
        canvas.drawCircle(offset, 6, pointPaint);
      }
      // Desenhar conexões entre landmarks
      _drawConnection(pose, PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftHip, PoseLandmarkType.rightHip, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee, linePaint, canvas);
      _drawConnection(pose, PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle, linePaint, canvas);
    }
  }

  Matrix4 _getTransformationMatrix() {
    // Ajusta a escala e rotação para que os pontos fiquem alinhados com a imagem exibida
    final scaleX = screenSize.width / previewSize.height;
    final scaleY = screenSize.height / previewSize.width;

    return Matrix4.identity()
      ..translate((previewSize.height / 2) + 20, (previewSize.width / 2)-55)
      ..rotateZ(rotation)
      ..scale(scaleX, scaleY)
      ..translate(-(previewSize.width / 2), -previewSize.height / 2);
  }

  void _drawConnection(
    Pose pose,
    PoseLandmarkType type1,
    PoseLandmarkType type2,
    Paint paint,
    Canvas canvas,
  ) {
    final start = pose.landmarks[type1];
    final end = pose.landmarks[type2];
    if (start == null || end == null) return;

    final startOffset = Offset(start.x, start.y);
    final endOffset = Offset(end.x, end.y);
    canvas.drawLine(startOffset, endOffset, paint);
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.poses != poses;
  }
}
