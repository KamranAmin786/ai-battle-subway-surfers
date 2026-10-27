# ChatGPT vs Gemini vs Claude: Subway Surfers in Flutter

Three AIs got the same prompt to build a Subway Surfers style endless runner in Flutter.
One file (`lib/main.dart`), no packages, no hand edits. Each AI could get up to two fix messages, then one polish round.

| | Round 1 | Round 2 (fix) | Round 3 (polish) | Lines (R3) |
|---|---|---|---|---|
| ChatGPT | built first try | track had too many rails, fixed | built first try | 4,805 |
| Gemini | built first try | black band at the bottom, fixed | built first try | 1,762 |
| Claude | built first try | giant wall triangles, fixed | built first try | ~1,000 |

## Run any version

```bash
flutter create my_runner
cp chatgpt/round3/lib/main.dart my_runner/lib/main.dart
cd my_runner && flutter run
```

Swipe left or right to change lanes, up to jump, down to roll.

## Prompts

**Round 1**

> Make a Subway Surfers style endless runner game in Flutter. Put everything in one file, lib/main.dart, and use no packages beyond Flutter itself.
> It must have: a 3-lane track seen from behind the runner with a 3D perspective, swipe left or right to change lanes, swipe up to jump and swipe down to roll, trains and barriers coming toward the player, coins to collect, speed that increases over time, a score and coin counter, and a game over screen with restart.
> Make it look and feel like a real mobile game: smooth animations, nice colors, satisfying effects. Reply with only the full code.

**Round 2 (fix, one per AI)**

> ChatGPT: Here is the problem: the track has too many rails, so it does not look like 3 lanes, and trains and barriers appear too rarely at the start. Fix it and reply with the full main.dart.
>
> Gemini: Here is the problem: the track stops above the bottom of the screen and leaves an empty black band, and the runner is too small. Fix it and reply with the full main.dart.
>
> Claude: Here is the problem: the side walls are drawn as huge flat triangles that block a big part of the view. Fix it and reply with the full main.dart.

**Round 3**

> Now make it look amazing: a power-up (jetpack or magnet), a combo/multiplier for coins, particles and screen shake on crashes, and a start screen with the high score. Reply with the full main.dart.
