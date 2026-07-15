# keep-preferences.yazi

Keep Yazi manager preferences per tab and per directory.

Requires Yazi 26.1.22 or newer.

When you enter a directory for the first time in the current tab, the plugin restores the defaults from `[mgr]` in `yazi.toml`. When you enter a directory that has already been seen in that tab, the plugin restores the previously recorded state for that directory.

Tracked state:

- `ratio`
- `sort_by`
- `sort_sensitive`
- `sort_reverse`
- `sort_dir_first`
- `sort_translit`
- `linemode`
- `show_hidden`

Records are tab-local, so the same directory can keep different manager state in different tabs.

## Installation

Install with Yazi's package manager:

```bash
ya pkg add XYenon/keep-preferences
```

This clones the repository, adds it to `~/.config/yazi/package.toml`, and pins the current revision.

## Usage

Enable the plugin from `~/.config/yazi/init.lua`:

```lua
require("keep-preferences"):setup()
```

### Path-specific defaults

You can override the defaults used for unvisited directories by matching the directory path:

```lua
require("keep-preferences"):setup({
	path_preferences = {
		{
			path = "^/Users/me/Downloads",
			defaults = {
				sort_by = "mtime",
				sort_reverse = true,
				show_hidden = true,
			},
		},
		{
			path = "^/Users/me/Pictures",
			defaults = {
				linemode = "size",
				ratio = { 1, 3, 4 },
			},
		},
	},
})
```

Path rules use Lua patterns and are applied on top of the global `[mgr]` defaults in order. If multiple rules match, later array entries override earlier ones. Once a directory has been visited in a tab, its recorded preferences take precedence over these path preferences.

### Sticky fields (native behavior)

By default every tracked field is restored per directory. To keep Yazi's native behavior for specific fields — they stay as you left them and do **not** change when you enter another directory — list them in `sticky`. Any tracked field can be sticky:

```lua
require("keep-preferences"):setup({
	sticky = { "show_hidden", "linemode" },
})
```

Sticky fields are still initialized once when a tab is first created (from `[mgr]` / path defaults), so a new tab does not inherit the previous tab's runtime values. After that, changing directory no longer rewrites those fields; only your own actions (for example toggling hidden files) update them.

## Notes

- `ratio` is global in Yazi, not tab-local. This plugin reapplies the active tab's recorded ratio whenever it restores a directory.
- Yazi does not currently provide `linemode`/`ratio` change hooks. Changes to those values are captured on the next observed event such as hover or directory change.

## Development

This repository uses [treefmt](https://github.com/numtide/treefmt) for formatting:

```bash
nix fmt
```

Feel free to open a PR to add more features or support additional editors.

### Implementation pitfalls

These are Yazi runtime details that shaped the implementation:

- `setup()` runs before `cx` is available. Only read `rt.mgr` defaults there; defer active tab/CWD access until events such as `cd`, `tab`, `load`, or `hover`.
- New tabs can inherit the previously active tab's runtime preferences before plugin events run. Do not save state for a tab until it has gone through the plugin's restore path.
- Yazi may fire internal `sort` preflight hooks with omitted fields. Only persist sort fields whose values are concrete Lua strings/booleans, otherwise `ya.emit("sort", ...)` can later fail on non-concrete values such as light userdata.
- `sort_by = "none"` is a valid concrete sort mode, and `linemode = "none"` is a valid concrete linemode. Do not treat these values as omitted fields.
- `hidden` preflight hooks can carry `state = "none"`, which means "leave the current hidden state unchanged". Do not cache it as a user preference change; only `show`, `hide`, and `toggle` are concrete hidden actions.
- Navigation can trigger internal sort hooks before the `cd` event for the destination directory. Sort hooks with no concrete changed fields must be ignored, or they can accidentally cache the source directory's state for the destination.
- `ya.emit("hidden", ...)` is not immediately reflected in `cx.active.pref.show_hidden`. A `hover` event right after restore may still see stale state, so the plugin protects the expected restored preference until the runtime state settles.
- Sticky fields must be merged from the current runtime into the protected restore preference. Otherwise a skipped sticky field can disagree with the cache/default snapshot and the hover guard will treat later passive events as stale forever.
- Sticky fields are still force-applied on a tab's first restore so a new tab starts from configured defaults instead of inheriting the previous tab.
- `key-sort`/`ind-sort` and `key-hidden`/`ind-hidden` are preflight hooks. Always return the original form when not cancelling, so Yazi can continue the original action.
