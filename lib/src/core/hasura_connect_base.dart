import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:hasura_connect/src/core/hasura.dart';
import 'package:hasura_connect/src/exceptions/hasura_error.dart';
import 'package:hasura_connect/src/services/local_storage.dart';
import 'package:hasura_connect/src/snapshot/snapshot.dart';
import 'package:hasura_connect/src/snapshot/snapshot_data.dart';
import 'package:hasura_connect/src/snapshot/snapshot_info.dart';
import 'package:hasura_connect/src/utils/utils.dart' as utils;
import 'package:websocket/websocket.dart';
import 'package:http/http.dart' as http;

import '../../hasura_connect.dart';

class HasuraConnectBase implements HasuraConnect {
  final _controller = StreamController.broadcast();
  final Map<String, SnapshotData> _snapmap = {};
  Map<String, String> _headers;
  final LocalStorage Function() localStorageDelegate;

  int _reconnectionAttemp;
  int _numbersOfConnectionAttempts = 0;
  LocalStorage _localStorageMutation;
  LocalStorage _localStorageCache;
  WebSocket _channelPromisse;
  bool _isDisconnected = false;
  bool _isConnected = false;
  Completer<bool> _onConnect = Completer<bool>();

  final String url;

  Future<String> Function(bool isError) _token;

  HasuraConnectBase(this.url,
      {Map<String, dynamic> headers,
      this.localStorageDelegate,
      Future<String> Function(bool isError) token,
      int reconnectionAttemp}) {
    _token = token;
    _headers = headers ?? <String, String>{};
    _localStorageMutation = localStorageDelegate();
    _localStorageCache = localStorageDelegate();
    _localStorageMutation.init('hasura_mutations');
    _localStorageCache.init('hasura_cache');
    this._reconnectionAttemp = reconnectionAttemp;
  }

  final _init = {
    'payload': {
      'headers': {'content-type': 'application/json'}
    },
    'type': 'connection_init'
  };

  @override
  bool get isConnected => _isConnected;

  StreamController<bool> _isConnectedController =
      StreamController<bool>.broadcast();

  @override
  Stream<bool> get isConnectedStream => this._isConnectedController.stream;

  @override
  Map<String, String> get headers => UnmodifiableMapView(_headers);

  @override
  void changeToken(Future<String> Function(bool isError) token) {
    _token = token;
  }

  @override
  void addHeader(String key, String value) {
    _headers[key] = value;
  }

  @override
  void removeHeader(String key) {
    _headers.remove(key);
  }

  @override
  void removeAllHeader() {
    _headers.clear();
  }

  Stream _generateStream(String key) {
    return _controller.stream.where((data) => data['id'] == key).transform(
      StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          if (data['type'] == 'data') {
            sink.add(data['payload']);
          } else if (data['type'] == 'error') {
            if ((data['payload'] as Map).containsKey('errors')) {
              sink.addError(HasuraError.fromJson(data['payload']['errors'][0]));
            } else {
              sink.addError(HasuraError.fromJson(data['payload']));
            }
          }
        },
      ),
    ).asBroadcastStream();
  }

  Stream _generateFutureQueryStream(Future query) {
    return Stream.fromFuture(query).asBroadcastStream();
  }

  @override
  Snapshot subscription(String query,
      {String key, Map<String, dynamic> variables}) {
    if (!RegExp(r"^(?:\s+)?subscription(?:\s|\{)").hasMatch(query)) {
      query = 'subscription $query';
    }

    key = key ?? utils.generateBase(query);

    final info = SnapshotInfo(key: key, query: query, variables: variables);
    // _localStorage.addSubscription(info);
    return _generateSnapshot(info);
  }

  @override
  Snapshot cachedQuery(String query,
      {String key, Map<String, dynamic> variables}) {
    print("[HASURA BASE] cachedQuery");

    if (query.trimLeft().split(' ')[0] != 'query') {
      query = 'query $query';
    }
    key = key ?? utils.generateBase(query);

    var jsonMap = {'query': query, 'variables': variables};
    final info = SnapshotInfo(
        key: key, query: query, variables: variables, isQuery: true);
    return _generateSnapshot(info, futureQuery: _sendPost(jsonMap));
  }

  Snapshot _generateSnapshot(SnapshotInfo info, {Future futureQuery}) {
    if (_snapmap.keys.isEmpty && futureQuery == null) {
      _connect();
    }

    if (_snapmap.containsKey(info.key) && futureQuery == null) {
      return _snapmap[info.key];
    }

    if (_isConnected && futureQuery == null) {
      _channelPromisse.addUtf8Text(
          _getDocument(info.query, info.key, info.variables).codeUnits);
    }

    var snap = SnapshotData(
        info,
        info.isQuery
            ? _generateFutureQueryStream(futureQuery)
            : _generateStream(info.key), () async {
      if (futureQuery == null) {
        _stopStream(info.key);
        _snapmap.remove(info.key);
        if (_snapmap.keys.isEmpty) {
          await _disconnect();
        }
      }
    }, (snapshotInternal) {
      _stopStream(info.key);
      if (_isConnected) {
        _channelPromisse.addUtf8Text(_getDocument(snapshotInternal.info.query,
                snapshotInternal.info.key, snapshotInternal.info.variables)
            .codeUnits);
      }
    }, conn: this, localStorageCache: _localStorageCache);

    if (futureQuery == null) {
      _snapmap[info.key] = snap;
    }
    return snap;
  }

  void _stopStream(String key) {
    var stop = {'id': key, 'type': 'stop'};
    if (_isConnected) _channelPromisse.addUtf8Text(jsonEncode(stop).codeUnits);
  }

  String _getDocument(
      String query, String key, Map<String, dynamic> variables) {
    return jsonEncode({
      'id': key,
      'payload': {
        'query': query,
        'variables': variables,
      },
      'type': 'start'
    });
  }

  void _addToken([bool isError = false]) async {
    if (_token != null) {
      var t = await _token(isError);
      if (t != null) {
        (_init['payload'] as Map)['headers']['Authorization'] = t;
      }
    }
  }

  @override
  void reconnect() {
    this._numbersOfConnectionAttempts = 0;
    this._connect();
  }

  @override
  void disconnect() {
    this._disconnect();
  }

  void _connect() async {
    if (this._reconnectionAttemp != null && this._reconnectionAttemp > 0) {
      if (this._numbersOfConnectionAttempts >= this._reconnectionAttemp) {
        print('maximum connection attempt numbers reached');
        this._isConnected = false;
        this._disconnect();
        return;
      }
      this._numbersOfConnectionAttempts++;
    }
    print('hasura connecting...');
    try {
      _channelPromisse = await WebSocket.connect(url.replaceFirst('http', 'ws'),
          protocols: ['graphql-ws']); //graphql-subscriptions
      await _addToken();
      if (_headers != null) {
        for (var key in _headers?.keys) {
          (_init['payload'] as Map)['headers'][key] = _headers[key];
        }
      }
      _channelPromisse.addUtf8Text(jsonEncode(_init).codeUnits);
      var _sub = _channelPromisse.stream.listen((data) async {
        data = jsonDecode(data);
        if (data['type'] == 'data' || data['type'] == 'error') {
          _controller.add(data);
        } else if (data['type'] == 'connection_ack') {
          print('HASURA CONNECT!');
          _isConnected = true;
          this._isConnectedController.add(true);
          for (var key in _snapmap.keys) {
            _channelPromisse.addUtf8Text(_getDocument(_snapmap[key].info.query,
                    _snapmap[key].info.key, _snapmap[key].info.variables)
                .codeUnits);
          }

          var mutationCache = await _localStorageMutation.getAll();
          for (var key in mutationCache.keys) {
            print("[HASURA BASE] mutationCache");

            await _sendPost(mutationCache[key], key);
          }
        } else if (data['type'] == 'connection_error') {
          print('Try again...');
          await Future.delayed(Duration(seconds: 2));
          await _addToken(true);
          _channelPromisse.addUtf8Text(jsonEncode(_init).codeUnits);
        } else if (data['type'] == 'ka') {
        } else {
          print(data);
        }
      });
      _sub.onError((e) {
        print(e);
      });
      await _channelPromisse.done;
      await _sub.cancel();
      _isConnected = false;
      this._isConnectedController.add(false);

      if (!_isDisconnected) {
        await Future.delayed(Duration(milliseconds: 3000));
        if (_onConnect.isCompleted) {
          _onConnect = Completer<bool>();
        }
        _connect();
      }
    } catch (e) {
      print(e);
      if (!_isDisconnected) {
        await Future.delayed(Duration(milliseconds: 3000));

        if (_onConnect.isCompleted) {
          _onConnect = Completer<bool>();
        }
        _connect();
      }
    }
  }

  void _disconnect() async {
    var disconect = {'type': 'connection_terminate'};
    if (_isConnected) {
      _channelPromisse.addUtf8Text(jsonEncode(disconect).codeUnits);
    }
    _isDisconnected = true;
    this._isConnectedController.add(false);
    await Future.delayed(Duration(milliseconds: 300));
    if (_channelPromisse?.closeCode != null) {
      await _channelPromisse.close();
    }
    print('disconnected hasura');
  }

  @override
  Future query(String doc, {Map<String, dynamic> variables}) async {
    if (doc.trimLeft().split(' ')[0] != 'query') {
      doc = 'query $doc';
    }
    var jsonMap = {'query': doc, 'variables': variables};
    print("[HASURA BASE] query");

    return await _sendPost(jsonMap);
  }

  int times = 1;

  @override
  Future mutation(String doc,
      {Map<String, dynamic> variables, bool tryAgain = true}) async {
    if (doc.trim().split(' ')[0] != 'mutation') {
      doc = 'mutation $doc';
    }
    var jsonMap = {'query': doc, 'variables': variables};
    var hash = utils.randomString(15);
    if (tryAgain) await _localStorageMutation.put(hash, jsonMap);

    print("[HASURA CONNECT BASE] mutation $hash ");
    return await _sendPost(jsonMap, hash);
  }

  Future _sendPost(Map jsonMap, [String hash]) async {
    var jsonString = jsonEncode(jsonMap);

    print(jsonString);
    print("$hash");

    var headersLocal = {
      'Content-type': 'application/json',
      'Accept': 'application/json'
    };

    if (_token != null) {
      var t = await _token(false);
      if (t != null) {
        headersLocal['Authorization'] = t;
      }
    }

    if (_headers != null) {
      for (var key in _headers?.keys) {
        headersLocal[key] = _headers[key];
      }
    }

    final client = http.Client();
    try {
      var response =
          await client.post(url, body: jsonString, headers: headersLocal);
      Map json = jsonDecode(response.body);

      if (hash != null) {
        await _localStorageMutation.remove(hash);
      }
      if (json.containsKey('errors')) {
        throw HasuraError.fromJson(json['errors'][0]);
      }
      return json;
    } on SocketException catch (_) {
      throw HasuraError('connection error', null);
    } catch (e) {
      rethrow;
    } finally {
      client.close();
    }
  }

  ///finalize Hasura connection
  void dispose() async {
    _disconnect();
    _snapmap.clear();
    await _localStorageMutation.close();
    await _localStorageCache.close();
    await _controller.close();
  }
}
