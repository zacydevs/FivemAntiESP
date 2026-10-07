<div align="center">

# FiveM Anti-ESP

**Camera-based player concealment for FiveM.**

Standalone resource · OneSync required · Built by Zacy

[Installation](#installation) · [How it works](#how-it-works) · [Configuration](#configuration) · [Diagnostics](#diagnostics) · [Limitations](#limitations)

</div>

---

This resource checks whether other streamed players are obstructed from the local camera and conceals their peds when every visibility sample is blocked. It combines asynchronous raycasts, delayed hiding, server-supplied position updates, and bounded synchronous fallback.

> **Project status:** A functional proof of concept. Concealment is controlled by the client, and hidden-player coordinates are still supplied to that client. This resource can be bypassed and should not be treated as a server-enforced anti-cheat boundary.

## At a glance

- **Standalone:** no framework, database, or external resource dependency beyond OneSync.
- **Six visibility samples:** body bones and an upper-body envelope reduce single-point decisions.
- **Fast reveal path:** one accepted clear sample reveals a concealed player.
- **Delayed hiding:** repeated blocked decisions reduce abrupt visibility changes.
- **Batched networking:** one position request can cover multiple concealed players.
- **One client thread:** discovery, ray processing, and outgoing events share a scheduler.
- **Startup snapshots:** local `<const>` function references and scalar settings resist later global replacements.
- **Optional reciprocal visibility:** allow players to see observers who report seeing them; disabled by default.

## Installation

1. Place the resource in your server's resources directory, for example:

   ```text
   resources/
   └── [standalone]/
       └── antiwallhack/
           ├── fxmanifest.lua
           ├── config.lua
           ├── client.lua
           └── server.lua
   ```

2. Enable OneSync in your server configuration if it is not already enabled:

   ```cfg
   set onesync on
   ```

3. Add the resource to `server.cfg`:

   ```cfg
   ensure antiwallhack
   ```

4. Adjust `Config.AntiWallhack` in [config.lua](config.lua), then restart the resource:

   ```text
   restart antiwallhack
   ```

The commands above assume the folder is named `antiwallhack`. Use your actual resource name if you rename it. The manifest declares the `/onesync` dependency.

**Restart after configuration changes.** Each script captures its settings at startup. Editing the global config table after initialization does not update the captured values.

## How it works

```text
Discover streamed players
          |
          v
Probe from the rendered camera toward a target
          |
          +-- Any accepted clear sample ----------> Reveal the ped
          |
          +-- All six samples blocked
                      |
                      v
             Start / check hide delay
                      |
                      v
                 Conceal ped
                      |
                      v
          Request real position from server
                      |
                      +--------------------------> Continue probing
```

### 1. Discover players

The client scans `GetActivePlayers()` approximately every 250 ms and tracks other players with valid local peds. This operates on players already streamed to that client, rather than every player connected to the server.

New entries start visible. If a player's ped changes or the player disappears from the active list, the old entry is released and its pending ray is discarded from the script's bookkeeping.

### 2. Sample visibility

Rays originate at `GetFinalRenderedCamCoord()`, so the decision follows the rendered camera, including third-person camera placement.

Each blocked decision requires six samples. For visible peds, the first three samples use head, spine, and pelvis bones. Remaining samples use a coordinate-based upper-body envelope, including lateral offsets. Hidden or recently restored peds use coordinate-based samples throughout because their local bone positions may be unreliable.

A completed sample is accepted as clear when it:

- Hits no obstruction.
- Hits the target ped or the vehicle occupied by that ped.
- Ends within 0.2 metres of the intended target point.

A target or camera position change greater than one metre during the probe causes a reveal decision instead of retaining the potentially stale obstruction result. Missing usable target coordinates also cause a reveal.

The default trace flags include world geometry, vehicles, and objects. Trace options ignore glass, see-through surfaces, and surfaces without collision. There is no separate field-of-view or screen-visibility test.

### 3. Hide and reveal

The client calls `NetworkConcealEntity` only when its tracked hidden state changes.

An accepted clear sample reveals immediately when processed. Hiding requires a complete blocked decision, followed by a later blocked decision for which the hide delay has elapsed.

**`hideDelayMs = 350` is not a guarantee of 350 ms total hide latency.** Discovery, six-sample cycles, cooldowns, pending queries, frame rate, and other tracked players all contribute to the final delay.

After revealing a ped, the client continues using cached positions for a 500 ms restoration window before returning to normal entity coordinates.

### 4. Refresh hidden positions

Concealed peds can have unreliable local coordinates. While targets are hidden, the client requests their real positions from the server approximately every 250 ms.

The server returns coordinates only for requested players who have valid peds, are in the requester's routing bucket, and are within the configured maximum distance. It excludes the requester and removes duplicate IDs.

The client prefers a fresh server position, then a recent cached world position. If neither is usable within `positionTimeoutMs`, it reveals the target. The server does not perform a line-of-sight check for these replies.

### 5. Handle failed probes

An asynchronous result can be pending, completed, or invalid. Pending probes are polled until completion or the configured timeout.

Failed queries retain the previous concealment state during a grace period. Persistent failures eventually reveal the target. After enough consecutive failures, the client can switch temporarily to synchronous probes, with a shared interval limiting how frequently they start.

Synchronous fallback can have a frame-time cost. Its interval is a rate limit, not a guaranteed CPU-time budget.

## Network events

All custom events use the `zacy:` prefix. IDs in these payloads are **player server IDs**, not network entity IDs.

| Event | Direction | Payload | Default activity |
| --- | --- | --- | --- |
| `zacy:requestPositions` | Client → server | `{ id, id, ... }` | Approximately every 250 ms while targets are hidden |
| `zacy:positions` | Server → requester | `{ { id, x, y, z }, ... }` | One reply to an accepted request with a valid requester ped |
| `zacy:report` | Client → server | `{ id, id, ... }` | Disabled; approximately every 1,000 ms when reciprocal visibility is enabled |
| `zacy:seenByBatch` | Server → individual player | `{ observerId, ... }` | Disabled; dirty recipients are flushed every 250 ms when enabled |

Position replies can be empty. These events are targeted; the resource does not broadcast position replies to every client.

Server handlers validate dense numeric arrays, integer ID ranges, maximum list size, and per-sender request rates. These limits use fixed one-second windows. Client reply handlers require the server event source, `65535`.

### Reciprocal visibility

With `reciprocalVisibility = true`, if player A reports seeing player B, the server sends A's ID to B. B then reveals A locally.

The server validates range and routing bucket, but cannot prove the client's visibility claim. Reciprocal reveals themselves do not set the local clear-ray flag, preventing that reveal alone from feeding back into reports. Other reveal paths can still mark an entry clear.

Reports replace the sender's previous set. Relationships expire through lease checks, and each batch replaces the receiver's observer list. Unchanged reports still refresh relationships and can produce another batch.

**Leave this option disabled unless you want its gameplay and trust tradeoffs.**

## Configuration

All settings live in `Config.AntiWallhack`. Time values are milliseconds unless stated otherwise; distance values use game-world units, conventionally metres.

### Visibility and discovery

| Setting | Default | Purpose |
| --- | --- | --- |
| `enabled` | `true` | Enables the resource logic at startup. |
| `maxDistance` | `500.0` | Maximum checking and server position-service range. Locally tracked targets beyond it are revealed. |
| `closeDistance` | `0.0` | Reveals targets closer than this distance. Zero disables this bypass. |
| `discoveryMs` | `250` | Interval for discovering and releasing streamed players. |
| `tickMs` | `20` | Normal loop wait with tracked players and no pending rays; maintenance deadlines may shorten it. |
| `checkMs` | `100` | Cooldown after a completed decision at distances up to 100 metres; also used for failed-query retries. |
| `farCheckMs` | `250` | Cooldown after a completed decision beyond 100 metres. |
| `hideDelayMs` | `350` | Required elapsed blockage time before a later blocked decision conceals the target. |
| `traceFlags` | `19` | Ray intersection mask: world, vehicles, and objects. |
| `traceOptions` | `7` | Ignore glass, see-through, and no-collision surfaces. |

### Probe limits and recovery

| Setting | Default | Purpose |
| --- | --- | --- |
| `rayTimeoutMs` | `200` | Maximum time a pending async probe is retained before counting as a failure. |
| `rayFailureGraceMs` | `1000` | Failure grace before revealing; successful individual samples reset this timer. |
| `synchronousFallback` | `true` | Allows synchronous probes after repeated failures. |
| `fallbackAfterFailures` | `2` | Consecutive failures needed to enter fallback. |
| `fallbackIntervalMs` | `100` | Minimum interval between synchronous starts across all targets on the client. |
| `maxRayStartsPerTick` | `8` | Maximum new probes per scheduler iteration. |
| `maxPendingRays` | `64` | Maximum script-tracked async probes awaiting results. |

### Position service and reporting

| Setting | Default | Purpose |
| --- | --- | --- |
| `maxTargets` | `1024` | Maximum IDs per outgoing list and accepted server input list; does not cap local discovery. |
| `positionRequestMs` | `250` | Interval between batched hidden-position requests. |
| `positionTimeoutMs` | `1500` | Maximum usable age of a cached position. |
| `maxPositionRequestsPerSecond` | `8` | Accepted position requests per sender per server rate-limit window. |
| `reciprocalVisibility` | `false` | Enables observer reporting and reciprocal reveals. |
| `reportMs` | `1000` | Client reciprocal-report interval. |
| `leaseMs` | `3500` | Lifetime used for reciprocal relationships and received observer entries. Server expiry is checked periodically. |
| `maxReportsPerSecond` | `4` | Accepted reciprocal reports per sender per server rate-limit window. |

### Gameplay bypasses

| Setting | Default | When enabled |
| --- | --- | --- |
| `revealInteriors` | `false` | Reveals targets if either the local player or target is in an interior. |
| `revealVehicles` | `false` | Reveals targets occupying a vehicle. |
| `revealDeadPlayers` | `false` | Reveals dead targets; also bypasses concealment when the local player is dead. |
| `revealWhileSpectating` | `false` | Bypasses concealment while the local client is spectating. |

Use sensible positive intervals and limits. The resource does not validate every configuration value for you.

## Local function and configuration protection

Both scripts capture native/runtime functions in local constant bindings:

```lua
local NetworkConcealEntity <const> = NetworkConcealEntity
```

After initialization, replacing `_G.NetworkConcealEntity` does not change that captured reference. The local binding supplies this isolation; `<const>` prevents ordinary Lua reassignment of the binding.

Configuration values are read once into individual local constants using `rawget`. The runtime logic then uses those captured scalar values, so changing or replacing `Config.AntiWallhack` afterward does not alter the active settings. `rawget` also avoids table `__index` lookups during capture.

**This does not make the config file or client runtime unhookable.** A function or setting modified before capture can still be captured in its modified form. Native-level hooks and a compromised runtime are outside the protection supplied by local constants. The editable config table itself is not frozen.

## Performance

The client has one scheduler thread. It polls every frame while rays are pending; otherwise it sleeps according to the normal tick and upcoming maintenance deadlines.

The server has no periodic thread with the default configuration. Enabling reciprocal visibility starts one thread that flushes updates every 250 ms and performs relationship cleanup approximately every second.

### What affects cost

- **Tracked player count:** the visibility loop visits every tracked entry.
- **Occlusion:** blocked decisions require six samples; clear decisions can finish after one.
- **Frame rate:** eight starts per iteration is not a fixed eight starts per 20 ms. Pending work can make the start budget scale with FPS.
- **Hidden-player count:** batches grow with the number of requested coordinates.
- **Fallback frequency:** synchronous probes may introduce frame-time spikes.

For `P` clients continuously requesting positions for an average of `H` unique eligible hidden targets:

```text
Requests per second       ≈ 4 × P
Replies per second        ≈ 4 × P
Coordinate rows per second ≈ 4 × P × H
```

For example, 128 requesting clients with 30 hidden targets each produce approximately 512 requests, 512 replies, and 15,360 returned coordinate rows per second. These are nominal arithmetic estimates, not measured packet counts or bandwidth figures.

The server performs fresh player-information lookups per request. There is no shared position cache or global work budget, so dense populations increase total requester-target work substantially.

## Diagnostics

Open the client F8 console and run:

```text
check 12
```

Replace `12` with the target's server ID. With a compatible chat resource, `/check 12` invokes the same command; output is printed to the console. The target must be locally streamed and tracked.

The command prints:

| Field | Meaning |
| --- | --- |
| `concealed` | The script's current hidden state for the target. |
| `reason` | Most recent visibility or failure reason. |
| `distance` | Last calculated target distance. |
| `reciprocal` | Whether an observer entry currently exists for the target. |
| `pending` | Total pending rays across this client. |
| `status` | Last ray status: invalid `0`, pending `1`, or completed `2`. |
| `failures` | Consecutive failed samples. |
| `completed` | Completed valid samples, not full six-sample decisions. |
| `fallbacks` | Synchronous probes started for this target. |

When available, a second line prints the last target point, hit endpoint, and hit entity.

### Troubleshooting

| Symptom | Check |
| --- | --- |
| A player remains visible behind cover | Inspect `reason`; consider incomplete sample cycles, camera position, ignored surfaces, motion, range, and failure recovery. |
| A player takes too long to hide | Consider all six samples, decision cooldowns, frame rate, and competing targets—not only `hideDelayMs`. |
| A hidden player repeatedly reappears | Check position replies, cache expiry, probe failures, and movement-triggered reveals. |
| A config edit has no effect | Restart the resource so the scripts capture the new values. |
| The command cannot find a player | Verify the server ID and that the player is within local streaming scope. |
| The resource costs too much frame time | Capture a profiler trace in clear and heavily occluded crowds; inspect fallback counts and ray activity. |

## Limitations

- **Client trust:** this code controls local concealment rather than server-side replication of visibility.
- **Position disclosure:** the server intentionally returns real hidden-player coordinates. It validates proximity and bucket, but does not require a verified concealment or LOS state.
- **Partial-failure edge case:** successful individual samples reset the failure timer. Repeated partial blocked cycles interrupted by failed samples can preserve an outdated hidden decision longer than the configured grace.
- **Approximate geometry:** body samples are not a complete mesh visibility test. Camera placement, animation, map collision, and vehicle geometry can affect results.
- **Ped-only handling:** vehicles, attached objects, name displays, map blips, and voice need separate consideration.
- **Integration conflicts:** another resource can change concealment without updating this resource's cached hidden state.
- **No detection or punishment:** the resource does not ban players, detect injected code, or prove a client is trustworthy.

Test with multiple clients before deployment, including crowded areas, vehicles, interiors, respawns, routing-bucket changes, poor network conditions, and resource restarts. Source inspection and mocked Lua checks do not replace in-game performance and behavior testing.

## Project files

| File | Responsibility |
| --- | --- |
| [fxmanifest.lua](fxmanifest.lua) | Resource metadata, script loading, and OneSync dependency. |
| [config.lua](config.lua) | Shared startup configuration. |
| [client.lua](client.lua) | Function/settings capture, visibility decisions, scheduling, concealment, and diagnostics. |
| [server.lua](server.lua) | Validated position replies and optional reciprocal relationship maintenance. |

---

<div align="center">

Built by **Zacy** · [Project repository](https://github.com/zacydevs/fivem-anti-esp)

</div>
