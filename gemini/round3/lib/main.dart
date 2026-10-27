import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const SubwaySurfersApp());
}

class SubwaySurfersApp extends StatelessWidget {
  const SubwaySurfersApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Subway Surfers',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0B1E),
      ),
      home: const GameScreen(),
    );
  }
}

// ==================== GAME MODELS & ENUMS ====================

enum GameState { menu, playing, gameOver }

enum ObjectType { train, lowBarrier, highBarrier, coin, ramp, jetpack, magnet }

class WorldObject {
  final String id;
  final ObjectType type;
  int lane; // -1: Left, 0: Center, 1: Right
  double z; // Distance from camera
  double y; // Height off ground
  double length;
  double height;
  bool collected;

  WorldObject({
    required this.id,
    required this.type,
    required this.lane,
    required this.z,
    this.y = 0.0,
    this.length = 1.0,
    this.height = 1.0,
    this.collected = false,
  });
}

class Particle {
  double x, y, z;
  double vx, vy, vz;
  Color color;
  double size;
  double life; // 1.0 to 0.0
  double maxLife;

  Particle({
    required this.x,
    required this.y,
    required this.z,
    required this.vx,
    required this.vy,
    required this.vz,
    required this.color,
    required this.size,
    required this.life,
  }) : maxLife = life;
}

class ScorePopup {
  final String text;
  final Color color;
  double x, y;
  double opacity;

  ScorePopup({
    required this.text,
    required this.color,
    required this.x,
    required this.y,
    this.opacity = 1.0,
  });
}

// ==================== MAIN GAME SCREEN ====================

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ticker;
  Duration _lastFrameTime = Duration.zero;

  // Game State
  GameState _gameState = GameState.menu;
  double _score = 0.0;
  int _highScore = 0;
  int _coins = 0;
  int _sessionCoins = 0;
  double _speed = 22.0;
  final double _baseSpeed = 22.0;
  double _distanceTraveled = 0.0;

  // Combo System
  int _multiplier = 1;
  double _comboTimer = 0.0;
  final double _comboMaxDuration = 3.0;

  // Power-Ups
  double _jetpackTimer = 0.0;
  double _magnetTimer = 0.0;
  final double _powerUpDuration = 6.0;

  // Screen Shake Effect
  double _screenShakeTimer = 0.0;
  double _shakeIntensity = 0.0;
  Offset _shakeOffset = Offset.zero;

  // Player State
  int _targetLane = 0; // -1, 0, 1
  double _playerX = 0.0; // Animated current X position
  double _playerY = 0.0; // Current height
  final double _playerZ = 0.0; // Z position fixed near camera
  double _jumpVelocity = 0.0;
  bool _isJumping = false;
  bool _isRolling = false;
  double _rollTimer = 0.0;
  double _currentGroundY = 0.0; // For landing on trains!
  double _animTime = 0.0;

  // World Elements
  final List<WorldObject> _objects = [];
  final List<Particle> _particles = [];
  final List<ScorePopup> _popups = [];
  double _spawnZ = 30.0;
  final Random _rng = Random();

  // Focus node for keyboard controls
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    _ticker.addListener(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startGame() {
    setState(() {
      _gameState = GameState.playing;
      _score = 0.0;
      _sessionCoins = 0;
      _speed = _baseSpeed;
      _distanceTraveled = 0.0;
      _multiplier = 1;
      _comboTimer = 0.0;
      _jetpackTimer = 0.0;
      _magnetTimer = 0.0;
      _screenShakeTimer = 0.0;
      _shakeOffset = Offset.zero;
      _targetLane = 0;
      _playerX = 0.0;
      _playerY = 0.0;
      _jumpVelocity = 0.0;
      _isJumping = false;
      _isRolling = false;
      _rollTimer = 0.0;
      _currentGroundY = 0.0;
      _objects.clear();
      _particles.clear();
      _popups.clear();
      _spawnZ = 25.0;

      // Seed initial track objects
      for (int i = 0; i < 5; i++) {
        _spawnChunk();
      }
    });
  }

  void _onTick() {
    if (_gameState != GameState.playing) return;

    // Calculate delta time
    final now = _ticker.lastElapsedDuration ?? Duration.zero;
    double dt = (now - _lastFrameTime).inMicroseconds / 1000000.0;
    _lastFrameTime = now;

    if (dt > 0.1) dt = 0.1; // Cap dt to avoid teleports on lag spikes

    setState(() {
      _updateGame(dt);
    });
  }

  void _updateGame(double dt) {
    _animTime += dt;

    // 0. Screen Shake Logic
    if (_screenShakeTimer > 0) {
      _screenShakeTimer -= dt;
      _shakeOffset = Offset(
        (_rng.nextDouble() - 0.5) * _shakeIntensity,
        (_rng.nextDouble() - 0.5) * _shakeIntensity,
      );
      if (_screenShakeTimer <= 0) {
        _shakeOffset = Offset.zero;
      }
    }

    // 1. Power-Ups Timers & Flying Logic
    bool isJetpackActive = _jetpackTimer > 0;
    if (isJetpackActive) {
      _jetpackTimer -= dt;
      _playerY = 5.0; // Fly above obstacles!
      _createRainbowJetpackParticles();
    }

    bool isMagnetActive = _magnetTimer > 0;
    if (isMagnetActive) {
      _magnetTimer -= dt;
    }

    // 2. Combo Timer Decay
    if (_comboTimer > 0) {
      _comboTimer -= dt;
      if (_comboTimer <= 0) {
        _multiplier = 1; // Reset combo multiplier
      }
    }

    // Increase speed slightly over time (Normal vs Flying)
    double effectiveSpeed = isJetpackActive ? _baseSpeed * 1.6 : _baseSpeed;
    _speed = effectiveSpeed + (_score * 0.004).clamp(0.0, 35.0);
    double distanceDelta = _speed * dt;
    _distanceTraveled += distanceDelta;
    _score += distanceDelta * 1.5 * _multiplier;

    // 3. Smooth Lane Switch Animation
    _playerX += (_targetLane - _playerX) * 18.0 * dt;

    // 4. Player Jump & Roll Physics (When not flying jetpack)
    if (!isJetpackActive) {
      const double gravity = 45.0;

      if (_isJumping) {
        _playerY += _jumpVelocity * dt;
        _jumpVelocity -= gravity * dt;

        if (_playerY <= _currentGroundY) {
          _playerY = _currentGroundY;
          _isJumping = false;
          _jumpVelocity = 0.0;
          _createLandingParticles();
        }
      } else {
        // Smoothly drop if ground level drops (e.g. running off a train)
        if (_playerY > _currentGroundY) {
          _playerY -= gravity * 0.8 * dt;
          if (_playerY < _currentGroundY) _playerY = _currentGroundY;
        } else if (_playerY < _currentGroundY) {
          _playerY = _currentGroundY;
        }
      }

      // Roll Timer
      if (_isRolling) {
        _rollTimer -= dt;
        if (_rollTimer <= 0) {
          _isRolling = false;
        }
      }
    }

    // 5. Move World Objects & Collision / Magnet Attraction
    bool onAnyTrain = false;
    double highestTrainTop = 0.0;

    for (int i = _objects.length - 1; i >= 0; i--) {
      var obj = _objects[i];
      obj.z -= distanceDelta;

      // Magnet Logic: Pull nearby coins towards player!
      if (isMagnetActive && obj.type == ObjectType.coin && !obj.collected) {
        if (obj.z > 0 && obj.z < 25.0) {
          obj.z += (_playerZ - obj.z) * 6.0 * dt;
          obj.lane += (_targetLane - obj.lane);
          obj.y += (_playerY + 0.5 - obj.y) * 6.0 * dt;
        }
      }

      // Check for landing on top of trains
      if (obj.type == ObjectType.train) {
        double trainFront = obj.z;
        double trainBack = obj.z + obj.length;
        if (trainFront <= _playerZ + 0.5 &&
            trainBack >= _playerZ - 0.5 &&
            (obj.lane - _playerX).abs() < 0.55) {
          if (_playerY >= obj.height - 0.3) {
            onAnyTrain = true;
            if (obj.height > highestTrainTop) highestTrainTop = obj.height;
          }
        }
      }

      // Collectible Collision (Coins & Power-ups)
      if (!obj.collected) {
        bool hitCollectible = (obj.z - _playerZ).abs() < 1.2 &&
            (obj.lane - _playerX).abs() < 0.6 &&
            (_playerY - obj.y).abs() < 2.0;

        if (hitCollectible) {
          if (obj.type == ObjectType.coin) {
            obj.collected = true;
            _coins++;
            _sessionCoins++;

            // Increase Combo Multiplier
            _multiplier = (_multiplier + 1).clamp(1, 8);
            _comboTimer = _comboMaxDuration;

            int earnedScore = 50 * _multiplier;
            _score += earnedScore;

            HapticFeedback.lightImpact();
            _createCoinParticles(obj.lane.toDouble(), obj.y, obj.z);
            _addPopup("+$earnedScore (x$_multiplier)", Colors.yellowAccent,
                obj.lane.toDouble(), obj.y + 1.0);
          } else if (obj.type == ObjectType.jetpack) {
            obj.collected = true;
            _jetpackTimer = _powerUpDuration;
            HapticFeedback.mediumImpact();
            _addPopup("JETPACK!", Colors.cyanAccent, obj.lane.toDouble(),
                obj.y + 1.5);
          } else if (obj.type == ObjectType.magnet) {
            obj.collected = true;
            _magnetTimer = _powerUpDuration;
            HapticFeedback.mediumImpact();
            _addPopup("MAGNET!", Colors.purpleAccent, obj.lane.toDouble(),
                obj.y + 1.5);
          }
        }
      }

      // Obstacle Collision (Ignored if in Jetpack mode)
      if (!isJetpackActive && _checkCollision(obj)) {
        _triggerGameOver();
        return;
      }

      // Remove offscreen objects
      if (obj.z + obj.length < -5.0) {
        _objects.removeAt(i);
      }
    }

    // Update Ground Height (Train top or ground level)
    _currentGroundY = onAnyTrain ? highestTrainTop : 0.0;

    // 6. Spawn New Track Objects
    if (_spawnZ - _distanceTraveled < 80.0) {
      _spawnChunk();
    }

    // 7. Update Particles
    for (int i = _particles.length - 1; i >= 0; i--) {
      var p = _particles[i];
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.z += p.vz * dt;
      p.life -= dt;
      if (p.life <= 0) _particles.removeAt(i);
    }

    // 8. Update Score Popups
    for (int i = _popups.length - 1; i >= 0; i--) {
      var pop = _popups[i];
      pop.y += 1.5 * dt;
      pop.opacity -= 1.2 * dt;
      if (pop.opacity <= 0) _popups.removeAt(i);
    }
  }

  bool _checkCollision(WorldObject obj) {
    if (obj.collected) return false;

    // Check Z overlap
    double frontZ = obj.z;
    double backZ = obj.z + obj.length;
    if (_playerZ < frontZ - 0.3 || _playerZ > backZ + 0.3) return false;

    // Check Lane X overlap
    if ((obj.lane - _playerX).abs() > 0.55) return false;

    // Check Y overlap according to obstacle type
    switch (obj.type) {
      case ObjectType.train:
        if (_playerY < obj.height - 0.2) {
          return true;
        }
        break;

      case ObjectType.lowBarrier:
        if (_playerY < 1.1) {
          return true;
        }
        break;

      case ObjectType.highBarrier:
        double headY = _isRolling ? _playerY + 0.8 : _playerY + 1.8;
        if (headY > 1.2) {
          return true;
        }
        break;

      case ObjectType.ramp:
        if (_playerY < obj.height) {
          _playerY = (1.0 - (frontZ - _playerZ) / obj.length).clamp(0.0, 1.0) *
              obj.height;
        }
        break;

      case ObjectType.coin:
      case ObjectType.jetpack:
      case ObjectType.magnet:
        break;
    }

    return false;
  }

  void _spawnChunk() {
    int pattern = _rng.nextInt(7);
    double chunkZ = _spawnZ;

    // Occasional Power-up Spawns
    bool spawnJetpack = _rng.nextDouble() < 0.12;
    bool spawnMagnet = !spawnJetpack && _rng.nextDouble() < 0.15;

    if (spawnJetpack) {
      _objects.add(WorldObject(
        id: 'jetpack_$chunkZ',
        type: ObjectType.jetpack,
        lane: _rng.nextInt(3) - 1,
        z: chunkZ + 2,
        y: 1.0,
      ));
    } else if (spawnMagnet) {
      _objects.add(WorldObject(
        id: 'magnet_$chunkZ',
        type: ObjectType.magnet,
        lane: _rng.nextInt(3) - 1,
        z: chunkZ + 2,
        y: 1.0,
      ));
    }

    switch (pattern) {
      case 0: // Train in middle, coins on sides
        _objects.add(WorldObject(
          id: 'train_$chunkZ',
          type: ObjectType.train,
          lane: 0,
          z: chunkZ,
          length: 16.0,
          height: 2.8,
        ));
        _spawnCoinLine(-1, chunkZ, 8);
        _spawnCoinLine(1, chunkZ, 8);
        _spawnZ += 24.0;
        break;

      case 1: // Jump over low barrier, roll under high barrier
        _objects.add(WorldObject(
          id: 'bar_low_$chunkZ',
          type: ObjectType.lowBarrier,
          lane: -1,
          z: chunkZ,
          height: 1.2,
        ));
        _objects.add(WorldObject(
          id: 'bar_high_$chunkZ',
          type: ObjectType.highBarrier,
          lane: 1,
          z: chunkZ,
          height: 2.2,
        ));
        _spawnCoinLine(-1, chunkZ + 2, 4, startY: 1.5);
        _spawnCoinLine(0, chunkZ, 6);
        _spawnZ += 18.0;
        break;

      case 2: // Ramp onto train with top coins
        _objects.add(WorldObject(
          id: 'ramp_$chunkZ',
          type: ObjectType.ramp,
          lane: 0,
          z: chunkZ,
          length: 3.0,
          height: 2.8,
        ));
        _objects.add(WorldObject(
          id: 'train_ramp_$chunkZ',
          type: ObjectType.train,
          lane: 0,
          z: chunkZ + 3.0,
          length: 18.0,
          height: 2.8,
        ));
        _spawnCoinLine(0, chunkZ + 3.0, 8, startY: 3.2);
        _spawnZ += 28.0;
        break;

      case 3: // Side trains, center open with coins
        _objects.add(WorldObject(
          id: 'train_l_$chunkZ',
          type: ObjectType.train,
          lane: -1,
          z: chunkZ,
          length: 14.0,
          height: 2.8,
        ));
        _objects.add(WorldObject(
          id: 'train_r_$chunkZ',
          type: ObjectType.train,
          lane: 1,
          z: chunkZ,
          length: 14.0,
          height: 2.8,
        ));
        _spawnCoinLine(0, chunkZ, 6);
        _spawnZ += 22.0;
        break;

      case 4: // High barrier across center & left
        _objects.add(WorldObject(
          id: 'bar_high_l_$chunkZ',
          type: ObjectType.highBarrier,
          lane: -1,
          z: chunkZ,
          height: 2.2,
        ));
        _objects.add(WorldObject(
          id: 'bar_high_c_$chunkZ',
          type: ObjectType.highBarrier,
          lane: 0,
          z: chunkZ,
          height: 2.2,
        ));
        _spawnCoinLine(0, chunkZ, 5, startY: 0.2);
        _spawnCoinLine(1, chunkZ, 5);
        _spawnZ += 16.0;
        break;

      default: // Pure coin field
        for (int l = -1; l <= 1; l++) {
          if (_rng.nextBool()) {
            _spawnCoinLine(l, chunkZ, 6);
          }
        }
        _spawnZ += 18.0;
        break;
    }
  }

  void _spawnCoinLine(int lane, double startZ, int count,
      {double startY = 0.5}) {
    for (int i = 0; i < count; i++) {
      _objects.add(WorldObject(
        id: 'coin_${lane}_${startZ + i * 1.8}',
        type: ObjectType.coin,
        lane: lane,
        z: startZ + i * 1.8,
        y: startY,
      ));
    }
  }

  // Visual Effects Generators
  void _createCoinParticles(double lane, double y, double z) {
    for (int i = 0; i < 12; i++) {
      double angle = _rng.nextDouble() * pi * 2;
      double speed = 2.0 + _rng.nextDouble() * 4.0;
      _particles.add(Particle(
        x: lane,
        y: y,
        z: z,
        vx: cos(angle) * speed,
        vy: sin(angle) * speed + 2.0,
        vz: (_rng.nextDouble() - 0.5) * 2.0,
        color: Colors.amberAccent,
        size: 5.0 + _rng.nextDouble() * 4.0,
        life: 0.4 + _rng.nextDouble() * 0.3,
      ));
    }
  }

  void _createLandingParticles() {
    for (int i = 0; i < 8; i++) {
      double angle = _rng.nextDouble() * pi * 2;
      _particles.add(Particle(
        x: _playerX,
        y: _playerY,
        z: _playerZ,
        vx: cos(angle) * 3.0,
        vy: 1.0 + _rng.nextDouble() * 2.0,
        vz: sin(angle) * 3.0,
        color: Colors.white70,
        size: 4.0,
        life: 0.25,
      ));
    }
  }

  void _createRainbowJetpackParticles() {
    List<Color> colors = [
      Colors.cyanAccent,
      Colors.pinkAccent,
      Colors.yellowAccent,
      Colors.purpleAccent
    ];
    for (int i = 0; i < 4; i++) {
      _particles.add(Particle(
        x: _playerX + (_rng.nextDouble() - 0.5) * 0.4,
        y: _playerY - 0.2,
        z: _playerZ,
        vx: (_rng.nextDouble() - 0.5) * 2.0,
        vy: -6.0 - _rng.nextDouble() * 4.0,
        vz: -2.0 - _rng.nextDouble() * 4.0,
        color: colors[_rng.nextInt(colors.length)],
        size: 6.0 + _rng.nextDouble() * 5.0,
        life: 0.3 + _rng.nextDouble() * 0.2,
      ));
    }
  }

  void _createCrashExplosion() {
    for (int i = 0; i < 60; i++) {
      double angle = _rng.nextDouble() * pi * 2;
      double speed = 5.0 + _rng.nextDouble() * 10.0;
      _particles.add(Particle(
        x: _playerX,
        y: _playerY + 1.0,
        z: _playerZ,
        vx: cos(angle) * speed,
        vy: (_rng.nextDouble() - 0.3) * speed,
        vz: sin(angle) * speed,
        color: [
          Colors.redAccent,
          Colors.orangeAccent,
          Colors.yellowAccent,
          Colors.white
        ][_rng.nextInt(4)],
        size: 7.0 + _rng.nextDouble() * 8.0,
        life: 0.6 + _rng.nextDouble() * 0.5,
      ));
    }
  }

  void _addPopup(String text, Color color, double x, double y) {
    _popups.add(ScorePopup(text: text, color: color, x: x, y: y));
  }

  void _triggerGameOver() {
    HapticFeedback.heavyImpact();
    _createCrashExplosion();

    // Trigger Screen Shake
    _screenShakeTimer = 0.4;
    _shakeIntensity = 20.0;

    if (_score.toInt() > _highScore) {
      _highScore = _score.toInt();
    }
    setState(() {
      _gameState = GameState.gameOver;
    });
  }

  // Control Actions
  void _moveLeft() {
    if (_gameState != GameState.playing) return;
    if (_targetLane > -1) {
      _targetLane--;
      HapticFeedback.selectionClick();
    }
  }

  void _moveRight() {
    if (_gameState != GameState.playing) return;
    if (_targetLane < 1) {
      _targetLane++;
      HapticFeedback.selectionClick();
    }
  }

  void _jump() {
    if (_gameState != GameState.playing) return;
    if (!_isJumping && _jetpackTimer <= 0) {
      _isJumping = true;
      _jumpVelocity = 14.5;
      _isRolling = false;
      HapticFeedback.lightImpact();
    }
  }

  void _roll() {
    if (_gameState != GameState.playing) return;
    if (!_isRolling && _jetpackTimer <= 0) {
      _isRolling = true;
      _rollTimer = 0.75;
      if (_isJumping) {
        // Fast drop slam
        _jumpVelocity = -22.0;
      }
      HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: RawKeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.keyA) {
              _moveLeft();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.keyD) {
              _moveRight();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                event.logicalKey == LogicalKeyboardKey.keyW ||
                event.logicalKey == LogicalKeyboardKey.space) {
              _jump();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                event.logicalKey == LogicalKeyboardKey.keyS) {
              _roll();
            }
          }
        },
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            if (details.primaryVelocity! < -200) {
              _jump();
            } else if (details.primaryVelocity! > 200) {
              _roll();
            }
          },
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity! < -200) {
              _moveLeft();
            } else if (details.primaryVelocity! > 200) {
              _moveRight();
            }
          },
          child: Transform.translate(
            offset: _shakeOffset,
            child: Stack(
              children: [
                // 3D Canvas Visualizer
                CustomPaint(
                  size: size,
                  painter: World3DPainter(
                    playerX: _playerX,
                    playerY: _playerY,
                    playerZ: _playerZ,
                    isRolling: _isRolling,
                    isJetpackActive: _jetpackTimer > 0,
                    isMagnetActive: _magnetTimer > 0,
                    animTime: _animTime,
                    distanceTraveled: _distanceTraveled,
                    objects: _objects,
                    particles: _particles,
                    popups: _popups,
                  ),
                ),

                // Dynamic HUD Overlay
                if (_gameState == GameState.playing) _buildHUD(),

                // Start Menu Overlay
                if (_gameState == GameState.menu) _buildStartMenu(),

                // Game Over Overlay
                if (_gameState == GameState.gameOver) _buildGameOverMenu(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHUD() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Score & Multiplier Display
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'SCORE',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: Colors.white70,
                            letterSpacing: 1.5,
                          ),
                        ),
                        if (_multiplier > 1) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.pinkAccent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'x$_multiplier',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${_score.toInt()}',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        shadows: [
                          Shadow(color: Colors.purpleAccent, blurRadius: 10)
                        ],
                      ),
                    ),
                  ],
                ),

                // Coins Display
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber.withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.monetization_on,
                          color: Colors.amber, size: 24),
                      const SizedBox(width: 8),
                      Text(
                        '$_coins',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.amberAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Active Power-up Progress Indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_jetpackTimer > 0)
                  _buildPowerUpBadge(
                    'JETPACK',
                    Colors.cyanAccent,
                    _jetpackTimer / _powerUpDuration,
                  ),
                if (_magnetTimer > 0) ...[
                  if (_jetpackTimer > 0) const SizedBox(width: 12),
                  _buildPowerUpBadge(
                    'MAGNET',
                    Colors.purpleAccent,
                    _magnetTimer / _powerUpDuration,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPowerUpBadge(String title, Color color, double progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            height: 6,
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.white24,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartMenu() {
    return Container(
      color: Colors.black45,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'SUBWAY',
              style: TextStyle(
                fontSize: 54,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                color: Colors.yellowAccent,
                letterSpacing: 2,
                shadows: [
                  Shadow(
                      color: Colors.orange,
                      blurRadius: 15,
                      offset: Offset(3, 3))
                ],
              ),
            ),
            const Text(
              'SURFERS',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                color: Colors.pinkAccent,
                letterSpacing: 4,
                shadows: [
                  Shadow(
                      color: Colors.purple,
                      blurRadius: 15,
                      offset: Offset(3, 3))
                ],
              ),
            ),
            const SizedBox(height: 25),

            // High Score Display on Main Menu
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.4),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.pinkAccent.withOpacity(0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.emoji_events, color: Colors.amber, size: 26),
                  const SizedBox(width: 10),
                  Text(
                    'HIGH SCORE: $_highScore',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 45),
            ElevatedButton(
              onPressed: _startGame,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.lightGreenAccent,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 48, vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 10,
              ),
              child: const Text(
                'TAP TO RUN',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'Swipe or use Keyboard Arrows to Move / Jump / Roll',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameOverMenu() {
    return Container(
      color: Colors.black.withOpacity(0.85),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(28),
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1735),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.pinkAccent.withOpacity(0.5), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.pinkAccent,
                blurRadius: 20,
                spreadRadius: -5,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'CRASHED!',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: Colors.redAccent,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statItem('SCORE', '${_score.toInt()}'),
                  _statItem('HIGH', '$_highScore'),
                  _statItem('COINS', '+$_sessionCoins', Colors.amber),
                ],
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _startGame,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 8,
                ),
                child: const Text(
                  'RUN AGAIN',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statItem(String title, String value, [Color color = Colors.white]) {
    return Column(
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12,
                color: Colors.white54,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w900, color: color)),
      ],
    );
  }
}

// ==================== 3D PERSPECTIVE PAINTER ====================

class World3DPainter extends CustomPainter {
  final double playerX;
  final double playerY;
  final double playerZ;
  final bool isRolling;
  final bool isJetpackActive;
  final bool isMagnetActive;
  final double animTime;
  final double distanceTraveled;
  final List<WorldObject> objects;
  final List<Particle> particles;
  final List<ScorePopup> popups;

  World3DPainter({
    required this.playerX,
    required this.playerY,
    required this.playerZ,
    required this.isRolling,
    required this.isJetpackActive,
    required this.isMagnetActive,
    required this.animTime,
    required this.distanceTraveled,
    required this.objects,
    required this.particles,
    required this.popups,
  });

  // Perspective Projection Engine
  Offset project(double x, double y, double z, Size size) {
    double horizonY = size.height * 0.35;
    // Ground level at z = 0 is pushed down past screen bottom so track fully fills screen
    double groundY = size.height * 1.05;
    double trackWidth = size.width * 1.15;

    // Perspective transformation calculation
    double depthScale = 1.0 / (1.0 + z * 0.065);

    double screenY = horizonY +
        (groundY - horizonY) * depthScale -
        (y * size.height * 0.14 * depthScale);
    double centerX = size.width * 0.5;
    double laneSpacing = (trackWidth / 2.6) * depthScale;
    double screenX = centerX + (x * laneSpacing);

    return Offset(screenX, screenY);
  }

  double getScale(double z) {
    return 1.0 / (1.0 + z * 0.065);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawSkyAndBackground(canvas, size);
    _drawTrackAndEnvironment(canvas, size);

    // Sort all objects by Z descending (Paint distant objects first)
    List<WorldObject> sortedObjects = List.from(objects)
      ..sort((a, b) => b.z.compareTo(a.z));

    // Render world objects
    for (var obj in sortedObjects) {
      if (obj.z < -1.0 && obj.type != ObjectType.train) continue;
      _drawWorldObject(canvas, size, obj);
    }

    // Render Particles
    _drawParticles(canvas, size);

    // Render Player Character at Z = 0
    _drawPlayer(canvas, size);

    // Render Score Popups
    _drawPopups(canvas, size);
  }

  void _drawSkyAndBackground(Canvas canvas, Size size) {
    // Cyberpunk/Subway Sunset Sky Gradient
    Rect skyRect = Rect.fromLTWH(0, 0, size.width, size.height * 0.35);
    Paint skyPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(0, size.height * 0.35),
        [
          const Color(0xFF0F0B1E),
          const Color(0xFF38144C),
          const Color(0xFF812057),
          const Color(0xFFE3534B),
        ],
        [0.0, 0.4, 0.75, 1.0],
      );
    canvas.drawRect(skyRect, skyPaint);

    // Sun / Horizon Glow
    Offset sunCenter = Offset(size.width * 0.5, size.height * 0.35);
    Paint sunPaint = Paint()
      ..shader = ui.Gradient.radial(
        sunCenter,
        70,
        [const Color(0xFFFFDD66), const Color(0x00FF8800)],
      );
    canvas.drawCircle(sunCenter, 70, sunPaint);

    // City Silhouette
    Paint cityPaint = Paint()..color = const Color(0xFF140B24);
    Path cityPath = Path()..moveTo(0, size.height * 0.35);

    double buildingX = 0;
    final rng = Random(42); // Fixed seed for consistent skyline layout
    while (buildingX < size.width) {
      double width = 20 + rng.nextDouble() * 30;
      double height = 30 + rng.nextDouble() * 70;
      cityPath.lineTo(buildingX, size.height * 0.35 - height);
      cityPath.lineTo(buildingX + width, size.height * 0.35 - height);
      buildingX += width;
    }
    cityPath.lineTo(size.width, size.height * 0.35);
    cityPath.close();
    canvas.drawPath(cityPath, cityPaint);
  }

  void _drawTrackAndEnvironment(Canvas canvas, Size size) {
    // Track Ground Bed (Gravel / Asphalt) extending past screen bottom (z = -2)
    Offset p1 = project(-2.2, 0, -2.0, size);
    Offset p2 = project(2.2, 0, -2.0, size);
    Offset p3 = project(2.2, 0, 80, size);
    Offset p4 = project(-2.2, 0, 80, size);

    Path trackBed = Path()
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p3.dx, p3.dy)
      ..lineTo(p4.dx, p4.dy)
      ..close();

    Paint trackPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height),
        Offset(0, size.height * 0.35),
        [const Color(0xFF1C1B2B), const Color(0xFF0D0C16)],
      );
    canvas.drawPath(trackBed, trackPaint);

    // Rails Rendering (-1, 0, 1 lanes)
    Paint railPaint = Paint()
      ..color = const Color(0xFF88A0C0)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    for (int lane = -1; lane <= 1; lane++) {
      // Left and right rail lines per lane
      for (double offset in [-0.28, 0.28]) {
        Offset rStart = project(lane + offset, 0, -2.0, size);
        Offset rEnd = project(lane + offset, 0, 80, size);
        canvas.drawLine(rStart, rEnd, railPaint);
      }
    }

    // Moving Sleeper/Tie Lines (Gives sensation of speed!)
    Paint tiePaint = Paint()
      ..color = const Color(0xFF322E46)
      ..strokeWidth = 2.5;

    double tieSpacing = 2.5;
    double offsetZ = (distanceTraveled % tieSpacing) - tieSpacing;

    for (double z = offsetZ; z < 70; z += tieSpacing) {
      if (z < -1.8) continue;
      Offset leftEdge = project(-1.8, 0, z, size);
      Offset rightEdge = project(1.8, 0, z, size);
      canvas.drawLine(leftEdge, rightEdge, tiePaint);
    }

    // Light Posts on Sides
    for (double z = ((distanceTraveled * 0.5) % 15.0) - 15.0; z < 60; z += 15.0) {
      if (z < -1.5) continue;
      _drawLightPost(canvas, size, -2.0, z);
      _drawLightPost(canvas, size, 2.0, z);
    }
  }

  void _drawLightPost(Canvas canvas, Size size, double laneX, double z) {
    Offset base = project(laneX, 0, z, size);
    Offset top = project(laneX, 4.0, z, size);
    Offset lamp = project(laneX * 0.7, 4.0, z, size);

    Paint polePaint = Paint()
      ..color = Colors.grey.shade800
      ..strokeWidth = 3.5 * getScale(z);

    canvas.drawLine(base, top, polePaint);
    canvas.drawLine(top, lamp, polePaint);

    // Glowing Lamp
    Paint glowPaint = Paint()
      ..color = Colors.amberAccent.withOpacity(0.8)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(lamp, 7.0 * getScale(z), glowPaint);
  }

  void _drawWorldObject(Canvas canvas, Size size, WorldObject obj) {
    switch (obj.type) {
      case ObjectType.train:
        _draw3DBox(
          canvas,
          size,
          obj.lane.toDouble(),
          obj.y,
          obj.z,
          0.85,
          obj.height,
          obj.length,
          const Color(0xFFD32F2F), // Front: Bright Red
          const Color(0xFFB71C1C), // Top: Darker Red
          const Color(0xFF9A0007), // Side: Deep Red
        );

        // Front Headlights & Windshield
        Offset frontTL =
            project(obj.lane - 0.35, obj.y + obj.height * 0.85, obj.z, size);
        Offset frontBR =
            project(obj.lane + 0.35, obj.y + obj.height * 0.55, obj.z, size);
        Paint windowPaint = Paint()..color = const Color(0xFF1A237E);
        canvas.drawRect(Rect.fromPoints(frontTL, frontBR), windowPaint);

        // Headlights
        double scale = getScale(obj.z);
        Offset leftLight =
            project(obj.lane - 0.28, obj.y + 0.4, obj.z, size);
        Offset rightLight =
            project(obj.lane + 0.28, obj.y + 0.4, obj.z, size);
        Paint lightPaint = Paint()..color = Colors.yellowAccent;
        canvas.drawCircle(leftLight, 5.0 * scale, lightPaint);
        canvas.drawCircle(rightLight, 5.0 * scale, lightPaint);
        break;

      case ObjectType.lowBarrier:
        _draw3DBox(
          canvas,
          size,
          obj.lane.toDouble(),
          0.0,
          obj.z,
          0.9,
          obj.height,
          0.4,
          Colors.orange.shade700,
          Colors.orange.shade800,
          Colors.orange.shade900,
        );
        break;

      case ObjectType.highBarrier:
        Offset pL = project(obj.lane - 0.45, 0, obj.z, size);
        Offset pR = project(obj.lane + 0.45, 0, obj.z, size);
        Offset topL = project(obj.lane - 0.45, obj.height, obj.z, size);
        Offset topR = project(obj.lane + 0.45, obj.height, obj.z, size);

        Paint framePaint = Paint()
          ..color = Colors.yellow.shade700
          ..strokeWidth = 5.0 * getScale(obj.z)
          ..style = PaintingStyle.stroke;

        canvas.drawLine(pL, topL, framePaint);
        canvas.drawLine(pR, topR, framePaint);
        canvas.drawLine(topL, topR, framePaint);

        Offset signTL = project(obj.lane - 0.4, obj.height, obj.z, size);
        Offset signBR = project(obj.lane + 0.4, obj.height - 0.6, obj.z, size);
        Paint signPaint = Paint()..color = Colors.redAccent;
        canvas.drawRect(Rect.fromPoints(signTL, signBR), signPaint);
        break;

      case ObjectType.ramp:
        _drawRamp(canvas, size, obj);
        break;

      case ObjectType.coin:
        if (!obj.collected) {
          _drawCoin(canvas, size, obj.lane.toDouble(), obj.y, obj.z);
        }
        break;

      case ObjectType.jetpack:
        if (!obj.collected) {
          _drawJetpackItem(canvas, size, obj.lane.toDouble(), obj.y, obj.z);
        }
        break;

      case ObjectType.magnet:
        if (!obj.collected) {
          _drawMagnetItem(canvas, size, obj.lane.toDouble(), obj.y, obj.z);
        }
        break;
    }
  }

  void _draw3DBox(
    Canvas canvas,
    Size size,
    double x,
    double y,
    double z,
    double width,
    double height,
    double length,
    Color frontColor,
    Color topColor,
    Color sideColor,
  ) {
    double halfW = width / 2;

    Offset flb = project(x - halfW, y, z, size);
    Offset frb = project(x + halfW, y, z, size);
    Offset flt = project(x - halfW, y + height, z, size);
    Offset frt = project(x + halfW, y + height, z, size);

    Offset blb = project(x - halfW, y, z + length, size);
    Offset brb = project(x + halfW, y, z + length, size);
    Offset blt = project(x - halfW, y + height, z + length, size);
    Offset brt = project(x + halfW, y + height, z + length, size);

    if (x < playerX) {
      Path side = Path()
        ..moveTo(frb.dx, frb.dy)
        ..lineTo(brb.dx, brb.dy)
        ..lineTo(brt.dx, brt.dy)
        ..lineTo(frt.dx, frt.dy)
        ..close();
      canvas.drawPath(side, Paint()..color = sideColor);
    } else if (x > playerX) {
      Path side = Path()
        ..moveTo(flb.dx, flb.dy)
        ..lineTo(blb.dx, blb.dy)
        ..lineTo(blt.dx, blt.dy)
        ..lineTo(flt.dx, flt.dy)
        ..close();
      canvas.drawPath(side, Paint()..color = sideColor);
    }

    Path top = Path()
      ..moveTo(flt.dx, flt.dy)
      ..lineTo(frt.dx, frt.dy)
      ..lineTo(brt.dx, brt.dy)
      ..lineTo(blt.dx, blt.dy)
      ..close();
    canvas.drawPath(top, Paint()..color = topColor);

    Path front = Path()
      ..moveTo(flb.dx, flb.dy)
      ..lineTo(frb.dx, frb.dy)
      ..lineTo(frt.dx, frt.dy)
      ..lineTo(flt.dx, flt.dy)
      ..close();
    canvas.drawPath(front, Paint()..color = frontColor);
  }

  void _drawRamp(Canvas canvas, Size size, WorldObject obj) {
    double halfW = 0.45;
    Offset flb = project(obj.lane - halfW, 0, obj.z, size);
    Offset frb = project(obj.lane + halfW, 0, obj.z, size);

    Offset blt = project(obj.lane - halfW, obj.height, obj.z + obj.length, size);
    Offset brt = project(obj.lane + halfW, obj.height, obj.z + obj.length, size);

    Path slope = Path()
      ..moveTo(flb.dx, flb.dy)
      ..lineTo(frb.dx, frb.dy)
      ..lineTo(brt.dx, brt.dy)
      ..lineTo(blt.dx, blt.dy)
      ..close();

    Paint rampPaint = Paint()..color = Colors.amber.shade800;
    canvas.drawPath(slope, rampPaint);
  }

  void _drawCoin(Canvas canvas, Size size, double laneX, double y, double z) {
    Offset pos = project(laneX, y + 0.5, z, size);
    double scale = getScale(z);
    double radius = 14.0 * scale;

    double spin = sin(animTime * 8.0 + z);
    double widthFactor = spin.abs().clamp(0.2, 1.0);

    Paint glow = Paint()
      ..color = Colors.amber.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(pos, radius * 1.3, glow);

    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.scale(widthFactor, 1.0);

    Paint coinBody = Paint()..color = Colors.amber;
    Paint coinRim = Paint()
      ..color = Colors.orangeAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * scale;

    canvas.drawCircle(Offset.zero, radius, coinBody);
    canvas.drawCircle(Offset.zero, radius * 0.7, coinRim);

    canvas.restore();
  }

  void _drawJetpackItem(
      Canvas canvas, Size size, double laneX, double y, double z) {
    Offset pos = project(laneX, y + 0.5, z, size);
    double scale = getScale(z);

    Paint glow = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(pos, 18 * scale, glow);

    Paint packPaint = Paint()..color = Colors.cyan;
    canvas.drawRect(
      Rect.fromCenter(center: pos, width: 20 * scale, height: 26 * scale),
      packPaint,
    );
  }

  void _drawMagnetItem(
      Canvas canvas, Size size, double laneX, double y, double z) {
    Offset pos = project(laneX, y + 0.5, z, size);
    double scale = getScale(z);

    Paint glow = Paint()
      ..color = Colors.purpleAccent.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(pos, 18 * scale, glow);

    Paint magPaint = Paint()
      ..color = Colors.purpleAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6 * scale;

    canvas.drawArc(
      Rect.fromCircle(center: pos, radius: 12 * scale),
      pi,
      pi,
      false,
      magPaint,
    );
  }

  void _drawPlayer(Canvas canvas, Size size) {
    double playerScaleMultiplier = 2.2;
    double scale = getScale(playerZ) * playerScaleMultiplier;

    // Ground Shadow (If not flying jetpack)
    if (!isJetpackActive) {
      Offset shadowPos = project(playerX, 0, playerZ, size);
      Paint shadowPaint = Paint()
        ..color = Colors.black54
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawOval(
        Rect.fromCenter(
          center: shadowPos,
          width: 44.0 * scale,
          height: 16.0 * scale,
        ),
        shadowPaint,
      );
    }

    // Player Base Position
    Offset pPos = project(playerX, playerY, playerZ, size);

    // Active Magnet Aura Glow Visual
    if (isMagnetActive) {
      Paint magAura = Paint()
        ..color = Colors.purpleAccent.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
      canvas.drawCircle(
          Offset(pPos.dx, pPos.dy - 30 * scale), 45 * scale, magAura);
    }

    if (isJetpackActive) {
      // Jetpack Flying Pose
      Paint jetpackBody = Paint()..color = Colors.cyanAccent;
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset(pPos.dx - 12 * scale, pPos.dy - 35 * scale),
            width: 10 * scale,
            height: 25 * scale),
        jetpackBody,
      );
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset(pPos.dx + 12 * scale, pPos.dy - 35 * scale),
            width: 10 * scale,
            height: 25 * scale),
        jetpackBody,
      );

      // Hero Body (Super Flying Pose)
      Paint hoodiePaint = Paint()..color = Colors.orangeAccent;
      canvas.drawCircle(
          Offset(pPos.dx, pPos.dy - 35 * scale), 16.0 * scale, hoodiePaint);

      Paint headPaint = Paint()..color = const Color(0xFFFFCC80);
      canvas.drawCircle(
          Offset(pPos.dx, pPos.dy - 55 * scale), 12.0 * scale, headPaint);
    } else if (isRolling) {
      // Rolling Posture
      Paint rollBody = Paint()..color = Colors.cyanAccent;
      canvas.drawCircle(
        Offset(pPos.dx, pPos.dy - 18 * scale),
        22.0 * scale,
        rollBody,
      );
      Paint visor = Paint()..color = Colors.black87;
      canvas.drawCircle(
        Offset(pPos.dx + 4 * scale, pPos.dy - 18 * scale),
        9.0 * scale,
        visor,
      );
    } else {
      // Dynamic Running / Jumping Character Render
      Offset boardCenter = Offset(pPos.dx, pPos.dy - 6 * scale);
      Paint boardPaint = Paint()..color = Colors.pinkAccent;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: boardCenter, width: 46 * scale, height: 11 * scale),
          const Radius.circular(6),
        ),
        boardPaint,
      );

      // Legs / Lower Body
      Paint pantsPaint = Paint()..color = const Color(0xFF3F51B5);
      double legCycle = sin(animTime * 18.0);
      Offset leftFoot =
          Offset(pPos.dx - 9 * scale, pPos.dy - (12 + legCycle * 6) * scale);
      Offset rightFoot =
          Offset(pPos.dx + 9 * scale, pPos.dy - (12 - legCycle * 6) * scale);

      canvas.drawLine(
          boardCenter, leftFoot, pantsPaint..strokeWidth = 7 * scale);
      canvas.drawLine(
          boardCenter, rightFoot, pantsPaint..strokeWidth = 7 * scale);

      // Hoodie Body
      Offset torsoPos = Offset(pPos.dx, pPos.dy - 34 * scale);
      Paint hoodiePaint = Paint()..color = Colors.orangeAccent;
      canvas.drawCircle(torsoPos, 17.0 * scale, hoodiePaint);

      // Head & Cap
      Offset headPos = Offset(pPos.dx, pPos.dy - 56 * scale);
      Paint skinPaint = Paint()..color = const Color(0xFFFFCC80);
      canvas.drawCircle(headPos, 12.0 * scale, skinPaint);

      // Cool Cap (Red)
      Paint capPaint = Paint()..color = Colors.redAccent;
      canvas.drawArc(
        Rect.fromCircle(center: headPos, radius: 13.0 * scale),
        pi,
        pi,
        true,
        capPaint,
      );
      canvas.drawRect(
        Rect.fromLTWH(headPos.dx - 16 * scale, headPos.dy - 4 * scale,
            18 * scale, 5 * scale),
        capPaint,
      );
    }
  }

  void _drawParticles(Canvas canvas, Size size) {
    for (var p in particles) {
      Offset pos = project(p.x, p.y, p.z, size);
      double scale = getScale(p.z);
      Paint paint = Paint()
        ..color = p.color.withOpacity((p.life / p.maxLife).clamp(0.0, 1.0));
      canvas.drawCircle(pos, p.size * scale, paint);
    }
  }

  void _drawPopups(Canvas canvas, Size size) {
    for (var pop in popups) {
      Offset pos = project(pop.x, pop.y, 0, size);
      TextSpan span = TextSpan(
        text: pop.text,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w900,
          color: pop.color.withOpacity(pop.opacity.clamp(0.0, 1.0)),
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      );
      TextPainter tp = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
