part of 'main.dart';

class HomeAssistant {
  String _hassioAPIEndpoint;
  String _hassioPassword;
  String _hassioAuthType;

  IOWebSocketChannel _hassioChannel;
  SendMessageQueue _messageQueue;

  int _currentMessageId = 0;
  int _statesMessageId = 0;
  int _servicesMessageId = 0;
  int _subscriptionMessageId = 0;
  int _configMessageId = 0;
  EntityCollection _entities;
  ViewBuilder _viewBuilder;
  Map _instanceConfig = {};

  Completer _fetchCompleter;
  Completer _statesCompleter;
  Completer _servicesCompleter;
  Completer _configCompleter;
  Completer _connectionCompleter;
  Timer _connectionTimer;
  Timer _fetchTimer;

  StreamSubscription _socketSubscription;

  int messageExpirationTime = 50; //seconds
  Duration fetchTimeout = Duration(seconds: 30);
  Duration connectTimeout = Duration(seconds: 10);

  String get locationName => _instanceConfig["location_name"] ?? "";
  int get viewsCount => _entities.viewList.length ?? 0;

  EntityCollection get entities => _entities;

  HomeAssistant() {
    _entities = EntityCollection();
    _messageQueue = SendMessageQueue(messageExpirationTime);
  }

  void updateConnectionSettings(String url, String password, String authType) {
    _hassioAPIEndpoint = url;
    _hassioPassword = password;
    _hassioAuthType = authType;
  }

  Future fetch() {
    if ((_fetchCompleter != null) && (!_fetchCompleter.isCompleted)) {
      TheLogger.log("Warning","Previous fetch is not complited");
    } else {
      _fetchCompleter = new Completer();
      _fetchTimer = Timer(fetchTimeout, () {
        TheLogger.log("Error", "Data fetching timeout");
        _completeFetching({"errorCode" : 9,"errorMessage": "Couldn't get data from server"});
      });
      _connection().then((r) {
        _getData();
      }).catchError((e) {
        _completeFetching(e);
      });
    }
    return _fetchCompleter.future;
  }

  disconnect() async {
    if ((_hassioChannel != null) && (_hassioChannel.closeCode == null) && (_hassioChannel.sink != null)) {
      await _hassioChannel.sink.close().timeout(Duration(seconds: 3),
        onTimeout: () => TheLogger.log("Warning", "Socket sink closing timeout")
      );
      _hassioChannel = null;
    }
  }

  Future _connection() {
    if ((_connectionCompleter != null) && (!_connectionCompleter.isCompleted)) {
      TheLogger.log("Debug","Previous connection is not complited");
    } else {
      _connectionCompleter = new Completer();
      if ((_hassioChannel == null) || (_hassioChannel.closeCode != null)) {
        disconnect().then((_){
          TheLogger.log("Debug", "Socket connecting...");
          _connectionTimer = Timer(connectTimeout, () {
            TheLogger.log("Error", "Socket connection timeout");
            _completeConnecting({"errorCode" : 1,"errorMessage": "Couldn't connect to Home Assistant. Check network connection or connection settings."});
          });
          if (_socketSubscription != null) {
            _socketSubscription.cancel();
          }
          _hassioChannel = IOWebSocketChannel.connect(
              _hassioAPIEndpoint, pingInterval: Duration(seconds: 30));
          _socketSubscription = _hassioChannel.stream.listen(
                  (message) => _handleMessage(_connectionCompleter, message),
              cancelOnError: true,
              onDone: () {
                TheLogger.log("Debug","Disconnect detected. Reconnecting...");
                disconnect().then((_) {
                  _connection();
                });
              },
              onError: (e) {
                TheLogger.log("Error","Socket stream Error: $e");
                disconnect().then((_) => _completeConnecting({"errorCode" : 1,"errorMessage": "Couldn't connect to Home Assistant. Check network connection or connection settings."}));
              }
          );
        });
      } else {
        //TheLogger.log("Debug","Socket looks connected...${_hassioChannel.protocol}, ${_hassioChannel.closeCode}, ${_hassioChannel.closeReason}");
        _completeConnecting(null);
      }
    }
    return _connectionCompleter.future;
  }

  _getData() {
    _getConfig().then((result) {
      _getStates().then((result) {
        _getServices().then((result) {
          _completeFetching(null);
        });
      });
    }).catchError((e) {
      _completeFetching(e);
    });
  }

  void _completeFetching(error) {
    _fetchTimer.cancel();
    _completeConnecting(error);
    if (!_fetchCompleter.isCompleted) {
      if (error != null) {
        disconnect().then((_){
          _fetchCompleter.completeError(error);
        });
      } else {
        _fetchCompleter.complete();
      }
    }
  }

  void _completeConnecting(error) {
    _connectionTimer.cancel();
    if (!_connectionCompleter.isCompleted) {
      if (error != null) {
        _connectionCompleter.completeError(error);
      } else {
        _connectionCompleter.complete();
      }
    }
  }

  _handleMessage(Completer connectionCompleter, String message) {
    var data = json.decode(message);
    //TheLogger.log("Debug","[Received] => Message type: ${data['type']}");
    if (data["type"] == "auth_required") {
      _sendAuthMessageRaw('{"type": "auth","$_hassioAuthType": "$_hassioPassword"}');
    } else if (data["type"] == "auth_ok") {
      _completeConnecting(null);
      _sendSubscribe();
    } else if (data["type"] == "auth_invalid") {
      _completeFetching({"errorCode": 6, "errorMessage": "${data["message"]}"});
    } else if (data["type"] == "result") {
      if (data["id"] == _configMessageId) {
        _parseConfig(data);
      } else if (data["id"] == _statesMessageId) {
        _parseEntities(data);
      } else if (data["id"] == _servicesMessageId) {
        _parseServices(data);
      } else if (data["id"] == _currentMessageId) {
        TheLogger.log("Debug","Request id:$_currentMessageId was successful");
      }
    } else if (data["type"] == "event") {
      if ((data["event"] != null) && (data["event"]["event_type"] == "state_changed")) {
        _handleEntityStateChange(data["event"]["data"]);
      } else if (data["event"] != null) {
        TheLogger.log("Warning","Unhandled event type: ${data["event"]["event_type"]}");
      } else {
        TheLogger.log("Error","Event is null: $message");
      }
    } else {
      TheLogger.log("Warning","Unknown message type: $message");
    }
  }

  void _sendSubscribe() {
    _incrementMessageId();
    _subscriptionMessageId = _currentMessageId;
    _sendMessageRaw('{"id": $_subscriptionMessageId, "type": "subscribe_events", "event_type": "state_changed"}', false);
  }

  Future _getConfig() {
    _configCompleter = new Completer();
    _incrementMessageId();
    _configMessageId = _currentMessageId;
    _sendMessageRaw('{"id": $_configMessageId, "type": "get_config"}', false);

    return _configCompleter.future;
  }

  Future _getStates() {
    _statesCompleter = new Completer();
    _incrementMessageId();
    _statesMessageId = _currentMessageId;
    _sendMessageRaw('{"id": $_statesMessageId, "type": "get_states"}', false);

    return _statesCompleter.future;
  }

  Future _getServices() {
    _servicesCompleter = new Completer();
    _incrementMessageId();
    _servicesMessageId = _currentMessageId;
    _sendMessageRaw('{"id": $_servicesMessageId, "type": "get_services"}', false);

    return _servicesCompleter.future;
  }

  _incrementMessageId() {
    _currentMessageId += 1;
  }

  void _sendAuthMessageRaw(String message) {
    TheLogger.log("Debug", "[Sending] ==> auth request");
    _hassioChannel.sink.add(message);
  }

  _sendMessageRaw(String message, bool queued) {
    var sendCompleter = Completer();
    if (queued) _messageQueue.add(message);
    _connection().then((r) {
      _messageQueue.getActualMessages().forEach((message){
        TheLogger.log("Debug", "[Sending queued] ==> $message");
        _hassioChannel.sink.add(message);
      });
      if (!queued) {
        TheLogger.log("Debug", "[Sending] ==> $message");
        _hassioChannel.sink.add(message);
      }
      sendCompleter.complete();
    }).catchError((e){
      sendCompleter.completeError(e);
    });
    return sendCompleter.future;
  }

  Future callService(String domain, String service, String entityId, Map<String, String> additionalParams) {
    _incrementMessageId();
    String message = '{"id": $_currentMessageId, "type": "call_service", "domain": "$domain", "service": "$service", "service_data": {"entity_id": "$entityId"';
    if (additionalParams != null) {
      additionalParams.forEach((name, value){
        message += ', "$name" : "$value"';
      });
    }
    message += '}}';
    return _sendMessageRaw(message, true);
  }

  void _handleEntityStateChange(Map eventData) {
    //TheLogger.log("Debug", "New state for ${eventData['entity_id']}");
    _entities.updateState(eventData);
    eventBus.fire(new StateChangedEvent(eventData["entity_id"], null, false));
  }

  void _parseConfig(Map data) {
    if (data["success"] == true) {
      _instanceConfig = Map.from(data["result"]);
      _configCompleter.complete();
    } else {
      _configCompleter.completeError({"errorCode": 2, "errorMessage": data["error"]["message"]});
    }
  }

  void _parseServices(response) {
    _servicesCompleter.complete();
    /*if (response["success"] == false) {
      _servicesCompleter.completeError({"errorCode": 4, "errorMessage": response["error"]["message"]});
      return;
    }
    try {
      Map data = response["result"];
      Map result = {};
      TheLogger.log("Debug","Parsing ${data.length} Home Assistant service domains");
      data.forEach((domain, services) {
        result[domain] = Map.from(services);
        services.forEach((serviceName, serviceData) {
          if (_entitiesData.isExist("$domain.$serviceName")) {
            result[domain].remove(serviceName);
          }
        });
      });
      _servicesData = result;
      _servicesCompleter.complete();
    } catch (e) {
      TheLogger.log("Error","Error parsing services. But they are not used :-)");
      _servicesCompleter.complete();
    }*/
  }

  void _parseEntities(response) async {
    if (response["success"] == false) {
      _statesCompleter.completeError({"errorCode": 3, "errorMessage": response["error"]["message"]});
      return;
    }
    _entities.parse(response["result"]);
    _viewBuilder = ViewBuilder(entityCollection: _entities);
    _statesCompleter.complete();
  }

  Widget buildViews(BuildContext context) {
    return _viewBuilder.buildWidget(context);
  }
}

class SendMessageQueue {
  int _messageTimeout;
  List<HAMessage> _queue = [];

  SendMessageQueue(this._messageTimeout);

  void add(String message) {
    _queue.add(HAMessage(_messageTimeout, message));
  }
  
  List<String> getActualMessages() {
    _queue.removeWhere((item) => item.isExpired());
    List<String> result = [];
    _queue.forEach((haMessage){
      result.add(haMessage.message);
    });
    this.clear();
    return result;
  }
  
  void clear() {
    _queue.clear();
  }
  
}

class HAMessage {
  DateTime _timeStamp;
  int _messageTimeout;
  String message;
  
  HAMessage(this._messageTimeout, this.message) {
    _timeStamp = DateTime.now();
  }
  
  bool isExpired() {
    return _timeStamp.difference(DateTime.now()).inSeconds > _messageTimeout;
  }
}