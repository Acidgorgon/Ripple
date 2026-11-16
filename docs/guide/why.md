# Why Ripple

Most Roblox games replicate player data in one of two ways:

1. **Send the whole thing** (a snapshot of the profile, or a big derived view) whenever something changes.
2. **Send path updates as tables** (`FireClient(player, {"Owned", id}, card)`), as Replica, ReplicaService,
   DataService and most other libraries do.

Both pay a cost you can't see in the script profiler: Roblox serializes every table you pass to a
RemoteEvent in C++. We measured it in Studio (Ryzen 7 7700X, Play Solo):

| What was sent with `FireClient` | Engine cost per call |
|---|---|
| a 300-card club table | **290 to 340 µs** |
| one card table | 4.6 to 4.8 µs |
| a path set `(1, {"Cash"}, n)` | 2.8 µs |
| a single number | 2.3 µs |
| a 24 B buffer | 2.8 to 2.9 µs |
| a 4,550 B buffer (the whole 300-card club) | **3.6 to 3.9 µs** |

A buffer costs about the same as a single number, whatever its size. A table costs roughly a microsecond
per card. That is server time spent on every send, on top of your own scripts.

Ripple is built around that:

- **Schema first.** You describe the state once. Ripple generates a server module and a client module
  that know the exact layout, so values are written straight into a buffer with no type tags or field names.
- **Only changes are sent.** Every struct field has a dirty bit, and maps and arrays remember which keys
  changed. Setting `club.Cash` sends about a dozen bytes. Changing one card's Level sends about 15.
- **One buffer per player per frame.** All changes for a player in a frame go out in one remote call on
  Heartbeat, however many fields or states changed.
- **Encoded once.** A change that several players see is encoded once and copied to each of them. Shared
  state (`Scope: All`) goes out in one `FireAllClients` when nothing private is pending.
- **Plain tables everywhere.** The data you hand Ripple on the server stays a plain table you can save. The
  client gets plain tables too, so reading is just indexing.

## Where it fits

Ripple is one of three libraries built to work together:

| Library | Job |
|---|---|
| [Current](https://acidgorgon.github.io/Current/) | Networking: typed events and functions over buffers, two-way events. |
| **Ripple** | State: server-owned data replicated to clients as deltas. |
| [Anchor](https://acidgorgon.github.io/Anchor/) | Saving: session-locked profiles, safe trades, no dupes. |

Use Current for things that *happen* (a shot, a chat message, a button press). Use Ripple for things that
*are* (cash, inventory, match score). Use Anchor to save the things that are.

## Compared with the usual choices

| | Ripple | ReplicaService / Replica | Charm + charm-sync | Reflex | DataService |
|---|---|---|---|---|---|
| Write syntax | `t.Cash = v` | `replica:SetValue({"Cash"}, v)` | atoms + selectors | actions + reducers | `set(player, path, v)` |
| What is sent | changed fields, in a buffer | the path and value, as tables | diffs, as tables | dispatched actions, as tables | the value at the path, as tables |
| Wire layout from a schema | yes | no | no | no | no |
| Validation on write | yes | no | no | no | no |
| Server-only fields | yes | no | no | no | no |

See [Benchmarks](/benchmarks) for numbers.
