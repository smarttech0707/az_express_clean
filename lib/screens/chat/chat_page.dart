import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../theme/app_theme.dart';

class ChatPage extends StatefulWidget {
  final String orderId;
  final String senderRole; // 'client' ou 'driver'
  const ChatPage(
      {super.key, required this.orderId, this.senderRole = 'client'});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Recording
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _uploading = false;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  // Playback
  final _player = AudioPlayer();
  String? _playingMsgId;
  PlayerState _playerState = PlayerState.stopped;
  Duration _playPos = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _playPos = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingMsgId = null;
          _playPos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  // ── RECORDING ────────────────────────────────────

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _snack("Permission microphone refusée");
        return;
      }
    }

    final dir = await getTemporaryDirectory();
    final path =
        "${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a";

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );

    _recordSeconds = 0;
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSeconds++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndSend() async {
    _recordTimer?.cancel();
    final duration = _recordSeconds;
    final path = await _recorder.stop();
    setState(() => _isRecording = false);

    if (path == null) {
      _snack("Enregistrement échoué");
      return;
    }
    if (duration < 1) return;

    await _uploadAudio(path, duration);
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recordSeconds = 0;
    });
  }

  Future<void> _uploadAudio(String path, int duration) async {
    setState(() => _uploading = true);
    try {
      final file = File(path);

      // Étape 1 : vérifier le fichier
      if (!file.existsSync() || file.lengthSync() == 0) {
        _snack("Fichier audio vide — réessayez");
        setState(() => _uploading = false);
        return;
      }

      // Étape 2 : lire les bytes
      final bytes = await file.readAsBytes();

      // Étape 3 : uploader
      final name = "voice_${DateTime.now().millisecondsSinceEpoch}.m4a";
      final ref =
          FirebaseStorage.instance.ref("chat_audio/${widget.orderId}/$name");

      final task =
          ref.putData(bytes, SettableMetadata(contentType: 'audio/mp4'));
      final snapshot = await task;

      if (snapshot.state != TaskState.success) {
        _snack("Upload Storage échoué (état: ${snapshot.state})");
        setState(() => _uploading = false);
        return;
      }

      // Étape 4 : récupérer l'URL
      final url = await ref.getDownloadURL();

      // Étape 5 : sauvegarder dans Firestore
      await FirebaseFirestore.instance
          .collection("chats")
          .doc(widget.orderId)
          .collection("messages")
          .add({
        "type": "audio",
        "audioUrl": url,
        "duration": duration,
        "sender": widget.senderRole,
        "time": Timestamp.now(),
      });
      _scrollToBottom();
    } on FirebaseException catch (e) {
      _snack("Erreur Firebase : ${e.code} — ${e.message}");
    } catch (e) {
      _snack("Erreur : $e");
    }
    if (mounted) setState(() => _uploading = false);
  }

  // ── TEXT ─────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await FirebaseFirestore.instance
        .collection("chats")
        .doc(widget.orderId)
        .collection("messages")
        .add({
      "type": "text",
      "text": text,
      "sender": widget.senderRole,
      "time": Timestamp.now(),
    });
    _scrollToBottom();
  }

  // ── PLAYBACK ──────────────────────────────────────

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

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
  }

  // ── BUILD ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDE7DC),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white24,
              child: Icon(Icons.delivery_dining, color: Colors.white, size: 18),
            ),
            SizedBox(width: 8),
            Text("Livreur", style: TextStyle(fontSize: 16)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection("chats")
                  .doc(widget.orderId)
                  .collection("messages")
                  .orderBy("time")
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "Impossible de charger les messages. Vérifiez votre connexion.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollCtrl.hasClients &&
                      _scrollCtrl.position.maxScrollExtent > 0) {
                    _scrollCtrl.animateTo(
                      _scrollCtrl.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  }
                });

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 56, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        const Text("Commencez la conversation",
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                  itemCount: docs.length,
                  itemBuilder: (ctx, i) {
                    final doc = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final isClient = data["sender"] == "client";
                    final type = data["type"] ?? "text";

                    if (type == "audio") {
                      return _AudioBubble(
                        msgId: doc.id,
                        data: data,
                        isClient: isClient,
                        isPlaying: _playingMsgId == doc.id &&
                            _playerState == PlayerState.playing,
                        position:
                            _playingMsgId == doc.id ? _playPos : Duration.zero,
                        onToggle: () =>
                            _togglePlay(doc.id, data["audioUrl"] ?? ""),
                      );
                    }
                    return _TextBubble(data: data, isClient: isClient);
                  },
                );
              },
            ),
          ),

          // Upload progress
          if (_uploading)
            LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: Colors.grey.shade200,
              color: AppColors.primary,
            ),

          // Input area
          _isRecording
              ? _RecordingBar(
                  seconds: _recordSeconds,
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

// ── TEXT BUBBLE ───────────────────────────────────────────────

class _TextBubble extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isClient;
  const _TextBubble({required this.data, required this.isClient});

  @override
  Widget build(BuildContext context) {
    final ts = data["time"] as Timestamp?;
    final date = ts?.toDate();
    final timeStr = date != null
        ? "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}"
        : "";

    return Align(
      alignment: isClient ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: isClient ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isClient ? 16 : 4),
            bottomRight: Radius.circular(isClient ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              data["text"] ?? "",
              style: TextStyle(
                color: isClient ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 2),
            Text(timeStr,
                style: TextStyle(
                    color: isClient ? Colors.white60 : Colors.grey,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── AUDIO BUBBLE ──────────────────────────────────────────────

class _AudioBubble extends StatelessWidget {
  final String msgId;
  final Map<String, dynamic> data;
  final bool isClient;
  final bool isPlaying;
  final Duration position;
  final VoidCallback onToggle;

  const _AudioBubble({
    required this.msgId,
    required this.data,
    required this.isClient,
    required this.isPlaying,
    required this.position,
    required this.onToggle,
  });

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return "${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final duration = (data["duration"] as num? ?? 0).toInt();
    final ts = data["time"] as Timestamp?;
    final date = ts?.toDate();
    final timeStr = date != null
        ? "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}"
        : "";

    final displaySecs = position.inSeconds > 0 ? position.inSeconds : duration;

    return Align(
      alignment: isClient ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.fromLTRB(10, 10, 12, 8),
        decoration: BoxDecoration(
          color: isClient ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isClient ? 16 : 4),
            bottomRight: Radius.circular(isClient ? 4 : 16),
          ),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isClient
                          ? Colors.white24
                          : AppColors.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: isClient ? Colors.white : AppColors.primary,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _WaveformBars(isClient: isClient, isPlaying: isPlaying),
                      const SizedBox(height: 4),
                      Text(
                        _fmt(displaySecs),
                        style: TextStyle(
                          color: isClient ? Colors.white70 : Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(timeStr,
                style: TextStyle(
                    color: isClient ? Colors.white60 : Colors.grey,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── WAVEFORM BARS ─────────────────────────────────────────────

class _WaveformBars extends StatefulWidget {
  final bool isClient;
  final bool isPlaying;
  const _WaveformBars({required this.isClient, required this.isPlaying});

  @override
  State<_WaveformBars> createState() => _WaveformBarsState();
}

class _WaveformBarsState extends State<_WaveformBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  static const _heights = [
    8.0,
    14.0,
    10.0,
    18.0,
    8.0,
    14.0,
    6.0,
    16.0,
    10.0,
    14.0,
    7.0,
    12.0,
    16.0,
    9.0,
    13.0,
  ];

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isClient ? Colors.white70 : Colors.grey.shade400;

    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: _heights.asMap().entries.map((e) {
            double h;
            if (widget.isPlaying) {
              final phase = (_anim.value + e.key * 0.12) % 1.0;
              h = e.value * (0.45 + 0.55 * phase);
            } else {
              h = e.value * 0.55;
            }
            return Container(
              width: 3,
              height: h.clamp(3.0, 20.0),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

// ── RECORDING BAR ─────────────────────────────────────────────

class _RecordingBar extends StatelessWidget {
  final int seconds;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  const _RecordingBar({
    required this.seconds,
    required this.onStop,
    required this.onCancel,
  });

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return "${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          8, 8, 8, 8 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
        ],
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
            tooltip: "Annuler",
          ),
          _BlinkingDot(),
          const SizedBox(width: 6),
          Text(
            _fmt(seconds),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 17,
              color: Colors.red,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text("Enregistrement...",
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          GestureDetector(
            onTap: onStop,
            child: Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ── INPUT BAR ─────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onMicTap;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onMicTap,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final has = widget.controller.text.isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          8, 8, 8, 8 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: widget.controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: "Message...",
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: _hasText
                ? GestureDetector(
                    key: const ValueKey("send"),
                    onTap: widget.onSend,
                    child: const _CircleBtn(
                        icon: Icons.send, color: AppColors.primary),
                  )
                : GestureDetector(
                    key: const ValueKey("mic"),
                    onTap: widget.onMicTap,
                    child: const _CircleBtn(
                        icon: Icons.mic, color: AppColors.primary),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _CircleBtn({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }
}
