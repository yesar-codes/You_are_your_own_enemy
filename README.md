# Shadow Learner

Top-down arena game in **Godot 4.3+ (GDScript)**. The enemy is a Shadow that learns how
*you* move and aims where it predicts you'll be. The more predictable you are, the more
it hits. You are your own enemy.

## Run

1. Open Godot 4.3 or newer -> **Import** -> select `project.godot`.
2. Press **F5**.

Run the unit tests (optional):

```
godot --headless --path . --script res://tests/test_predictor.gd
```

## Controls

| Key | Action |
|---|---|
| WASD / arrows | move |
| Space | dash (1.2 s cooldown) |
| Z | cycle context mode (history only / arena zone / threat bearing) |
| F1 | hide/show model internals |
| R | restart run (model is kept) |
| N | new model (wipes what it learned) |

Red circles are aimed by the model. Blue circles are exploration shots (epsilon-greedy).
The yellow/blue line shows the future path the Shadow *believed* you would take.

## How it works

```
 player input ──► ActionSampler (10 Hz) ──► action (8 dirs, IDLE, DASH)
                                               │
                    score last guess ◄─────────┤
                                               ▼
                         MarkovPredictor.update(history, situation, action)
                                               │
 Shadow fires ──► AttackPlanner.plan_volley ──►│ rollout: ask model for next action,
                                               │ step the simulated player, repeat
                                               ▼
                              telegraphed Attack at predicted position
```

| File | Role |
|---|---|
| `scripts/markov_predictor.gd` | n-gram model (orders 0-4) with backoff, smoothing, forgetting, JSON save/load. No Node dependencies. |
| `scripts/attack_planner.gd` | Autoregressive rollout, epsilon-greedy exploration, volley hedging. |
| `scripts/action_space.gd` | The action alphabet and quantisation. |
| `scripts/game_config.gd` | Tunables and the "situation" features. |
| `scripts/main.gd` | Game loop, observe/score/learn/predict tick, persistence. |
| `scripts/player.gd`, `shadow.gd`, `attack.gd` | Actors. |
| `scripts/debug_overlay.gd` | Prediction bars, rolling accuracy graph, plan path. |
| `scripts/save_manager.gd` | JSON persistence in `user://shadow_model.json`. |

### Context modes (press Z)

- **history only**: P(next | last k actions).
- **arena zone**: also conditions on which 3x3 cell you're in.
- **threat bearing** (default): also conditions on the direction of the nearest telegraphed
  attack. This is what learns habits like "when a circle appears to my right, I dash left".

Only the active mode accumulates its situation statistics, so give a mode some time after
switching to it.

## Tuning (`scripts/game_config.gd`, `markov_predictor.gd`)

- `WINDUP_START` / `WINDUP_MIN`: reaction time you get (fairness).
- `EPS_START`, `EPS_MIN`, `EPS_DECAY`: exploration.
- `MarkovPredictor.max_order`, `min_evidence`, `alpha`, `decay`: model capacity, trust
  threshold, smoothing, forgetting speed.

## Ideas to extend

- Plan against your *reaction*: add the planned telegraph itself as a threat in the rollout.
- Replace n-grams with a small neural net trained offline on logged inputs.
- Multiple Shadow personalities (cautious / aggressive) mixing different orders.
- Log per-run accuracy to CSV and plot learning curves across many runs.

## Honest limits

This is a single-player behavioural model, not a security boundary. Saved data is only
your own movement statistics, stored locally in `user://shadow_model.json`.
The code was written without access to a Godot binary in the authoring environment, so
run the test script once after importing and report any engine-version issues.
