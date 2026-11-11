// Tactical RMM REST / WebSocket client used by the TRMM Desktop screens.
//
// Conventions of the Tactical RMM api (see TacticalRmm/api/tacticalrmm):
// - auth header "Authorization: Token <knox token>"
// - errors: HTTP 400 with a JSON string body (notify_error)
// - 401: token expired -> login again; 403: no permission ({"detail": ...})
// - many agent calls are synchronous round trips to the agent: long timeout
// - websockets: wss://<api host>/ws/<path>/?access_token=<token>

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class TrmmApiException implements Exception {
  final int status;
  final String message;
  TrmmApiException(this.status, this.message);

  bool get unauthorized => status == 401;
  bool get forbidden => status == 403;

  @override
  String toString() => message;
}

/// texts of 403 answers: the screens show them as a big "no permission"
/// notice (they only get the message string)
final Set<String> forbiddenMessages = {'Permission denied'};

bool isTrmmForbidden(String message) => forbiddenMessages.contains(message);

class TrmmClient {
  /// e.g. https://api.example.com (no trailing slash)
  final String apiUrl;
  String? token;
  final Duration timeout;
  final http.Client _http;

  /// called on 401 so the app can show the login screen
  void Function()? onUnauthorized;

  TrmmClient(String apiUrl,
      {this.token, this.timeout = const Duration(seconds: 190), http.Client? client})
      : apiUrl = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl,
        _http = client ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Token $token',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final p = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$apiUrl$p');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      for (final e in query.entries)
        if (e.value != null) e.key: e.value.toString(),
    });
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, [Object? body]) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path, {Map<String, dynamic>? query, Object? body}) =>
      _send('DELETE', path, query: query, body: body);

  /// any method with its own timeout (file transfers)
  Future<dynamic> send(String method, String path,
          {Object? body, Map<String, dynamic>? query, Duration? timeout}) =>
      _send(method, path, body: body, query: query, timeout: timeout);

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, dynamic>? query, Duration? timeout}) async {
    final req = http.Request(method, _uri(path, query));
    req.headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    return _decode(await _roundTrip(req, timeout));
  }

  Future<http.Response> _roundTrip(http.BaseRequest req, Duration? t) async {
    try {
      final streamed = await _http.send(req).timeout(t ?? timeout);
      return await http.Response.fromStream(streamed).timeout(t ?? timeout);
    } on TimeoutException {
      throw TrmmApiException(0, 'Timeout');
    } on SocketException catch (e) {
      throw TrmmApiException(0, 'Backend is offline: ${e.message}');
    } on http.ClientException catch (e) {
      throw TrmmApiException(0, e.message);
    }
  }

  /// GET of binary data: status (200 or 204), body and headers. Errors are
  /// thrown as in the json calls.
  Future<(int, Uint8List, Map<String, String>)> getBytes(String path,
      {Map<String, dynamic>? query, Duration? timeout}) async {
    final req = http.Request('GET', _uri(path, query));
    req.headers.addAll({
      'Accept': 'application/octet-stream, application/json',
      if (token != null) 'Authorization': 'Token $token',
    });
    final resp = await _roundTrip(req, timeout);
    if (resp.statusCode >= 400) _decode(resp);
    return (resp.statusCode, resp.bodyBytes, resp.headers);
  }

  /// PUT of binary data, json answer
  Future<dynamic> putBytes(String path, List<int> bytes,
      {Map<String, String>? headers, Duration? timeout}) async {
    final req = http.Request('PUT', _uri(path));
    req.headers.addAll(_headers);
    req.headers['Content-Type'] = 'application/octet-stream';
    if (headers != null) req.headers.addAll(headers);
    req.bodyBytes = bytes;
    return _decode(await _roundTrip(req, timeout));
  }

  /// raw bytes (file downloads), returns body + suggested file name.
  /// [onProgress]: bytes received and total (null when the server doesn't
  /// tell the size); [cancelled] is checked for each piece received.
  Future<(List<int>, String?)> download(String path,
      {String method = 'GET',
      Object? body,
      void Function(int received, int? total)? onProgress,
      bool Function()? cancelled}) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final http.StreamedResponse resp;
    try {
      resp = await _http.send(req).timeout(timeout);
    } on TimeoutException {
      throw TrmmApiException(0, 'Timeout');
    } on SocketException catch (e) {
      throw TrmmApiException(0, 'Backend is offline: ${e.message}');
    }
    if (resp.statusCode >= 400) _decode(await http.Response.fromStream(resp));
    final total = resp.contentLength;
    final bytes = BytesBuilder(copy: false);
    try {
      // no piece for a minute: the connection is gone
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        if (cancelled?.call() == true) throw TrmmApiException(-1, 'Cancelled');
        bytes.add(chunk);
        onProgress?.call(bytes.length, total);
      }
    } on TimeoutException {
      throw TrmmApiException(0, 'Timeout');
    } on http.ClientException catch (e) {
      throw TrmmApiException(0, e.message);
    }
    final cd = resp.headers['content-disposition'] ?? '';
    final m = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    return (bytes.takeBytes(), m?.group(1));
  }

  dynamic _decode(http.Response resp) {
    dynamic data;
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (text.isNotEmpty) {
      try {
        data = jsonDecode(text);
      } catch (_) {
        data = text;
      }
    }
    if (resp.statusCode < 400) return data;

    if (resp.statusCode == 401) onUnauthorized?.call();
    final msg = _errorMessage(resp.statusCode, data);
    if (resp.statusCode == 403) forbiddenMessages.add(msg);
    throw TrmmApiException(resp.statusCode, msg);
  }

  static String _errorMessage(int status, dynamic data) {
    if (data is String && data.isNotEmpty) return data;
    if (data is Map) {
      if (data['detail'] != null) return data['detail'].toString();
      if (data['error'] != null) return data['error'].toString();
      if (data['non_field_errors'] is List && data['non_field_errors'].isNotEmpty) {
        return data['non_field_errors'][0].toString();
      }
      if (data.isNotEmpty) {
        final e = data.entries.first;
        final v = e.value is List && e.value.isNotEmpty ? e.value[0] : e.value;
        return '${e.key}: $v';
      }
    }
    switch (status) {
      case 401:
        return 'Session expired';
      case 403:
        return 'Permission denied';
      case 404:
        return 'Not found';
    }
    return 'Error $status';
  }

  /// wss://<api host>/ws/<path>/?access_token=<token>
  Uri wsUri(String path) {
    final api = Uri.parse(apiUrl);
    final p = path.startsWith('/') ? path.substring(1) : path;
    return Uri(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      host: api.host,
      port: api.hasPort ? api.port : null,
      path: '/ws/${p.endsWith('/') ? p : '$p/'}',
      queryParameters: {'access_token': token ?? ''},
    );
  }

  Future<WebSocket> connectWs(String path) =>
      WebSocket.connect(wsUri(path).toString()).timeout(const Duration(seconds: 20));

  void close() => _http.close();
}
