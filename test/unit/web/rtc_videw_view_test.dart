@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:flutter_webrtc/src/web/rtc_video_renderer_impl.dart';
import 'package:flutter_webrtc/src/web/rtc_video_view_impl.dart';

import 'package:web/web.dart' as web;

class TrackingRenderer extends RTCVideoRenderer {
  bool get observed => hasListeners;
}

class CaptureView extends RTCVideoView {
  CaptureView(super.renderer, {super.key});

  @override
  RTCVideoViewState createState() => CaptureState();
}

class CaptureTrackingView extends RTCVideoView {
  CaptureTrackingView(super.renderer, {super.key});

  @override
  RTCVideoViewState createState() => CaptureTrackingState();
}

class CaptureTrackingState extends RTCVideoViewState {
  var captureCalls = 0;

  @override
  Future<bool> captureFrame() {
    captureCalls++;
    return super.captureFrame();
  }
}

class CaptureState extends RTCVideoViewState {
  Completer<ui.Image> pending = Completer<ui.Image>();

  @override
  Future<ui.Image> captureImage(web.HTMLVideoElement element) => pending.future;
}

void main() {
  testWidgets('HTML mode does not start captured-frame polling',
      (tester) async {
    if (!useHtmlElementView) return;
    final renderer = TrackingRenderer();
    await renderer.initialize();
    final key = GlobalKey<CaptureTrackingState>();

    await tester.pumpWidget(
      MaterialApp(home: CaptureTrackingView(renderer, key: key)),
    );

    expect(key.currentState!.captureCalls, 0);
    expect(key.currentState!.callbackID, isNull);
    await renderer.dispose();
  });

  testWidgets('HTML stream updates preserve element and srcObject identity',
      (tester) async {
    if (!useHtmlElementView) return;
    final renderer = TrackingRenderer();
    final firstBrowserStream = web.HTMLCanvasElement().captureStream();
    final secondBrowserStream = web.HTMLCanvasElement().captureStream();
    final firstTrack = firstBrowserStream.getVideoTracks().toDart.single;
    final secondTrack = secondBrowserStream.getVideoTracks().toDart.single;
    final firstStream = MediaStreamWeb(firstBrowserStream, 'local');
    final secondStream = MediaStreamWeb(secondBrowserStream, 'local');
    renderer.srcObject = firstStream;
    await renderer.initialize();

    final element = renderer.createElement();
    web.document.body!.append(element);
    final browserStream = element.srcObject as web.MediaStream;
    expect(browserStream.getVideoTracks().toDart.single.id, firstTrack.id);
    expect(element.isConnected, isTrue);

    renderer.srcObject = secondStream;
    await tester.pump();

    expect(renderer.findHtmlView(), same(element));
    expect(element.srcObject, same(browserStream));
    expect(browserStream.getVideoTracks().toDart.single.id, secondTrack.id);
    expect(element.isConnected, isTrue);
    expect(renderer.viewType, 'RTCVideoRenderer-${renderer.textureId}');
    await renderer.dispose();
    element.remove();
  });

  testWidgets('HTML renderer initialization and presentation are stable',
      (tester) async {
    if (!useHtmlElementView) return;
    final renderer = TrackingRenderer();
    await renderer.initialize();
    await renderer.initialize();
    final element = renderer.createElement();

    renderer.mirror = true;
    renderer.objectFit = 'cover';

    expect(renderer.createElement(), same(element));
    expect(element.style.transform, 'scaleX(-1)');
    expect(element.style.objectFit, 'cover');
    await renderer.dispose();
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

    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const Color(0xff000000), ui.BlendMode.src);
    final picture = recorder.endRecording();

    final image = await tester.runAsync(() => picture.toImage(1, 1));

    picture.dispose();
    state.pending.complete(image!);
    await pendingCapture;
    expect(image.debugDisposed, isTrue);
    await renderer.dispose();
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

  // TODO(wer-mathurin): should revisit after this bug is resolved, https://github.com/flutter/flutter/issues/66045.
  test('should complete succesfully', () async {
    var renderer = RTCVideoRenderer();
    await renderer.initialize();
    await renderer.dispose();
  });
}
