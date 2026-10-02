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
| M | mute sound and music |
| V | switch between the 3D and the 2D view |
| R | restart run (model is kept) |
| N | new model (wipes what it learned, the replays and the ghost) |
| P | after game over: watch a replay of the run you just played |
| B | after game over: watch a replay of your best run |
| P / R / Esc | during a replay: back to live play |

Red circles are aimed by the model. Blue circles are exploration shots (epsilon-greedy).
The yellow/blue line shows the future path the Shadow *believed* you would take.

## 3D view (2.5D)

The game is shown in 3D by default (`scripts/view_3d.gd`, `shaders/floor.gdshader`). It's
2.5D: the simulation is still the 2D arena plane in `main.gd`, and the 3D view only *reads*
positions every frame and draws them. 2D pixels map to metres at 40 px/m. So the AI, replays,
the ghost and the tests behave exactly as in 2D, and **V** switches views at any time
(the choice is saved).

What's in the 3D scene:

- **Camera:** angled at 55°, following you slightly. Screen shake moves this camera.
- **You:** a glowing capsule with a nose for your facing direction, plus dash afterimages.
- **The Shadow:** a floating dark orb with a purple light that casts real shadows, eyes that
  track you, and a flash when it fires.
- **Attacks:** glowing rings on the floor with a shrinking inner ring and their own light,
  then a column of light on impact.
- **Arena:** thorns are 3D spikes that grow out of the floor, the blind spot is a green dome,
  and the ghost is a see-through purple you.
- **Floor:** dark tiles on the arena's 12x10 grid. With F1 on, the heat map glows orange in
  the floor and the predicted paths are drawn as lines.
- **Particles:** the same particles as in 2D, as glowing billboards. Lighting uses filmic
  tonemapping, glow (bloom) and a little fog.

The HUD panel, speech bubble (anchored to the Shadow's 3D position), game-over card and the
hit shader stay 2D on top. The renderer is now **Forward+** (needs Vulkan; most PCs have it)
for glow and soft shadows. To switch back, set `rendering_method` to `gl_compatibility` in
`project.godot` and play in 2D (V).

## Replays, the Ghost Shadow and the profile card

**Replay system.** A run is saved as its starting state (the model's counts, the planner's
RNG seed and epsilon, the context mode) plus one 5-bit input value per physics frame
(`scripts/input_bits.gd`, `scripts/run_recording.gd`). Nothing else is stored, no positions.
Godot's physics step is fixed (60 Hz), the player never reads the keyboard directly, and every
random number comes from the seeded planner RNG, so re-simulating the same inputs reproduces
the run exactly: same predictions, same volleys, same hits. A replay uses its own copy of the
model, so watching one does not teach the live Shadow anything. Rollback netcode depends on
the same determinism. If a replay ever runs out of inputs before the recorded death, the
screen says `REPLAY DIVERGED`, which means something in the simulation isn't deterministic.

Files: `user://replays/last.json` and `user://replays/best.json`.

**Ghost Shadow (final boss).** When round `GHOST_ROUND` (default 3, at 50 s) starts, your best
earlier run comes back as a purple ghost. It is the player script fed the recorded inputs of
that run, so it walks and dashes exactly as you did, from the same spawn point. Touching it
costs a heart (after a 1.5 s grace period). The Shadow fires about 35% less often while it is
out. The fight ends when the ghost's recording reaches the moment that run died, or after one
round. You need one finished run before a ghost exists.

**The arena learns too.** It keeps a heat map (12x10 cells) of where you stand, which slowly
forgets and carries over between runs. Every 12 s it reshapes:

- **Thorns** grow on your hottest cells: one more each time, up to 8. They blink for 1.5 s
  first, then standing on them costs a heart.
- A **blind spot** (green circle) opens on a cold cell at least 220 px away. Inside it the
  Shadow's strikes can't hurt you, but only for 4 s in total. Camping there heats the cell,
  so it tends to become the next thorns.

With F1 on, the orange tint shows the heat map. The ghost passes through thorns. All the
arena's choices come from the heat map and the run seed, so replays stay exact. Replays
recorded before this version can't be replayed any more (the simulation changed), but they
can still be used as the ghost. Tunables: `ARENA_*` and `POCKET_*` in `game_config.gd`.
Code: `scripts/arena_shaper.gd` (logic) and `scripts/arena_view.gd` (drawing).

**Game feel.**

- Screen shake (trauma model: shake = trauma squared, so big hits are violent and small ones subtle).
- Hit-stop: the world freezes for 6 frames when you lose a heart.
- Particles on strikes, hits, dashes and the ghost's arrival, plus a dash trail of afterimages.
- Glowing telegraphs (additive halo that pulses faster just before the strike).
- Chromatic aberration and a red vignette when you're hit (`shaders/hit_aberration.gdshader`).
- Procedural audio, no sound files (`scripts/synth.gd`): a rising tone during each wind-up, so
  you can dodge by ear, a deep thud on impact, and sounds for hits, dashes, reshapes, the
  ghost and death.
- Adaptive music: a 112 BPM loop whose layers (bass, hats, arpeggio, a dissonant pad) fade in
  as the Shadow's prediction accuracy rises. **M** mutes.

All of this is presentation only (own RNG, never read by the simulation), so replays stay
exact. Hit-stop does pause the simulation, but only for a fixed number of frames after a
hit, so it happens identically in a replay.

**The Shadow talks.** A speech bubble above the Shadow, typed out with a little voice blip
(`scripts/shadow_voice.gd`, `scripts/speech_bubble.gd`). Lines come from two places:

- **Your habits.** About every 9 s it taunts you with your strongest current habit from the
  profile stats: "A circle to your right? You'll go left.", "Back to the bottom-left corner
  again?", "After moving right, you go down. I know." It never repeats the same habit twice
  in a row.
- **Events.** Being hit by an aimed strike ("I saw that coming."), by an exploration shot,
  by thorns or by the ghost. Three dashes the same way ("Left again?"). A blind spot saving
  you ("Hiding? I'll remember this spot."). The ghost arriving and being beaten. Its accuracy
  rising past 42% and 60% ("I know you.") or collapsing ("...you're changing."). Being very
  sure of a long pattern ("I've seen this before."). Your run number when you come back.

Priorities stop it talking over itself: hits and the ghost may interrupt, habit taunts only
speak after a quiet gap. It's presentation only, so replays are unaffected.

**Profile card.** On game over, the card shows up to four habits the run revealed, for example
"When a circle appears to your right, you move left 71% of the time" or "68% of your dashes
go up". Candidates are threat reactions, behaviour when two or more circles are near, dash
direction, favourite arena zone, and what you do after each action. They are ranked by how
much better than a uniform random guess each one predicts you
(`scripts/profile_stats.gd`).

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
| `scripts/ensemble_predictor.gd` | Three experts (n-gram, repeat, threat reflex) blended by Hedge weights. |
| `scripts/attack_planner.gd` | Autoregressive rollout, epsilon-greedy exploration, volley hedging. |
| `scripts/action_space.gd` | The action alphabet and quantisation. |
| `scripts/game_config.gd` | Tunables and the "situation" features. |
| `scripts/main.gd` | Game loop, observe/score/learn/predict tick, recording, replays, ghost fight, persistence. |
| `scripts/player.gd`, `shadow.gd`, `attack.gd` | Actors. |
| `scripts/view_3d.gd`, `shaders/floor.gdshader` | 3D presentation of the 2D simulation (V toggles). |
| `scripts/shadow_voice.gd`, `speech_bubble.gd` | What the Shadow says (habit taunts, event lines) and the bubble. |
| `scripts/fx.gd`, `post_fx.gd`, `synth.gd` | Particles + shake, hit shader layer, procedural sound + adaptive music. |
| `scripts/arena_shaper.gd`, `arena_view.gd` | Learning arena: heat map, thorns, blind spot. |
| `scripts/ghost.gd` | Ghost Shadow: the player script driven by a recorded run. |
| `scripts/input_bits.gd` | One frame of input packed into 5 bits (the replay unit). |
| `scripts/run_recording.gd` | Starting state + per-frame inputs, run-length encoded JSON. |
| `scripts/profile_stats.gd` | Per-run habit statistics for the game-over profile card. |
| `scripts/debug_overlay.gd` | Prediction bars, rolling accuracy graph, plan path, replay banner, profile card. |
| `scripts/save_manager.gd` | JSON persistence in `user://shadow_model.json` and `user://replays/`. |

### Three experts that vote (Hedge)

The Shadow doesn't rely on one model. `scripts/ensemble_predictor.gd` runs three experts side
by side and blends their predictions:

| Expert | Predicts | Good against |
|---|---|---|
| n-gram patterns | P(next \| last k actions [, situation]), the Markov model above | rhythms, zig-zags, routines |
| repeat last move | you keep doing what you're doing | holding one direction |
| threat reflex | P(action \| direction of the nearest circle), ignores history | fixed dodge reflexes |

After every tick, each expert pays a **log-loss** for the probability it gave to what you
actually did, scaled to 0..1. Its weight is multiplied by `exp(-ETA * loss)` (the **Hedge**
/ multiplicative-weights algorithm). A small **fixed share** (1% per tick) mixes uniform weight
back in, so an expert that was bad a minute ago regains trust within seconds once it's right
again. The blended prediction is `sum_i w_i * p_i` and drives the attack planner.

The panel shows each expert's weight ("trust") and its own recent top-1 accuracy, with `>`
marking the trusted one. Faint coloured lines in the accuracy graph show the weights over
time. The Shadow announces when it switches ("You're repeating yourself.", "I'm watching how
you react to me."), and the profile card says which expert it trusted most during the run.
Tunables: `ETA`, `SHARE`, `REPEAT_EPS`, `THREAT_DECAY` in `ensemble_predictor.gd`.

Old saves still load: the n-gram expert keeps what it learned and the others start fresh.

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
your own movement statistics and input recordings, stored locally in `user://`.
The code was written without access to a Godot binary in the authoring environment, so
run the test script once after importing and report any engine-version issues.
