import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() => runApp(const RunnerApp());

class RunnerApp extends StatelessWidget {
  const RunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Subway Dash',
      theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
      home: const GamePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// World model
// ---------------------------------------------------------------------------

/// Obstacle kinds: a train must be dodged, a low barrier jumped, a high barrier rolled under.
enum ObstacleKind { train, lowBarrier, highBarrier }

class Obstacle {
  Obstacle(this.lane, this.z, this.kind, {this.length = 1});
  final int lane; // -1, 0, 1
  double z; // distance ahead of the player (world units)
  final ObstacleKind kind;
  final double length; // depth of the obstacle (trains are long)
  final Color color = [const Color(0xFFE53935), const Color(0xFF1E88E5), const Color(0xFF43A047), const Color(0xFFFB8C00)][Random().nextInt(4)];
}

class Coin {
  Coin(this.lane, this.z, {this.height = 0});
  final int lane;
  double z;
  final double height;
  bool taken = false;
}

class Spark {
  Spark(this.pos, this.vel, this.color, this.size);
  Offset pos;
  Offset vel;
  final Color color;
  final double size;
  double life = 1;
}

class FloatText {
  FloatText(this.text, this.pos, this.color);
  final String text;
  Offset pos;
  final Color color;
  double life = 1;
}

enum GameState { ready, running, over }

// ---------------------------------------------------------------------------
// Game page
// ---------------------------------------------------------------------------

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _rnd = Random();
  final _focus = FocusNode();

  GameState _state = GameState.ready;
  Duration _last = Duration.zero;

  // Player
  int _lane = 0;
  double _laneX = 0; // smoothed lane position for animation
  double _jumpY = 0; // height above ground
  double _jumpV = 0;
  double _rollTime = 0; // > 0 while rolling
  double _runPhase = 0; // drives arm/leg swing

  // World
  final List<Obstacle> _obstacles = [];
  final List<Coin> _coins = [];
  final List<Spark> _sparks = [];
  final List<FloatText> _floats = [];
  double _speed = 18; // world units per second
  double _distance = 0;
  double _spawnZ = 40;
  int _coinsTaken = 0;
  int _best = 0;
  double _shake = 0;
  double _coinPulse = 0;

  static const double _gravity = -60;
  static const double _jumpPower = 20;
  static const double _viewDepth = 90;

  int get _score => (_distance * 2).floor() + _coinsTaken * 10;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _obstacles.clear();
      _coins.clear();
      _sparks.clear();
      _floats.clear();
      _lane = 0;
      _laneX = 0;
      _jumpY = 0;
      _jumpV = 0;
      _rollTime = 0;
      _speed = 18;
      _distance = 0;
      _spawnZ = 30;
      _coinsTaken = 0;
      _shake = 0;
      _state = GameState.running;
    });
  }

  // ---- input ----
  void _move(int dir) {
    if (_state != GameState.running) return;
    final next = (_lane + dir).clamp(-1, 1);
    if (next != _lane) {
      _lane = next;
      HapticFeedback.selectionClick();
    }
  }

  void _jump() {
    if (_state != GameState.running) return;
    if (_jumpY <= 0.01) {
      _jumpV = _jumpPower;
      _rollTime = 0;
    }
  }

  void _roll() {
    if (_state != GameState.running) return;
    _rollTime = 0.7;
    if (_jumpY > 0) _jumpV = -30; // slam down like the real game
  }

  void _onSwipe(DragEndDetails d) {
    if (_state != GameState.running) {
      _start();
      return;
    }
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < 50) return;
    if (v.dx.abs() > v.dy.abs()) {
      _move(v.dx > 0 ? 1 : -1);
    } else {
      v.dy < 0 ? _jump() : _roll();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) _move(-1);
    if (k == LogicalKeyboardKey.arrowRight) _move(1);
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.space) _jump();
    if (k == LogicalKeyboardKey.arrowDown) _roll();
    if (_state != GameState.running && k == LogicalKeyboardKey.enter) _start();
    return KeyEventResult.handled;
  }

  // ---- game loop ----
  void _onTick(Duration now) {
    final dt = ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = now;
    if (_state != GameState.running) {
      if (_sparks.isNotEmpty || _floats.isNotEmpty || _shake > 0) {
        setState(() => _updateEffects(dt));
      }
      return;
    }
    setState(() {
      _speed = min(45, _speed + dt * 0.6);
      final step = _speed * dt;
      _distance += step;
      _runPhase += dt * _speed * 0.55;
      _laneX += (_lane - _laneX) * min(1, dt * 14);

      // jump physics
      if (_jumpY > 0 || _jumpV > 0) {
        _jumpV += _gravity * dt;
        _jumpY = max(0, _jumpY + _jumpV * dt);
        if (_jumpY == 0) _jumpV = 0;
      }
      if (_rollTime > 0) _rollTime -= dt;

      for (final o in _obstacles) {
        o.z -= step;
      }
      for (final c in _coins) {
        c.z -= step;
      }
      _obstacles.removeWhere((o) => o.z + o.length < -4);
      _coins.removeWhere((c) => c.z < -4 || c.taken);

      _spawnZ -= step;
      while (_spawnZ < _viewDepth) {
        _spawnRow(_spawnZ);
        _spawnZ += 14 + _rnd.nextDouble() * 10;
      }

      _checkCoins();
      _checkCrash();
      _updateEffects(dt);
      _coinPulse = max(0, _coinPulse - dt * 3);
    });
  }

  /// Spawns one "row" of the track: obstacles in some lanes, coins in a free one.
  void _spawnRow(double z) {
    final lanes = [-1, 0, 1]..shuffle(_rnd);
    final blocked = 1 + _rnd.nextInt(2); // always leave at least one lane open
    for (var i = 0; i < blocked; i++) {
      final roll = _rnd.nextDouble();
      if (roll < 0.45) {
        _obstacles.add(Obstacle(lanes[i], z, ObstacleKind.train, length: 10 + _rnd.nextDouble() * 8));
      } else if (roll < 0.75) {
        _obstacles.add(Obstacle(lanes[i], z, ObstacleKind.lowBarrier, length: 1));
      } else {
        _obstacles.add(Obstacle(lanes[i], z, ObstacleKind.highBarrier, length: 1));
      }
    }
    final free = lanes[blocked];
    for (var i = 0; i < 5; i++) {
      _coins.add(Coin(free, z + i * 2.2));
    }
    // a coin arc over a low barrier rewards jumping
    for (final o in _obstacles.where((o) => o.z == z && o.kind == ObstacleKind.lowBarrier)) {
      for (var i = -2; i <= 2; i++) {
        _coins.add(Coin(o.lane, z + i * 1.6, height: 3.2 - (i * i) * 0.45));
      }
    }
  }

  void _checkCoins() {
    for (final c in _coins) {
      if (c.taken || c.lane != _lane) continue;
      if (c.z.abs() < 1.0 && (c.height - _jumpY).abs() < 2.2) {
        c.taken = true;
        _coinsTaken++;
        _coinPulse = 1;
        final size = MediaQuery.sizeOf(context);
        final p = Offset(size.width / 2 + _laneX * size.width * 0.28, size.height * 0.72 - _jumpY * 14);
        for (var i = 0; i < 8; i++) {
          final a = _rnd.nextDouble() * 2 * pi;
          _sparks.add(Spark(p, Offset(cos(a), sin(a)) * (60 + _rnd.nextDouble() * 120), const Color(0xFFFFD54F), 3 + _rnd.nextDouble() * 3));
        }
        _floats.add(FloatText('+10', p - const Offset(0, 30), const Color(0xFFFFD54F)));
      }
    }
  }

  void _checkCrash() {
    for (final o in _obstacles) {
      if (o.lane != _lane) continue;
      if (o.z > 0.8 || o.z + o.length < -0.6) continue;
      final hit = switch (o.kind) {
        ObstacleKind.train => true,
        ObstacleKind.lowBarrier => _jumpY < 1.6,
        ObstacleKind.highBarrier => _rollTime <= 0,
      };
      if (hit) {
        _crash();
        return;
      }
    }
  }

  void _crash() {
    HapticFeedback.heavyImpact();
    _state = GameState.over;
    _shake = 1;
    _best = max(_best, _score);
    final size = MediaQuery.sizeOf(context);
    final p = Offset(size.width / 2 + _laneX * size.width * 0.28, size.height * 0.7);
    for (var i = 0; i < 30; i++) {
      final a = _rnd.nextDouble() * 2 * pi;
      _sparks.add(Spark(p, Offset(cos(a), sin(a) - 0.6) * (80 + _rnd.nextDouble() * 260), i.isEven ? Colors.orangeAccent : Colors.white, 3 + _rnd.nextDouble() * 5));
    }
  }

  void _updateEffects(double dt) {
    for (final s in _sparks) {
      s.pos += s.vel * dt;
      s.vel = Offset(s.vel.dx * 0.96, s.vel.dy * 0.96 + 400 * dt);
      s.life -= dt * 1.6;
    }
    _sparks.removeWhere((s) => s.life <= 0);
    for (final f in _floats) {
      f.pos += Offset(0, -50 * dt);
      f.life -= dt * 1.4;
    }
    _floats.removeWhere((f) => f.life <= 0);
    _shake = max(0, _shake - dt * 2.5);
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final shake = _shake > 0 ? Offset(sin(_shake * 60) * 10 * _shake, cos(_shake * 47) * 8 * _shake) : Offset.zero;
    return Scaffold(
      backgroundColor: const Color(0xFF87CEEB),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanEnd: _onSwipe,
          onTap: () {
            if (_state != GameState.running) _start();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: shake,
                child: CustomPaint(
                  painter: WorldPainter(
                    obstacles: _obstacles,
                    coins: _coins,
                    distance: _distance,
                    laneX: _laneX,
                    jumpY: _jumpY,
                    rolling: _rollTime > 0,
                    runPhase: _runPhase,
                    crashed: _state == GameState.over,
                  ),
                ),
              ),
              CustomPaint(painter: EffectsPainter(_sparks, _floats)),
              SafeArea(child: _hud()),
              if (_state == GameState.ready) _startPanel(),
              if (_state == GameState.over) _overPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hud() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _chip(Icons.directions_run, '$_score', const Color(0xFF1E88E5)),
          const Spacer(),
          AnimatedScale(
            scale: 1 + _coinPulse * 0.25,
            duration: const Duration(milliseconds: 80),
            child: _chip(Icons.monetization_on, '$_coinsTaken', const Color(0xFFFFB300)),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 6),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _startPanel() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SUBWAY\nDASH',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 64, height: 0.95, fontWeight: FontWeight.w900, color: Colors.white, shadows: [Shadow(blurRadius: 0, offset: Offset(4, 4), color: Color(0xFFE53935))])),
          const SizedBox(height: 24),
          _button('TAP TO RUN', _start),
          const SizedBox(height: 16),
          const Text('Swipe to dodge, jump and roll', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _overPanel() {
    return Center(
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 30, offset: Offset(0, 12))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('BUSTED!', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Color(0xFFE53935))),
            const SizedBox(height: 12),
            Text('Score $_score', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            Text('Coins $_coinsTaken', style: const TextStyle(fontSize: 20, color: Color(0xFFFFA000), fontWeight: FontWeight.w700)),
            Text('Best $_best', style: const TextStyle(fontSize: 16, color: Colors.black54)),
            const SizedBox(height: 20),
            _button('PLAY AGAIN', _start),
          ],
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF43A047), Color(0xFF2E7D32)]),
          borderRadius: BorderRadius.circular(40),
          boxShadow: const [BoxShadow(color: Color(0xFF1B5E20), offset: Offset(0, 6))],
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rendering: a simple pinhole projection of the 3-lane world
// ---------------------------------------------------------------------------

class WorldPainter extends CustomPainter {
  WorldPainter({
    required this.obstacles,
    required this.coins,
    required this.distance,
    required this.laneX,
    required this.jumpY,
    required this.rolling,
    required this.runPhase,
    required this.crashed,
  });

  final List<Obstacle> obstacles;
  final List<Coin> coins;
  final double distance, laneX, jumpY, runPhase;
  final bool rolling, crashed;

  static const double laneWidth = 3.0;
  static const double camHeight = 6.0;
  static const double camBack = 8.0;
  static const double focal = 1.1;

  late Size _size;
  late double _horizon;

  /// World (x, y, z) -> screen. z is distance ahead of the player.
  Offset project(double x, double y, double z) {
    final depth = z + camBack;
    final s = focal * _size.width / depth;
    final camX = laneX * laneWidth * 0.35; // camera follows the player a little
    return Offset(_size.width / 2 + (x - camX) * s, _horizon + (camHeight - y) * s);
  }

  double scaleAt(double z) => focal * _size.width / (z + camBack);

  @override
  void paint(Canvas canvas, Size size) {
    _size = size;
    _horizon = size.height * 0.36;

    _sky(canvas, size);
    _ground(canvas, size);
    _buildings(canvas);

    // painter's algorithm: draw far things first
    final items = <(double, void Function())>[];
    for (final o in obstacles) {
      if (o.z < 120) items.add((o.z + o.length, () => _obstacle(canvas, o)));
    }
    for (final c in coins) {
      if (!c.taken && c.z > -2 && c.z < 90) items.add((c.z, () => _coin(canvas, c)));
    }
    items.add((0.0, () => _player(canvas)));
    items.sort((a, b) => b.$1.compareTo(a.$1));
    for (final i in items) {
      i.$2();
    }
  }

  void _sky(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, _horizon + 2);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4FC3F7), Color(0xFFB3E5FC), Color(0xFFFFE0B2)],
        ).createShader(rect),
    );
    canvas.drawCircle(Offset(size.width * 0.8, _horizon * 0.35), 34, Paint()..color = const Color(0xFFFFF59D));
  }

  void _ground(Canvas canvas, Size size) {
    // gravel bed
    final far = 140.0, near = -camBack + 0.5;
    final bed = Path()
      ..moveTo(project(-laneWidth * 2.2, 0, far).dx, project(0, 0, far).dy)
      ..lineTo(project(laneWidth * 2.2, 0, far).dx, project(0, 0, far).dy)
      ..lineTo(project(laneWidth * 2.2, 0, near).dx, size.height + 400)
      ..lineTo(project(-laneWidth * 2.2, 0, near).dx, size.height + 400)
      ..close();
    canvas.drawRect(Rect.fromLTWH(0, _horizon, size.width, size.height), Paint()..color = const Color(0xFF6D8B3A));
    canvas.drawPath(bed, Paint()..color = const Color(0xFF8D7B68));

    // sleepers scroll toward the camera
    final sleeper = Paint()..color = const Color(0xFF5D4037);
    final offset = distance % 2.0;
    for (double z = 60 - offset; z > -camBack + 1; z -= 2.0) {
      for (var lane = -1; lane <= 1; lane++) {
        final x = lane * laneWidth;
        final a = project(x - 1.3, 0, z), b = project(x + 1.3, 0, z);
        final c = project(x + 1.3, 0, z - 0.45), d = project(x - 1.3, 0, z - 0.45);
        canvas.drawPath(Path()..addPolygon([a, b, c, d], true), sleeper);
      }
    }
    // rails
    final rail = Paint()
      ..color = const Color(0xFFCFD8DC)
      ..strokeWidth = 3;
    for (var lane = -1; lane <= 1; lane++) {
      for (final side in [-0.75, 0.75]) {
        final x = lane * laneWidth + side;
        canvas.drawLine(project(x, 0, 80), project(x, 0, -camBack + 1), rail);
      }
    }
    // distance fog
    final fog = Rect.fromLTWH(0, _horizon, size.width, scaleAt(60) * 2);
    canvas.drawRect(
      fog,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFFFFE0B2), const Color(0xFFFFE0B2).withValues(alpha: 0)],
        ).createShader(fog),
    );
  }

  void _buildings(Canvas canvas) {
    final colors = [const Color(0xFFEF9A9A), const Color(0xFFFFCC80), const Color(0xFF90CAF9), const Color(0xFFA5D6A7), const Color(0xFFCE93D8)];
    final offset = distance % 12.0;
    var i = (distance / 12).floor();
    for (double z = 96 - offset; z - 10 > -camBack - 10; z -= 12, i--) {
      for (final side in [-1, 1]) {
        final x = side * laneWidth * 2.6;
        final h = 9.0 + ((i * 7 + side * 3) % 5) * 3;
        final w = 4.0;
        final color = colors[(i + side).abs() % colors.length];
        final front = [project(x - w / 2, 0, z), project(x + w / 2, 0, z), project(x + w / 2, h, z), project(x - w / 2, h, z)];
        final inner = side < 0 ? x + w / 2 : x - w / 2;
        // clip the side wall at a near plane in front of the camera:
        // points at or behind the camera project to huge, flipped triangles
        const nearZ = -camBack + 1.5;
        final backZ = max(z - 10, nearZ);
        final sideFace = [project(inner, 0, max(z, nearZ)), project(inner, 0, backZ), project(inner, h, backZ), project(inner, h, max(z, nearZ))];
        canvas.drawPath(Path()..addPolygon(sideFace, true), Paint()..color = Color.lerp(color, Colors.black, 0.25)!);
        if (z < nearZ) continue; // front face is behind the near plane
        canvas.drawPath(Path()..addPolygon(front, true), Paint()..color = color);
        // windows
        final win = Paint()..color = Colors.white.withValues(alpha: 0.55);
        for (double wy = 2; wy < h - 1; wy += 2.5) {
          for (final wx in [-1.0, 0.6]) {
            final p1 = project(x + wx, wy, z), p2 = project(x + wx + 0.6, wy + 1.2, z);
            canvas.drawRect(Rect.fromPoints(p1, p2), win);
          }
        }
      }
    }
  }

  void _box(Canvas canvas, double x, double w, double h, double z0, double z1, Color color, {double y0 = 0}) {
    // visible faces: top, the side facing the centre of the screen, and the front
    final l = x - w / 2, r = x + w / 2;
    final top = [project(l, y0 + h, z0), project(r, y0 + h, z0), project(r, y0 + h, z1), project(l, y0 + h, z1)];
    canvas.drawPath(Path()..addPolygon(top, true), Paint()..color = Color.lerp(color, Colors.white, 0.3)!);
    final camX = laneX * laneWidth * 0.35;
    final sx = x > camX ? l : r;
    final side = [project(sx, y0, z0), project(sx, y0, z1), project(sx, y0 + h, z1), project(sx, y0 + h, z0)];
    canvas.drawPath(Path()..addPolygon(side, true), Paint()..color = Color.lerp(color, Colors.black, 0.3)!);
    final front = [project(l, y0, z0), project(r, y0, z0), project(r, y0 + h, z0), project(l, y0 + h, z0)];
    canvas.drawPath(Path()..addPolygon(front, true), Paint()..color = color);
  }

  void _obstacle(Canvas canvas, Obstacle o) {
    final x = o.lane * laneWidth;
    final z0 = max(o.z, -camBack + 1.5);
    final z1 = o.z + o.length;
    if (z1 <= z0) return;
    switch (o.kind) {
      case ObstacleKind.train:
        _box(canvas, x, 2.6, 4.2, z0, z1, o.color, y0: 0.2);
        if (o.z > -camBack + 1.5) {
          // windscreen and headlights on the front face
          final a = project(x - 1.0, 2.6, o.z), b = project(x + 1.0, 3.8, o.z);
          canvas.drawRect(Rect.fromPoints(a, b), Paint()..color = const Color(0xFF263238));
          final s = scaleAt(o.z);
          for (final lx in [-0.8, 0.8]) {
            canvas.drawCircle(project(x + lx, 1.0, o.z), 0.28 * s, Paint()..color = const Color(0xFFFFF9C4));
          }
          final stripe = [project(x - 1.3, 1.8, o.z), project(x + 1.3, 1.8, o.z), project(x + 1.3, 2.1, o.z), project(x - 1.3, 2.1, o.z)];
          canvas.drawPath(Path()..addPolygon(stripe, true), Paint()..color = Colors.white);
        }
      case ObstacleKind.lowBarrier:
        _box(canvas, x, 2.6, 1.2, z0, z1, const Color(0xFFFFFFFF));
        for (var i = 0; i < 3; i++) {
          final p1 = project(x - 1.3 + i * 0.9, 0.2, o.z), p2 = project(x - 0.85 + i * 0.9, 1.2, o.z);
          canvas.drawRect(Rect.fromPoints(p1, p2), Paint()..color = const Color(0xFFE53935));
        }
      case ObstacleKind.highBarrier:
        for (final px in [-1.2, 1.2]) {
          _box(canvas, x + px, 0.25, 3.2, z0, z0 + 0.3, const Color(0xFF607D8B));
        }
        _box(canvas, x, 2.8, 1.0, z0, z1, const Color(0xFFFFC107), y0: 2.6);
        final s = scaleAt(o.z);
        final tp = TextPainter(
          text: TextSpan(text: 'STOP', style: TextStyle(color: Colors.black, fontSize: 0.6 * s, fontWeight: FontWeight.w900)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, project(x, 3.1, o.z) - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _coin(Canvas canvas, Coin c) {
    final p = project(c.lane * laneWidth, 1.2 + c.height, c.z);
    final s = scaleAt(c.z);
    final spin = cos(distance * 0.8 + c.z * 0.5);
    final rect = Rect.fromCenter(center: p, width: 1.0 * s * spin.abs().clamp(0.15, 1.0), height: 1.0 * s);
    canvas.drawOval(rect.inflate(0.12 * s), Paint()..color = const Color(0xFFFF8F00));
    canvas.drawOval(rect, Paint()..color = const Color(0xFFFFD54F));
    canvas.drawOval(rect.deflate(0.22 * s), Paint()..color = const Color(0xFFFFECB3).withValues(alpha: 0.7));
  }

  void _player(Canvas canvas) {
    final x = laneX * laneWidth;
    final s = scaleAt(0);
    final foot = project(x, jumpY, 0);
    final squash = rolling ? 0.55 : 1.0;
    // shadow on the ground
    final shadowC = project(x, 0, 0);
    canvas.drawOval(Rect.fromCenter(center: shadowC, width: 1.6 * s / (1 + jumpY * 0.1), height: 0.45 * s), Paint()..color = Colors.black.withValues(alpha: 0.3));

    canvas.save();
    canvas.translate(foot.dx, foot.dy);
    canvas.scale(s / 40, s / 40 * squash);
    final swing = crashed ? 0.0 : sin(runPhase) * (jumpY > 0 ? 0.3 : 1.0);

    final skin = Paint()..color = const Color(0xFFFFCC99);
    final shirt = Paint()..color = const Color(0xFF00897B);
    final pants = Paint()..color = const Color(0xFF283593);
    final shoe = Paint()..color = Colors.white;
    final cap = Paint()..color = const Color(0xFFE53935);

    if (rolling) {
      // tucked into a ball
      canvas.drawCircle(const Offset(0, -38), 30, shirt);
      canvas.drawCircle(const Offset(0, -62), 16, cap);
    } else {
      // legs (seen from behind, swing up and down)
      for (final side in [-1, 1]) {
        final lift = swing * side * 10;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(side * 9 - 7, -44 - lift, 14, 40 + lift), const Radius.circular(6)), pants);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(side * 9 - 9, -8 - lift, 18, 10), const Radius.circular(5)), shoe);
      }
      // body and backpack
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-20, -90, 40, 50), const Radius.circular(12)), shirt);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-14, -84, 28, 30), const Radius.circular(8)), Paint()..color = const Color(0xFFFFB300));
      // arms
      for (final side in [-1, 1]) {
        canvas.save();
        canvas.translate(side * 22.0, -84);
        canvas.rotate(-swing * side * 0.6 + (jumpY > 0 ? side * -0.9 : 0));
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-6, 0, 12, 34), const Radius.circular(6)), shirt);
        canvas.drawCircle(const Offset(0, 36), 6, skin);
        canvas.restore();
      }
      // head with cap (from behind)
      canvas.drawCircle(const Offset(0, -106), 17, skin);
      canvas.drawArc(Rect.fromCircle(center: const Offset(0, -108), radius: 18), pi, pi, true, cap);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-18, -112, 36, 6), const Radius.circular(3)), cap);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class EffectsPainter extends CustomPainter {
  EffectsPainter(this.sparks, this.floats);
  final List<Spark> sparks;
  final List<FloatText> floats;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in sparks) {
      canvas.drawCircle(s.pos, s.size * s.life, Paint()..color = s.color.withValues(alpha: s.life.clamp(0, 1)));
    }
    for (final f in floats) {
      final tp = TextPainter(
        text: TextSpan(
          text: f.text,
          style: TextStyle(
            color: f.color.withValues(alpha: f.life.clamp(0, 1)),
            fontSize: 26,
            fontWeight: FontWeight.w900,
            shadows: const [ui.Shadow(color: Colors.black54, blurRadius: 4)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, f.pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
