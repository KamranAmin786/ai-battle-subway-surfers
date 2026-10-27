
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );
  runApp(const MetroDashApp());
}

class MetroDashApp extends StatelessWidget {
  const MetroDashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Metro Dash',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const RunnerGame(),
    );
  }
}

// ============================================================
// GAME CONFIGURATION
// ============================================================

class GameConfig {
  static const double viewDistance = 115;
  static const double playerZ = 7;
  static const double initialSpeed = 27;
  static const double maxSpeed = 64;
  static const double gravity = 30;
  static const double jumpVelocity = 12.5;
  static const double rollDuration = 0.85;
  static const double laneChangeSpeed = 12;
}

enum GamePhase { ready, playing, gameOver }

enum ObstacleType { train, barrier, overhead, coin }

class GameObject {
  GameObject({
    required this.type,
    required this.lane,
    required this.z,
    this.variant = 0,
  });

  final ObstacleType type;
  final int lane;
  double z;
  final int variant;
  bool collected = false;
  bool resolved = false;

  double get length {
    switch (type) {
      case ObstacleType.train:
        return 13;
      case ObstacleType.barrier:
        return 1.5;
      case ObstacleType.overhead:
        return 2;
      case ObstacleType.coin:
        return 0;
    }
  }
}

class Particle {
  Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.color,
    required this.radius,
  });

  double x, y, vx, vy, life;
  final double radius;
  final Color color;
  double age = 0;

  double get opacity =>
      (1 - age / life).clamp(0.0, 1.0);

  bool get alive => age < life;
}

class FloatingText {
  FloatingText(this.text, this.x, this.y, this.color);

  final String text;
  final double x, y;
  final Color color;
  double age = 0;
}

class SceneryItem {
  SceneryItem(this.z, this.side, this.kind);

  double z;
  final int side;
  final int kind;
}

// ============================================================
// GAME STATE / UPDATE LOOP
// ============================================================

class RunnerGame extends StatefulWidget {
  const RunnerGame({super.key});

  @override
  State<RunnerGame> createState() => _RunnerGameState();
}

class _RunnerGameState extends State<RunnerGame>
    with SingleTickerProviderStateMixin {
  late AnimationController _ticker;
  final math.Random _random = math.Random();

  GamePhase _phase = GamePhase.ready;

  final List<GameObject> _objects = [];
  final List<Particle> _particles = [];
  final List<FloatingText> _texts = [];
  final List<SceneryItem> _scenery = [];

  int _lane = 1;
  double _visualLane = 1;

  double _jumpHeight = 0;
  double _jumpV = 0;
  double _rollTime = 0;

  double _distance = 0;
  double _speed = GameConfig.initialSpeed;
  double _spawnDistance = 0;
  double _worldTime = 0;
  double _trackOffset = 0;

  int _coins = 0;
  int _score = 0;
  int _bestScore = 0;

  double _shake = 0;
  double _flash = 0;
  double _coinPulse = 0;
  double _nearMissCooldown = 0;

  Duration _previousElapsed = Duration.zero;

  Offset? _touchStart;
  bool _gestureConsumed = false;

  double _screenWidth = 390;
  double _screenHeight = 844;

  bool get _jumping => _jumpHeight > 0.05;
  bool get _rolling => _rollTime > 0;

  @override
  void initState() {
    super.initState();

    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(days: 1),
    );

    _ticker.addListener(_tick);
    _resetWorld();
    _ticker.forward();
  }

  void _resetWorld() {
    _objects.clear();
    _particles.clear();
    _texts.clear();
    _scenery.clear();

    _lane = 1;
    _visualLane = 1;

    _jumpHeight = 0;
    _jumpV = 0;
    _rollTime = 0;

    _distance = 0;
    _speed = GameConfig.initialSpeed;
    _spawnDistance = 0;
    _worldTime = 0;
    _trackOffset = 0;

    _coins = 0;
    _score = 0;

    _shake = 0;
    _flash = 0;
    _coinPulse = 0;
    _nearMissCooldown = 0;

    for (int i = 0; i < 38; i++) {
      _scenery.add(
        SceneryItem(
          _random.nextDouble() * 135,
          i.isEven ? -1 : 1,
          _random.nextInt(5),
        ),
      );
    }

    // Safe introductory coins.
    for (int i = 0; i < 7; i++) {
      _objects.add(
        GameObject(
          type: ObstacleType.coin,
          lane: 1,
          z: 28 + i * 5.5,
        ),
      );
    }

    _spawnDistance = 65;
  }

  void _startGame() {
    setState(() {
      _resetWorld();
      _phase = GamePhase.playing;
      _previousElapsed = _ticker.lastElapsedDuration ??
          Duration.zero;
    });

    HapticFeedback.lightImpact();
  }

  void _tick() {
    final elapsed =
        _ticker.lastElapsedDuration ?? Duration.zero;

    double dt =
        (elapsed - _previousElapsed).inMicroseconds /
            1000000.0;

    _previousElapsed = elapsed;

    if (dt <= 0 || dt > 0.2) {
      dt = 1 / 60;
    }

    dt = dt.clamp(0.001, 0.033);

    _worldTime += dt;

    _updateParticles(dt);
    _updateFloatingTexts(dt);

    _shake = math.max(0, _shake - dt * 3.5);
    _flash = math.max(0, _flash - dt * 2.5);
    _coinPulse = math.max(0, _coinPulse - dt * 3);
    _nearMissCooldown =
        math.max(0, _nearMissCooldown - dt);

    if (_phase == GamePhase.playing) {
      _updateGame(dt);
    } else if (_phase == GamePhase.ready) {
      _trackOffset += dt * 8;
    }

    if (mounted) setState(() {});
  }

  void _updateGame(double dt) {
    _distance += _speed * dt;
    _trackOffset += _speed * dt;

    _speed = math.min(
      GameConfig.maxSpeed,
      GameConfig.initialSpeed + _distance * 0.012,
    );

    _score = (_distance * 2).floor() + _coins * 25;

    final laneDelta = _lane - _visualLane;
    final move = GameConfig.laneChangeSpeed * dt;

    if (laneDelta.abs() <= move) {
      _visualLane = _lane.toDouble();
    } else {
      _visualLane += laneDelta.sign * move;
    }

    if (_jumpHeight > 0 || _jumpV > 0) {
      _jumpHeight += _jumpV * dt;
      _jumpV -= GameConfig.gravity * dt;

      if (_jumpHeight <= 0) {
        _jumpHeight = 0;
        _jumpV = 0;
        _spawnLandingDust();
      }
    }

    if (_rollTime > 0) {
      _rollTime = math.max(0, _rollTime - dt);
    }

    for (final object in _objects) {
      object.z -= _speed * dt;
    }

    _objects.removeWhere(
      (o) => o.z < -22 || o.collected,
    );

    for (final item in _scenery) {
      item.z -= _speed * dt * 0.9;

      if (item.z < -8) {
        item.z += 135 + _random.nextDouble() * 25;
      }
    }

    _spawnDistance -= _speed * dt;

    if (_spawnDistance <= 0) {
      _spawnPattern();

      final difficulty =
          ((_speed - GameConfig.initialSpeed) /
                  (GameConfig.maxSpeed -
                      GameConfig.initialSpeed))
              .clamp(0.0, 1.0);

      _spawnDistance =
          24 + _random.nextDouble() * 12 -
              difficulty * 7;
    }

    _checkCollisions();
  }

  void _spawnPattern() {
    const double startZ = 125;

    final pattern = _random.nextInt(9);
    final a = _random.nextInt(3);
    final b = (a + 1 + _random.nextInt(2)) % 3;
    final safe = 3 - a - b;

    switch (pattern) {
      case 0:
        _addObstacle(ObstacleType.barrier, a, startZ);
        _spawnCoinLine(b, startZ - 6, 5);
        break;

      case 1:
        _addObstacle(ObstacleType.train, a, startZ);
        _spawnCoinLine(b, startZ - 8, 5);
        break;

      case 2:
        _addObstacle(ObstacleType.overhead, a, startZ);
        _spawnCoinLine(a, startZ - 10, 3);
        _spawnCoinLine(b, startZ - 3, 3);
        break;

      case 3:
        _addObstacle(ObstacleType.barrier, a, startZ);
        _addObstacle(ObstacleType.barrier, b, startZ);
        _spawnCoinLine(safe, startZ - 8, 6);
        break;

      case 4:
        _addObstacle(ObstacleType.train, a, startZ);
        _addObstacle(ObstacleType.barrier, b, startZ);
        _spawnCoinLine(safe, startZ - 9, 5);
        break;

      case 5:
        _spawnCoinLine(a, startZ - 15, 8);
        break;

      case 6:
        _addObstacle(ObstacleType.overhead, a, startZ);
        _addObstacle(ObstacleType.train, b, startZ);
        _spawnCoinLine(safe, startZ - 10, 5);
        break;

      case 7:
        _addObstacle(ObstacleType.barrier, a, startZ);
        _spawnCoinLine(
          b,
          startZ - 3,
          7,
          spacing: 3.7,
        );
        break;

      default:
        _addObstacle(ObstacleType.train, a, startZ);
        _spawnCoinLine(safe, startZ - 6, 6);
    }
  }

  void _addObstacle(
    ObstacleType type,
    int lane,
    double z,
  ) {
    _objects.add(
      GameObject(
        type: type,
        lane: lane,
        z: z,
        variant: _random.nextInt(4),
      ),
    );
  }

  void _spawnCoinLine(
    int lane,
    double startZ,
    int count, {
    double spacing = 4.5,
  }) {
    for (int i = 0; i < count; i++) {
      _objects.add(
        GameObject(
          type: ObstacleType.coin,
          lane: lane,
          z: startZ + i * spacing,
        ),
      );
    }
  }

  void _checkCollisions() {
    for (final o in _objects) {
      if (o.resolved || o.collected) continue;

      final sameLane =
          (_visualLane - o.lane).abs() < 0.34;

      if (!sameLane) continue;

      if (o.type == ObstacleType.coin) {
        if ((o.z - GameConfig.playerZ).abs() < 2.8) {
          o.collected = true;
          _coins++;
          _coinPulse = 1;

          _spawnCoinParticles(o.lane);

          _texts.add(
            FloatingText(
              '+25',
              _laneScreenX(o.lane),
              _screenHeight * 0.65,
              const Color(0xFFFFD54F),
            ),
          );

          HapticFeedback.selectionClick();
        }
        continue;
      }

      final delta = o.z - GameConfig.playerZ;

      if (delta < -1.8 || delta > 2.5) {
        continue;
      }

      bool safe = false;

      switch (o.type) {
        case ObstacleType.barrier:
          safe = _jumpHeight > 1.25;
          break;

        case ObstacleType.overhead:
          safe = _rolling;
          break;

        case ObstacleType.train:
          safe = false;
          break;

        case ObstacleType.coin:
          safe = true;
          break;
      }

      if (!safe) {
        _gameOver();
        return;
      }

      o.resolved = true;

      if (_nearMissCooldown <= 0) {
        _nearMissCooldown = 0.6;
        _texts.add(
          FloatingText(
            'NICE!',
            _screenWidth / 2,
            _screenHeight * 0.46,
            const Color(0xFF76FFB3),
          ),
        );
      }
    }
  }

  void _gameOver() {
    if (_phase != GamePhase.playing) return;

    _phase = GamePhase.gameOver;
    _shake = 1;
    _flash = 0.7;

    if (_score > _bestScore) {
      _bestScore = _score;
    }

    _spawnCrashParticles();
    HapticFeedback.heavyImpact();
  }

  void _changeLane(int direction) {
    if (_phase != GamePhase.playing) return;

    final next = (_lane + direction).clamp(0, 2);

    if (next != _lane) {
      _lane = next;
      HapticFeedback.selectionClick();
    }
  }

  void _jump() {
    if (_phase != GamePhase.playing) return;

    if (!_jumping && !_rolling) {
      _jumpV = GameConfig.jumpVelocity;
      _jumpHeight = 0.01;
      _spawnLandingDust();
      HapticFeedback.lightImpact();
    }
  }

  void _roll() {
    if (_phase != GamePhase.playing) return;

    if (_jumping) {
      // Fast-drop for responsive midair controls.
      _jumpV = -17;
    } else {
      _rollTime = GameConfig.rollDuration;
      HapticFeedback.lightImpact();
    }
  }

  void _handleSwipe(Offset delta) {
    if (_phase == GamePhase.ready) {
      _startGame();
      return;
    }

    if (_phase == GamePhase.gameOver) return;

    if (delta.distance < 22) return;

    if (delta.dx.abs() > delta.dy.abs()) {
      _changeLane(delta.dx > 0 ? 1 : -1);
    } else {
      if (delta.dy < 0) {
        _jump();
      } else {
        _roll();
      }
    }
  }

  void _updateParticles(double dt) {
    for (final p in _particles) {
      p.age += dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vy += 130 * dt;
    }

    _particles.removeWhere((p) => !p.alive);
  }

  void _updateFloatingTexts(double dt) {
    for (final text in _texts) {
      text.age += dt;
    }

    _texts.removeWhere((t) => t.age > 1);
  }

  double _laneScreenX(int lane) {
    final width = _screenWidth * 0.78;
    return _screenWidth / 2 +
        (lane - 1) * width / 3;
  }

  void _spawnCoinParticles(int lane) {
    final x = _laneScreenX(lane);
    final y = _screenHeight * 0.72;

    for (int i = 0; i < 15; i++) {
      final angle = _random.nextDouble() * math.pi * 2;
      final speed = 70 + _random.nextDouble() * 230;

      _particles.add(
        Particle(
          x: x,
          y: y,
          vx: math.cos(angle) * speed,
          vy: math.sin(angle) * speed - 45,
          life: 0.35 + _random.nextDouble() * 0.35,
          radius: 2 + _random.nextDouble() * 5,
          color: i.isEven
              ? const Color(0xFFFFEB70)
              : const Color(0xFFFF9D2E),
        ),
      );
    }
  }

  void _spawnLandingDust() {
    final x = _laneScreenX(_lane);
    final y = _screenHeight * 0.83;

    for (int i = 0; i < 8; i++) {
      _particles.add(
        Particle(
          x: x,
          y: y,
          vx: (_random.nextDouble() - 0.5) * 180,
          vy: -_random.nextDouble() * 90,
          life: 0.3 + _random.nextDouble() * 0.3,
          radius: 2 + _random.nextDouble() * 3,
          color: const Color(0xFFA8E6F7),
        ),
      );
    }
  }

  void _spawnCrashParticles() {
    final x = _laneScreenX(_lane);
    final y = _screenHeight * 0.74;

    for (int i = 0; i < 50; i++) {
      final angle = _random.nextDouble() * math.pi * 2;
      final speed = 80 + _random.nextDouble() * 330;

      _particles.add(
        Particle(
          x: x,
          y: y,
          vx: math.cos(angle) * speed,
          vy: math.sin(angle) * speed - 80,
          life: 0.5 + _random.nextDouble() * 0.65,
          radius: 2 + _random.nextDouble() * 6,
          color: [
            const Color(0xFFFFD54F),
            const Color(0xFFFF5252),
            const Color(0xFF40E0D0),
            Colors.white,
          ][_random.nextInt(4)],
        ),
      );
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ==========================================================
  // USER INTERFACE
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF102449),
      body: LayoutBuilder(
        builder: (context, constraints) {
          _screenWidth = constraints.maxWidth;
          _screenHeight = constraints.maxHeight;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              _touchStart = details.localPosition;
              _gestureConsumed = false;
            },
            onPanUpdate: (details) {
              if (_touchStart == null || _gestureConsumed) {
                return;
              }

              final delta =
                  details.localPosition - _touchStart!;

              if (delta.distance > 30) {
                _gestureConsumed = true;
                _handleSwipe(delta);
              }
            },
            onPanEnd: (_) {
              _touchStart = null;
            },
            onTap: () {
              if (_phase == GamePhase.ready) {
                _startGame();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: GamePainter(
                    objects: _objects,
                    scenery: _scenery,
                    particles: _particles,
                    texts: _texts,
                    visualLane: _visualLane,
                    jumpHeight: _jumpHeight,
                    rolling: _rolling,
                    worldTime: _worldTime,
                    trackOffset: _trackOffset,
                    speed: _speed,
                    shake: _shake,
                    flash: _flash,
                    phase: _phase,
                  ),
                ),

                if (_phase == GamePhase.playing)
                  _buildHUD(),

                if (_phase == GamePhase.ready)
                  _buildStartScreen(),

                if (_phase == GamePhase.gameOver)
                  _buildGameOverScreen(),

                if (_phase == GamePhase.playing)
                  _buildControlsHint(),

                if (_flash > 0)
                  IgnorePointer(
                    child: Container(
                      color: Colors.white.withValues(
                        alpha: _flash * 0.23,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHUD() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 12,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _hudCard(
                    icon: Icons.bolt_rounded,
                    iconColor: const Color(0xFF5FFFE2),
                    title: 'SCORE',
                    value: _score.toString(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Transform.scale(
                    scale: 1 + _coinPulse * 0.08,
                    child: _hudCard(
                      icon: Icons.monetization_on_rounded,
                      iconColor: const Color(0xFFFFDA55),
                      title: 'COINS',
                      value: _coins.toString(),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF102341)
                      .withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: Colors.white24,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.speed_rounded,
                      color: Color(0xFF75FFE7),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${(_speed / GameConfig.initialSpeed).toStringAsFixed(1)}x SPEED',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hudCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF10294F).withValues(alpha: 0.94),
            const Color(0xFF0A1935).withValues(alpha: 0.89),
          ],
        ),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.16),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 30),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartScreen() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF09152E)
                .withValues(alpha: 0.22),
            Colors.transparent,
            const Color(0xFF07152F)
                .withValues(alpha: 0.9),
          ],
          stops: const [0, 0.38, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Transform.rotate(
              angle: -0.045,
              child: Column(
                children: [
                  Text(
                    'METRO',
                    style: TextStyle(
                      fontSize: math.min(
                        _screenWidth * 0.17,
                        74,
                      ),
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      letterSpacing: -3,
                      height: 0.95,
                      color: const Color(0xFFFFE05E),
                      shadows: const [
                        Shadow(
                          color: Color(0xFFFB7439),
                          offset: Offset(4, 5),
                          blurRadius: 0,
                        ),
                        Shadow(
                          color: Color(0xFF152A55),
                          offset: Offset(6, 9),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    'DASH',
                    style: TextStyle(
                      fontSize: math.min(
                        _screenWidth * 0.21,
                        90,
                      ),
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      height: 0.95,
                      letterSpacing: 2,
                      color: const Color(0xFF69FCE7),
                      shadows: const [
                        Shadow(
                          color: Color(0xFF158BBB),
                          offset: Offset(5, 6),
                          blurRadius: 0,
                        ),
                        Shadow(
                          color: Color(0xFF152A55),
                          offset: Offset(7, 10),
                          blurRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF112A4E),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: const Color(0xFF69FCE7),
                  width: 1.5,
                ),
              ),
              child: const Text(
                'RUN  •  DODGE  •  COLLECT',
                style: TextStyle(
                  color: Color(0xFFB7FFF1),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ),
            const Spacer(flex: 3),
            _primaryButton(
              label: 'LET\'S RUN!',
              icon: Icons.play_arrow_rounded,
              onPressed: _startGame,
            ),
            const SizedBox(height: 28),
            const Text(
              'SWIPE TO SURVIVE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: Color(0xFFD5F9FF),
              ),
            ),
            const SizedBox(height: 14),
            _buildGestureLegend(),
            const SizedBox(height: 38),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureLegend() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _gestureItem(Icons.swap_horiz_rounded, 'MOVE'),
        const SizedBox(width: 25),
        _gestureItem(Icons.arrow_upward_rounded, 'JUMP'),
        const SizedBox(width: 25),
        _gestureItem(Icons.arrow_downward_rounded, 'ROLL'),
      ],
    );
  }

  Widget _gestureItem(IconData icon, String label) {
    return Column(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFF17385A)
                .withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white30,
            ),
          ),
          child: Icon(
            icon,
            color: const Color(0xFF76FFE9),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _buildControlsHint() {
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 400),
          opacity: _distance < 90 ? 0.9 : 0,
          child: const Center(
            child: Text(
              '←  SWIPE TO MOVE  →',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                shadows: [
                  Shadow(
                    color: Colors.black,
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGameOverScreen() {
    return Container(
      color: const Color(0xDD08162D),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.flash_on_rounded,
                  color: Color(0xFFFFDA55),
                  size: 65,
                ),
                const SizedBox(height: 8),
                const Text(
                  'RUN OVER!',
                  style: TextStyle(
                    color: Color(0xFFFFD557),
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Amazing run! Ready for another?',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF244772),
                        Color(0xFF11284D),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                      color: Colors.white24,
                    ),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'FINAL SCORE',
                        style: TextStyle(
                          color: Color(0xFF9EDBEB),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '$_score',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 55,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Divider(
                        height: 32,
                        color: Colors.white24,
                      ),
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceAround,
                        children: [
                          _resultStat(
                            Icons.monetization_on_rounded,
                            '$_coins',
                            'COINS',
                            const Color(0xFFFFD653),
                          ),
                          _resultStat(
                            Icons.route_rounded,
                            '${_distance.floor()}m',
                            'DISTANCE',
                            const Color(0xFF74FEE5),
                          ),
                          _resultStat(
                            Icons.emoji_events_rounded,
                            '$_bestScore',
                            'BEST',
                            const Color(0xFFFF9D71),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                _primaryButton(
                  label: 'RUN AGAIN',
                  icon: Icons.replay_rounded,
                  onPressed: _startGame,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultStat(
    IconData icon,
    String value,
    String label,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, color: color, size: 25),
        const SizedBox(height: 7),
        Text(
          value,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: math.min(_screenWidth * 0.78, 330),
      height: 65,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFFFFE477),
            Color(0xFFFFA83D),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFFF3A6),
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0xFFB75A21),
            offset: Offset(0, 6),
            blurRadius: 0,
          ),
          BoxShadow(
            color: Color(0x66FFB54D),
            blurRadius: 22,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 29,
                color: const Color(0xFF49301B),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF49301B),
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// CUSTOM 3D-STYLE GAME RENDERER
// ============================================================

class GamePainter extends CustomPainter {
  GamePainter({
    required this.objects,
    required this.scenery,
    required this.particles,
    required this.texts,
    required this.visualLane,
    required this.jumpHeight,
    required this.rolling,
    required this.worldTime,
    required this.trackOffset,
    required this.speed,
    required this.shake,
    required this.flash,
    required this.phase,
  });

  final List<GameObject> objects;
  final List<SceneryItem> scenery;
  final List<Particle> particles;
  final List<FloatingText> texts;

  final double visualLane;
  final double jumpHeight;
  final bool rolling;
  final double worldTime;
  final double trackOffset;
  final double speed;
  final double shake;
  final double flash;
  final GamePhase phase;

  late Canvas canvas;
  late Size size;

  double get w => size.width;
  double get h => size.height;

  double get horizon => h * 0.31;
  double get ground => h * 0.96;
  double get centerX => w * 0.5;

  final Paint _p = Paint()
    ..isAntiAlias = true;

  // Perspective scale. Objects grow as they approach.
  double depthT(double z) {
    final normalized =
        (1 - z / GameConfig.viewDistance).clamp(0.0, 1.0);

    return math.pow(normalized, 1.65).toDouble();
  }

  double roadY(double z) {
    return horizon + (ground - horizon) * depthT(z);
  }

  double roadHalfWidth(double z) {
    return w * (0.105 + depthT(z) * 0.48);
  }

  double laneX(double lane, double z) {
    return centerX +
        (lane - 1) * roadHalfWidth(z) * 2 / 3;
  }

  double objectScale(double z) {
    return 0.13 + depthT(z) * 1.18;
  }

  @override
  void paint(Canvas canvas, Size size) {
    this.canvas = canvas;
    this.size = size;

    canvas.save();

    if (shake > 0) {
      canvas.translate(
        math.sin(worldTime * 85) * shake * 9,
        math.cos(worldTime * 70) * shake * 6,
      );
    }

    _drawSky();
    _drawSun();
    _drawCity();
    _drawMountains();
    _drawEnvironment();
    _drawRoad();
    _drawTrackDetails();
    _drawScenery();
    _drawObjects();
    _drawRunner();
    _drawParticles();
    _drawFloatingTexts();
    _drawAtmosphere();

    canvas.restore();
  }

  void _drawSky() {
    final rect = Rect.fromLTWH(0, 0, w, h);

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF162B6C),
            Color(0xFF3769B1),
            Color(0xFF64CEDC),
            Color(0xFFFFBA81),
          ],
          stops: [0, 0.35, 0.7, 1],
        ).createShader(rect),
    );

    // Soft atmospheric glow.
    canvas.drawCircle(
      Offset(w * 0.76, horizon * 0.78),
      w * 0.52,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x88FFCE8B),
            const Color(0x00FFCE8B),
          ],
        ).createShader(
          Rect.fromCircle(
            center: Offset(w * 0.76, horizon * 0.78),
            radius: w * 0.52,
          ),
        ),
    );

    for (int i = 0; i < 7; i++) {
      final x = ((i * 113.0 + 37) % (w + 150)) - 75;
      final y = h * (0.095 + (i % 3) * 0.055);

      _drawCloud(
        Offset(x, y),
        0.65 + (i % 3) * 0.2,
      );
    }
  }

  void _drawCloud(Offset pos, double scale) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..maskFilter =
          const MaskFilter.blur(BlurStyle.normal, 12);

    canvas.drawOval(
      Rect.fromCenter(
        center: pos,
        width: 95 * scale,
        height: 17 * scale,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: pos.translate(-12, -7),
        width: 48 * scale,
        height: 23 * scale,
      ),
      paint,
    );
  }

  void _drawSun() {
    final sun = Offset(w * 0.77, horizon * 0.74);
    final radius = w * 0.095;

    canvas.drawCircle(
      sun,
      radius * 2.5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x77FFF0AB),
            const Color(0x00FFF0AB),
          ],
        ).createShader(
          Rect.fromCircle(
            center: sun,
            radius: radius * 2.5,
          ),
        ),
    );

    canvas.drawCircle(
      sun,
      radius,
      Paint()..color = const Color(0xFFFFE9AB),
    );
  }

  void _drawCity() {
    final back = Paint()
      ..color = const Color(0xFF366AA0).withValues(alpha: 0.65);

    final front = Paint()
      ..color = const Color(0xFF244D80).withValues(alpha: 0.86);

    for (int i = 0; i < 32; i++) {
      final bw = 17.0 + (i * 13 % 23);
      final bx = i * w / 24 - w * 0.1;
      final bh = 24.0 + (i * 37 % 95);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            bx,
            horizon - bh + 15,
            bw,
            bh,
          ),
          const Radius.circular(2),
        ),
        i.isEven ? back : front,
      );

      if (i % 3 == 0) {
        canvas.drawRect(
          Rect.fromLTWH(
            bx + bw * 0.4,
            horizon - bh + 21,
            3,
            3,
          ),
          Paint()
            ..color = const Color(0xFFFFD78D)
                .withValues(alpha: 0.6),
        );
      }
    }
  }

  void _drawMountains() {
    final mountain = Path()
      ..moveTo(0, horizon + 20)
      ..lineTo(0, horizon - 12)
      ..lineTo(w * 0.13, horizon - 49)
      ..lineTo(w * 0.26, horizon - 9)
      ..lineTo(w * 0.39, horizon - 42)
      ..lineTo(w * 0.53, horizon + 2)
      ..lineTo(w * 0.69, horizon - 34)
      ..lineTo(w * 0.84, horizon + 1)
      ..lineTo(w, horizon - 44)
      ..lineTo(w, horizon + 25)
      ..close();

    canvas.drawPath(
      mountain,
      Paint()
        ..color = const Color(0xFF4A8D9C)
            .withValues(alpha: 0.48),
    );
  }

  void _drawEnvironment() {
    final y = horizon;

    canvas.drawRect(
      Rect.fromLTWH(0, y, w, h - y),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF429A8B),
            Color(0xFF217762),
            Color(0xFF184C56),
          ],
        ).createShader(
          Rect.fromLTWH(0, y, w, h - y),
        ),
    );

    // Sidewalk strips.
    final left = Path()
      ..moveTo(centerX - roadHalfWidth(115), horizon)
      ..lineTo(centerX - roadHalfWidth(0), ground)
      ..lineTo(centerX - roadHalfWidth(0) - 30, ground)
      ..lineTo(centerX - roadHalfWidth(115) - 5, horizon)
      ..close();

    final right = Path()
      ..moveTo(centerX + roadHalfWidth(115), horizon)
      ..lineTo(centerX + roadHalfWidth(0), ground)
      ..lineTo(centerX + roadHalfWidth(0) + 30, ground)
      ..lineTo(centerX + roadHalfWidth(115) + 5, horizon)
      ..close();

    canvas.drawPath(
      left,
      Paint()..color = const Color(0xFFB7A9A2),
    );

    canvas.drawPath(
      right,
      Paint()..color = const Color(0xFFB7A9A2),
    );
  }

  void _drawRoad() {
    final path = Path()
      ..moveTo(
        centerX - roadHalfWidth(115),
        horizon,
      )
      ..lineTo(
        centerX + roadHalfWidth(115),
        horizon,
      )
      ..lineTo(
        centerX + roadHalfWidth(0),
        ground,
      )
      ..lineTo(
        centerX - roadHalfWidth(0),
        ground,
      )
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF44596A),
            Color(0xFF304456),
            Color(0xFF202E40),
          ],
        ).createShader(
          Rect.fromLTWH(0, horizon, w, ground - horizon),
        ),
    );

    // Road edge lighting.
    for (final sign in [-1.0, 1.0]) {
      final p = Path()
        ..moveTo(
          centerX + sign * roadHalfWidth(115),
          horizon,
        )
        ..lineTo(
          centerX + sign * roadHalfWidth(0),
          ground,
        );

      canvas.drawPath(
        p,
        Paint()
          ..color = const Color(0xFF81D5D4)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
    }

    // Lane shading.
    for (int lane = 0; lane < 3; lane++) {
      final l = lane - 1.5;
      final r = lane - 0.5;

      final p = Path()
        ..moveTo(
          centerX + l * 2 * roadHalfWidth(115) / 3,
          horizon,
        )
        ..lineTo(
          centerX + r * 2 * roadHalfWidth(115) / 3,
          horizon,
        )
        ..lineTo(
          centerX + r * 2 * roadHalfWidth(0) / 3,
          ground,
        )
        ..lineTo(
          centerX + l * 2 * roadHalfWidth(0) / 3,
          ground,
        )
        ..close();

      canvas.drawPath(
        p,
        Paint()
          ..color = lane.isEven
              ? const Color(0x12000000)
              : const Color(0x0DFFFFFF),
      );
    }
  }

  void _drawTrackDetails() {
    // Railroad ties move toward the camera.
    final offset = trackOffset % 7;

    for (double z = 115 - offset; z >= 0; z -= 7) {
      final y = roadY(z);
      final width = roadHalfWidth(z);
      final thickness = 1.5 + depthT(z) * 9;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(centerX, y),
            width: width * 1.93,
            height: thickness,
          ),
          Radius.circular(thickness * 0.2),
        ),
        Paint()..color = const Color(0xFF665950),
      );

      canvas.drawLine(
        Offset(centerX - width * 0.94, y - thickness / 2),
        Offset(centerX + width * 0.94, y - thickness / 2),
        Paint()
          ..color = const Color(0xFF9E8070)
          ..strokeWidth = math.max(0.5, thickness * 0.16),
      );
    }

    // Two rails per lane.
    for (int lane = 0; lane < 3; lane++) {
      for (final side in [-1.0, 1.0]) {
        final laneOffset = lane - 1.0 + side * 0.25;

        final p = Path()
          ..moveTo(
            centerX +
                laneOffset * roadHalfWidth(115) * 2 / 3,
            horizon,
          )
          ..lineTo(
            centerX +
                laneOffset * roadHalfWidth(0) * 2 / 3,
            ground,
          );

        canvas.drawPath(
          p,
          Paint()
            ..color = const Color(0xFF141F31)
            ..strokeWidth = 7
            ..style = PaintingStyle.stroke,
        );

        canvas.drawPath(
          p,
          Paint()
            ..color = const Color(0xFFCFDEE2)
            ..strokeWidth = 2.6
            ..style = PaintingStyle.stroke,
        );
      }
    }

    // Dotted lane boundaries.
    for (int boundary = 1; boundary <= 2; boundary++) {
      final offsetX = boundary - 1.5;

      for (double z = 110 - (trackOffset % 17);
          z > 0;
          z -= 17) {
        final z2 = math.max(0.0, z - 7);

        final p = Path()
          ..moveTo(
            centerX +
                offsetX * 2 * roadHalfWidth(z) / 3,
            roadY(z),
          )
          ..lineTo(
            centerX +
                offsetX * 2 * roadHalfWidth(z2) / 3,
            roadY(z2),
          );

        canvas.drawPath(
          p,
          Paint()
            ..color = const Color(0x55FFF4DB)
            ..strokeWidth = 1 + depthT(z) * 3
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  void _drawScenery() {
    final sorted = [...scenery]
      ..sort((a, b) => b.z.compareTo(a.z));

    for (final item in sorted) {
      if (item.z < 0 || item.z > 115) continue;

      final scale = objectScale(item.z);
      final x = centerX +
          item.side *
              (roadHalfWidth(item.z) + 24 * scale);
      final y = roadY(item.z);

      switch (item.kind) {
        case 0:
        case 1:
          _drawTree(x, y, scale, item.kind);
          break;

        case 2:
          _drawLamp(x, y, scale);
          break;

        case 3:
          _drawBuilding(x, y, scale, item.side);
          break;

        default:
          _drawBillboard(x, y, scale, item.side);
      }
    }
  }

  void _drawTree(
    double x,
    double y,
    double scale,
    int variant,
  ) {
    final s = scale * 0.8;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, y + 2),
        width: 34 * s,
        height: 10 * s,
      ),
      Paint()..color = const Color(0x550D3D36),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 5 * s,
          y - 66 * s,
          10 * s,
          66 * s,
        ),
        Radius.circular(3 * s),
      ),
      Paint()..color = const Color(0xFF795747),
    );

    final leafColor = variant == 0
        ? const Color(0xFF1FD39F)
        : const Color(0xFF27B7AE);

    for (final spec in [
      [-21.0, -83.0, 25.0],
      [19.0, -83.0, 27.0],
      [0.0, -105.0, 34.0],
    ]) {
      canvas.drawCircle(
        Offset(x + spec[0] * s, y + spec[1] * s),
        spec[2] * s,
        Paint()..color = leafColor,
      );
    }

    canvas.drawCircle(
      Offset(x - 9 * s, y - 113 * s),
      13 * s,
      Paint()
        ..color = const Color(0xFF90F8C0)
            .withValues(alpha: 0.4),
    );
  }

  void _drawLamp(double x, double y, double scale) {
    final s = scale;

    canvas.drawLine(
      Offset(x, y),
      Offset(x, y - 120 * s),
      Paint()
        ..color = const Color(0xFF28415C)
        ..strokeWidth = 6 * s
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawLine(
      Offset(x, y - 120 * s),
      Offset(x - 20 * s, y - 120 * s),
      Paint()
        ..color = const Color(0xFF28415C)
        ..strokeWidth = 5 * s,
    );

    canvas.drawCircle(
      Offset(x - 20 * s, y - 120 * s),
      8 * s,
      Paint()
        ..color = const Color(0xFFFFEDAE)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          7 * s,
        ),
    );

    canvas.drawCircle(
      Offset(x - 20 * s, y - 120 * s),
      5 * s,
      Paint()..color = const Color(0xFFFFF5C7),
    );
  }

  void _drawBuilding(
    double x,
    double y,
    double scale,
    int side,
  ) {
    final s = scale;
    final bw = 85 * s;
    final bh = 155 * s;

    final rect = Rect.fromLTWH(
      side < 0 ? x - bw : x,
      y - bh,
      bw,
      bh,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(5 * s),
      ),
      Paint()..color = const Color(0xFF385B84),
    );

    canvas.drawRect(
      Rect.fromLTWH(
        rect.left,
        rect.top,
        rect.width,
        12 * s,
      ),
      Paint()..color = const Color(0xFF527A9D),
    );

    for (int row = 0; row < 5; row++) {
      for (int col = 0; col < 3; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              rect.left + (12 + col * 24) * s,
              rect.top + (22 + row * 24) * s,
              12 * s,
              13 * s,
            ),
            Radius.circular(2 * s),
          ),
          Paint()
            ..color = (row + col).isEven
                ? const Color(0xFFFFD58E)
                : const Color(0xFF8DC3D0),
        );
      }
    }
  }

  void _drawBillboard(
    double x,
    double y,
    double scale,
    int side,
  ) {
    final s = scale;

    canvas.drawLine(
      Offset(x, y),
      Offset(x, y - 85 * s),
      Paint()
        ..color = const Color(0xFF29425A)
        ..strokeWidth = 6 * s,
    );

    final rect = Rect.fromCenter(
      center: Offset(
        x + side * 15 * s,
        y - 100 * s,
      ),
      width: 85 * s,
      height: 44 * s,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(6 * s),
      ),
      Paint()..color = const Color(0xFF14385B),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(3 * s),
        Radius.circular(4 * s),
      ),
      Paint()..color = const Color(0xFFFDAD5D),
    );

    _drawText(
      'GO!',
      Offset(rect.center.dx, rect.center.dy - 12 * s),
      23 * s,
      const Color(0xFF23385B),
      weight: FontWeight.w900,
      centered: true,
    );
  }

  // ==========================================================
  // OBJECT SORTING AND DRAWING
  // ==========================================================

  void _drawObjects() {
    final visible = objects.where(
      (o) => o.z >= -12 && o.z <= 120 && !o.collected,
    ).toList()
      ..sort((a, b) => b.z.compareTo(a.z));

    for (final o in visible) {
      final x = laneX(o.lane.toDouble(), o.z);
      final y = roadY(o.z);
      final scale = objectScale(o.z);

      switch (o.type) {
        case ObstacleType.coin:
          _drawCoin(x, y, scale, o);
          break;
        case ObstacleType.barrier:
          _drawBarrier(x, y, scale);
          break;
        case ObstacleType.overhead:
          _drawOverhead(x, y, scale);
          break;
        case ObstacleType.train:
          _drawTrain(x, y, scale, o);
          break;
      }
    }
  }

  void _drawCoin(
    double x,
    double y,
    double scale,
    GameObject object,
  ) {
    final s = scale * 0.87;
    final cy = y - 31 * s;
    final spin = math.cos(
      worldTime * 8 + object.z * 0.09,
    );

    final rx = math.max(3.0 * s, 15 * s * spin.abs());

    // Ground glow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, y),
        width: 32 * s,
        height: 9 * s,
      ),
      Paint()
        ..color = const Color(0x88FFDB4A)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          9 * s,
        ),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, cy),
        width: rx * 2 + 8 * s,
        height: 38 * s,
      ),
      Paint()
        ..color = const Color(0x88FFBD39)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          10 * s,
        ),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, cy),
        width: rx * 2,
        height: 32 * s,
      ),
      Paint()..color = const Color(0xFFB87819),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x - 1.5 * s, cy - 1 * s),
        width: math.max(2 * s, rx * 1.72),
        height: 27 * s,
      ),
      Paint()..color = const Color(0xFFFFE46B),
    );

    if (spin.abs() > 0.38) {
      _drawText(
        '★',
        Offset(x, cy - 11 * s),
        18 * s,
        const Color(0xFFFFA72E),
        centered: true,
        weight: FontWeight.w900,
      );
    }

    canvas.drawCircle(
      Offset(x - rx * 0.36, cy - 9 * s),
      2.5 * s,
      Paint()..color = Colors.white,
    );
  }

  void _drawBarrier(double x, double y, double scale) {
    final s = scale;
    final bw = 65 * s;
    final bh = 52 * s;

    _drawShadow(x, y, bw, s);

    // Feet.
    for (final dx in [-24.0, 24.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x + dx * s - 5 * s,
            y - 15 * s,
            10 * s,
            15 * s,
          ),
          Radius.circular(2 * s),
        ),
        Paint()..color = const Color(0xFF28374D),
      );
    }

    final rect = Rect.fromLTWH(
      x - bw / 2,
      y - bh - 10 * s,
      bw,
      bh,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(7 * s),
      ),
      Paint()..color = const Color(0xFF273D51),
    );

    final inner = rect.deflate(5 * s);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        inner,
        Radius.circular(3 * s),
      ),
      Paint()..color = const Color(0xFFFFD34F),
    );

    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        inner,
        Radius.circular(3 * s),
      ),
    );

    for (double dx = -80 * s;
        dx < 100 * s;
        dx += 24 * s) {
      final p = Path()
        ..moveTo(inner.left + dx, inner.bottom)
        ..lineTo(inner.left + dx + 18 * s, inner.top)
        ..lineTo(inner.left + dx + 30 * s, inner.top)
        ..lineTo(inner.left + dx + 12 * s, inner.bottom)
        ..close();

      canvas.drawPath(
        p,
        Paint()..color = const Color(0xFF26354C),
      );
    }

    canvas.restore();

    // Reflective upper edge.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          rect.left + 5 * s,
          rect.top + 3 * s,
          bw - 10 * s,
          4 * s,
        ),
        Radius.circular(2 * s),
      ),
      Paint()..color = const Color(0xFFFFEDAE),
    );
  }

  void _drawOverhead(double x, double y, double scale) {
    final s = scale;
    final bw = 76 * s;
    final height = 105 * s;

    _drawShadow(x, y, bw, s);

    // Support legs.
    for (final dx in [-32.0, 32.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x + dx * s - 5 * s,
            y - height,
            10 * s,
            height,
          ),
          Radius.circular(3 * s),
        ),
        Paint()..color = const Color(0xFF273B55),
      );
    }

    final sign = Rect.fromLTWH(
      x - bw / 2,
      y - height,
      bw,
      37 * s,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        sign,
        Radius.circular(6 * s),
      ),
      Paint()..color = const Color(0xFF23374C),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        sign.deflate(4 * s),
        Radius.circular(4 * s),
      ),
      Paint()..color = const Color(0xFFE84765),
    );

    _drawText(
      'SLIDE!',
      Offset(x, sign.center.dy - 9 * s),
      16 * s,
      Colors.white,
      weight: FontWeight.w900,
      centered: true,
    );

    canvas.drawRect(
      Rect.fromLTWH(
        x - 21 * s,
        sign.bottom - 2 * s,
        42 * s,
        5 * s,
      ),
      Paint()..color = const Color(0xFFFFC85F),
    );

    // Down arrows.
    for (final dx in [-16.0, 0.0, 16.0]) {
      final p = Path()
        ..moveTo(x + dx * s, y - 42 * s)
        ..lineTo(x + (dx - 5) * s, y - 49 * s)
        ..lineTo(x + (dx + 5) * s, y - 49 * s)
        ..close();

      canvas.drawPath(
        p,
        Paint()..color = const Color(0xFFFFD26A),
      );
    }
  }

  void _drawTrain(
    double x,
    double y,
    double scale,
    GameObject object,
  ) {
    final s = scale;
    final bw = 76 * s;
    final bh = 135 * s;

    final colors = [
      const Color(0xFF29B5C6),
      const Color(0xFFFF725C),
      const Color(0xFF8183E8),
      const Color(0xFFFFB64D),
    ];

    final bodyColor = colors[object.variant % colors.length];

    _drawShadow(x, y, bw * 1.15, s);

    // Carriage depth (visible roof).
    final top = Path()
      ..moveTo(x - bw * 0.5, y - bh)
      ..lineTo(x - bw * 0.38, y - bh - 22 * s)
      ..lineTo(x + bw * 0.38, y - bh - 22 * s)
      ..lineTo(x + bw * 0.5, y - bh)
      ..close();

    canvas.drawPath(
      top,
      Paint()
        ..color = Color.lerp(
          bodyColor,
          Colors.white,
          0.3,
        )!,
    );

    // Main train body.
    final bodyRect = Rect.fromLTWH(
      x - bw / 2,
      y - bh,
      bw,
      bh,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        bodyRect,
        Radius.circular(15 * s),
      ),
      Paint()..color = const Color(0xFF253B53),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        bodyRect.deflate(4 * s),
        Radius.circular(12 * s),
      ),
      Paint()..color = bodyColor,
    );

    // Side highlight.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bodyRect.left + 6 * s,
          bodyRect.top + 16 * s,
          6 * s,
          bh - 37 * s,
        ),
        Radius.circular(3 * s),
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22),
    );

    // Windshield.
    final windshield = Rect.fromLTWH(
      x - 29 * s,
      y - bh + 21 * s,
      58 * s,
      56 * s,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        windshield,
        Radius.circular(10 * s),
      ),
      Paint()..color = const Color(0xFF1C344F),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        windshield.deflate(4 * s),
        Radius.circular(8 * s),
      ),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF8CE5E8),
            Color(0xFF367CA2),
            Color(0xFF1D4265),
          ],
        ).createShader(windshield),
    );

    // Windshield reflection.
    final reflection = Path()
      ..moveTo(windshield.left + 9 * s, windshield.top + 7 * s)
      ..lineTo(windshield.left + 29 * s, windshield.top + 7 * s)
      ..lineTo(windshield.left + 13 * s, windshield.bottom - 7 * s)
      ..lineTo(windshield.left + 5 * s, windshield.bottom - 7 * s)
      ..close();

    canvas.drawPath(
      reflection,
      Paint()..color = const Color(0x55FFFFFF),
    );

    // Destination panel.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 20 * s,
          y - bh + 7 * s,
          40 * s,
          12 * s,
        ),
        Radius.circular(3 * s),
      ),
      Paint()..color = const Color(0xFF142C41),
    );

    _drawText(
      'EXPRESS',
      Offset(x, y - bh + 7.2 * s),
      8 * s,
      const Color(0xFFFFE2A6),
      weight: FontWeight.w900,
      centered: true,
    );

    // Lower nose.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 30 * s,
          y - 50 * s,
          60 * s,
          35 * s,
        ),
        Radius.circular(11 * s),
      ),
      Paint()
        ..color = Color.lerp(
          bodyColor,
          const Color(0xFF142D47),
          0.25,
        )!,
    );

    // White racing stripe.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 31 * s,
          y - 46 * s,
          62 * s,
          7 * s,
        ),
        Radius.circular(2 * s),
      ),
      Paint()..color = const Color(0xFFE9F8F5),
    );

    // Headlights.
    for (final dx in [-22.0, 22.0]) {
      canvas.drawCircle(
        Offset(x + dx * s, y - 28 * s),
        8 * s,
        Paint()
          ..color = const Color(0x88FFF0AB)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            10 * s,
          ),
      );

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x + dx * s, y - 28 * s),
            width: 13 * s,
            height: 10 * s,
          ),
          Radius.circular(3 * s),
        ),
        Paint()..color = const Color(0xFFFFF2C4),
      );
    }

    // Bumper.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 28 * s,
          y - 13 * s,
          56 * s,
          10 * s,
        ),
        Radius.circular(4 * s),
      ),
      Paint()..color = const Color(0xFF23384F),
    );
  }

  void _drawShadow(
    double x,
    double y,
    double width,
    double scale,
  ) {
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, y - 1),
        width: width * 1.2,
        height: 18 * scale,
      ),
      Paint()
        ..color = const Color(0x88071526)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          6 * scale,
        ),
    );
  }

  // ==========================================================
  // RUNNER CHARACTER
  // ==========================================================

  void _drawRunner() {
    final x = laneX(visualLane, GameConfig.playerZ);
    final baseY = roadY(GameConfig.playerZ) - 6;
    final heightOffset = jumpHeight * h * 0.047;

    final y = baseY - heightOffset;
    final s = (w / 390).clamp(0.75, 1.35);

    final run = math.sin(worldTime * speed * 0.48);
    final run2 = math.cos(worldTime * speed * 0.48);

    final bob = jumpHeight > 0
        ? 0.0
        : math.sin(worldTime * speed * 0.9).abs() * 3 * s;

    // Ground contact shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(x, baseY),
        width: (56 - jumpHeight * 4).clamp(22, 56) * s,
        height: 14 * s,
      ),
      Paint()
        ..color = const Color(0x990B1C2B)
            .withValues(
              alpha: (0.65 - jumpHeight * 0.07)
                  .clamp(0.1, 0.65),
            )
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          6 * s,
        ),
    );

    canvas.save();
    canvas.translate(x, y - bob);

    if (rolling) {
      _drawRollingRunner(s, run);
    } else {
      _drawStandingRunner(
        s,
        jumpHeight > 0 ? 0.15 : run,
        jumpHeight > 0 ? 0.1 : run2,
      );
    }

    canvas.restore();
  }

  void _drawStandingRunner(
    double s,
    double run,
    double run2,
  ) {
    // Legs / pants.
    _drawLimb(
      Offset(-10 * s, -43 * s),
      Offset(
        (-12 - run * 8) * s,
        (-20 + run.abs() * 5) * s,
      ),
      12 * s,
      const Color(0xFF263E72),
    );

    _drawLimb(
      Offset(10 * s, -43 * s),
      Offset(
        (12 + run * 8) * s,
        (-20 + run.abs() * 5) * s,
      ),
      12 * s,
      const Color(0xFF263E72),
    );

    // Shoes.
    _drawShoe(
      (-12 - run * 8) * s,
      (-12 + run.abs() * 4) * s,
      s,
      const Color(0xFFFF5B62),
    );

    _drawShoe(
      (12 + run * 8) * s,
      (-12 + run.abs() * 4) * s,
      s,
      const Color(0xFF59E8E0),
    );

    // Arms behind torso.
    _drawLimb(
      Offset(-22 * s, -88 * s),
      Offset(
        (-29 + run2 * 10) * s,
        (-58 + run2 * 9) * s,
      ),
      10 * s,
      const Color(0xFFFFB27E),
    );

    _drawLimb(
      Offset(22 * s, -88 * s),
      Offset(
        (29 - run2 * 10) * s,
        (-58 - run2 * 9) * s,
      ),
      10 * s,
      const Color(0xFFFFB27E),
    );

    // Hoodie body.
    final hoodie = Path()
      ..moveTo(-17 * s, -101 * s)
      ..quadraticBezierTo(0, -110 * s, 17 * s, -101 * s)
      ..lineTo(23 * s, -53 * s)
      ..quadraticBezierTo(0, -45 * s, -23 * s, -53 * s)
      ..close();

    canvas.drawPath(
      hoodie,
      Paint()..color = const Color(0xFFEF4B69),
    );

    // Side shading.
    final shade = Path()
      ..moveTo(9 * s, -103 * s)
      ..lineTo(17 * s, -101 * s)
      ..lineTo(23 * s, -53 * s)
      ..lineTo(7 * s, -50 * s)
      ..close();

    canvas.drawPath(
      shade,
      Paint()..color = const Color(0xFFCC3558),
    );

    // Hoodie pouch.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -14 * s,
          -73 * s,
          28 * s,
          18 * s,
        ),
        Radius.circular(6 * s),
      ),
      Paint()..color = const Color(0xFFFF7892),
    );

    // Backpack.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -15 * s,
          -96 * s,
          30 * s,
          37 * s,
        ),
        Radius.circular(10 * s),
      ),
      Paint()..color = const Color(0xFF35D9D3),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -12 * s,
          -79 * s,
          24 * s,
          15 * s,
        ),
        Radius.circular(5 * s),
      ),
      Paint()..color = const Color(0xFF188FA7),
    );

    canvas.drawCircle(
      Offset(0, -72 * s),
      4 * s,
      Paint()..color = const Color(0xFFFFD45F),
    );

    // Neck.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -7 * s,
          -111 * s,
          14 * s,
          14 * s,
        ),
        Radius.circular(4 * s),
      ),
      Paint()..color = const Color(0xFFECA276),
    );

    // Head.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, -126 * s),
        width: 36 * s,
        height: 39 * s,
      ),
      Paint()..color = const Color(0xFFFFC395),
    );

    // Hair / cap.
    canvas.drawArc(
      Rect.fromLTWH(
        -19 * s,
        -148 * s,
        38 * s,
        29 * s,
      ),
      math.pi,
      math.pi,
      true,
      Paint()..color = const Color(0xFF27344D),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -21 * s,
          -146 * s,
          42 * s,
          15 * s,
        ),
        Radius.circular(8 * s),
      ),
      Paint()..color = const Color(0xFF334E95),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -26 * s,
          -137 * s,
          52 * s,
          7 * s,
        ),
        Radius.circular(4 * s),
      ),
      Paint()..color = const Color(0xFF4468C4),
    );

    // Cap emblem.
    canvas.drawCircle(
      Offset(0, -140 * s),
      4 * s,
      Paint()..color = const Color(0xFFFFD35B),
    );

    // Ears.
    canvas.drawCircle(
      Offset(-17 * s, -123 * s),
      5 * s,
      Paint()..color = const Color(0xFFF2AD80),
    );

    canvas.drawCircle(
      Offset(17 * s, -123 * s),
      5 * s,
      Paint()..color = const Color(0xFFF2AD80),
    );
  }

  void _drawRollingRunner(double s, double run) {
    canvas.save();
    canvas.translate(0, -8 * s);

    // Compact sliding body.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, -24 * s),
        width: 72 * s,
        height: 35 * s,
      ),
      Paint()..color = const Color(0xFFED4C69),
    );

    // Bent legs.
    _drawLimb(
      Offset(0, -23 * s),
      Offset(29 * s, -15 * s),
      13 * s,
      const Color(0xFF263E72),
    );

    _drawShoe(
      35 * s,
      -11 * s,
      s,
      const Color(0xFF59E8E0),
    );

    // Backpack.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -10 * s,
          -47 * s,
          33 * s,
          23 * s,
        ),
        Radius.circular(9 * s),
      ),
      Paint()..color = const Color(0xFF35D9D3),
    );

    // Head.
    canvas.drawCircle(
      Offset(-28 * s, -28 * s),
      17 * s,
      Paint()..color = const Color(0xFFFFBD91),
    );

    // Cap.
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(-28 * s, -31 * s),
        radius: 18 * s,
      ),
      math.pi,
      math.pi,
      true,
      Paint()..color = const Color(0xFF4468C4),
    );

    // Sliding sparks / dust.
    for (int i = 0; i < 3; i++) {
      final dx =
          (28 + i * 13 + (worldTime * 100 % 15)) * s;

      canvas.drawCircle(
        Offset(-dx, -5 * s - i * 3 * s),
        (3 - i * 0.6) * s,
        Paint()
          ..color = const Color(0xFFBBF9E6)
              .withValues(alpha: 0.7),
      );
    }

    canvas.restore();
  }

  void _drawLimb(
    Offset a,
    Offset b,
    double width,
    Color color,
  ) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawShoe(
    double x,
    double y,
    double s,
    Color color,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, y),
          width: 25 * s,
          height: 14 * s,
        ),
        Radius.circular(6 * s),
      ),
      Paint()..color = color,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 13 * s,
          y + 4 * s,
          26 * s,
          5 * s,
        ),
        Radius.circular(2 * s),
      ),
      Paint()..color = Colors.white,
    );
  }

  // ==========================================================
  // EFFECTS, TEXT, POSTPROCESSING
  // ==========================================================

  void _drawParticles() {
    for (final p in particles) {
      canvas.drawCircle(
        Offset(p.x, p.y),
        p.radius * (0.4 + p.opacity * 0.6),
        Paint()
          ..color = p.color.withValues(alpha: p.opacity),
      );

      if (p.radius > 4) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          p.radius * 1.5,
          Paint()
            ..color = p.color.withValues(
              alpha: p.opacity * 0.25,
            )
            ..maskFilter =
                const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
    }
  }

  void _drawFloatingTexts() {
    for (final t in texts) {
      final opacity =
          (1 - t.age / 1).clamp(0.0, 1.0);

      final y = t.y - t.age * 90;
      final scale = 1 + math.sin(t.age * math.pi) * 0.3;

      canvas.save();
      canvas.translate(t.x, y);
      canvas.scale(scale);

      _drawText(
        t.text,
        Offset.zero,
        25,
        t.color.withValues(alpha: opacity),
        weight: FontWeight.w900,
        centered: true,
        strokeColor: const Color(0xFF1C2D45)
            .withValues(alpha: opacity),
        strokeWidth: 5,
      );

      canvas.restore();
    }
  }

  void _drawAtmosphere() {
    // Vignette for cinematic depth.
    final rect = Rect.fromLTWH(0, 0, w, h);

    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.1),
          radius: 1.12,
          colors: [
            Colors.transparent,
            const Color(0x66071930),
          ],
          stops: const [0.42, 1],
        ).createShader(rect),
    );

    // Speed streaks at high velocities.
    final intensity =
        ((speed - GameConfig.initialSpeed) /
                (GameConfig.maxSpeed -
                    GameConfig.initialSpeed))
            .clamp(0.0, 1.0);

    if (intensity > 0.2 && phase == GamePhase.playing) {
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(
          alpha: intensity * 0.18,
        );

      for (int i = 0; i < 12; i++) {
        final side = i.isEven ? -1.0 : 1.0;
        final yy =
            ((i * 97.0 + worldTime * speed * 24) % h);
        final xx = centerX +
            side * (w * 0.35 + (i % 4) * w * 0.04);

        canvas.drawLine(
          Offset(xx, yy),
          Offset(
            xx + side * 8,
            yy + 20 + intensity * 55,
          ),
          paint,
        );
      }
    }
  }

  void _drawText(
    String text,
    Offset offset,
    double fontSize,
    Color color, {
    FontWeight weight = FontWeight.bold,
    bool centered = false,
    Color? strokeColor,
    double strokeWidth = 0,
  }) {
    final span = TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        fontWeight: weight,
        height: 1,
        letterSpacing: -0.5,
      ),
    );

    if (strokeColor != null && strokeWidth > 0) {
      final outline = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: weight,
            height: 1,
            letterSpacing: -0.5,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = strokeColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      outline.paint(
        canvas,
        Offset(
          centered
              ? offset.dx - outline.width / 2
              : offset.dx,
          offset.dy,
        ),
      );
    }

    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();

    painter.paint(
      canvas,
      Offset(
        centered
            ? offset.dx - painter.width / 2
            : offset.dx,
        offset.dy,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant GamePainter oldDelegate) => true;
}