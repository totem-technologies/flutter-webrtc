@TestOn('browser')
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:flutter_webrtc/src/web/rtc_video_renderer_impl.dart';
import 'package:flutter_webrtc/src/web/rtc_video_view_impl.dart';

class TrackingRenderer extends RTCVideoRenderer {
  bool get observed => hasListeners;
}

class CaptureView extends RTCVideoView {
  CaptureView(super.renderer, {super.key});

  @override
  RTCVideoViewState createState() => CaptureState();
}

class CaptureState extends RTCVideoViewState {
  Completer<ui.Image> pending = Completer<ui.Image>();

  @override
  Future<ui.Image> captureImage(web.HTMLVideoElement element) => pending.future;
}

void main() {
  test('video is an autoplaying, non-interactive render surface', () async {
    final renderer = RTCVideoRenderer();
    final video = renderer.createElement();
    expect(video.autoplay, isTrue);
    expect(video.controls, isFalse);
    expect(video.hasAttribute('playsinline'), isTrue);
    expect(video.style.pointerEvents, 'none');
    expect(video.hasAttribute('disablepictureinpicture'), isTrue);
    expect(video.hasAttribute('disableremoteplayback'), isTrue);
    expect(video.getAttribute('controlsList'),
        'nodownload nofullscreen noremoteplayback');
    if (useHtmlElementView) {
      expect(video.style.userSelect, 'none');
      web.document.body!.append(video);
      renderer.mirror = true;
      renderer.objectFit = 'cover';
      expect(video.style.transform, 'scaleX(-1)');
      expect(video.style.objectFit, 'cover');
      renderer.mirror = false;
      renderer.objectFit = 'contain';
      expect(video.style.transform, '');
      expect(video.style.objectFit, 'contain');
    }
    await renderer.dispose();
    video.remove();
  });

  testWidgets('late texture image is released after unmount', (tester) async {
    if (useHtmlElementView) return;
    final renderer = TrackingRenderer();
    await renderer.initialize();
    final key = GlobalKey<CaptureState>();
    await tester.pumpWidget(MaterialApp(home: CaptureView(renderer, key: key)));
    final state = key.currentState!;
    final pendingCapture = state.captureFrame();
    await tester.pumpWidget(const SizedBox());
    expect(renderer.observed, isFalse);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff000000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(1, 1));
    picture.dispose();
    state.pending.complete(image!);
    await pendingCapture;
    expect(image.debugDisposed, isTrue);
    await renderer.dispose();
  });

  testWidgets('a new frame disposes the previously owned image',
      (tester) async {
    if (useHtmlElementView) return;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final key = GlobalKey<CaptureState>();
    await tester.pumpWidget(MaterialApp(home: CaptureView(renderer, key: key)));
    final state = key.currentState!;
    Future<ui.Image> image() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xff000000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final result = await tester.runAsync(() => picture.toImage(1, 1));
      picture.dispose();
      return result!;
    }

    final firstCapture = state.captureFrame();
    final first = await image();
    state.pending.complete(first);
    await firstCapture;
    state.lastFrameTime = null;
    state.pending = Completer<ui.Image>();
    final secondCapture = state.captureFrame();
    final second = await image();
    state.pending.complete(second);
    await secondCapture;
    expect(first.debugDisposed, isTrue);
    expect(state.capturedFrame, same(second));
    await tester.pumpWidget(const SizedBox());
    expect(second.debugDisposed, isTrue);
    await renderer.dispose();
  });

  testWidgets('unmount cancels a pending source video lookup', (tester) async {
    if (useHtmlElementView) return;
    final renderer = TrackingRenderer();
    final key = GlobalKey<RTCVideoViewState>();
    await tester
        .pumpWidget(MaterialApp(home: RTCVideoView(renderer, key: key)));
    final state = key.currentState!;
    expect(state.videoElement, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.videoElement, isNull);
    expect(state.callbackID, isNull);
    expect(renderer.observed, isFalse);
    await renderer.dispose();
  });

  testWidgets('renderer replacement releases an in-flight frame from A',
      (tester) async {
    if (useHtmlElementView) return;
    final first = RTCVideoRenderer();
    final second = RTCVideoRenderer();
    await first.initialize();
    await second.initialize();
    final key = GlobalKey<CaptureState>();
    await tester.pumpWidget(MaterialApp(home: CaptureView(first, key: key)));
    final state = key.currentState!;
    final capture = state.captureFrame();
    await tester.pumpWidget(MaterialApp(home: CaptureView(second, key: key)));
    expect(state.videoElement, same(second.findHtmlView()));
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff000000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(1, 1));
    picture.dispose();
    state.pending.complete(image!);
    await capture;
    expect(image.debugDisposed, isTrue);
    expect(state.capturedFrame, isNull);
    await tester.pumpWidget(const SizedBox());
    await first.dispose();
    await second.dispose();
  });

  testWidgets('failed frame capture can recover on the next frame',
      (tester) async {
    if (useHtmlElementView) return;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final key = GlobalKey<CaptureState>();
    await tester.pumpWidget(MaterialApp(home: CaptureView(renderer, key: key)));
    final state = key.currentState!;
    final failed = state.captureFrame();
    state.pending.completeError(Exception('temporary capture failure'));
    expect(await failed, isFalse);
    state.pending = Completer<ui.Image>();
    final recovered = state.captureFrame();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff000000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(1, 1));
    picture.dispose();
    state.pending.complete(image!);
    expect(await recovered, isTrue);
    expect(state.capturedFrame, same(image));
    await tester.pumpWidget(const SizedBox());
    expect(image.debugDisposed, isTrue);
    await renderer.dispose();
  });

  testWidgets('view transfers listeners and capture ownership on replacement',
      (tester) async {
    final first = TrackingRenderer();
    final second = TrackingRenderer();
    await first.initialize();
    await second.initialize();
    final key = GlobalKey<RTCVideoViewState>();
    Widget view(RTCVideoRenderer renderer) => MaterialApp(
          home: RTCVideoView(renderer,
              key: key,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        );
    await tester.pumpWidget(view(first));
    expect(first.observed, isTrue);
    if (useHtmlElementView) {
      expect(key.currentState!.videoElement, isNull);
      expect(key.currentState!.callbackID, isNull);
      await tester.pump(const Duration(milliseconds: 300));
      expect(key.currentState!.videoElement, isNull);
      expect(key.currentState!.callbackID, isNull);
    } else {
      expect(key.currentState!.videoElement, same(first.findHtmlView()));
    }
    await tester.pumpWidget(view(second));
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    if (!useHtmlElementView) {
      expect(key.currentState!.videoElement, same(second.findHtmlView()));
    }
    expect(second.mirror, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(second.observed, isFalse);
    await first.dispose();
    await second.dispose();
  });

  test('renderer can initialize and dispose without a media stream', () async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    await renderer.dispose();
  });
}
