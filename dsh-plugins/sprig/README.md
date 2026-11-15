# dsh-plugin-sprig

DSH client plugin that turns selected conversation text into a [Sprig](https://github.com/thatwzzh/sprig) explanation card.

Select text in a DSH conversation → the native quote bar becomes **Copy / Quote / Explain with Sprig**.

## Install

```bash
dsh plugin add dsh-plugin-sprig
```

Or from DSH settings → **Plugins → Add plugin** and paste `dsh-plugin-sprig`.

Then make sure **Sprig is running** and **cross-app selection is enabled** in Sprig's settings, and refresh the DSH page (or start a new session).

## What it does

- Reuses DSH's own `quote` surface (same key, lower priority) instead of adding a second right-click menu that duplicates the native Copy.
- Sends at most **one real user/assistant message either side** of the selection — `<system-reminder>`, `available_skills`, and context nodes are filtered out, capped at 1800 characters.
- Delivers the payload to a **running Sprig** over the local bridge on `127.0.0.1:53917`. Sprig creates the card and explains.
- Sprig carries the source with the explanation, so a selection inside a DSH answer still knows which conversation it came from.

## Requirements

- Sprig running on the same machine, with **cross-app selection** enabled.
- DSH **Web UI**. The terminal/CLI does not work — there is no browser surface to hook into.

## Limitations

- The plugin hooks DSH's internal quote surface. A major DSH upgrade may change that surface and require an update here.
- The bridge listens on loopback only, has no token, and can only create explanation cards. It never reads local data.
- Request logs go to `/tmp/sprig-bridge.log`.

## Links

- Repo: [thatwzzh/sprig](https://github.com/thatwzzh/sprig) · plugin source at [`dsh-plugins/sprig`](https://github.com/thatwzzh/sprig/tree/main/dsh-plugins/sprig)
- Sprig site: [sprig-site.app.workbuddy.host](https://sprig-site.app.workbuddy.host/?sharecode=HVF3SOVDGG)

## License

MIT
