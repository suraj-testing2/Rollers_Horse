//  Copyright 2011 Google Inc. All Rights Reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

library server;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:convert' show JSON;

import 'package:collab/collab.dart';
import 'package:collab/utils.dart';

part 'connection.dart';

class CollabServer {
  // clientId -> connection
  final Map<String, Connection> _connections;
  // docTypeId -> DocumentType
  final Map<String, DocumentType> _docTypes;
  // messageType -> MessageFactory
  final Map<String, MessageFactory> _messageFactories;
  final Map<String, Map<String, Transform>> _transforms;
  // docId -> document
  final Map<String, Document> _documents;
  // docId -> clientId
  final Map<String, Set<String>> _listeners;
  final Queue<Message> _queue;

  CollabServer()
    : _connections = new Map<String, Connection>(),
      _docTypes = new Map<String, DocumentType>(),
      _messageFactories = new Map.from(SystemMessageFactories.messageFactories),
      _transforms = new Map<String, Map<String, Transform>>(),
      _documents = new Map<String, Document>(),
      _listeners = new Map<String, Set<String>>(),
      _queue = new Queue<Message>();

  void addConnection(Connection connection) {
    String clientId = randomId();
    _connections[clientId] = connection;
    connection.stream.map(JSON.decode).listen((json) {
      var factory = _messageFactories[json['type']];
      var message = factory(json);
      _enqueue(message);
    },
    onDone: () {
      print("closed: $clientId");
      _removeConnection(clientId);
    },
    onError: (e) {
      print("error: $clientId $e");
      _removeConnection(clientId);
    });
    ClientIdMessage message = new ClientIdMessage(SERVER_ID, clientId);
    connection.add(message.json);
  }

  void registerDocumentType(DocumentType docType) {
    _docTypes[docType.id] = docType;
    _messageFactories.addAll(docType.messageFactories);
    _transforms.addAll(docType.transforms);
  }

  void _enqueue(Message message) {
    _queue.add(message);
    _processDeferred();
  }

  void _processDeferred() {
    Timer.run(() => _process());
  }

  void _process() {
    if (!_queue.isEmpty) {
      _dispatch(_queue.removeFirst());
      _processDeferred();
    }
  }

  void _dispatch(Message message) {
    String clientId = message.senderId;
    print("dispatch: $message");
    switch (message.type) {
      case "create":
        create(clientId, message);
        break;
      case "log":
        print((message as LogMessage).text);
        break;
      case "open":
        OpenMessage m = message;
        _open(clientId, m.docId, m.docType);
        break;
      case "close":
        CloseMessage m = message;
        _removeListener(clientId, m.docId);
        break;
      default:
        if (message is Operation) {
          _doOperation(message);
        } else {
          print("unknown message type: ${message.type}");
        }
    }
  }

  void _doOperation(Operation op) {
    Document doc = _documents[op.docId];
    // TODO: apply transform
    // transform by every applied op with a seq number greater than
    // op.docVersion those operations are in flight to the client that sent [op]
    // and will be transformed by op in the client. The result will be the same.
    Operation transformed = op;
    int currentVersion = doc.version;
    Queue<Operation> newerOps = new Queue<Operation>();
    for (int i = doc.log.length - 1; i >= 0; i--) {
      Operation appliedOp = doc.log[i];
      if (appliedOp.sequence > op.docVersion) {
        Transform t = _transforms[transformed.type][appliedOp.type];
        transformed = (t == null) ? transformed : t(transformed, appliedOp);
      }
    }
    doc.version++;
    transformed.sequence = doc.version;
    transformed.apply(doc);
    doc.log.add(transformed);
    _broadcast(transformed);
  }

  void _broadcast(Operation op) {
    Set<String> listenerIds = _listeners[op.docId];
    if (listenerIds == null) {
      print("no listeners");
      return;
    }
    for (String listenerId in listenerIds) {
        _send(listenerId, op);
    }
  }

  void _send(String clientId, Message message) {
    var connection = _connections[clientId];
    if (connection == null) {
      // not sure why this happens sometimes
      _connections.remove(clientId);
      return;
    }
    connection.add(message.json);
  }

  void _open(String clientId, String docId, String docType) {
    if (_documents[docId] == null) {
      _create(docId, docType);
    }
    _addListener(clientId, docId);
  }

  void _addListener(String clientId, String docId) {
    _listeners.putIfAbsent(docId, () => new Set<String>());
    _listeners[docId].add(clientId);
    Document d = _documents[docId];
    Message m =
        new SnapshotMessage(SERVER_ID, docId, d.version, d.serialize());
    _send(clientId, m);
  }

  void _removeListener(String clientId, String docId) {
    _listeners.putIfAbsent(docId, () => new Set<String>());
    _listeners[docId].remove(clientId);
  }

  void create(String clientId, CreateMessage message) {
    var d = _create(randomId(), message.docType);
    CreatedMessage m = new CreatedMessage(d.id, d.type.id, message.id);
    _send(clientId, m);
  }

  Document _create(String docId, String docTypeId) {
    Document d = _docTypes[docTypeId].create(docId);
    _documents[d.id] = d;
    return d;
  }

  void _removeConnection(String clientId) {
    _connections.remove(clientId);
  }
}
