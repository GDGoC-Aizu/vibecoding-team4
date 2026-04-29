import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'firebase_options.dart';

void main() async {
  // FlutterのUIバインディングを初期化（Firebase初期化の前に必須）
  WidgetsFlutterBinding.ensureInitialized();

  // Firebaseの初期化
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const SproutApp());
}

class SproutApp extends StatelessWidget {
  const SproutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sprout in UoA',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const LocationCheckScreen(),
    );
  }
}

/// 1. GPS位置情報を確認する起動画面
class LocationCheckScreen extends StatefulWidget {
  const LocationCheckScreen({super.key});

  @override
  State<LocationCheckScreen> createState() => _LocationCheckScreenState();
}

class _LocationCheckScreenState extends State<LocationCheckScreen> {
  bool _isLoading = true;
  bool _isWithinArea = false;

  // 会津大学の座標（概算）
  final double uoaLat = 37.5232;
  final double uoaLng = 139.9380;
  final double allowRadiusInMeters = 2000.0; // 2km以内を許可

  @override
  void initState() {
    super.initState();
    _checkLocation();
  }

  Future<void> _checkLocation() async {
    // 実際にはここで位置情報の権限リクエストを行います
    // LocationPermission permission = await Geolocator.requestPermission();

    // 仮の現在地（テスト用に会津大付近の座標を設定）
    double currentLat = 37.5230;
    double currentLng = 139.9380;

    double distance = Geolocator.distanceBetween(
      uoaLat,
      uoaLng,
      currentLat,
      currentLng,
    );

    setState(() {
      _isWithinArea = distance <= allowRadiusInMeters;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // エリア内の場合はホーム画面へ、エリア外の場合はエラー画面を表示
    if (_isWithinArea) {
      return const HomeScreen();
    } else {
      return Scaffold(
        appBar: AppBar(title: const Text('Sprout in UoA')),
        body: const Center(
          child: Text(
            '会津大学の周辺でのみ利用可能なアプリです。\n大学に近づいてから再度お試しください。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
  }
}

/// 2. ホーム画面（マッチング＆履歴FAB）
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _startRandomMatching(BuildContext context) async {
    // マッチングダイアログを表示し、マッチングが成功したらroomIdを受け取る
    final String? roomId = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 画面外タップで閉じないようにする
      builder: (_) => const MatchingDialog(),
    );

    // roomIdが返ってきたら（マッチング成功したら）、チャット画面へ遷移
    if (roomId != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              ChatRoomScreen(roomId: roomId, isReadOnly: false),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sprout in UoA')),
      body: Center(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          onPressed: () => _startRandomMatching(context),
          child: const Text('新規トークを探す (マッチング)', style: TextStyle(fontSize: 18)),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const HistoryScreen()),
          );
        },
        child: const Icon(Icons.history),
      ),
    );
  }
}

/// マッチング処理を行うダイアログ
class MatchingDialog extends StatefulWidget {
  const MatchingDialog({super.key});

  @override
  State<MatchingDialog> createState() => _MatchingDialogState();
}

class _MatchingDialogState extends State<MatchingDialog> {
  StreamSubscription<DocumentSnapshot>? _queueSubscription;
  String? _myUid;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _startMatchingProcess();
  }

  Future<void> _startMatchingProcess() async {
    try {
      // 1. 匿名ログインをして自分のユーザーID(UID)を取得
      UserCredential userCred = await FirebaseAuth.instance.signInAnonymously();
      _myUid = userCred.user!.uid;

      final firestore = FirebaseFirestore.instance;
      final queueRef = firestore.collection('matching_queue');
      final roomsRef = firestore.collection('chat_rooms');

      bool isMatchSuccessful = false;
      String? matchedRoomId;

      // 複数ペアが同時にマッチングしようとした時の競合を防ぐため、トランザクションとリトライで処理する
      while (!isMatchSuccessful) {
        // 2. 待機中の他の人を探す
        final querySnapshot = await queueRef
            .where('isWaiting', isEqualTo: true)
            .limit(1) // 1人だけ探す
            .get();

        if (querySnapshot.docs.isEmpty) {
          break; // 誰も待っていないのでループを抜けて自分が待機列に並ぶ
        }

        final opponent = querySnapshot.docs.first;
        if (opponent.id == _myUid) {
          break; // 自分自身の場合はループを抜ける
        }

        final opponentRef = opponent.reference;

        try {
          await firestore.runTransaction((transaction) async {
            // トランザクション内で相手の最新状態を取得
            final snapshot = await transaction.get(opponentRef);
            if (!snapshot.exists) {
              throw Exception("相手が待機をキャンセルしました");
            }
            final data = snapshot.data();
            if (data == null || data['isWaiting'] != true) {
              throw Exception("相手は既に他の人とマッチングしました");
            }

            // 【パターンA: 相手がいた】
            // 新しいチャットルームを作成
            final newRoomRef = roomsRef.doc();
            matchedRoomId = newRoomRef.id;

            transaction.set(newRoomRef, {
              'members': [_myUid, opponentRef.id], // 自分と相手のUIDを登録
              'status': 'open',
              'createdAt': FieldValue.serverTimestamp(),
            });

            // 相手の待機ドキュメントを更新し、作成したルームのIDを伝える
            transaction.update(opponentRef, {
              'isWaiting': false,
              'matchedRoomId': matchedRoomId,
            });
          });

          // トランザクションが成功したらマッチング成功
          isMatchSuccessful = true;
        } catch (e) {
          debugPrint('マッチング競合が発生しました。リトライします: $e');
          // 競合した場合は少し待ってから再度探す
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      if (isMatchSuccessful && matchedRoomId != null) {
        // ダイアログを閉じ、ルームIDを返す
        if (!mounted) return;
        if (!_isDisposed) Navigator.pop(context, matchedRoomId);
        return;
      }

      // 【パターンB: 相手がいなかった】
      // 3. 自分が待機列に並ぶ
      final myQueueDoc = queueRef.doc(_myUid);
      await myQueueDoc.set({
        'isWaiting': true,
        'matchedRoomId': null,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 4. 誰かがマッチングして、ルームIDを入れてくれるのを監視（リッスン）する
      _queueSubscription = myQueueDoc.snapshots().listen((snapshot) {
        if (!snapshot.exists) return;

        final data = snapshot.data();
        if (data != null && data['matchedRoomId'] != null) {
          // 誰かがルームを作ってくれた！
          final roomId = data['matchedRoomId'];

          // 待機列から自分を削除
          myQueueDoc.delete();

          // ダイアログを閉じ、ルームIDを返す
          if (!mounted) return;
          if (!_isDisposed) Navigator.pop(context, roomId);
        }
      });
    } catch (e) {
      debugPrint('マッチングエラー: $e');
      if (!mounted) return;
      if (!_isDisposed) Navigator.pop(context, null);
    }
  }

  // キャンセルボタンを押した時の処理
  void _cancelMatching() async {
    if (_myUid != null) {
      // 待機列から自分を削除
      await FirebaseFirestore.instance
          .collection('matching_queue')
          .doc(_myUid)
          .delete();
    }
    if (!mounted) return;
    if (!_isDisposed) Navigator.pop(context, null);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _queueSubscription?.cancel(); // 監視をストップ
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('マッチング中...'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text("会津大周辺のオンラインユーザーを探しています🌱"),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancelMatching,
          child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

/// 簡易チャット画面
class ChatRoomScreen extends StatefulWidget {
  final String roomId;
  final bool isReadOnly;

  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.isReadOnly,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _messageController = TextEditingController();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    if (_myUid == null) {
      debugPrint("エラー: ユーザーがログインしていません");
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.roomId)
          .collection('messages')
          .add({
            'text': text,
            'senderId': _myUid,
            'createdAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      debugPrint("メッセージ送信エラー: $e");
    }
  }

  void _performExit() {
    if (_myUid == null) return;
    try {
      final roomRef = FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.roomId);
      roomRef.update({
        'status': 'closed',
        'leftBy': FieldValue.arrayUnion([_myUid]),
      });
      roomRef.collection('messages').add({
        'text': '相手が退出しました',
        'isSystem': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("退出処理エラー: $e");
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('chat_rooms').doc(widget.roomId).snapshots(),
      builder: (context, roomSnapshot) {
        bool isClosed = widget.isReadOnly;
        if (roomSnapshot.hasData && roomSnapshot.data!.exists) {
          final roomData = roomSnapshot.data!.data() as Map<String, dynamic>;
          if (roomData['status'] == 'closed') {
            isClosed = true;
          }
        }

        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop && !isClosed) {
              _performExit();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('トークルーム'),
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
              actions: [
                if (!isClosed)
                  IconButton(
                    icon: const Icon(Icons.exit_to_app),
                    tooltip: '退出する',
                    onPressed: () => Navigator.pop(context),
                  ),
              ],
            ),
            body: Column(
              children: [
                // メッセージリスト
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('chat_rooms')
                        .doc(widget.roomId)
                        .collection('messages')
                        .orderBy('createdAt', descending: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const Center(child: Text('エラーが発生しました'));
                      }
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final docs = snapshot.data?.docs ?? [];
                      if (docs.isEmpty) {
                        return const Center(child: Text('メッセージがありません。'));
                      }

                      return ListView.builder(
                        reverse: true, // 下から上へ表示
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final data = docs[index].data() as Map<String, dynamic>;
                          final text = data['text'] ?? '';
                          final isSystem = data['isSystem'] == true;

                          if (isSystem) {
                            return Center(
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 8),
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  text,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            );
                          }

                          final senderId = data['senderId'] ?? '';
                          final isMyMessage = senderId == _myUid;

                          return Align(
                            alignment: isMyMessage ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                              decoration: BoxDecoration(
                                color: isMyMessage
                                    ? Theme.of(context).colorScheme.primaryContainer
                                    : Theme.of(context).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(16).copyWith(
                                  bottomRight: isMyMessage ? const Radius.circular(0) : const Radius.circular(16),
                                  bottomLeft: isMyMessage ? const Radius.circular(16) : const Radius.circular(0),
                                ),
                              ),
                              child: Text(
                                text,
                                style: TextStyle(
                                  color: isMyMessage
                                      ? Theme.of(context).colorScheme.onPrimaryContainer
                                      : Theme.of(context).colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                // 入力エリア (読み取り専用でない場合のみ表示)
                if (!isClosed)
                  SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            offset: const Offset(0, -2),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              decoration: InputDecoration(
                                hintText: 'メッセージを入力...',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              ),
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.send),
                            color: Theme.of(context).colorScheme.primary,
                            onPressed: _sendMessage,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// トーク履歴画面
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    if (myUid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('トーク履歴')),
        body: const Center(child: Text('ログインしていません')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('トーク履歴')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chat_rooms')
            .where('members', arrayContains: myUid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('トーク履歴取得エラー: ${snapshot.error}');
            return const Center(child: Text('エラーが発生しました'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs.toList() ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('トーク履歴がありません'));
          }

          // Firestoreの複合インデックス作成を回避するため、クライアント側で降順にソートする
          docs.sort((a, b) {
            final aData = a.data() as Map<String, dynamic>;
            final bData = b.data() as Map<String, dynamic>;
            final aTime = aData['createdAt'] as Timestamp?;
            final bTime = bData['createdAt'] as Timestamp?;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;
              final status = data['status'] ?? 'open';
              final createdAt = data['createdAt'] as Timestamp?;
              final dateString = createdAt != null
                  ? '${createdAt.toDate().month}/${createdAt.toDate().day} ${createdAt.toDate().hour}:${createdAt.toDate().minute.toString().padLeft(2, '0')}'
                  : '日時不明';

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: status == 'closed'
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                      : Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    Icons.chat,
                    color: status == 'closed'
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                title: Text('トークルーム ($dateString)'),
                subtitle: Text(status == 'closed' ? '終了したトーク' : '進行中のトーク'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ChatRoomScreen(
                        roomId: doc.id,
                        isReadOnly: status == 'closed',
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
