import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;
import 'package:webrtc_interface/webrtc_interface.dart';

import 'rtc_video_renderer_impl.dart';

class RTCVideoView extends StatefulWidget {
  RTCVideoView(
    this._renderer, {
    super.key,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.mirror = false,
    this.filterQuality = FilterQuality.low,
    this.placeholderBuilder,
  });

  final RTCVideoRenderer _renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final FilterQuality filterQuality;
  final WidgetBuilder? placeholderBuilder;

  @override
  RTCVideoViewState createState() => RTCVideoViewState();
}

class RTCVideoViewState extends State<RTCVideoView> {
  RTCVideoViewState();

  RTCVideoRenderer get videoRenderer => widget._renderer;

  @override
  void initState() {
    super.initState();
    videoRenderer.addListener(_onRendererListener);
    videoRenderer.mirror = widget.mirror;
    videoRenderer.objectFit =
        widget.objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
            ? 'contain'
            : 'cover';

    if (!useHtmlElementView) {
      videoElement = videoRenderer.findHtmlView();
      frameCallback(0.toJS, 0.toJS);
    }
  }

  void _onRendererListener() {
    if (mounted) setState(() {});
  }

  int? callbackID;

  void getFrame(web.HTMLVideoElement element) {
    callbackID =
        element.requestVideoFrameCallbackWithFallback(frameCallback.toJS);
  }

  void cancelFrame(web.HTMLVideoElement element) {
    if (callbackID != null) {
      element.cancelVideoFrameCallbackWithFallback(callbackID!);
    }
  }

  void frameCallback(JSAny now, JSAny metadata) {
    if (_disposed || useHtmlElementView) return;
    final element = videoElement;
    if (element == null) {
      if (mounted) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && !_disposed) frameCallback(0.toJS, 0.toJS);
        });
      }
      return;
    }

    if (element.readyState > 2) {
      captureFrame().then((_) {
        if (!_disposed) getFrame(element);
      });
    } else {
      getFrame(element);
    }
  }

  bool _disposed = false;
  ui.Image? capturedFrame;
  num? lastFrameTime;

  @visibleForTesting
  Future<ui.Image> captureImage(web.HTMLVideoElement element) async {
    return await ui_web.createImageFromTextureSource(element,
        width: element.videoWidth,
        height: element.videoHeight,
        transferOwnership: true);
  }

  @visibleForTesting
  Future<bool> captureFrame() async {
    if (useHtmlElementView || videoElement == null) return false;
    final element = videoElement!;
    if (lastFrameTime == element.currentTime) return false;
    lastFrameTime = element.currentTime;
    try {
      final image = await captureImage(element);
      if (!mounted || _disposed) {
        image.dispose();
        return false;
      }
      final previous = capturedFrame;
      setState(() => capturedFrame = image);
      previous?.dispose();
      return true;
    } on web.DOMException catch (err) {
      lastFrameTime = null;
      if (err.name == 'InvalidStateError') return false;
      rethrow;
    } catch (_) {
      lastFrameTime = null;
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    videoRenderer.removeListener(_onRendererListener);
    if (!useHtmlElementView && videoElement != null) {
      cancelFrame(videoElement!);
    }
    capturedFrame?.dispose();
    capturedFrame = null;
    super.dispose();
  }

  Size? size;

  void updateElement() {
    if (videoElement != null && size != null) {
      videoElement!.width = size!.width.toInt();
      videoElement!.height = size!.height.toInt();
    }
  }

  @override
  void didUpdateWidget(RTCVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget._renderer != widget._renderer) {
      oldWidget._renderer.removeListener(_onRendererListener);
      videoRenderer.addListener(_onRendererListener);
      if (!useHtmlElementView) videoElement = videoRenderer.findHtmlView();
    }
    videoRenderer.mirror = widget.mirror;
    videoRenderer.objectFit =
        widget.objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
            ? 'contain'
            : 'cover';
  }

  web.HTMLVideoElement? videoElement;

  Widget buildVideoElementView() {
    if (useHtmlElementView) {
      return HtmlElementView(viewType: videoRenderer.viewType);
    } else {
      return LayoutBuilder(builder: (context, constraints) {
        if (videoElement != null && size != constraints.biggest) {
          size = constraints.biggest;
          updateElement();
        }

        return Stack(children: [
          if (capturedFrame != null)
            Positioned.fill(
                child: FittedBox(
                    fit: switch (widget.objectFit) {
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain =>
                        BoxFit.contain,
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover =>
                        BoxFit.cover,
                    },
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                        width: capturedFrame!.width.toDouble(),
                        height: capturedFrame!.height.toDouble(),
                        child: CustomPaint(
                            willChange: true,
                            painter: VideoFramePainter(
                              capturedFrame!,
                              widget.mirror,
                              widget.filterQuality,
                            )))))
        ]);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Center(
          child: Container(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: widget._renderer.renderVideo
                ? buildVideoElementView()
                : widget.placeholderBuilder?.call(context) ?? Container(),
          ),
        );
      },
    );
  }
}

typedef _VideoFrameRequestCallback = JSFunction;

extension _HTMLVideoElementRequestAnimationFrame on web.HTMLVideoElement {
  int requestVideoFrameCallbackWithFallback(
      _VideoFrameRequestCallback callback) {
    if (hasProperty('requestVideoFrameCallback'.toJS).toDart) {
      return requestVideoFrameCallback(callback);
    } else {
      return web.window.requestAnimationFrame((double num) {
        callback.callAsFunction(this, 0.toJS, 0.toJS);
      }.toJS);
    }
  }

  void cancelVideoFrameCallbackWithFallback(int callbackID) {
    if (hasProperty('requestVideoFrameCallback'.toJS).toDart) {
      cancelVideoFrameCallback(callbackID);
    } else {
      web.window.cancelAnimationFrame(callbackID);
    }
  }

  external int requestVideoFrameCallback(_VideoFrameRequestCallback callback);
  external void cancelVideoFrameCallback(int callbackID);
}

@visibleForTesting
class VideoFramePainter extends CustomPainter {
  VideoFramePainter(this.image, this.flip, this.filterQuality);

  final ui.Image image;
  final bool flip;
  final ui.FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    if (flip) {
      canvas.scale(-1, 1);
    }
    canvas.drawImage(image, Offset(flip ? -size.width : 0, 0),
        Paint()..filterQuality = filterQuality);
  }

  @override
  bool shouldRepaint(covariant VideoFramePainter oldDelegate) =>
      image != oldDelegate.image ||
      flip != oldDelegate.flip ||
      filterQuality != oldDelegate.filterQuality;
}
