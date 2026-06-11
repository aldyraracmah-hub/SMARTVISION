import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

// ════════════════════════════════════════════════════════════════════════════════
//  SMART VISION — AI Mobility Assistant untuk Tunanetra
//  Versi: 8.0 (Groq Vision API)
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │          KONSEP ALGORITMA PEMROGRAMAN YANG DIGUNAKAN                    │
//  ├─────────────────────────────────────────────────────────────────────────┤
//  │ 1. CLASS         → Tts, Stt, DetectedObj, SplashScreen, MainAppScreen  │
//  │    Membungkus data + fungsi dalam satu unit. Prinsip OOP (enkapsulasi).│
//  │                                                                         │
//  │ 2. ENUM          → Phase { greeting, listening, scanning, navigating…} │
//  │    Tipe data terbatas/terdefinisi. Mirip "struct" bernilai konstan.    │
//  │                                                                         │
//  │ 3. STRUCT/MODEL  → DetectedObj (label, side, distM, isDanger)          │
//  │    Record data immutable. Di Dart diimplementasi sebagai class.         │
//  │                                                                         │
//  │ 4. INHERITANCE   → State<T>, StatefulWidget, StatelessWidget            │
//  │    Kelas turunan mewarisi perilaku kelas induk (extends).               │
//  │                                                                         │
//  │ 5. ASYNC/AWAIT   → Semua fungsi Future<T> berjalan non-blocking.       │
//  │    Algoritma konkurensi: program tidak beku saat tunggu I/O.           │
//  │                                                                         │
//  │ 6. TIMER         → Timer.periodic untuk real-time scan background.     │
//  │    Algoritma event-driven: kode dijalankan secara berkala.             │
//  │                                                                         │
//  │ 7. MUTEX/FLAG    → _capturing bool mencegah double-capture race cond.  │
//  │    Algoritma sinkronisasi (mutual exclusion).                           │
//  │                                                                         │
//  │ 8. SORTING       → results.sort() urutkan objek dari terdekat.         │
//  │    Algoritma pengurutan (sort by ascending distance).                  │
//  │                                                                         │
//  │ 9. PATTERN MATCH → switch(cmd) untuk routing perintah suara.          │
//  │    Algoritma percabangan bersarang (multi-branch decision).             │
//  │                                                                         │
//  │10. OBSERVER      → WidgetsBindingObserver: lifecycle app dipantau.     │
//  │    Pola desain Observer (event pub-sub).                               │
//  └─────────────────────────────────────────────────────────────────────────┘
// ════════════════════════════════════════════════════════════════════════════════

// ─── Globals ──────────────────────────────────────────────────────────────────
List<CameraDescription> cameras = [];
String globalName = "", globalEmail = "", globalPassword = "";

const _kLoggedIn = 'sv_logged_in';
const _kName     = 'sv_name';
const _kEmail    = 'sv_email';
const _kPass     = 'sv_pass';

// ══════════════════════════════════════════════════════════════════════════════
// ⚠️  PENTING: Ganti value di bawah dengan API Key Groq kamu yang valid!
//    Ambil GRATIS dari: https://console.groq.com/keys  → Create API Key
//    Format key biasanya: gsk_... (panjang ~56 karakter)
//    Model vision: meta-llama/llama-4-scout-17b-16e-instruct
// ══════════════════════════════════════════════════════════════════════════════
const _kGroqApiKey = "";

// ─── Entry point ──────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { cameras = await availableCameras(); } catch (_) {}

  final prefs    = await SharedPreferences.getInstance();
  final loggedIn = prefs.getBool(_kLoggedIn) ?? false;
  if (loggedIn) {
    globalName     = prefs.getString(_kName)  ?? '';
    globalEmail    = prefs.getString(_kEmail) ?? '';
    globalPassword = prefs.getString(_kPass)  ?? '';
  }

  runApp(SmartVisionApp(skipToMain: loggedIn));
}

class SmartVisionApp extends StatelessWidget {
  final bool skipToMain;
  const SmartVisionApp({Key? key, required this.skipToMain}) : super(key: key);

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SmartVision',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      primaryColor: const Color(0xFF1E3A8A),
      scaffoldBackgroundColor: const Color(0xFF0A0F1E),
    ),
    home: SplashScreen(skipToMain: skipToMain),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// TTS (Text-To-Speech)
// ── KONSEP: CLASS + ENKAPSULASI ──────────────────────────────────────────────
// Class Tts membungkus (enkapsulasi) FlutterTts + state internal (_ready,
// _isSpeaking). Pengguna class ini tidak perlu tahu detail implementasi TTS —
// cukup panggil tts.speak("teks") atau tts.stop(). Ini adalah prinsip
// Information Hiding dalam OOP.
// ─────────────────────────────────────────────────────────────────────────────
// ════════════════════════════════════════════════════════════════════════════
class Tts {
  final FlutterTts _t = FlutterTts();
  bool _ready = false;
  bool _isSpeaking = false;

  Future<void> _init() async {
    if (_ready) return;
    try {
      await _t.setLanguage("id-ID");
      await _t.setSpeechRate(0.45);
      await _t.setVolume(1.0);
      await _t.setPitch(1.0);
      _ready = true;
    } catch (_) { _ready = true; }
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _init();
    if (_isSpeaking) {
      try { await _t.stop(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _isSpeaking = true;

    final done = Completer<void>();
    _t.setCompletionHandler(() { _isSpeaking = false; if (!done.isCompleted) done.complete(); });
    _t.setCancelHandler(()    { _isSpeaking = false; if (!done.isCompleted) done.complete(); });
    _t.setErrorHandler((_)   { _isSpeaking = false; if (!done.isCompleted) done.complete(); });

    try { await _t.speak(text); } catch (_) {
      _isSpeaking = false;
      if (!done.isCompleted) done.complete();
      return;
    }
    final ms = (text.length * 90).clamp(2000, 200000);
    try { await done.future.timeout(Duration(milliseconds: ms)); } catch (_) {}
    _isSpeaking = false;
    await Future.delayed(const Duration(milliseconds: 120));
  }

  Future<void> stop() async {
    _isSpeaking = false;
    try { await _t.stop(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 60));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STT
// ════════════════════════════════════════════════════════════════════════════
class Stt {
  final stt.SpeechToText _s = stt.SpeechToText();
  bool _inited = false;

  Future<bool> init() async {
    if (_inited) return true;
    for (int i = 0; i < 5; i++) {
      try {
        _inited = await _s.initialize(
          onError:  (e) => debugPrint("[STT err] ${e.errorMsg}"),
          onStatus: (s) => debugPrint("[STT] $s"),
        );
        if (_inited) return true;
      } catch (e) { debugPrint("[STT init] $e"); }
      await Future.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<String> listenOnce({
    required Tts tts,
    String prompt = "",
    Duration timeout = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
    String defaultVal = "",
    void Function(String)? onPartial,
    // Delay ekstra setelah TTS selesai sebelum STT mulai — cegah suara AI terdeteksi
    Duration postTtsDelay = const Duration(milliseconds: 1200),
  }) async {
    if (prompt.isNotEmpty) await tts.speak(prompt);
    // Tunggu TTS benar-benar selesai + buffer agar gema suara AI tidak masuk STT
    await Future.delayed(postTtsDelay);
    if (!await init()) return defaultVal;
    await _safeStop();
    await Future.delayed(const Duration(milliseconds: 400));

    final result = Completer<String>();
    String last = "";
    Timer? commit;
    // Tandai waktu mulai listen — tolak hasil yang muncul terlalu cepat (gema TTS)
    final startTime = DateTime.now();

    try {
      await _s.listen(
        localeId: "id-ID",
        partialResults: true,
        listenFor: timeout,
        pauseFor: pauseFor,
        onResult: (r) {
          if (r.recognizedWords.isEmpty) return;
          // Echo protection: abaikan hasil yang muncul < 800ms setelah listen dimulai
          if (DateTime.now().difference(startTime).inMilliseconds < 800) return;
          final w = r.recognizedWords.toLowerCase().trim();
          last = w;
          onPartial?.call(w);
          if (r.finalResult && w.isNotEmpty) {
            commit?.cancel();
            commit = Timer(const Duration(milliseconds: 600), () {
              if (!result.isCompleted) result.complete(w);
            });
          }
        },
      );
    } catch (e) { debugPrint("[STT listenOnce] $e"); }

    final val = await result.future
        .timeout(timeout + const Duration(seconds: 5), onTimeout: () => last);
    commit?.cancel();
    await _safeStop();
    final out = val.trim();
    return out.isEmpty ? defaultVal : out;
  }

  Future<void> listenStream({
    required void Function(String w, bool isFinal) onResult,
    Duration listenFor = const Duration(seconds: 20),
    Duration pauseFor  = const Duration(seconds: 5),
    Duration echoGuard = const Duration(milliseconds: 600),
  }) async {
    if (!await init()) return;
    await _safeStop();
    await Future.delayed(const Duration(milliseconds: 300));

    final done = Completer<void>();
    final startTime = DateTime.now();

    try {
      await _s.listen(
        localeId: "id-ID",
        partialResults: true,
        listenFor: listenFor,
        pauseFor:  pauseFor,
        onResult: (r) {
          if (r.recognizedWords.isEmpty) return;
          // Echo protection: abaikan hasil terlalu cepat setelah listen mulai
          if (DateTime.now().difference(startTime) < echoGuard) return;
          onResult(r.recognizedWords.toLowerCase().trim(), r.finalResult);
        },
      );
    } catch (e) { debugPrint("[STT stream] $e"); }

    Timer? checker;
    checker = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!_s.isListening) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    try {
      await done.future.timeout(listenFor + const Duration(seconds: 3));
    } catch (_) {}
    checker.cancel();
    await _safeStop();
  }

  Future<void> _safeStop() async {
    try { if (_s.isListening) await _s.stop(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 150));
  }

  Future<void> stop() => _safeStop();
  bool get isListening => _s.isListening;
}

// ════════════════════════════════════════════════════════════════════════════
// GROQ VISION
// ════════════════════════════════════════════════════════════════════════════

// ── KONSEP: STRUCT / DATA CLASS ──────────────────────────────────────────────
// DetectedObj adalah "struct" (record data murni) — hanya menyimpan data,
// tidak memiliki logika bisnis. Di Dart, struct direpresentasikan sebagai
// class dengan semua field final (immutable). Mirip struct di C/C++.
//
// Contoh di bahasa lain:
//   C:    struct DetectedObj { char label[50]; float distM; bool isDanger; };
//   Java: record DetectedObj(String label, double distM, boolean isDanger) {}
// ─────────────────────────────────────────────────────────────────────────────
class DetectedObj {
  final String label, side, distanceDesc;
  final double distM;
  final bool isDanger;
  // Constructor dengan named parameters — semua required (tidak ada default)
  const DetectedObj({
    required this.label, required this.side,
    required this.distanceDesc, required this.distM, required this.isDanger,
  });
}

const _dangerWords = [
  "tangga","lubang","got","selokan","parit","motor","mobil","truk","bus",
  "kendaraan","tiang","dinding kaca","stairs","car","truck","motorcycle",
  "vehicle","pole","bicycle","sepeda","rock","batu besar","lubang jalan",
  "api","genangan","jurang","tebing","listrik","kawat","pagar berduri",
];
bool _isDanger(String l) => _dangerWords.any((d) => l.toLowerCase().contains(d));

String _distStr(double d) {
  if (d < 1.0) return "${(d * 100).round()} sentimeter";
  return "${d.toStringAsFixed(1)} meter";
}

Future<List<DetectedObj>> detectWithGroq(String imagePath) async {
  // ── Validasi API key sebelum request ──────────────────────────────────────
  if (_kGroqApiKey.isEmpty ||
      _kGroqApiKey.startsWith("GANTI_") ||
      _kGroqApiKey.length < 20) {
    debugPrint("[Groq] ⚠️ API Key belum diset! Isi _kGroqApiKey dengan key valid dari console.groq.com");
    return [];
  }
  try {
    final imgFile = File(imagePath);
    if (!imgFile.existsSync()) { debugPrint("[Groq] File tidak ada: $imagePath"); return []; }
    final imgBytes = await imgFile.readAsBytes();
    if (imgBytes.isEmpty) { debugPrint("[Groq] File kosong"); return []; }
    final b64 = base64Encode(imgBytes);

    const prompt = """
Kamu adalah sistem navigasi AI untuk tunanetra. Analisis gambar ini dengan teliti.

Identifikasi SEMUA objek yang terlihat: manusia, hewan, kendaraan, furnitur, elektronik, makanan, tanaman, bangunan, rambu, jalan, trotoar, tangga, pintu, jendela, dinding, lantai, langit-langit, dan lain-lain.

Balas HANYA dengan JSON array (tanpa markdown, tanpa teks lain sama sekali):
[{"label":"nama objek","posisi":"kiri","jarak_meter":1.5,"bahaya":false}]

Aturan:
- label: nama dalam bahasa Indonesia (contoh: "kursi kayu", "pintu kaca", "motor merah")
- posisi: hanya "kiri", "tengah", atau "kanan"
- jarak_meter: estimasi jarak dalam meter antara 0.3 hingga 10.0
- bahaya: true jika bisa menyebabkan jatuh/cedera/tabrakan
- Minimal 1, maksimal 8 objek, urutkan dari terdekat ke terjauh
- Jika gelap/buram, tetap coba deteksi
- Jika benar-benar kosong: []
HANYA JSON array.""";

    // ── Model Groq Vision (LLaMA 4 Scout mendukung gambar) ───────────────────
    // Fallback ke model lain jika gagal
    final models = [
      "meta-llama/llama-4-scout-17b-16e-instruct",
      "meta-llama/llama-4-maverick-17b-128e-instruct",
    ];

    http.Response? resp;
    for (final model in models) {
      try {
        resp = await http.post(
          Uri.parse("https://api.groq.com/openai/v1/chat/completions"),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer $_kGroqApiKey",
          },
          body: jsonEncode({
            "model": model,
            "temperature": 0.1,
            "max_tokens": 1024,
            "messages": [
              {
                "role": "user",
                "content": [
                  {
                    "type": "image_url",
                    "image_url": {
                      "url": "data:image/jpeg;base64,$b64",
                    },
                  },
                  {
                    "type": "text",
                    "text": prompt,
                  },
                ],
              }
            ],
          }),
        ).timeout(const Duration(seconds: 30));

        if (resp.statusCode == 200) {
          debugPrint("[Groq] ✅ Model '$model' berhasil digunakan");
          break;
        } else if (resp.statusCode == 404 || resp.statusCode == 400) {
          debugPrint("[Groq] Model '$model' tidak tersedia (${resp.statusCode}), coba berikutnya...");
          resp = null;
          continue;
        } else {
          debugPrint("[Groq] HTTP ${resp.statusCode} dari '$model': ${resp.body.substring(0, min(300, resp.body.length))}");
          if (resp.statusCode == 401 || resp.statusCode == 403) break; // key salah, stop
          resp = null;
        }
      } catch (e) {
        debugPrint("[Groq] Error model '$model': $e");
        resp = null;
      }
    }

    if (resp == null || resp.statusCode != 200) {
      debugPrint("[Groq] ❌ Semua model gagal atau resp null");
      return [];
    }

    final data = jsonDecode(resp.body);
    String text = "";
    try {
      // Groq pakai format OpenAI: choices[0].message.content
      text = data["choices"][0]["message"]["content"] as String;
    } catch (e) {
      debugPrint("[Groq] Parse choices error: $e | body: ${resp.body.substring(0, min(300, resp.body.length))}");
      return [];
    }

    // Bersihkan JSON dari markdown dan teks liar
    text = text.trim()
        .replaceAll(RegExp(r'```json\s*'), '')
        .replaceAll(RegExp(r'```\s*'), '')
        .trim();

    // Ambil hanya bagian array JSON
    final startIdx = text.indexOf('[');
    final endIdx   = text.lastIndexOf(']');
    if (startIdx < 0 || endIdx <= startIdx) {
      debugPrint("[Groq] Tidak ada JSON array dalam respons: $text");
      return [];
    }
    text = text.substring(startIdx, endIdx + 1);

    List<dynamic> list;
    try {
      list = jsonDecode(text) as List;
    } catch (e) {
      debugPrint("[Groq] JSON decode error: $e | text: $text");
      return [];
    }

    final results = <DetectedObj>[];
    for (final item in list) {
      try {
        final label = (item["label"] as String?)?.trim() ?? "objek";
        if (label.isEmpty) continue;
        final posStr = (item["posisi"] as String? ?? "tengah").toLowerCase().trim();
        final distM  = (item["jarak_meter"] as num?)?.toDouble() ?? 3.0;
        final bahaya = item["bahaya"] as bool? ?? _isDanger(label);

        final side = posStr.contains("kiri")  ? "di sebelah kiri"
            : posStr.contains("kanan") ? "di sebelah kanan"
            : "tepat di depan Anda";

        results.add(DetectedObj(
          label: label, side: side,
          distanceDesc: _distStr(distM),
          distM: distM.clamp(0.1, 12.0),
          isDanger: bahaya || _isDanger(label),
        ));
      } catch (e) { debugPrint("[Groq] item parse error: $e"); }
    }

    // ── KONSEP: SORTING (Pengurutan) ──────────────────────────────────────
    // results.sort() mengurutkan list DetectedObj berdasarkan distM (jarak)
    // dari terdekat ke terjauh (ascending). Kompleksitas: O(n log n).
    // Penting agar objek berbahaya terdekat selalu diumumkan lebih dulu.
    // ─────────────────────────────────────────────────────────────────────
    results.sort((a, b) => a.distM.compareTo(b.distM));
    debugPrint("[Groq] Deteksi ${results.length} objek: ${results.map((r) => '${r.label}(${r.distM}m)').join(', ')}");
    return results;
  } catch (e) {
    debugPrint("[Groq] error: $e");
    return [];
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SPLASH
// ════════════════════════════════════════════════════════════════════════════
class SplashScreen extends StatefulWidget {
  final bool skipToMain;
  const SplashScreen({Key? key, required this.skipToMain}) : super(key: key);
  @override State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ac;
  late Animation<double> _fade, _scale;

  @override void initState() {
    super.initState();
    _ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _fade  = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOut));
    _scale = Tween<double>(begin: 0.7, end: 1).animate(CurvedAnimation(parent: _ac, curve: Curves.elasticOut));
    _ac.forward();
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(
        builder: (_) => widget.skipToMain ? const MainAppScreen() : const PermScreen(),
      ));
    });
  }

  @override void dispose() { _ac.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: RadialGradient(
        center: Alignment(0, -0.3), radius: 1.2,
        colors: [Color(0xFF1E3A8A), Color(0xFF0A0F1E)],
      )),
      child: Center(child: FadeTransition(opacity: _fade,
          child: ScaleTransition(scale: _scale,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: 100, height: 100,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF1E3A8A)]),
                      boxShadow: [BoxShadow(color: const Color(0xFF3B82F6).withOpacity(0.5), blurRadius: 30)]),
                  child: const Icon(Icons.visibility_rounded, size: 56, color: Colors.white)),
              const SizedBox(height: 28),
              const Text('SMART VISION', style: TextStyle(fontSize: 32,
                  fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 6)),
              const SizedBox(height: 8),
              const Text('AI Mobility Assistant', style: TextStyle(
                  color: Color(0xFF64748B), fontSize: 14, letterSpacing: 2)),
            ]),
          ))),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// PERM SCREEN — FIX: AI menjelaskan via suara, user jawab suara, popup jelas
// ════════════════════════════════════════════════════════════════════════════
class PermScreen extends StatefulWidget {
  const PermScreen({Key? key}) : super(key: key);
  @override State<PermScreen> createState() => _PermState();
}

class _PermState extends State<PermScreen> {
  final _tts = Tts();
  final _stt = Stt();
  bool _done = false, _started = false, _listening = false;
  String _status = "Mempersiapkan...";
  bool _showManualBtn = false;
  int _attemptCount = 0;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) { _started = true; _run(); }
    });
  }

  Future<void> _run() async {
    if (!mounted) return;
    setState(() => _status = "AI menjelaskan izin...");
    await _stt.init();

    // === Penjelasan AI via suara ===
    await _tts.speak(
        "Halo! Selamat datang di Smart Vision. "
            "Saya adalah asisten mobilitas berbasis kecerdasan buatan yang akan membantu Anda bernavigasi dengan aman."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Aplikasi ini membutuhkan tiga izin untuk bekerja. "
            "Pertama, izin kamera untuk mendeteksi objek di sekitar Anda. "
            "Kedua, izin mikrofon agar Anda bisa memberi perintah suara. "
            "Ketiga, izin lokasi untuk membuka navigasi Google Maps."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Setelah Anda menekan tombol izinkan, "
            "Android akan menampilkan popup izin satu per satu. "
            "Pada setiap popup, cari dan ketuk tombol bertuliskan IZINKAN atau ALLOW. "
            "Posisi tombol IZINKAN berbeda-beda tergantung merek dan versi Android Anda, "
            "biasanya berada di bagian bawah popup. "
            "Pastikan Anda memilih IZINKAN atau ALLOW, bukan TOLAK atau DENY."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Khusus untuk izin lokasi, pilih opsi "
            "Izinkan hanya saat menggunakan aplikasi, "
            "agar Google Maps bisa mendeteksi posisi Anda saat navigasi."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Apakah Anda siap? Ucapkan IYA atau IZINKAN, "
            "atau sentuh tombol biru besar IZINKAN DAN MULAI di bawah layar."
    );
    if (!mounted || _done) return;

    setState(() { _status = "🎙 Ucapkan IYA atau IZINKAN"; _listening = true; });

    // Tampilkan tombol manual setelah 4 detik
    Future.delayed(const Duration(seconds: 4), () {
      if (!_done && mounted) {
        setState(() => _showManualBtn = true);
        _tts.speak(
            "Jika belum terdengar, tombol IZINKAN DAN MULAI ada di bagian bawah layar. Warnanya biru besar."
        );
      }
    });

    bool got = false;
    while (!_done && !got && _attemptCount < 4) {
      _attemptCount++;
      await _stt.listenStream(
        listenFor: const Duration(seconds: 15),
        pauseFor:  const Duration(seconds: 5),
        onResult: (w, isFinal) {
          if (got || _done || !mounted) return;
          if (mounted) setState(() => _status = "Terdengar: \"$w\"");
          if (w.contains("iya") || w.contains("ya") || w.contains("izin") ||
              w.contains("lanjut") || w.contains("oke") || w.contains("ok") ||
              w.contains("boleh") || w.contains("mulai") || w.contains("setuju") ||
              w.contains("siap") || w.contains("bisa")) {
            got = true;
            _stt.stop();
            _proceed();
          }
        },
      );
      if (_done || got) break;
      if (_attemptCount < 4 && !_done) {
        if (_attemptCount == 1) {
          await _tts.speak("Belum terdengar. Ucapkan IYA dengan lebih keras.");
        } else if (_attemptCount == 2) {
          await _tts.speak("Coba lagi. Ucapkan IZINKAN.");
        } else {
          await _tts.speak(
              "Silakan sentuh tombol biru IZINKAN DAN MULAI di bagian bawah layar."
          );
        }
      }
    }

    if (!_done && !got && mounted) {
      setState(() { _listening = false; _status = "Sentuh tombol biru di bawah ini"; });
    }
  }

  Future<void> _proceed() async {
    if (_done) return;
    _done = true;
    if (mounted) setState(() { _listening = false; _status = "Meminta izin..."; });
    await _tts.stop();
    await _stt.stop();

    // Request semua izin — Android akan tampilkan popup satu per satu
    await _tts.speak(
        "Baik. Sebentar lagi muncul popup izin dari Android. "
            "Pilih IZINKAN atau ALLOW pada setiap popup yang muncul."
    );

    await [Permission.camera, Permission.microphone, Permission.location].request();
    if (!mounted) return;

    await _tts.speak("Terima kasih. Selamat datang di Smart Vision!");
    if (mounted) Navigator.pushReplacement(
      context, MaterialPageRoute(builder: (_) => const WelcomeScreen()),
    );
  }

  @override void dispose() { _done = true; _tts.stop(); _stt.stop(); super.dispose(); }

  @override Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: LinearGradient(
        colors: [Color(0xFF0A0F1E), Color(0xFF0F2040)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
      )),
      child: SafeArea(child: SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(children: [
          const SizedBox(height: 20),
          Container(width: 80, height: 80,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: const Color(0xFF1E3A8A).withOpacity(0.3),
                  border: Border.all(color: const Color(0xFF3B82F6), width: 2)),
              child: const Icon(Icons.security_rounded, size: 40, color: Color(0xFF60A5FA))),
          const SizedBox(height: 20),
          const Text("IZIN APLIKASI", style: TextStyle(color: Colors.white,
              fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 6),
          const Text("Smart Vision membutuhkan akses berikut:",
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          // Popup info Android
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.4))),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFFF59E0B), size: 20),
              SizedBox(width: 10),
              Expanded(child: Text(
                  "Setelah menekan tombol, Android akan menampilkan POPUP izin satu per satu.\n"
                      "Pilih IZINKAN / ALLOW pada setiap popup.",
                  style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11, height: 1.5))),
            ]),
          ),
          ...[
            [Icons.camera_alt_rounded,  "Kamera Belakang", "Deteksi objek AI secara real-time"],
            [Icons.mic_rounded,         "Mikrofon",        "Perintah suara hands-free"],
            [Icons.location_on_rounded, "Lokasi GPS",      "Navigasi via Google Maps"],
          ].map((item) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1))),
            child: Row(children: [
              Icon(item[0] as IconData, color: const Color(0xFF60A5FA), size: 22),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item[1] as String, style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                Text(item[2] as String, style: const TextStyle(
                    color: Colors.white54, fontSize: 11)),
              ])),
            ]),
          )),
          const SizedBox(height: 16),
          // Status box
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
                color: _listening
                    ? const Color(0xFF064E3B).withOpacity(0.6)
                    : const Color(0xFF1E3A8A).withOpacity(0.3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: _listening ? const Color(0xFF10B981) : const Color(0xFF3B82F6))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(_listening ? Icons.mic : Icons.volume_up,
                  color: _listening ? const Color(0xFF10B981) : const Color(0xFF60A5FA), size: 16),
              const SizedBox(width: 8),
              Flexible(child: Text(_status, textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _listening ? const Color(0xFF10B981) : const Color(0xFF93C5FD),
                      fontSize: 12, fontWeight: FontWeight.w600))),
            ]),
          ),
          const SizedBox(height: 20),
          // Tombol utama — selalu tampil
          GestureDetector(
            onTap: _proceed,
            child: Container(width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 22),
              decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)]),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(
                      color: const Color(0xFF3B82F6).withOpacity(0.4),
                      blurRadius: 16, offset: const Offset(0, 6))]),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.check_circle_outline, color: Colors.white, size: 24),
                SizedBox(width: 10),
                Text("IZINKAN DAN MULAI", style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w900,
                    fontSize: 18, letterSpacing: 1.5)),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          const Text("Atau ucapkan \"IYA\" / \"IZINKAN\"",
              style: TextStyle(color: Color(0xFF4B5563), fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 20),
        ]),
      ))),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// WELCOME SCREEN — FIX: Loop STT tidak pernah berhenti sampai user pilih
// ════════════════════════════════════════════════════════════════════════════
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({Key? key}) : super(key: key);
  @override State<WelcomeScreen> createState() => _WelcomeState();
}

class _WelcomeState extends State<WelcomeScreen> with TickerProviderStateMixin {
  final _tts = Tts();
  final _stt = Stt();
  bool _listening = false, _done = false, _started = false, _showHint = false;
  String _statusText = "AI sedang berbicara...";
  late AnimationController _pulse;
  late Animation<double> _pulseAnim;
  int _loopCount = 0;

  @override void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) { _started = true; _start(); }
    });
  }

  Future<void> _start() async {
    await _stt.init();

    // === AI jelaskan halaman dan posisi tombol DULU ===
    await _tts.speak(
        "Selamat datang di Smart Vision. Ini adalah halaman utama."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Di layar ada dua tombol besar. "
            "Tombol di sebelah KIRI adalah tombol DAFTAR, untuk membuat akun baru. "
            "Tombol di sebelah KANAN adalah tombol MASUK, untuk masuk jika sudah punya akun."
    );
    if (!mounted || _done) return;

    await _tts.speak(
        "Anda bisa menyentuh salah satu tombol tersebut, "
            "atau cukup ucapkan DAFTAR jika ingin membuat akun baru, "
            "atau ucapkan MASUK jika sudah punya akun."
    );
    if (!mounted || _done) return;

    setState(() { _listening = true; _statusText = "🎙 Ucapkan DAFTAR atau MASUK"; });

    // Tampilkan hint tombol setelah 5 detik
    Future.delayed(const Duration(seconds: 5), () {
      if (!_done && mounted) setState(() => _showHint = true);
    });

    _listenLoop();
  }

  Future<void> _listenLoop() async {
    while (!_done && mounted) {
      _loopCount++;
      bool handled = false;

      await _stt.listenStream(
        listenFor: const Duration(seconds: 15),
        pauseFor:  const Duration(seconds: 5),
        onResult: (w, isFinal) {
          if (handled || _done || !mounted) return;
          if (mounted) setState(() => _statusText = "Terdengar: \"$w\"");

          if (w.contains("daftar") || w.contains("register") ||
              w.contains("buat") || w.contains("dafter") || w.contains("signup")) {
            handled = true; _done = true;
            _stt.stop(); _tts.stop();
            if (mounted) { setState(() => _listening = false); _nav(const SignUpScreen()); }
          } else if (w.contains("masuk") || w.contains("login") ||
              w.contains("sign") || w.contains("masu") || w.contains("sudah")) {
            handled = true; _done = true;
            _stt.stop(); _tts.stop();
            if (mounted) { setState(() => _listening = false); _nav(const SignInScreen()); }
          }
        },
      );

      if (_done || !mounted) break;
      await Future.delayed(const Duration(milliseconds: 300));

      if (!_done && mounted) {
        setState(() => _statusText = "🎙 Ucapkan DAFTAR atau MASUK");
        // Reminder setiap 2 loop
        if (_loopCount % 2 == 0) {
          await _tts.speak("Ucapkan DAFTAR untuk akun baru, atau MASUK jika sudah punya akun.");
          if (!mounted || _done) break;
        }
      }
    }
  }

  void _nav(Widget w) {
    if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => w));
  }

  @override void dispose() {
    _done = true;
    _pulse.dispose();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  @override Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: LinearGradient(
        colors: [Color(0xFF0A0F1E), Color(0xFF0F2040)],
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
      )),
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(children: [
          const SizedBox(height: 30),
          Container(padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    const Color(0xFF3B82F6).withOpacity(0.3),
                    const Color(0xFF1E3A8A).withOpacity(0.3),
                  ]),
                  border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.5), width: 2)),
              child: const Icon(Icons.accessibility_new_rounded, size: 60, color: Color(0xFF60A5FA))),
          const SizedBox(height: 20),
          const Text('Smart Vision', style: TextStyle(fontSize: 36,
              fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -1)),
          const SizedBox(height: 8),
          const Text('Asisten mobilitas AI\ndeteksi spasial & perintah suara',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 14, height: 1.6),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          // Status box
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
                color: _listening
                    ? const Color(0xFF064E3B).withOpacity(0.6)
                    : const Color(0xFF1E3A8A).withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _listening ? const Color(0xFF10B981).withOpacity(0.5)
                        : const Color(0xFF3B82F6).withOpacity(0.5))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ScaleTransition(scale: _pulseAnim, child: Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                      color: _listening ? const Color(0xFF10B981) : const Color(0xFF3B82F6),
                      shape: BoxShape.circle))),
              const SizedBox(width: 10),
              Flexible(child: Text(_statusText,
                  style: TextStyle(
                      color: _listening ? const Color(0xFF10B981) : const Color(0xFF93C5FD),
                      fontSize: 12, fontWeight: FontWeight.w600))),
            ]),
          ),
          if (_showHint) ...[
            const SizedBox(height: 8),
            Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.4))),
                child: const Text("💡 Tombol DAFTAR & MASUK ada di bawah — sentuh untuk memilih",
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11),
                    textAlign: TextAlign.center)),
          ],
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: GestureDetector(
              onTap: () {
                _done = true; _tts.stop(); _stt.stop();
                Future.delayed(const Duration(milliseconds: 200), () {
                  if (mounted) _nav(const SignUpScreen());
                });
              },
              child: Container(height: 150,
                decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF1D4ED8), Color(0xFF1E3A8A)]),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(
                        color: const Color(0xFF1D4ED8).withOpacity(0.4),
                        blurRadius: 20, offset: const Offset(0, 8))]),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.person_add_rounded, size: 40, color: Colors.white),
                  SizedBox(height: 10),
                  Text('DAFTAR', style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 2)),
                  SizedBox(height: 2),
                  Text('Buat akun baru', style: TextStyle(color: Colors.white60, fontSize: 12)),
                ]),
              ),
            )),
            const SizedBox(width: 16),
            Expanded(child: GestureDetector(
              onTap: () {
                _done = true; _tts.stop(); _stt.stop();
                Future.delayed(const Duration(milliseconds: 200), () {
                  if (mounted) _nav(const SignInScreen());
                });
              },
              child: Container(height: 150,
                decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF3B82F6), width: 2)),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.login_rounded, size: 40, color: Color(0xFF60A5FA)),
                  SizedBox(height: 10),
                  Text('MASUK', style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 2)),
                  SizedBox(height: 2),
                  Text('Sudah punya akun', style: TextStyle(color: Colors.white60, fontSize: 12)),
                ]),
              ),
            )),
          ]),
          const Spacer(),
          const Text("Ucapkan 'DAFTAR' atau 'MASUK'",
              style: TextStyle(color: Color(0xFF334155), fontSize: 11),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
        ]),
      )),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// SIGN UP — via suara, field diisi otomatis
// ════════════════════════════════════════════════════════════════════════════
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({Key? key}) : super(key: key);
  @override State<SignUpScreen> createState() => _SignUpState();
}

class _SignUpState extends State<SignUpScreen> with SingleTickerProviderStateMixin {
  final _nCtrl = TextEditingController();
  final _eCtrl = TextEditingController();
  final _pCtrl = TextEditingController();
  final _tts   = Tts();
  final _stt   = Stt();
  int  _step = 0;
  bool _listening = false, _done = false, _started = false;
  late AnimationController _prog;

  @override void initState() {
    super.initState();
    _prog = AnimationController(vsync: this, duration: const Duration(seconds: 25));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) { _started = true; _run(); }
    });
  }

  Future<void> _run() async {
    await _stt.init();

    // Step 0: Nama
    if (!mounted || _done) return;
    setState(() { _step = 0; _listening = false; }); _prog.reset(); _prog.forward();
    String name = "";
    for (int retry = 0; retry < 3 && name.isEmpty && mounted && !_done; retry++) {
      final prompt = retry == 0
          ? "Halaman pendaftaran. Sebutkan nama lengkap Anda dengan jelas."
          : "Maaf, belum terdengar. Sebutkan nama lengkap Anda sekali lagi.";
      name = await _stt.listenOnce(
        tts: _tts, prompt: prompt,
        timeout: const Duration(seconds: 35), pauseFor: const Duration(seconds: 6),
        defaultVal: "",
        onPartial: (w) { if (mounted) setState(() { _listening = true; _nCtrl.text = w; }); },
      );
    }
    if (name.isEmpty) name = "Pengguna";
    if (!mounted || _done) return;
    globalName = name;
    setState(() { _nCtrl.text = name; _listening = false; });
    await _tts.speak("Nama $name tersimpan.");

    // Step 1: Email
    if (!mounted || _done) return;
    setState(() { _step = 1; _listening = false; }); _prog.reset(); _prog.forward();
    String email = "";
    for (int retry = 0; retry < 3 && email.isEmpty && mounted && !_done; retry++) {
      final prompt = retry == 0
          ? "Sekarang sebutkan alamat email Anda. Misalnya: nama, lalu ketik sendiri tanda at, lalu gmail, lalu titik, lalu com. Tunggu bunyi beep lalu ucapkan email Anda."
          : "Belum terdengar. Sebutkan email Anda sekali lagi setelah bunyi beep.";
      email = await _stt.listenOnce(
        tts: _tts, prompt: prompt,
        timeout: const Duration(seconds: 35), pauseFor: const Duration(seconds: 6),
        defaultVal: "",
        // Delay panjang agar suara AI tidak ikut terdeteksi sebagai input email
        postTtsDelay: const Duration(milliseconds: 2000),
        onPartial: (w) { if (mounted) setState(() {
          _listening = true;
          // Konversi ucapan ke format email: "at" -> "@", "dot" -> ".", "titik" -> "."
          _eCtrl.text = _parseEmailInput(w);
        }); },
      );
      // Konversi hasil akhir
      if (email.isNotEmpty) email = _parseEmailInput(email);
    }
    if (email.isEmpty) email = "user@email.com";
    if (!mounted || _done) return;
    globalEmail = email.toLowerCase();
    setState(() { _eCtrl.text = globalEmail; _listening = false; });
    await _tts.speak("Email tersimpan.");

    // Step 2: Password
    if (!mounted || _done) return;
    setState(() { _step = 2; _listening = false; }); _prog.reset(); _prog.forward();
    String pass = "";
    for (int retry = 0; retry < 3 && pass.isEmpty && mounted && !_done; retry++) {
      final prompt = retry == 0
          ? "Terakhir, sebutkan kata sandi yang ingin Anda gunakan. Misalnya angka atau kata."
          : "Belum terdengar. Sebutkan kata sandi sekali lagi.";
      pass = await _stt.listenOnce(
        tts: _tts, prompt: prompt,
        timeout: const Duration(seconds: 35), pauseFor: const Duration(seconds: 6),
        defaultVal: "",
        onPartial: (w) { if (mounted) setState(() { _listening = true; _pCtrl.text = w; }); },
      );
    }
    if (pass.isEmpty) pass = "123456";
    if (!mounted || _done) return;
    globalPassword = pass;
    setState(() { _pCtrl.text = pass; _listening = false; });
    _done = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, true);
    await prefs.setString(_kName,  globalName);
    await prefs.setString(_kEmail, globalEmail);
    await prefs.setString(_kPass,  globalPassword);

    await _tts.speak("Pendaftaran berhasil, $globalName. Memulai panduan fitur Smart Vision.");
    if (mounted) Navigator.pushReplacement(
      context, MaterialPageRoute(builder: (_) => const DemoScreen()),
    );
  }

  @override void dispose() {
    _done = true; _prog.dispose(); _tts.stop(); _stt.stop();
    _nCtrl.dispose(); _eCtrl.dispose(); _pCtrl.dispose();
    super.dispose();
  }

  // Konversi ucapan ke format email: "at" -> "@", "dot/titik" -> "."
  String _parseEmailInput(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(' at ', '@')
        .replaceAll(' at', '@')
        .replaceAll('at ', '@')
        .replaceAll(' dot ', '.')
        .replaceAll(' dot', '.')
        .replaceAll('dot ', '.')
        .replaceAll(' titik ', '.')
        .replaceAll(' titik', '.')
        .replaceAll('titik ', '.')
        .replaceAll(' underscore ', '_')
        .replaceAll(' garis bawah ', '_')
        .replaceAll(RegExp(r'\s+'), '');
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {bool obs = false, required bool active, required bool done}) =>
      AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
              color: active ? const Color(0xFF1E3A8A).withOpacity(0.15)
                  : done ? const Color(0xFF064E3B).withOpacity(0.1)
                  : Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: active ? const Color(0xFF3B82F6)
                      : done ? const Color(0xFF10B981).withOpacity(0.5)
                      : Colors.white.withOpacity(0.08),
                  width: active ? 2 : 1)),
          child: TextField(
              controller: c, obscureText: obs, readOnly: true,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                  labelText: label,
                  labelStyle: TextStyle(
                      color: active ? const Color(0xFF60A5FA) : const Color(0xFF4B5563)),
                  prefixIcon: Icon(icon, color: active
                      ? const Color(0xFF3B82F6) : done
                      ? const Color(0xFF10B981) : const Color(0xFF374151)),
                  suffixIcon: done
                      ? const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981))
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16))));

  @override Widget build(BuildContext context) {
    final labels = ["Nama", "Email", "Password"];
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(
            colors: [Color(0xFF0A0F1E), Color(0xFF0F2040)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              GestureDetector(
                  onTap: () { _done = true; _tts.stop(); _stt.stop(); Navigator.pop(context); },
                  child: Container(padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18))),
              const SizedBox(width: 16),
              const Text("BUAT AKUN", style: TextStyle(fontSize: 22,
                  fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2)),
            ]),
            const SizedBox(height: 8),
            const Text("Sistem mengisi otomatis via suara Anda",
                style: TextStyle(color: Color(0xFF4B5563), fontSize: 13)),
            const SizedBox(height: 20),
            // Step indicator
            Row(children: List.generate(3, (i) {
              final a = i == _step, d = i < _step;
              return Expanded(child: Container(
                  margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                  child: Column(children: [
                    AnimatedContainer(duration: const Duration(milliseconds: 400), height: 4,
                        decoration: BoxDecoration(
                            color: a ? const Color(0xFF3B82F6)
                                : d ? const Color(0xFF10B981)
                                : Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(2))),
                    const SizedBox(height: 6),
                    Text(labels[i], style: TextStyle(
                        color: a ? const Color(0xFF60A5FA)
                            : d ? const Color(0xFF10B981)
                            : const Color(0xFF374151),
                        fontSize: 11, fontWeight: FontWeight.w600)),
                  ])));
            })),
            const SizedBox(height: 16),
            // STT status
            Container(padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFF1E3A8A).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.4))),
                child: Row(children: [
                  AnimatedContainer(duration: const Duration(milliseconds: 300),
                      width: 42, height: 42,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          color: _listening
                              ? Colors.redAccent.withOpacity(0.2)
                              : const Color(0xFF1E3A8A).withOpacity(0.4),
                          border: Border.all(
                              color: _listening ? Colors.redAccent : const Color(0xFF3B82F6), width: 2)),
                      child: Center(child: Icon(
                          _listening ? Icons.mic : Icons.mic_off,
                          color: _listening ? Colors.redAccent : const Color(0xFF3B82F6), size: 20))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        _listening
                            ? "🎙 Mendengarkan ${labels[_step.clamp(0,2)]}..."
                            : "⏳ AI sedang berbicara...",
                        style: const TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 5),
                    AnimatedBuilder(animation: _prog, builder: (_, __) => Stack(children: [
                      Container(height: 4, decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(2))),
                      FractionallySizedBox(widthFactor: 1 - _prog.value,
                          child: Container(height: 4, decoration: BoxDecoration(
                              color: const Color(0xFF3B82F6),
                              borderRadius: BorderRadius.circular(2)))),
                    ])),
                  ])),
                ])),
            const SizedBox(height: 18),
            _field(_nCtrl, "Nama Lengkap", Icons.person_outline_rounded,
                active: _step == 0, done: _step > 0),
            _field(_eCtrl, "Alamat Email",  Icons.mail_outline_rounded,
                active: _step == 1, done: _step > 1),
            _field(_pCtrl, "Kata Sandi",    Icons.lock_outline_rounded,
                obs: true, active: _step == 2, done: false),
          ]),
        )),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SIGN IN — via suara
// ════════════════════════════════════════════════════════════════════════════
class SignInScreen extends StatefulWidget {
  const SignInScreen({Key? key}) : super(key: key);
  @override State<SignInScreen> createState() => _SignInState();
}

class _SignInState extends State<SignInScreen> with SingleTickerProviderStateMixin {
  final _eCtrl = TextEditingController();
  final _pCtrl = TextEditingController();
  final _tts   = Tts();
  final _stt   = Stt();
  int  _step = 0;
  bool _listening = false, _done = false, _started = false;
  late AnimationController _prog;

  @override void initState() {
    super.initState();
    _prog = AnimationController(vsync: this, duration: const Duration(seconds: 25));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) { _started = true; _run(); }
    });
  }

  Future<void> _run() async {
    await _stt.init();

    if (!mounted || _done) return;
    setState(() { _step = 0; _listening = false; }); _prog.reset(); _prog.forward();
    final email = await _stt.listenOnce(
      tts: _tts, prompt: "Halaman masuk. Sebutkan email Anda.",
      timeout: const Duration(seconds: 30), pauseFor: const Duration(seconds: 5),
      defaultVal: "user@email.com",
      onPartial: (w) { if (mounted) setState(() {
        _listening = true; _eCtrl.text = w.replaceAll(' ', '').toLowerCase();
      }); },
    );
    if (!mounted || _done) return;
    globalEmail = email.replaceAll(' ', '').toLowerCase();
    setState(() { _eCtrl.text = globalEmail; _listening = false; });
    await _tts.speak("Email tersimpan.");

    if (!mounted || _done) return;
    setState(() { _step = 1; _listening = false; }); _prog.reset(); _prog.forward();
    final pass = await _stt.listenOnce(
      tts: _tts, prompt: "Sekarang sebutkan kata sandi Anda.",
      timeout: const Duration(seconds: 30), pauseFor: const Duration(seconds: 5),
      defaultVal: "123456",
      onPartial: (w) { if (mounted) setState(() { _listening = true; _pCtrl.text = w; }); },
    );
    if (!mounted || _done) return;
    globalPassword = pass;
    setState(() { _pCtrl.text = pass; _listening = false; });
    _done = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, true);
    await prefs.setString(_kEmail, globalEmail);
    await prefs.setString(_kPass,  globalPassword);

    await _tts.speak("Login berhasil. Memulai panduan fitur Smart Vision.");
    if (mounted) Navigator.pushReplacement(
      context, MaterialPageRoute(builder: (_) => const DemoScreen()),
    );
  }

  @override void dispose() {
    _done = true; _prog.dispose(); _tts.stop(); _stt.stop();
    _eCtrl.dispose(); _pCtrl.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final eA = _step == 0, eD = _step > 0;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(
            colors: [Color(0xFF0A0F1E), Color(0xFF0F2040)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: SafeArea(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              GestureDetector(
                  onTap: () { _done = true; _tts.stop(); _stt.stop(); Navigator.pop(context); },
                  child: Container(padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18))),
              const SizedBox(width: 16),
              const Text("MASUK AKUN", style: TextStyle(fontSize: 22,
                  fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2)),
            ]),
            const SizedBox(height: 32),
            Center(child: Container(width: 80, height: 80,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: const Color(0xFF1E3A8A).withOpacity(0.3),
                    border: Border.all(color: const Color(0xFF3B82F6), width: 2)),
                child: const Icon(Icons.lock_open_rounded, size: 40, color: Color(0xFF60A5FA)))),
            const SizedBox(height: 24),
            Container(padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFF1E3A8A).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.4))),
                child: Row(children: [
                  Container(width: 42, height: 42,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          color: _listening ? Colors.redAccent.withOpacity(0.2) : const Color(0xFF1E3A8A),
                          border: Border.all(
                              color: _listening ? Colors.redAccent : const Color(0xFF3B82F6))),
                      child: Icon(_listening ? Icons.mic : Icons.mic_off,
                          color: _listening ? Colors.redAccent : const Color(0xFF3B82F6), size: 20)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        _listening
                            ? "🎙 Mendengar ${_step == 0 ? 'Email' : 'Password'}..."
                            : "⏳ AI sedang berbicara...",
                        style: const TextStyle(color: Colors.white,
                            fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 5),
                    AnimatedBuilder(animation: _prog, builder: (_, __) => Stack(children: [
                      Container(height: 4, decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(2))),
                      FractionallySizedBox(widthFactor: 1 - _prog.value,
                          child: Container(height: 4, decoration: BoxDecoration(
                              color: const Color(0xFF3B82F6),
                              borderRadius: BorderRadius.circular(2)))),
                    ])),
                  ])),
                ])),
            const SizedBox(height: 20),
            AnimatedContainer(duration: const Duration(milliseconds: 400),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                    color: eA ? const Color(0xFF1E3A8A).withOpacity(0.15)
                        : eD ? const Color(0xFF064E3B).withOpacity(0.1)
                        : Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: eA ? const Color(0xFF3B82F6)
                            : eD ? const Color(0xFF10B981).withOpacity(0.5)
                            : Colors.white.withOpacity(0.08))),
                child: TextField(controller: _eCtrl, readOnly: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                        labelText: "Email",
                        labelStyle: const TextStyle(color: Color(0xFF60A5FA)),
                        prefixIcon: const Icon(Icons.mail_outline_rounded, color: Color(0xFF3B82F6)),
                        suffixIcon: eD ? const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981)) : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16)))),
            AnimatedContainer(duration: const Duration(milliseconds: 400),
                decoration: BoxDecoration(
                    color: !eA ? const Color(0xFF1E3A8A).withOpacity(0.15) : Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: !eA ? const Color(0xFF3B82F6) : Colors.white.withOpacity(0.08))),
                child: TextField(controller: _pCtrl, obscureText: true, readOnly: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                        labelText: "Password",
                        labelStyle: TextStyle(color: Color(0xFF60A5FA)),
                        prefixIcon: Icon(Icons.lock_outline_rounded, color: Color(0xFF3B82F6)),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 18, horizontal: 16)))),
          ]),
        )),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DEMO SCREEN — FIX: Auto-advance tidak skip, AI bicara penuh dulu
// ════════════════════════════════════════════════════════════════════════════
class DemoScreen extends StatefulWidget {
  const DemoScreen({Key? key}) : super(key: key);
  @override State<DemoScreen> createState() => _DemoState();
}

class _DemoState extends State<DemoScreen> with SingleTickerProviderStateMixin {
  final _tts = Tts();
  final _stt = Stt();
  int  _step    = 1;
  bool _done    = false, _speaking = false, _started = false;
  late AnimationController _slide;

  // icon disimpan sebagai codePoint Icons.xxx.codePoint agar tidak salah render
  static const _stepsData = [
    {
      "title": "DETEKSI OBJEK AI",
      // Icons.camera_rear_rounded  codePoint = 0xf4fa
      "iconCode": 0xf4fa, "fontFamily": "MaterialIcons",
      "colorVal": 0xFF3B82F6,
      "pos": "Scan realtime via Groq AI",
      "lines": [
        "Fitur pertama adalah Deteksi Objek dengan Groq AI.",
        "Kamera belakang memindai objek nyata di sekitar Anda setiap beberapa detik.",
        "Setiap objek disebutkan nama, posisi, dan estimasi jarak.",
        "Warna merah artinya sangat dekat dan berbahaya. Kuning artinya dekat. Hijau artinya aman.",
        "Anda juga bisa ucapkan SCAN kapan saja untuk memindai sekarang.",
      ],
      "desc": "Groq AI scan otomatis tiap 6 detik\n→ Nama + posisi + jarak diucapkan\n→ 3 level: merah, kuning, hijau",
    },
    {
      "title": "NAVIGASI MAPS",
      // Icons.near_me_rounded  codePoint = 0xf587
      "iconCode": 0xf587, "fontFamily": "MaterialIcons",
      "colorVal": 0xFF10B981,
      "pos": "Sebutkan nama tujuan → Google Maps terbuka",
      "lines": [
        "Fitur kedua adalah Navigasi Google Maps hands-free.",
        "Cukup sebutkan nama tempat atau alamat tujuan Anda kapan saja.",
        "Google Maps akan terbuka dan langsung mulai navigasi.",
        "Smart Vision tetap aktif dan terus scan objek sekalipun Maps sedang berjalan.",
      ],
      "desc": "Sebutkan nama tujuan\n→ Maps buka + navigasi langsung\n→ SmartVision tetap scan",
    },
    {
      "title": "PERINTAH SUARA",
      // Icons.mic_rounded  codePoint = 0xe4ce
      "iconCode": 0xe4ce, "fontFamily": "MaterialIcons",
      "colorVal": 0xFF8B5CF6,
      "pos": "Ucapkan perintah kapan saja",
      "lines": [
        "Fitur ketiga adalah Perintah Suara.",
        "Ucapkan SCAN untuk memindai objek sekarang.",
        "Ucapkan ULANG untuk mengulang informasi terakhir.",
        "Ucapkan nama tempat untuk membuka navigasi.",
        "Ucapkan kata pengaturan untuk membuka menu pengaturan.",
        "Ucapkan keluar akun untuk logout dari akun.",
      ],
      "desc": "SCAN → pindai sekarang\nULANG → info terakhir\nNama tempat → navigasi\nPENGATURAN / KELUAR AKUN → menu",
    },
    {
      "title": "SIAP DIGUNAKAN",
      // Icons.check_circle_rounded  codePoint = 0xef47
      "iconCode": 0xef47, "fontFamily": "MaterialIcons",
      "colorVal": 0xFFF59E0B,
      "pos": "Smart Vision siap membantu Anda",
      "lines": [
        "Panduan selesai. Smart Vision siap digunakan.",
        "Aplikasi akan otomatis scan objek dan terus mendengarkan perintah suara Anda.",
        "Tidak perlu menyentuh layar untuk menggunakan fitur utama.",
        "Selamat menggunakan Smart Vision. Selalu waspada dan berhati-hati.",
      ],
      "desc": "Tidak perlu sentuh layar\n→ Semua via perintah suara\n→ Scan otomatis aktif",
    },
  ];

  @override void initState() {
    super.initState();
    _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started) { _started = true; _runStep(); }
    });
  }

  Future<void> _runStep() async {
    if (!mounted || _done) return;
    final idx = _step - 1;
    if (idx >= _stepsData.length) { _finish(); return; }
    final d = _stepsData[idx];
    final lines = d["lines"] as List<String>;

    setState(() { _speaking = true; });
    _slide.reset();
    _slide.forward();

    // Ucapkan SEMUA baris — tunggu sampai benar-benar selesai
    for (final line in lines) {
      if (!mounted || _done) return;
      await _tts.speak(line);
      if (!mounted || _done) return;
      // Jeda kecil antar kalimat
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (!mounted || _done) return;
    setState(() { _speaking = false; });

    final isLast = _step >= _stepsData.length;
    if (isLast) {
      await _tts.speak("Smart Vision siap. Memulai sekarang.");
      if (mounted && !_done) _finish();
      return;
    }

    // Beritahu user bisa lanjut
    await _tts.speak("Lanjut ke fitur berikutnya. Ucapkan LANJUT atau tunggu sebentar.");
    if (!mounted || _done) return;

    // Listen untuk voice command, dengan auto-advance setelah 4 detik
    bool advanced = false;

    // Timer auto-advance
    Timer? advTimer;
    advTimer = Timer(const Duration(seconds: 4), () {
      if (!advanced && mounted && !_done) {
        advanced = true;
        _next();
      }
    });

    // Listen untuk "lanjut"
    await _stt.listenStream(
      listenFor: const Duration(seconds: 6),
      pauseFor:  const Duration(seconds: 3),
      onResult: (w, isFinal) {
        if (advanced || _done || !mounted) return;
        if (w.contains("lanjut") || w.contains("skip") || w.contains("berikut") ||
            w.contains("next") || w.contains("oke") || w.contains("ya")) {
          advanced = true;
          advTimer?.cancel();
          _next();
        }
      },
    );

    advTimer.cancel();
    if (!advanced && mounted && !_done) {
      advanced = true;
      _next();
    }
  }

  void _next() {
    if (_done || !mounted) return;
    if (_step < _stepsData.length) {
      setState(() => _step++);
      _runStep();
    } else {
      _finish();
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _tts.stop();
    _stt.stop();
    if (mounted) Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const MainAppScreen()));
  }

  @override void dispose() {
    _done = true;
    _slide.dispose();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final idx = (_step - 1).clamp(0, _stepsData.length - 1);
    final d = _stepsData[idx];
    final color = Color(d["colorVal"] as int);

    return Scaffold(body: Container(
      decoration: BoxDecoration(gradient: LinearGradient(
          colors: [const Color(0xFF0A0F1E), color.withOpacity(0.12)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter)),
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text("PANDUAN ${_step}/${_stepsData.length}",
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
            Row(children: List.generate(_stepsData.length, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: i + 1 == _step ? 24 : 8, height: 8,
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                    color: i < _step ? color : Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4))))),
          ]),
          const SizedBox(height: 32),
          Container(width: 80, height: 80,
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: color.withOpacity(0.15),
                  border: Border.all(color: color.withOpacity(0.5), width: 2)),
              child: Icon(
                  IconData(d["iconCode"] as int, fontFamily: 'MaterialIcons'),
                  color: color, size: 40)),
          const SizedBox(height: 20),
          Text(d["title"] as String, style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text(d["pos"] as String, style: TextStyle(color: color, fontSize: 12),
              textAlign: TextAlign.center),
          const Spacer(),
          Container(padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.08))),
              child: Text(d["desc"] as String,
                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.8))),
          const Spacer(),
          AnimatedOpacity(
              opacity: _speaking ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: color)),
                const SizedBox(width: 8),
                Text("AI menjelaskan fitur ini...", style: TextStyle(color: color, fontSize: 12)),
              ])),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _speaking ? null : _next,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                  gradient: !_speaking
                      ? LinearGradient(colors: [color, color.withOpacity(0.7)])
                      : null,
                  color: _speaking ? Colors.white.withOpacity(0.05) : null,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: !_speaking ? color : Colors.white.withOpacity(0.1))),
              child: Center(child: Text(
                  _speaking ? "AI sedang menjelaskan..."
                      : _step < _stepsData.length ? "LANJUT →" : "MULAI SMART VISION",
                  style: TextStyle(
                      color: !_speaking ? Colors.white : Colors.white38,
                      fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 1))),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      )),
    ));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// MAIN APP SCREEN
// ════════════════════════════════════════════════════════════════════════════
// ── KONSEP: ENUM (Enumeration) ───────────────────────────────────────────────
// Enum adalah tipe data dengan himpunan nilai yang terbatas dan sudah
// didefinisikan. Berguna untuk state machine — program tahu persis
// kondisi apa saja yang mungkin terjadi.
//
// Analogi: lampu lalu lintas → enum Traffic { merah, kuning, hijau }
// Tanpa enum, kita pakai String "scanning", "listening", dll → rawan typo.
// ─────────────────────────────────────────────────────────────────────────────
enum Phase { greeting, listening, scanning, navigating, repeating, setting, logout, idle }

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({Key? key}) : super(key: key);
  @override State<MainAppScreen> createState() => _MainState();
}

class _MainState extends State<MainAppScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  // ── Core services ──────────────────────────────────────────────────────────
  final _tts = Tts();
  final _stt = Stt();

  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _camReady   = false;
  bool _torchOn    = false;
  bool _capturing  = false; // mutex: cegah double capture

  // ── State ──────────────────────────────────────────────────────────────────
  Phase _phase        = Phase.idle;
  bool  _disposed     = false;
  bool  _settingOpen  = false;
  bool  _navPopup     = false;
  bool  _loopActive   = false;
  bool  _navActive    = false;
  bool  _wasInBackground = false;

  String            _destination = "";
  String            _lastPhrase  = "";
  List<DetectedObj> _objects     = [];
  List<DetectedObj> _prevObjects = [];

  // ── Timers ─────────────────────────────────────────────────────────────────
  Timer? _rtTimer;   // real-time scan background
  Timer? _navTimer;  // pengarahan saat navigasi

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _mic;
  late Animation<double>   _micScale;
  late AnimationController _popup;

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════
  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mic = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _micScale = Tween<double>(begin: 1.0, end: 1.25)
        .animate(CurvedAnimation(parent: _mic, curve: Curves.easeInOut));
    _popup = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted && !_disposed) _boot();
    });
  }

  @override void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _rtTimer?.cancel();
    _navTimer?.cancel();
    _mic.dispose();
    _popup.dispose();
    try { _cam?.setFlashMode(FlashMode.off); } catch (_) {}
    _cam?.dispose();
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  // Kembali dari Maps / background
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wasInBackground = true;
    } else if (state == AppLifecycleState.resumed && _wasInBackground) {
      _wasInBackground = false;
      if (!_disposed && mounted) {
        Future.delayed(const Duration(milliseconds: 800), () async {
          if (_disposed || !mounted) return;

          // Reset mutex — bisa stuck true kalau app di-background saat capture
          _capturing = false;

          // Reinit kamera jika perlu (sering blank/hitam setelah resume dari Maps)
          if (_cam != null && !_cam!.value.isInitialized) {
            _camReady = false;
            try { await _cam!.dispose(); } catch (_) {}
            _cam = null;
            await _initCam();
          }
          if (_disposed || !mounted) return;

          await _tts.speak("SmartVision kembali aktif.");
          if (_disposed || !mounted) return;

          if (mounted) setState(() =>
          _phase = _navActive ? Phase.navigating : Phase.listening);

          // Restart RT scan bersih
          _stopRtScan();
          _startRtScan();

          // Restart cmd loop jika tidak aktif — reset flag dulu anti race condition
          if (!_loopActive) {
            _cmdLoop();
          }
        });
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BOOT
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> _boot() async {
    if (_disposed || !mounted) return;
    await [Permission.camera, Permission.microphone, Permission.location]
        .request();
    await _initCam();
    await _stt.init();
    if (_disposed || !mounted) return;

    if (mounted) setState(() => _phase = Phase.greeting);
    final name = globalName.isNotEmpty ? globalName : "pengguna";

    await _tts.speak(
        "Selamat datang $name. Smart Vision aktif. "
            "Kamera langsung memindai objek di sekitar Anda.");
    if (_disposed || !mounted) return;

    // Scan pertama saat boot — _fullScan() sudah tanya navigasi & _startRtScan di dalamnya
    await _fullScan();
    if (_disposed || !mounted) return;

    if (!_loopActive) _cmdLoop();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CAMERA
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> _initCam() async {
    if (cameras.isEmpty) return;
    // Dispose kamera lama jika ada tapi tidak initialized
    if (_cam != null && !_cam!.value.isInitialized) {
      try { await _cam!.dispose(); } catch (_) {}
      _cam = null;
      _camReady = false;
    }
    if (_cam != null && _camReady) return; // sudah siap
    try {
      final back = cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      _cam = CameraController(back, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await _cam!.initialize();
      try { await _cam!.setFocusMode(FocusMode.auto); } catch (_) {}
      // Warmup sensor: tanpa ini foto pertama sering gelap/blur
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) setState(() => _camReady = true);
    } catch (e) { debugPrint("[Cam] init error: $e"); }
  }

  Future<void> _autoTorch(String imagePath) async {
    if (_cam == null || !_camReady) return;
    try {
      final bytes = await File(imagePath).readAsBytes();
      double sum = 0; int count = 0;
      final step = (bytes.length / 1000).round().clamp(1, 9999);
      for (int i = 0; i < bytes.length; i += step) { sum += bytes[i]; count++; }
      final avg = count > 0 ? sum / count : 128;
      final shouldOn = avg < 50;
      if (shouldOn != _torchOn) {
        _torchOn = shouldOn;
        await _cam!.setFlashMode(shouldOn ? FlashMode.torch : FlashMode.off);
      }
    } catch (_) {}
  }

  // Capture 1 frame dan kirim ke Groq
  // ── KONSEP: MUTEX (Mutual Exclusion) ─────────────────────────────────────
  // _capturing adalah boolean flag yang berfungsi sebagai "mutex" sederhana.
  // Mencegah dua proses capture berjalan bersamaan (race condition).
  // Jika _capturing == true → proses sebelumnya belum selesai → langsung return [].
  // Ini adalah algoritma sinkronisasi dasar dalam pemrograman konkuren.
  // ─────────────────────────────────────────────────────────────────────────
  Future<List<DetectedObj>> _captureAndDetect() async {
    if (!_camReady || _cam == null || !_cam!.value.isInitialized) return [];
    if (_capturing) return []; // cegah double capture
    _capturing = true;
    try {
      return await _doCaptureDetect(retryLeft: 2);
    } finally {
      // finally SELALU jalan — _capturing PASTI di-reset meski exception
      _capturing = false;
    }
  }

  // Helper: capture + detect dengan retry bersih
  // retryLeft = sisa percobaan. Dipanggil rekursif jika hasil kosong.
  Future<List<DetectedObj>> _doCaptureDetect({required int retryLeft}) async {
    // Tunggu kamera selesai kalau sedang ambil foto lain
    for (int w = 0; w < 20 && _cam!.value.isTakingPicture; w++) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    if (_cam == null || !_cam!.value.isInitialized) return [];

    // Stabilisasi autofokus — lebih lama di percobaan pertama
    await Future.delayed(Duration(milliseconds: retryLeft == 2 ? 400 : 200));

    String? path;
    try {
      final xfile = await _cam!.takePicture();
      path = xfile.path;
    } catch (e) {
      debugPrint("[Capture] takePicture error: $e");
      return [];
    }

    if (!File(path).existsSync()) return [];

    await _autoTorch(path);
    final results = await detectWithGroq(path);

    // Hapus file setelah diproses
    try { File(path).deleteSync(); } catch (_) {}

    // Jika kosong dan masih ada retry → tunggu sebentar lalu coba lagi
    if (results.isEmpty && retryLeft > 0) {
      debugPrint("[Capture] Hasil kosong, retry ($retryLeft sisa)...");
      await Future.delayed(const Duration(milliseconds: 800));
      if (_cam == null || !_cam!.value.isInitialized) return [];
      return _doCaptureDetect(retryLeft: retryLeft - 1);
    }

    return results;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // REAL-TIME SCAN BACKGROUND
  // ── KONSEP: TIMER + EVENT-DRIVEN PROGRAMMING ─────────────────────────────
  // Timer.periodic adalah algoritma event-driven: callback dipanggil setiap
  // N detik secara otomatis. Berbeda dengan loop biasa (while/for) yang
  // memblokir thread, Timer berjalan di background tanpa membekukan UI.
  //
  // Analogi: alarm jam yang berbunyi setiap X menit — kamu tidak perlu
  // terus-menerus cek jam, alarm yang memberitahumu.
  // ─────────────────────────────────────────────────────────────────────────
  void _startRtScan() {
    _rtTimer?.cancel();
    // ── Real-time scan setiap 4 detik (lebih responsif dari 7 detik) ────────
    _rtTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_disposed || !mounted) return;
      // Skip hanya saat sedang full-scan manual atau greeting — BUKAN saat listening
      if (_phase == Phase.scanning || _phase == Phase.greeting) return;
      if (!_camReady || _cam == null || !_cam!.value.isInitialized) return;
      // Skip jika sedang capture (mutex) — JANGAN skip saat phase == listening
      if (_capturing) return;

      final res = await _captureAndDetect();
      if (_disposed || !mounted || res.isEmpty) return;
      if (mounted) setState(() => _objects = res);

      // ── Tentukan objek yang perlu diumumkan ──────────────────────────────
      final toAnnounce = <DetectedObj>[];
      bool newDanger   = false;

      for (final o in res) {
        final prev = _prevObjects.where((p) => p.label == o.label).firstOrNull;
        if (prev == null) {
          // Objek baru — selalu umumkan
          toAnnounce.add(o);
        } else if ((o.distM - prev.distM).abs() > 0.4) {
          // Objek bergerak signifikan (threshold turun dari 0.5 ke 0.4)
          toAnnounce.add(o);
        } else if (o.isDanger && !prev.isDanger) {
          // Status berubah jadi bahaya
          toAnnounce.add(o);
        }
        if (o.isDanger && o.distM < 2.0) newDanger = true;
      }

      // Selalu umumkan objek SANGAT dekat (< 1.2 m) meski tidak berubah
      final closeObjs = res.where((o) => o.distM < 1.2).toList();
      // Gabungkan: objek baru/berubah + objek sangat dekat (deduplikasi)
      final announceSet = <String>{};
      final relevant = <DetectedObj>[];
      for (final o in [...toAnnounce, ...closeObjs]) {
        if (announceSet.add(o.label)) relevant.add(o);
      }

      if (relevant.isNotEmpty || newDanger) {
        final sb = StringBuffer();
        if (newDanger) {
          for (final d in res.where((o) => o.isDanger && o.distM < 2.0).take(3)) {
            sb.write("PERHATIAN! ${d.label} ${d.side}, ${d.distanceDesc}. ");
          }
        }
        for (final o in relevant.where((o) => !o.isDanger || o.distM >= 2.0).take(4)) {
          sb.write("${o.label} ${o.side}, ${o.distanceDesc}. ");
        }
        if (sb.isNotEmpty) {
          _lastPhrase = sb.toString().trim();
          await _tts.speak(_lastPhrase);
        }
      }

      _prevObjects = List.from(res);
    });
  }

  void _stopRtScan() { _rtTimer?.cancel(); _rtTimer = null; }

  // ══════════════════════════════════════════════════════════════════════════
  // FULL SCAN (on-demand: ucapkan SEMUA objek)
  // ══════════════════════════════════════════════════════════════════════════
  Future<List<DetectedObj>> _fullScan() async {
    _stopRtScan();
    _capturing = false;

    if (mounted) setState(() { _phase = Phase.scanning; _objects = []; });
    await _tts.speak("Memindai sekarang...");

    final res = await _captureAndDetect();
    if (mounted) setState(() => _objects = res);

    if (res.isEmpty) {
      _lastPhrase = "Tidak ada objek terdeteksi. Arahkan kamera ke depan Anda.";
      await _tts.speak(_lastPhrase);
    } else {
      // Bahaya duluan
      final dangers = res.where((o) => o.isDanger && o.distM < 3.0).toList();
      if (dangers.isNotEmpty) {
        final sb = StringBuffer("PERHATIAN! ");
        for (final d in dangers) {
          sb.write("${d.label} ${d.side}, sejauh ${d.distanceDesc}. ");
        }
        await _tts.speak(sb.toString());
        if (_disposed || !mounted) return res;
      }
      final sb = StringBuffer("Terdeteksi ${res.length} objek. ");
      for (final o in res.take(8)) {
        if (!o.isDanger || o.distM >= 3.0) {
          sb.write("${o.label} ${o.side}, sejauh ${o.distanceDesc}. ");
        }
      }
      _lastPhrase = sb.toString().trim();
      await _tts.speak(_lastPhrase);
    }

    if (_disposed || !mounted) return res;

    // ── Prompt singkat: scan selesai, tunggu input ────────────────────────
    // Tidak sebut kata "sebutkan" / "nama" supaya tidak tertangkap STT sebagai echo
    await _tts.speak("Siap. Tujuan?");
    // Jeda lebih panjang agar gema TTS benar-benar hilang sebelum STT mulai
    await Future.delayed(const Duration(milliseconds: 1500));

    if (_disposed || !mounted) return res;
    if (mounted) setState(() => _phase = Phase.listening);

    // ── Dengarkan satu input — bisa: nama tempat, scan, ulang, setting ────
    String input = "";
    bool gotInput = false;

    await _stt.listenStream(
      listenFor: const Duration(seconds: 12),
      pauseFor:  const Duration(seconds: 3),
      // echoGuard lebih panjang supaya echo "Siap. Tujuan?" tidak masuk
      echoGuard: const Duration(milliseconds: 1800),
      onResult: (w, isFinal) {
        if (gotInput || _disposed || !mounted) return;
        final wc = w.trim().toLowerCase();
        if (wc.isEmpty) return;

        // Perintah sistem — tangkap secepatnya
        if (wc.contains("scan") || wc.contains("pindai") ||
            wc.contains("deteksi") || wc.contains("lihat") ||
            wc.contains("apa di depan") || wc.contains("cek")) {
          gotInput = true; input = "__scan__"; _stt.stop(); return;
        }
        if (wc.contains("ulang") || wc.contains("ulangi")) {
          gotInput = true; input = "__ulang__"; _stt.stop(); return;
        }
        if (wc.contains("setting") || wc.contains("seting") ||
            wc.contains("pengaturan") || wc.contains("setelan")) {
          gotInput = true; input = "__setting__"; _stt.stop(); return;
        }
        if (wc.contains("logout") || wc.contains("log out") ||
            wc.contains("keluar akun")) {
          gotInput = true; input = "__logout__"; _stt.stop(); return;
        }

        // Semua input lain = nama tempat/jalan → langsung navigasi
        const noise = ["iya","ya","tidak","oke","ok","halo","hai","hey",
          "diam","stop","berhenti","engga","enggak","nggak","gak","ga",
          "batal","cukup","selesai","test","hei","tolong","coba"];
        final isNoise = noise.contains(wc);
        final wordCount = wc.split(' ').length;
        if (!isNoise && (wordCount >= 2 || (wordCount == 1 && wc.length >= 4))) {
          if (isFinal || wordCount >= 2) {
            gotInput = true; input = w.trim(); _stt.stop(); return;
          }
        }
      },
    );
    if (_disposed || !mounted) return res;

    // ── Routing hasil input ───────────────────────────────────────────────
    if (input == "__scan__") {
      _capturing = false;
      return await _fullScan();
    }
    if (input == "__ulang__") {
      await _handleUlang();
      _startRtScan();
      return res;
    }
    if (input == "__setting__") {
      await _handleSetting();
      _startRtScan();
      return res;
    }
    if (input == "__logout__") {
      await _handleLogout();
      return res;
    }
    if (input.isNotEmpty) {
      // Nama tempat/jalan → langsung navigasi
      await _doNavigate(input);
      return res;
    }

    // Tidak ada input — lanjut scan realtime biasa
    if (mounted) setState(() => _phase = Phase.listening);
    _startRtScan();
    return res;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NAVIGASI
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> _doNavigate(String dest) async {
    if (_disposed || !mounted) return;
    _stopRtScan();
    _navTimer?.cancel();

    final display = dest.split(' ')
        .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w)
        .join(' ');

    if (mounted) setState(() {
      _phase       = Phase.navigating;
      _destination = display;
      _navPopup    = true;
      _navActive   = true;
    });
    _popup.forward(from: 0);

    // Dapatkan posisi GPS user
    String origin = "";
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm != LocationPermission.deniedForever &&
          await Geolocator.isLocationServiceEnabled()) {
        final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high)
            .timeout(const Duration(seconds: 8));
        origin = "${pos.latitude},${pos.longitude}";
        debugPrint("[Nav] GPS: $origin");
      }
    } catch (e) { debugPrint("[Nav] GPS error: $e"); }

    // Bicara singkat, lalu STOP TTS sebelum buka GMaps
    // supaya suara SmartVision tidak tumpuk dengan suara arah GMaps
    await _tts.speak("Menuju $display.");
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 300));

    if (_disposed || !mounted) return;

    // Buka GMaps — suara navigasi GMaps mulai setelah ini
    await _openMapsNavigation(dest, origin);

    // navTimer: scan objek saat navigasi aktif
    // Jeda 10 detik pertama agar suara arah GMaps tidak langsung ditimpa
    _navTimer?.cancel();
    _navTimer = Timer(const Duration(seconds: 10), () {
      if (_disposed || !mounted) return;
      _navTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
        if (_disposed || !mounted || _phase == Phase.scanning) return;
        if (_capturing) return;
        final r = await _captureAndDetect();
        if (_disposed || !mounted || r.isEmpty) return;
        if (mounted) setState(() => _objects = r);

        final sb = StringBuffer();
        final dangers = r.where((o) => o.isDanger && o.distM < 2.5).toList();
        for (final d in dangers.take(2)) {
          sb.write("PERHATIAN! ${d.label} ${d.side}, ${d.distanceDesc}. ");
        }
        for (final o in r.where((o) => !o.isDanger && o.distM < 2.0).take(2)) {
          sb.write("${o.label} ${o.side}. ");
        }
        final phrase = sb.toString().trim();
        if (phrase.isNotEmpty) {
          // Jeda 600ms sebelum bicara — beri ruang suara GMaps selesai dulu
          await Future.delayed(const Duration(milliseconds: 600));
          if (_disposed || !mounted) return;
          _lastPhrase = phrase;
          await _tts.speak(phrase);
        }
      });
    });
  }

  Future<void> _openMapsNavigation(String dest, String origin) async {
    final enc = Uri.encodeComponent(dest);
    final urls = <String>[];

    if (origin.isNotEmpty) {
      // ── Prioritas 1: intent native GMaps — langsung mulai navigasi berjalan kaki
      // format: google.navigation:q=<dest>&mode=w  (w = walking)
      // origin lat,lng dikirim via parameter "saddr" di intent URL lain
      urls.add("google.navigation:q=$enc&mode=w");

      // ── Prioritas 2: Maps deep-link dengan origin koordinat eksplisit
      urls.add(
          "https://www.google.com/maps/dir/?api=1"
              "&origin=${Uri.encodeComponent(origin)}"
              "&destination=$enc"
              "&travelmode=walking"
              "&dir_action=navigate");

      // ── Prioritas 3: comgooglemaps scheme (jika Google Maps app versi lama)
      urls.add(
          "comgooglemaps://?saddr=${Uri.encodeComponent(origin)}"
              "&daddr=$enc&directionsmode=walking");
    }

    // ── Fallback tanpa origin (GMaps pakai posisi GPS real-time sendiri)
    urls.add("google.navigation:q=$enc&mode=w");
    urls.add(
        "https://www.google.com/maps/dir/?api=1"
            "&destination=$enc"
            "&travelmode=walking"
            "&dir_action=navigate");
    urls.add("https://maps.google.com/?q=$enc&dirflg=w");

    for (final u in urls) {
      try {
        final uri = Uri.parse(u);
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (launched) {
          debugPrint("[Maps] ✅ Berhasil buka: $u");
          return;
        }
      } catch (_) {}
    }

    // Semua gagal
    if (mounted) {
      await _tts.speak(
          "Tidak bisa membuka Google Maps. Pastikan aplikasi Maps sudah terpasang.");
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // COMMAND LOOP  — dengarkan perintah user secara terus-menerus
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> _cmdLoop() async {
    if (_disposed || !mounted || _loopActive) return;
    _loopActive = true;

    while (!_disposed && mounted) {
      // Set fase listening kalau tidak sedang scan/navigasi/proses lain
      if (_phase != Phase.scanning  &&
          _phase != Phase.navigating &&
          _phase != Phase.repeating  &&
          _phase != Phase.setting    &&
          _phase != Phase.logout) {
        if (mounted) setState(() => _phase = Phase.listening);
      }

      // Bersihkan STT sebelum dengarkan baru
      await _stt.stop();
      await Future.delayed(const Duration(milliseconds: 200));
      if (_disposed || !mounted) break;

      String cmd = "";
      String navRaw = "";
      bool   handled = false;

      await _stt.listenStream(
        listenFor: const Duration(seconds: 25),
        pauseFor:  const Duration(seconds: 6),
        onResult: (w, isFinal) {
          if (handled || _disposed || !mounted) return;

          // ── Perintah dasar ──────────────────────────────────────────────
          if (w.contains("ulang") || w.contains("ulangi")) {
            handled = true; cmd = "ulang"; _stt.stop(); return;
          }
          if (w.contains("setting")    || w.contains("seting") ||
              w.contains("pengaturan") || w.contains("setelan")) {
            handled = true; cmd = "setting"; _stt.stop(); return;
          }
          if (w.contains("logout")     || w.contains("log out") ||
              w.contains("keluar akun") || w.contains("sign out")) {
            handled = true; cmd = "logout"; _stt.stop(); return;
          }
          if (w.contains("scan")   || w.contains("pindai") ||
              w.contains("deteksi") || w.contains("cek sekitar") ||
              w.contains("lihat") || w.contains("apa di depan")) {
            handled = true; cmd = "scan"; _stt.stop(); return;
          }

          // ── Deteksi navigasi: hanya jika ada kata kunci eksplisit ───────
          // Daftar kata kunci navigasi — cukup fleksibel untuk percakapan natural
          const navKws = [
            "pergi ke",    "bawa ke",    "navigasi ke", "antar ke",
            "tuju ke",     "arahkan ke", "mau ke",      "ingin ke",
            "ke tempat",   "buka maps",  "cari jalan",  "tunjukkan jalan",
            "antarkan ke", "menuju ke",  "menuju",      "tujuan",
          ];
          for (final kw in navKws) {
            if (w.contains(kw)) {
              final idx   = w.indexOf(kw);
              final after = w.substring(idx + kw.length).trim();
              if (after.length >= 2) {
                handled = true; cmd = "nav"; navRaw = after;
                _stt.stop(); return;
              }
            }
          }
          // ── Fallback: tangkap sebagai nama tempat navigasi ────────────
          // Abaikan satu kata pendek yang bisa noise (iya, oke, halo, dll)
          const _noiseWords = [
            "iya","ya","tidak","oke","ok","halo","hai","hey","tolong",
            "coba","stop","berhenti","diam","mati","hidup","test","hei",
          ];
          final wTrimmed = w.trim();
          final wordCount = wTrimmed.split(' ').length;
          final isNoise   = _noiseWords.contains(wTrimmed);
          // Minimal 2 kata ATAU 1 kata >= 4 karakter yang bukan noise
          if (!isNoise && (wordCount >= 2 || (wordCount == 1 && wTrimmed.length >= 4))) {
            // Tangkap saat isFinal ATAU partial tapi sudah 3+ kata (lebih reliable)
            if (isFinal || wordCount >= 3) {
              handled = true; cmd = "nav"; navRaw = wTrimmed;
              _stt.stop(); return;
            }
          }
        },
      );

      if (_disposed || !mounted) break;

      // ── KONSEP: SWITCH-CASE (Pattern Matching / Multi-Branch Decision) ──
      // Switch lebih efisien dari if-else berantai untuk banyak kondisi.
      // Setiap "case" adalah cabang eksekusi berbeda berdasarkan nilai cmd.
      // Ini adalah implementasi Command Pattern dalam desain perangkat lunak.
      // ─────────────────────────────────────────────────────────────────────
      switch (cmd) {
        case "scan":
          await _tts.stop();
          _stopRtScan();
          _capturing = false; // reset mutex sebelum full scan
          await _fullScan();
          // _startRtScan sudah dipanggil di dalam _fullScan()
          break;

        case "ulang":
          await _tts.stop();
          await _handleUlang();
          if (!_navActive) _startRtScan();
          break;

        case "setting":
          await _tts.stop();
          await _handleSetting();
          break;

        case "logout":
          await _tts.stop();
          await _handleLogout();
          _loopActive = false;
          return;

        case "nav":
          await _tts.stop();
          _stopRtScan();
          if (_navActive) {
            _navTimer?.cancel(); _navActive = false;
            await _tts.speak("Mengganti tujuan navigasi.");
          }
          await _doNavigate(navRaw);
          break;

        default:
        // Tidak ada perintah — tidak perlu bicara, cukup lanjutkan loop
          break;
      }

      await Future.delayed(const Duration(milliseconds: 150));
    }

    _loopActive = false;
    // Restart loop otomatis — hanya jika belum logout dan widget masih hidup
    if (!_disposed && mounted && _phase != Phase.logout) {
      await Future.delayed(const Duration(milliseconds: 300));
      // Cek lagi setelah delay — bisa saja dispose dipanggil selama delay
      if (!_disposed && mounted && !_loopActive) _cmdLoop();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HANDLERS
  // ══════════════════════════════════════════════════════════════════════════
  Future<void> _handleUlang() async {
    if (_disposed || !mounted) return;
    if (mounted) setState(() => _phase = Phase.repeating);
    if (_objects.isNotEmpty) {
      final sb = StringBuffer(
          "Mengulang. Terdeteksi ${_objects.length} objek. ");
      for (final o in _objects.take(8)) {
        sb.write(
            "${o.isDanger ? 'PERHATIAN! ' : ''}${o.label} ${o.side}, "
                "sejauh ${o.distanceDesc}. ");
      }
      _lastPhrase = sb.toString().trim();
      await _tts.speak(_lastPhrase);
    } else if (_lastPhrase.isNotEmpty) {
      await _tts.speak(_lastPhrase);
    } else {
      await _tts.speak(
          "Belum ada hasil scan. Memindai sekarang.");
      await _fullScan();
      return;
    }
    if (mounted) setState(() =>
    _phase = _navActive ? Phase.navigating : Phase.listening);
  }

  Future<void> _handleSetting() async {
    if (_disposed || !mounted) return;
    final nowOpen = !_settingOpen;
    if (mounted) setState(() { _phase = Phase.setting; _settingOpen = nowOpen; });
    await _tts.speak(nowOpen ? "Pengaturan dibuka." : "Pengaturan ditutup.");
    if (mounted) setState(() =>
    _phase = _navActive ? Phase.navigating : Phase.listening);
  }

  Future<void> _handleLogout() async {
    if (_disposed || !mounted) return;
    if (mounted) setState(() => _phase = Phase.logout);
    _stopRtScan(); _navTimer?.cancel(); _navActive = false;
    try { await _cam?.setFlashMode(FlashMode.off); } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, false);
    await _tts.speak("Keluar akun. Sampai jumpa.");
    if (mounted && !_disposed) Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const WelcomeScreen()));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════════════════════════════════
  Color get _scanColor {
    if (_objects.isEmpty) return Colors.greenAccent;
    final d = _objects.first.distM;
    if (d < 0.8) return Colors.redAccent;
    if (d < 1.5) return Colors.orangeAccent;
    if (d < 3.0) return Colors.yellowAccent;
    return Colors.greenAccent;
  }

  bool get _busy =>
      _phase == Phase.scanning  || _phase == Phase.navigating ||
          _phase == Phase.repeating || _phase == Phase.setting    ||
          _phase == Phase.logout    || _phase == Phase.greeting;

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(children: [

      // ── KAMERA PREVIEW (full screen) ──────────────────────────────────
      Positioned.fill(
        child: _camReady && _cam != null && _cam!.value.isInitialized
            ? CameraPreview(_cam!)
            : Container(color: Colors.black,
            child: const Center(child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF3B82F6)),
                  SizedBox(height: 16),
                  Text("Memuat kamera...",
                      style: TextStyle(color: Colors.white54)),
                ]))),
      ),

      // ── OVERLAY gradient ──────────────────────────────────────────────
      Positioned.fill(child: Container(
          decoration: BoxDecoration(gradient: LinearGradient(
              colors: [
                Colors.black.withOpacity(0.55),
                Colors.transparent,
                Colors.black.withOpacity(0.75)],
              begin: Alignment.topCenter,
              end:   Alignment.bottomCenter)))),

      // ── TORCH INDICATOR ───────────────────────────────────────────────
      if (_torchOn)
        Positioned(top: 52, left: 16,
            child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFFF59E0B).withOpacity(0.6))),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.flashlight_on_rounded,
                      color: Color(0xFFF59E0B), size: 14),
                  SizedBox(width: 4),
                  Text("Senter",
                      style: TextStyle(color: Color(0xFFF59E0B), fontSize: 10)),
                ]))),

      // ── NAV POPUP ─────────────────────────────────────────────────────
      if (_navPopup)
        Positioned(top: 52, left: _torchOn ? 100 : 16, right: 72,
            child: SlideTransition(
                position: Tween<Offset>(
                    begin: const Offset(0, -1.5), end: Offset.zero)
                    .animate(CurvedAnimation(
                    parent: _popup, curve: Curves.easeOutCubic)),
                child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: const Color(0xFF0A0F1E).withOpacity(0.96),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: const Color(0xFF10B981), width: 1.5),
                        boxShadow: [BoxShadow(
                            color: const Color(0xFF10B981).withOpacity(0.25),
                            blurRadius: 16)]),
                    child: Row(children: [
                      Container(width: 34, height: 34,
                          decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withOpacity(0.2),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: const Color(0xFF10B981))),
                          child: const Icon(Icons.navigation_rounded,
                              color: Color(0xFF10B981), size: 16)),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("NAVIGASI AKTIF", style: TextStyle(
                                color: Color(0xFF10B981), fontSize: 9,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5)),
                            const SizedBox(height: 2),
                            Text(_destination, style: const TextStyle(
                                color: Colors.white, fontSize: 12,
                                fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis),
                            const Text(
                                "Ucapkan nama baru untuk ganti tujuan",
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 9)),
                          ])),
                      GestureDetector(
                          onTap: () => setState(() {
                            _navPopup = false; _popup.reverse();
                          }),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white54, size: 18)),
                    ])))),

      // ── SETTING ICON ──────────────────────────────────────────────────
      Positioned(top: 52, right: 16,
          child: GestureDetector(
              onTap: () async {
                await _tts.stop(); _stt.stop();
                await Future.delayed(const Duration(milliseconds: 200));
                if (!mounted || _disposed) return;
                setState(() {
                  _settingOpen = !_settingOpen;
                  _phase = Phase.setting;
                });
                await _tts.speak(_settingOpen
                    ? "Pengaturan dibuka." : "Pengaturan ditutup.");
                if (mounted) setState(() => _phase = Phase.listening);
              },
              child: Container(width: 44, height: 44,
                  decoration: BoxDecoration(
                      color: const Color(0xFF0A0F1E).withOpacity(0.85),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: _settingOpen
                              ? const Color(0xFFF59E0B)
                              : Colors.white.withOpacity(0.2),
                          width: 1.5)),
                  child: Icon(Icons.settings_rounded,
                      color: _settingOpen
                          ? const Color(0xFFF59E0B) : Colors.white,
                      size: 22)))),

      // ── SETTING PANEL ─────────────────────────────────────────────────
      if (_settingOpen)
        Positioned(top: 108, left: 16, right: 16,
            child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1E).withOpacity(0.97),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 24)
                    ]),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Text("PENGATURAN", style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w900,
                            fontSize: 14, letterSpacing: 1.5)),
                        const Spacer(),
                        GestureDetector(
                            onTap: () => setState(() => _settingOpen = false),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white54, size: 20)),
                      ]),
                      const Divider(color: Colors.white12, height: 20),
                      Row(children: [
                        Container(width: 40, height: 40,
                            decoration: BoxDecoration(shape: BoxShape.circle,
                                color: const Color(0xFF1E3A8A).withOpacity(0.4),
                                border: Border.all(
                                    color: const Color(0xFF3B82F6), width: 1.5)),
                            child: const Icon(Icons.person_rounded,
                                color: Color(0xFF60A5FA), size: 20)),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(globalName.isEmpty ? "Pengguna SmartVision"
                                  : globalName,
                                  style: const TextStyle(color: Colors.white,
                                      fontWeight: FontWeight.bold, fontSize: 14)),
                              Text(globalEmail.isEmpty ? "Sesi Aktif" : globalEmail,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 12)),
                            ])),
                      ]),
                      const Divider(color: Colors.white12, height: 20),
                      // Toggle senter
                      GestureDetector(
                          onTap: () async {
                            _torchOn = !_torchOn;
                            try {
                              await _cam?.setFlashMode(
                                  _torchOn ? FlashMode.torch : FlashMode.off);
                            } catch (_) {}
                            setState(() {});
                          },
                          child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.04),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.white.withOpacity(0.08))),
                              child: Row(children: [
                                Icon(
                                    _torchOn
                                        ? Icons.flashlight_on_rounded
                                        : Icons.flashlight_off_rounded,
                                    color: _torchOn
                                        ? const Color(0xFFF59E0B) : Colors.white54,
                                    size: 20),
                                const SizedBox(width: 12),
                                Text(
                                    _torchOn ? "Senter: NYALA" : "Senter: MATI",
                                    style: TextStyle(
                                        color: _torchOn
                                            ? const Color(0xFFF59E0B) : Colors.white54,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ]))),
                      const SizedBox(height: 10),
                      // Logout
                      GestureDetector(
                          onTap: () async {
                            setState(() => _settingOpen = false);
                            await _handleLogout();
                          },
                          child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.redAccent.withOpacity(0.3))),
                              child: const Row(children: [
                                Icon(Icons.logout_rounded,
                                    color: Colors.redAccent, size: 20),
                                SizedBox(width: 12),
                                Text("Keluar Akun", style: TextStyle(
                                    color: Colors.redAccent, fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                              ]))),
                    ]))),

      // ── OBJECT DETECTION PANEL ────────────────────────────────────────
      Positioned(bottom: 118, left: 12, right: 12,
          child: AnimatedOpacity(
              opacity: _objects.isNotEmpty || _phase == Phase.scanning
                  ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 300),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    border: Border.all(color: _scanColor, width: 2),
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.black.withOpacity(0.5)),
                child: _objects.isEmpty
                    ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_phase == Phase.scanning)
                        const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.greenAccent))
                      else
                        const Icon(Icons.mic,
                            color: Colors.greenAccent, size: 14),
                      const SizedBox(width: 8),
                      Flexible(child: Text(
                          _phase == Phase.scanning
                              ? "🔍 Memindai dengan Groq AI..."
                              : "Ucapkan perintah atau nama tempat tujuan",
                          style: TextStyle(color: _scanColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600))),
                    ])
                    : SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Container(width: 8, height: 8,
                                decoration: BoxDecoration(
                                    color: _scanColor,
                                    shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                            Text("${_objects.length} Objek Terdeteksi",
                                style: TextStyle(color: _scanColor,
                                    fontSize: 10, letterSpacing: 1,
                                    fontWeight: FontWeight.w700)),
                            const Spacer(),
                            Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                    color: Colors.blueAccent.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: Colors.blueAccent
                                            .withOpacity(0.3))),
                                child: const Text("GEMINI", style: TextStyle(
                                    color: Colors.blueAccent, fontSize: 8,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1))),
                          ]),
                          const SizedBox(height: 8),
                          ..._objects.take(8).map((o) {
                            final dStr = o.distM < 1
                                ? "${(o.distM * 100).round()} cm"
                                : "${o.distM.toStringAsFixed(1)} m";
                            final oc = o.isDanger || o.distM < 0.8
                                ? Colors.redAccent
                                : o.distM < 1.5 ? Colors.orangeAccent
                                : o.distM < 3.0 ? Colors.yellowAccent
                                : Colors.greenAccent;
                            return Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Row(children: [
                                  Icon(o.isDanger
                                      ? Icons.warning_rounded
                                      : Icons.circle,
                                      color: oc,
                                      size: o.isDanger ? 12 : 8),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(
                                      "${o.label}  •  ${o.side}",
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 12,
                                          fontWeight: FontWeight.w600))),
                                  Text(dStr, style: TextStyle(color: oc,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800)),
                                ]));
                          }),
                        ])),
              ))),

      // ── STATUS BAR ────────────────────────────────────────────────────
      Positioned(bottom: 106, left: 0, right: 0,
          child: Center(child: AnimatedOpacity(
              opacity: (_phase == Phase.listening || _busy) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 16),
                  decoration: BoxDecoration(
                      color: (_phase == Phase.listening
                          ? Colors.greenAccent : Colors.orange)
                          .withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: (_phase == Phase.listening
                          ? Colors.greenAccent : Colors.orange)
                          .withOpacity(0.4))),
                  child: Text(
                      _phase == Phase.scanning
                          ? "🔍 Memindai objek..."
                          : _phase == Phase.navigating
                          ? "🗺 Navigasi aktif — ${_destination.isNotEmpty ? _destination : ''}"
                          : _phase == Phase.listening
                          ? "🎙 Mendengarkan..."
                          : _phase == Phase.repeating
                          ? "🔁 Mengulang..."
                          : _phase == Phase.setting
                          ? "⚙️ Pengaturan"
                          : "⏳ Memproses...",
                      style: TextStyle(
                          color: _phase == Phase.listening
                              ? Colors.greenAccent : Colors.orange,
                          fontSize: 11, fontWeight: FontWeight.w600)))))),

      // ── BOTTOM BAR ────────────────────────────────────────────────────
      Positioned(bottom: 0, left: 0, right: 0,
          child: _bottomBar()),
    ]),
  );

  Widget _bottomBar() => Container(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    decoration: BoxDecoration(
        color: const Color(0xFF070C1A).withOpacity(0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 20, offset: const Offset(0,-4))],
        border: Border(top: BorderSide(
            color: Colors.white.withOpacity(0.1), width: 1))),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [

      // ULANG
      GestureDetector(
          onTap: () async {
            await _tts.stop();
            await _stt.stop();
            _loopActive = false;
            _capturing = false;
            await Future.delayed(const Duration(milliseconds: 300));
            if (!mounted || _disposed) return;
            await _handleUlang();
            if (!_navActive) _startRtScan();
            if (!_loopActive && mounted && !_disposed) _cmdLoop();
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 58, height: 58,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: const Color(0xFF1A2440),
                    border: Border.all(color: const Color(0xFF4A6FA5), width: 1.5),
                    boxShadow: [BoxShadow(color: const Color(0xFF4A6FA5).withOpacity(0.2), blurRadius: 12, spreadRadius: 1)]),
                child: const Icon(Icons.volume_up_rounded,
                    color: Color(0xFF7EB8FF), size: 26)),
            const SizedBox(height: 6),
            const Text("Ulang",
                style: TextStyle(color: Color(0xFF7EB8FF), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ])),

      // SCAN (tengah) — tombol utama, lebih besar
      GestureDetector(
          onTap: () async {
            // Stop semua yang sedang jalan dulu
            await _tts.stop();
            await _stt.stop();
            _loopActive = false;
            _stopRtScan();
            _capturing = false; // force reset mutex
            // Tunggu STT & TTS benar-benar berhenti sebelum capture
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted || _disposed) return;
            await _fullScan();
            // _startRtScan sudah dipanggil di dalam _fullScan()
            if (!_loopActive && mounted && !_disposed) _cmdLoop();
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ScaleTransition(
                scale: _phase == Phase.listening
                    ? _micScale : const AlwaysStoppedAnimation(1.0),
                child: Container(width: 76, height: 76,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                            colors: _phase == Phase.listening
                                ? [const Color(0xFF00E676), const Color(0xFF00897B)]
                                : _busy
                                ? [const Color(0xFFFFA726), const Color(0xFFE65100)]
                                : [const Color(0xFF2979FF), const Color(0xFF0D47A1)]),
                        boxShadow: [BoxShadow(
                            color: (_phase == Phase.listening
                                ? const Color(0xFF00E676)
                                : _busy ? const Color(0xFFFFA726)
                                : const Color(0xFF2979FF)).withOpacity(0.55),
                            blurRadius: 24, spreadRadius: 2)]),
                    child: Icon(
                        _busy ? Icons.hourglass_empty_rounded
                            : _phase == Phase.listening ? Icons.mic_rounded
                            : Icons.document_scanner_rounded,
                        color: Colors.white, size: 34))),
            const SizedBox(height: 6),
            Text(_phase == Phase.listening ? "Mendengar"
                : _busy ? "Proses..." : "Scan",
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ])),

      // PETA — tap untuk input tujuan via suara
      GestureDetector(
          onTap: () async {
            await _tts.stop(); _stt.stop();
            await Future.delayed(const Duration(milliseconds: 200));
            if (!mounted || _disposed) return;
            _stopRtScan();
            _loopActive = false;
            await _tts.speak("Tujuan?");
            await Future.delayed(const Duration(milliseconds: 1500));
            if (!mounted || _disposed) return;
            if (mounted) setState(() => _phase = Phase.listening);

            String dest = "";
            bool got = false;
            await _stt.listenStream(
              listenFor: const Duration(seconds: 15),
              pauseFor: const Duration(seconds: 3),
              echoGuard: const Duration(milliseconds: 1800),
              onResult: (w, isFinal) {
                if (got) return;
                final wc = w.trim().toLowerCase();
                const noise = ["iya","ya","tidak","oke","ok","halo","hai",
                  "hey","diam","stop","berhenti","engga","enggak","nggak",
                  "gak","ga","batal","cukup","selesai","test"];
                final isNoise = noise.contains(wc);
                final wc2 = wc.split(' ').length;
                if (!isNoise && (wc2 >= 2 || (wc2 == 1 && wc.length >= 4))) {
                  if (isFinal || wc2 >= 2) {
                    got = true; dest = w.trim(); _stt.stop();
                  }
                }
              },
            );
            if (!mounted || _disposed) return;
            if (dest.isNotEmpty) {
              await _doNavigate(dest);
            } else {
              await _tts.speak("Tujuan tidak terdengar.");
              _startRtScan();
            }
            if (!_loopActive && mounted && !_disposed) _cmdLoop();
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 58, height: 58,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: _navActive
                        ? const Color(0xFF10B981).withOpacity(0.2)
                        : const Color(0xFF1A2E1A),
                    border: Border.all(
                        color: _navActive
                            ? const Color(0xFF10B981)
                            : const Color(0xFF4A9E4A), width: 1.5),
                    boxShadow: [BoxShadow(
                        color: const Color(0xFF4A9E4A).withOpacity(0.25),
                        blurRadius: 12, spreadRadius: 1)]),
                child: Icon(Icons.explore_rounded,
                    color: _navActive
                        ? const Color(0xFF10B981) : const Color(0xFF7EE87E),
                    size: 26)),
            const SizedBox(height: 6),
            Text("Navigasi",
                style: TextStyle(
                    color: _navActive ? const Color(0xFF10B981) : const Color(0xFF7EE87E),
                    fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ])),
    ]),
  );
}
