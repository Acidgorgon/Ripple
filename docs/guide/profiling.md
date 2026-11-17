# Profiling with Lighthouse

[Lighthouse](https://acidgorgon.github.io/Lighthouse/) is the family's profiler. The generated
`Server.luau` and `Client.luau` have its hooks built in: require Lighthouse and start it on the server
and the client, and Ripple's bytes and flush time show up in its overlay under **Ripple**.

```lua
local Lighthouse = require(ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

Ripple reads `shared.Lighthouse` once per flush on the server (once per frame, on Heartbeat) and once
per received packet on the client (the server sends at most one per frame). Without Lighthouse that is
all it costs: no counters run and nothing is allocated.

## Network channels

The channel is the **state name** from your schema (`Club`, `Match`, ...). Each frame the server
reports, for every player it sent to, the bytes of each state in that player's buffer (creates,
patches, removals and the shared stream of `Scope: All` states), with the player. The client reports
the bytes of each state in every buffer it applies. Ops for a shared state the client does not hold
(yet) are reported as `Skipped`.

| Channel | Direction | What |
|---|---|---|
| `<State>` | server out, client in | that state's ops in each player's buffer |
| `Skipped` | client in | shared patches for a state this client does not hold yet |

The sum over channels is exactly the size of the buffers Ripple sends. If you [ride on
Current](./current), the same bytes also show under Current's event, since both libraries count them.

## Probes

| Probe | Side | Covers |
|---|---|---|
| `Ripple.Encode` | server | encoding patches and creates for every dirty state |
| `Ripple.Send` | server | building each player's buffer and the remote calls |
| `Ripple.Apply` | client | decoding a buffer into the client tables |
| `Ripple.Events` | client | `changed` / `observe` listeners and added / removed callbacks |
