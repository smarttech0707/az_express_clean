import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/mp_product.dart';
import '../mp_constants.dart';
import '../../widgets/stream_error_state.dart';

// ── Chat page marketplace ─────────────────────────────────────────────────────
// chatId = mp_{productId}_{buyerUid}
// Collection: marketplace_chats/{chatId}/messages
// Sender: 'buyer' | 'seller'
class MpChatPage extends StatefulWidget {
  final MpProduct product;
  final String? buyerId; // null si on est le vendeur qui répond
  final String? buyerName; // null si on est le vendeur qui répond

  const MpChatPage({
    super.key,
    required this.product,
    this.buyerId,
    this.buyerName,
  });

  @override
  State<MpChatPage> createState() => _MpChatPageState();
}

class _MpChatPageState extends State<MpChatPage> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  bool _isRecording = false;
  bool _uploading = false;
  int _recordSecs = 0;
  Timer? _recTimer;

  String? _playingMsgId;
  PlayerState _playerState = PlayerState.stopped;
  Duration _playPos = Duration.zero;

  late final String _uid;
  late final String _chatId;
  late final String _myRole; // 'buyer' | 'seller'

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // If buyerId is passed we're the buyer; if not we're the seller
    final bId = widget.buyerId ?? _uid;
    _chatId = 'mp_${widget.product.id}_$bId';
    _myRole = (widget.buyerId == null && _uid == widget.product.sellerId)
        ? 'seller'
        : 'buyer';

    // Ensure chat metadata exists
    _initChat(bId);

    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _playPos = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted)
        setState(() {
          _playingMsgId = null;
          _playPos = Duration.zero;
        });
    });
  }

  Future<void> _initChat(String buyerId) async {
    final ref =
        FirebaseFirestore.instance.collection('marketplace_chats').doc(_chatId);
    final doc = await ref.get();
    if (!doc.exists) {
      await ref.set({
        'productId': widget.product.id,
        'productTitle': widget.product.title,
        'productImage':
            widget.product.images.isNotEmpty ? widget.product.images.first : '',
        'sellerId': widget.product.sellerId,
        'sellerName': widget.product.sellerName,
        'buyerId': buyerId,
        'buyerName': widget.buyerName ?? 'Acheteur',
        'updatedAt': FieldValue.serverTimestamp(),
        'unreadSeller': 0,
        'unreadBuyer': 0,
      });
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _recTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  // ── Envoyer texte ─────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await _addMessage({'type': 'text', 'text': text});
  }

  // ── Enregistrement vocal ──────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _snack('Permission microphone refusée');
        return;
      }
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/mp_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1),
      path: path,
    );
    _recordSecs = 0;
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSecs++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndSend() async {
    _recTimer?.cancel();
    final dur = _recordSecs;
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null || dur < 1) return;
    await _uploadAudio(path, dur);
  }

  Future<void> _cancelRecording() async {
    _recTimer?.cancel();
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recordSecs = 0;
    });
  }

  Future<void> _uploadAudio(String path, int duration) async {
    setState(() => _uploading = true);
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) {
        _snack('Fichier audio vide');
        setState(() => _uploading = false);
        return;
      }
      final bytes = await file.readAsBytes();
      final name = 'mp_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final ref = FirebaseStorage.instance.ref('mp_chat_audio/$_chatId/$name');
      await ref.putData(bytes, SettableMetadata(contentType: 'audio/mp4'));
      final url = await ref.getDownloadURL();
      await _addMessage(
          {'type': 'audio', 'audioUrl': url, 'duration': duration});
    } catch (e) {
      _snack('Erreur : $e');
    }
    if (mounted) setState(() => _uploading = false);
  }

  // ── Ajouter message en Firestore ───────────────────────────────────────────

  Future<void> _addMessage(Map<String, dynamic> extra) async {
    final col = FirebaseFirestore.instance
        .collection('marketplace_chats')
        .doc(_chatId)
        .collection('messages');
    await col.add({
      ...extra,
      'sender': _myRole,
      'senderUid': _uid,
      'time': FieldValue.serverTimestamp(),
    });
    // Update chat metadata
    await FirebaseFirestore.instance
        .collection('marketplace_chats')
        .doc(_chatId)
        .update({'updatedAt': FieldValue.serverTimestamp()});
    _scrollToBottom();
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Future<void> _togglePlay(String msgId, String url) async {
    if (_playingMsgId == msgId) {
      if (_playerState == PlayerState.playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } else {
      await _player.stop();
      setState(() {
        _playingMsgId = msgId;
        _playPos = Duration.zero;
      });
      await _player.play(UrlSource(url));
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 250), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));

  String get _phone =>
      widget.product.sellerPhone.replaceAll(RegExp(r'[^0-9+]'), '');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDE7DC),
      appBar: AppBar(
        backgroundColor: kMpOrange,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white24,
            child: Text(
              widget.product.sellerName.isNotEmpty
                  ? widget.product.sellerName[0].toUpperCase()
                  : '?',
              style: GoogleFonts.urbanist(
                  color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _myRole == 'buyer'
                      ? widget.product.sellerName
                      : (widget.buyerName ?? 'Acheteur'),
                  style: GoogleFonts.urbanist(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.product.title,
                  style: GoogleFonts.urbanist(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.85)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ]),
        actions: [
          if (_phone.isNotEmpty) ...[
            // WhatsApp
            IconButton(
              onPressed: () => launchUrl(
                Uri.parse('https://wa.me/$_phone'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Text('💬', style: TextStyle(fontSize: 18)),
              tooltip: 'WhatsApp',
            ),
            // Appel
            IconButton(
              onPressed: () => launchUrl(Uri.parse('tel:$_phone')),
              icon: const Icon(Icons.phone_rounded, color: Colors.white),
              tooltip: 'Appeler',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Product info mini-banner
          _ProductBanner(product: widget.product),

          // Messages
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('marketplace_chats')
                  .doc(_chatId)
                  .collection('messages')
                  .orderBy('time')
                  .snapshots(),
              builder: (_, snap) {
                if (snap.hasError) {
                  return const StreamErrorState(
                      message: "Impossible de charger les messages.");
                }
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(color: kMpOrange));
                }
                final docs = snap.data!.docs;

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollCtrl.hasClients &&
                      _scrollCtrl.position.pixels <
                          _scrollCtrl.position.maxScrollExtent) {
                    _scrollCtrl.animateTo(
                      _scrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    );
                  }
                });

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              size: 56, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text('Posez vos questions sur ce produit',
                              style: GoogleFonts.urbanist(color: Colors.grey)),
                        ]),
                  );
                }

                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final doc = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final isMine = data['sender'] == _myRole;
                    final type = data['type'] ?? 'text';

                    if (type == 'audio') {
                      return _AudioBubble(
                        msgId: doc.id,
                        data: data,
                        isMine: isMine,
                        isPlaying: _playingMsgId == doc.id &&
                            _playerState == PlayerState.playing,
                        position:
                            _playingMsgId == doc.id ? _playPos : Duration.zero,
                        onToggle: () =>
                            _togglePlay(doc.id, data['audioUrl'] ?? ''),
                      );
                    }
                    return _TextBubble(data: data, isMine: isMine);
                  },
                );
              },
            ),
          ),

          if (_uploading)
            LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: Colors.grey.shade200,
              color: kMpOrange,
            ),

          // Input bar
          _isRecording
              ? _RecordingBar(
                  seconds: _recordSecs,
                  onStop: _stopAndSend,
                  onCancel: _cancelRecording,
                )
              : _InputBar(
                  controller: _textCtrl,
                  onSend: _sendText,
                  onMicTap: _startRecording,
                ),
        ],
      ),
    );
  }
}

// ── Product mini-banner ────────────────────────────────────────────────────────
class _ProductBanner extends StatelessWidget {
  final MpProduct product;
  const _ProductBanner({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 44,
            child: product.images.isNotEmpty
                ? Image.network(product.images.first,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        color: const Color(0xFFF0F0F0),
                        child: const Icon(Icons.devices_rounded,
                            color: Color(0xFFBDBDBD), size: 20)))
                : Container(
                    color: const Color(0xFFF0F0F0),
                    child: const Icon(Icons.devices_rounded,
                        color: Color(0xFFBDBDBD), size: 20)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(product.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.urbanist(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1A1A2E))),
              Text(_fmt(product.price),
                  style: GoogleFonts.urbanist(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: kMpOrange)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ── Text bubble ────────────────────────────────────────────────────────────────
class _TextBubble extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isMine;
  const _TextBubble({required this.data, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final ts = data['time'] as Timestamp?;
    final timeStr = ts != null
        ? '${ts.toDate().hour.toString().padLeft(2, '0')}:${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '';

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: isMine ? kMpOrange : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMine ? 16 : 4),
            bottomRight: Radius.circular(isMine ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(data['text'] ?? '',
                style: TextStyle(
                    color: isMine ? Colors.white : Colors.black87,
                    fontSize: 14,
                    height: 1.4)),
            const SizedBox(height: 3),
            Text(timeStr,
                style: TextStyle(
                    fontSize: 10,
                    color: isMine
                        ? Colors.white.withValues(alpha: 0.7)
                        : Colors.grey)),
          ],
        ),
      ),
    );
  }
}

// ── Audio bubble ───────────────────────────────────────────────────────────────
class _AudioBubble extends StatelessWidget {
  final String msgId;
  final Map<String, dynamic> data;
  final bool isMine;
  final bool isPlaying;
  final Duration position;
  final VoidCallback onToggle;
  const _AudioBubble({
    required this.msgId,
    required this.data,
    required this.isMine,
    required this.isPlaying,
    required this.position,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final dur = (data['duration'] as num? ?? 0).toInt();
    final ts = data['time'] as Timestamp?;
    final timeStr = ts != null
        ? '${ts.toDate().hour.toString().padLeft(2, '0')}:${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '';
    final secs = position.inSeconds;
    final total = dur > 0 ? dur : 1;
    final progress = (secs / total).clamp(0.0, 1.0);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMine ? kMpOrange : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMine ? 16 : 4),
            bottomRight: Radius.circular(isMine ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))
          ],
        ),
        child: Column(children: [
          Row(children: [
            GestureDetector(
              onTap: onToggle,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.25)
                      : kMpOrange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: isMine ? Colors.white : kMpOrange,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: isMine
                        ? Colors.white.withValues(alpha: 0.3)
                        : const Color(0xFFEEEEEE),
                    color: isMine ? Colors.white : kMpOrange,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isPlaying ? '${secs}s / ${dur}s' : '${dur}s',
                    style: TextStyle(
                        fontSize: 10,
                        color: isMine
                            ? Colors.white.withValues(alpha: 0.8)
                            : Colors.grey),
                  ),
                ],
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: Text(timeStr,
                style: TextStyle(
                    fontSize: 9,
                    color: isMine
                        ? Colors.white.withValues(alpha: 0.7)
                        : Colors.grey)),
          ),
        ]),
      ),
    );
  }
}

// ── Input bar ──────────────────────────────────────────────────────────────────
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onMicTap;
  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onMicTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: controller,
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message...',
                  hintStyle:
                      GoogleFonts.urbanist(color: Colors.grey, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Mic button
          Semantics(
            label: 'Message vocal',
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onMicTap,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Color(0xFFEEEEEE),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic_rounded,
                    color: Color(0xFF555555), size: 22),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Send button
          Semantics(
            label: 'Envoyer le message',
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onSend,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: kMpOrange,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Recording bar ──────────────────────────────────────────────────────────────
class _RecordingBar extends StatelessWidget {
  final int seconds;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  const _RecordingBar({
    required this.seconds,
    required this.onStop,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SafeArea(
        top: false,
        child: Row(children: [
          // Cancel
          Semantics(
            label: 'Annuler l\'enregistrement vocal',
            button: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onCancel,
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFEBEE),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete_rounded,
                    color: Colors.red, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Recording indicator
          Expanded(
            child: Row(children: [
              const _PulsingDot(),
              const SizedBox(width: 8),
              Text('Enregistrement...',
                  style: GoogleFonts.urbanist(
                      fontSize: 13,
                      color: Colors.red,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.red),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          // Send voice
          GestureDetector(
            onTap: onStop,
            child: Container(
              width: 44,
              height: 44,
              decoration:
                  const BoxDecoration(color: kMpOrange, shape: BoxShape.circle),
              child:
                  const Icon(Icons.send_rounded, color: Colors.white, size: 20),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 10,
        height: 10,
        decoration:
            const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
      ),
    );
  }
}

String _fmt(int price) {
  if (price >= 1000000) {
    return '${(price / 1000000).toStringAsFixed(1).replaceAll('.0', '')} M FCFA';
  }
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} FCFA';
}
