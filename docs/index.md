---
layout: home

hero:
  name: Ripple
  text: State that syncs itself
  tagline: Describe your state once, write plain tables on the server, and Ripple sends only what changed, packed into buffers, to every client that should see it.
  image:
    src: /family/ripple.svg
    alt: Ripple
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Benchmarks
      link: /benchmarks
    - theme: alt
      text: GitHub
      link: https://github.com/Acidgorgon/Ripple

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>
    title: Just write to tables
    details: "club.Cash += 250 is the whole API for changes. Every write is checked against your schema, and only the fields that changed are sent: about a dozen bytes for a Cash change."
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2 4 14h7l-1 8 9-12h-7z"/></svg>
    title: Buffers, encoded once
    details: Roblox spends ~300 µs serializing a 300-card table per FireClient; a Ripple buffer costs ~3 µs at any size. Each change is encoded once, however many players see it.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>
    title: Secure by default
    details: Server authoritative. Types, ranges, NaN and unknown fields are rejected on write, and server-only fields never leave the server.
---

::: tip Made with Claude
Most of Ripple was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.
:::

## Install

::: code-group

```sh [rokit]
rokit add Acidgorgon/Ripple
```

```sh [generate]
ripple game.ripple --out src/shared/Ripple --watch
```

```ripple [game.ripple]
state Club {
	Scope: Player,
	Data: struct {
		Cash: f64(0..),
		Owned: map { [string]: struct { CardId: u16, Level: u8(1..99) } },
	},
}
```

:::

Then `Ripple.Club.new(player, profile.Data)` on the server and `Ripple.Club.wait()` on the client.
[Getting started](/guide/getting-started) walks through it.
