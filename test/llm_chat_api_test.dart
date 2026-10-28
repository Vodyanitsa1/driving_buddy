import 'dart:async';
import 'dart:convert';

import 'package:driving_buddy/features/llm_chat/llm_chat.dart';
import 'package:driving_buddy/models/detection_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _okReply = {
  'reply': 'Wah, kamu mulai capek. Menepi dulu ya.',
  'session_id': 'uid-1',
  'provider': 'groq',
  'model': 'openai/gpt-oss-120b',
  'latency_ms': 412,
  'fallback': false,
  'error': null,
};

http.Response _json(Object body, int status, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

LlmChatApi _api(MockClientHandler handler, {Duration? timeout}) => LlmChatApi(
  config: LlmChatConfig(baseUrl: 'http://192.168.1.10:8000'),
  client: MockClient(handler),
  timeout: timeout ?? const Duration(seconds: 25),
);

void main() {
  group('LlmChatConfig.normalizeBaseUrl', () {
    test('menambah http dan membuang path /chat', () {
      expect(
        LlmChatConfig.normalizeBaseUrl('192.168.1.10:8000'),
        'http://192.168.1.10:8000',
      );
      expect(
        LlmChatConfig.normalizeBaseUrl(
          'http://192.168.1.10:8000/chat/health?deep=true',
        ),
        'http://192.168.1.10:8000',
      );
      expect(
        LlmChatConfig.normalizeBaseUrl(' https://buddy.example/api/ '),
        'https://buddy.example/api',
      );
    });

    test('menolak alamat tidak valid', () {
      expect(LlmChatConfig.normalizeBaseUrl(''), isNull);
      expect(LlmChatConfig.normalizeBaseUrl('ftp://x:21'), isNull);
      expect(LlmChatConfig.normalizeBaseUrl('http://'), isNull);
    });
  });

  group('LlmChatApi.send', () {
    test('mengirim JSON yang benar dan membaca balasan', () async {
      late http.Request sent;
      final api = _api((request) async {
        sent = request;
        return _json(_okReply, 200);
      });
      const detection = DetectionResult(
        status: DriverStatus.noFace,
        subStatus: '',
        ear: 0,
        mar: 0,
        blinkCount: 28,
        yawnCount: 3,
      );

      final reply = await api.send(
        sessionId: 'uid-1',
        message: '  Aku mulai ngantuk nih  ',
        driverState: LlmDriverState.fromDetection(detection, tripMinutes: 90),
      );

      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://192.168.1.10:8000/chat');
      expect(jsonDecode(sent.body), {
        'session_id': 'uid-1',
        'message': 'Aku mulai ngantuk nih',
        'driver_state': {
          'status': 'No Face',
          'yawnCount': 3,
          'blinkCount': 28,
          'tripMinutes': 90,
        },
      });
      expect(reply.reply, _okReply['reply']);
      expect(reply.provider, 'groq');
      expect(reply.latencyMs, 412);
      expect(reply.fallback, isFalse);
    });

    test('reset ikut terkirim kalau diminta', () async {
      late Map<String, dynamic> body;
      final api = _api((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_okReply, 200);
      });
      await api.send(sessionId: 'uid-1', message: 'halo', reset: true);
      expect(body['reset'], isTrue);
      expect(body.containsKey('driver_state'), isFalse);
    });

    test('balasan darurat dari server tetap dikembalikan', () async {
      final api = _api(
        (_) async =>
            _json({..._okReply, 'fallback': true, 'error': 'timeout'}, 200),
      );
      final reply = await api.send(sessionId: 'uid-1', message: 'halo');
      expect(reply.fallback, isTrue);
      expect(reply.error, 'timeout');
    });

    test(
      'pesan kosong / session_id aneh ditolak tanpa memanggil server',
      () async {
        var calls = 0;
        final api = _api((_) async {
          calls++;
          return _json(_okReply, 200);
        });
        expect(
          () => api.send(sessionId: 'uid-1', message: '   '),
          throwsA(
            isA<LlmChatException>().having(
              (e) => e.kind,
              'kind',
              LlmChatErrorKind.invalidRequest,
            ),
          ),
        );
        expect(
          () => api.send(sessionId: 'a b@c', message: 'halo'),
          throwsA(
            isA<LlmChatException>().having(
              (e) => e.kind,
              'kind',
              LlmChatErrorKind.invalidRequest,
            ),
          ),
        );
        expect(calls, 0);
      },
    );

    test('503 -> notConfigured dengan pesan dari server', () async {
      final api = _api(
        (_) async => _json({
          'detail': {
            'error': 'llm_not_configured',
            'message': 'API key untuk \'groq\' belum diisi',
          },
        }, 503),
      );
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>()
              .having((e) => e.kind, 'kind', LlmChatErrorKind.notConfigured)
              .having((e) => e.message, 'message', contains('API key')),
        ),
      );
    });

    test('429 -> rateLimited dengan Retry-After', () async {
      final api = _api(
        (_) async => _json(
          {
            'detail': {'error': 'rate_limited', 'retry_after_s': 7},
          },
          429,
          headers: {'retry-after': '7'},
        ),
      );
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>()
              .having((e) => e.kind, 'kind', LlmChatErrorKind.rateLimited)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
    });

    test('404 -> modul belum dipasang', () async {
      final api = _api((_) async => _json({'detail': 'Not Found'}, 404));
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>().having(
            (e) => e.kind,
            'kind',
            LlmChatErrorKind.notConfigured,
          ),
        ),
      );
    });

    test('server mati -> unreachable', () async {
      final api = _api((_) async => throw http.ClientException('refused'));
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>()
              .having((e) => e.kind, 'kind', LlmChatErrorKind.unreachable)
              .having((e) => e.message, 'message', contains('192.168.1.10')),
        ),
      );
    });

    test('server lambat -> timeout', () async {
      final api = _api(
        (_) => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>().having(
            (e) => e.kind,
            'kind',
            LlmChatErrorKind.timeout,
          ),
        ),
      );
    });

    test('jawaban bukan JSON -> badResponse', () async {
      final api = _api((_) async => http.Response('<html>', 200));
      expect(
        () => api.send(sessionId: 'uid-1', message: 'halo'),
        throwsA(
          isA<LlmChatException>().having(
            (e) => e.kind,
            'kind',
            LlmChatErrorKind.badResponse,
          ),
        ),
      );
    });
  });

  group('LlmChatApi.sendSafe', () {
    test('server mati -> balasan darurat sesuai tingkat kantuk', () async {
      final api = _api((_) async => throw http.ClientException('refused'));

      final sleepy = await api.sendSafe(
        sessionId: 'uid-1',
        message: 'halo',
        driverState: const LlmDriverState(status: DriverStatus.sleep),
      );
      expect(sleepy.fallback, isTrue);
      expect(sleepy.provider, 'offline');
      expect(sleepy.error, 'unreachable');
      expect(sleepy.reply, LlmChatApi.offlineReplies[2]);

      final tired = await api.sendSafe(
        sessionId: 'uid-1',
        message: 'capek banget',
      );
      expect(tired.reply, LlmChatApi.offlineReplies[1]);

      final calm = await api.sendSafe(sessionId: 'uid-1', message: 'halo');
      expect(calm.reply, LlmChatApi.offlineReplies[0]);
    });

    test('server sehat -> sama dengan send', () async {
      final api = _api((_) async => _json(_okReply, 200));
      final reply = await api.sendSafe(sessionId: 'uid-1', message: 'halo');
      expect(reply.fallback, isFalse);
      expect(reply.reply, _okReply['reply']);
    });
  });

  group('health & clear', () {
    test('health deep membaca hasil cek provider', () async {
      late Uri url;
      final api = _api((request) async {
        url = request.url;
        return _json({
          'status': 'ok',
          'provider': 'groq',
          'model': 'openai/gpt-oss-120b',
          'host': 'api.groq.com',
          'problem': null,
          'active_sessions': 0,
          'reachable': true,
          'model_available': true,
          'models_listed': 20,
        }, 200);
      });
      final health = await api.health(deep: true);
      expect(url.toString(), 'http://192.168.1.10:8000/chat/health?deep=true');
      expect(health.configured, isTrue);
      expect(health.reachable, isTrue);
      expect(health.modelAvailable, isTrue);
    });

    test('health belum dikonfigurasi', () async {
      final api = _api(
        (_) async => _json({
          'status': 'not_configured',
          'provider': 'groq',
          'model': 'openai/gpt-oss-120b',
          'problem': 'API key untuk \'groq\' belum diisi',
        }, 200),
      );
      final health = await api.health();
      expect(health.configured, isFalse);
      expect(health.problem, contains('API key'));
      expect(health.reachable, isNull);
    });

    test('clear memanggil DELETE /chat/{id}', () async {
      late http.Request sent;
      final api = _api((request) async {
        sent = request;
        return _json({'session_id': 'uid-1', 'cleared': true}, 200);
      });
      expect(await api.clear('uid-1'), isTrue);
      expect(sent.method, 'DELETE');
      expect(sent.url.path, '/chat/uid-1');
    });
  });

  test('sanitizeSessionId', () {
    expect(
      LlmChatApi.sanitizeSessionId('bram@binus.ac.id'),
      'bram_binus.ac.id',
    );
    expect(LlmChatApi.sanitizeSessionId('   '), 'anon');
    expect(LlmChatApi.sanitizeSessionId('x' * 80).length, 64);
  });
}
