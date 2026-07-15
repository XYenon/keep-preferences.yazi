--- @since 26.1.22

---@alias KeepPreferencesRatio { [1]: integer, [2]: integer, [3]: integer }
---@alias KeepPreferencesSortBy "none"|"mtime"|"btime"|"extension"|"alphabetical"|"natural"|"size"|"random"
---@alias KeepPreferencesField "ratio"|"sort_by"|"sort_sensitive"|"sort_reverse"|"sort_dir_first"|"sort_translit"|"linemode"|"show_hidden"
---@alias KeepPreferencesPref { ratio: KeepPreferencesRatio, sort_by: KeepPreferencesSortBy, sort_sensitive: boolean, sort_reverse: boolean, sort_dir_first: boolean, sort_translit: boolean, linemode: string, show_hidden: boolean }
---@alias KeepPreferencesPrefPatch { ratio?: KeepPreferencesRatio|table, sort_by?: KeepPreferencesSortBy, sort_sensitive?: boolean, sort_reverse?: boolean, sort_dir_first?: boolean, sort_translit?: boolean, linemode?: string, show_hidden?: boolean }
---@alias KeepPreferencesPathPreference { path: string, defaults: KeepPreferencesPrefPatch }
---@alias KeepPreferencesSetupOpts { path_preferences?: KeepPreferencesPathPreference[], sticky?: KeepPreferencesField[] }
---@alias KeepPreferencesSortForm { [1]?: KeepPreferencesSortBy, by?: KeepPreferencesSortBy, sensitive?: boolean, reverse?: boolean, dir_first?: boolean, ["dir-first"]?: boolean, translit?: boolean }
---@alias KeepPreferencesHiddenForm { [1]?: "show"|"hide"|"toggle", state?: "show"|"hide"|"toggle" }

-- Plugin state layout:
--   default: KeepPreferencesPref copied from yazi.toml's [mgr] at setup time.
--   path_preferences: array<{ path: string, defaults: KeepPreferencesPrefPatch }>; path-specific default overrides.
--   sticky:  table<field, true>; fields that keep native Yazi behavior (not restored per directory).
--   tabs:    table<tab-id, table<cwd, KeepPreferencesPref>>; all directory records are tab-local.
--   last:    table<tab-id, cwd>; used to save the directory being left before applying the next one.
--   applying: true while this plugin is restoring state, so restore-triggered sort/hidden events are ignored.
--   restoring: table<tab-id, { cwd: string, pref: KeepPreferencesPref }>; protects restored state from stale hover events.
local STATE = {
	default = "default",
	path_preferences = "path_preferences",
	sticky = "sticky",
	tabs = "tabs",
	last = "last",
	applying = "applying",
	restoring = "restoring",
}

local PLUGIN = "keep-preferences"

---Return a plain 3-item ratio array accepted by `rt.mgr.ratio = ...`.
---Yazi exposes `rt.mgr.ratio` as a named table (`parent/current/preview/all`),
---while the setter expects only parent/current/preview.
---@param ratio table Yazi ratio table or a 3-item ratio array.
---@return KeepPreferencesRatio
local function clone_ratio(ratio)
	return {
		ratio.parent or ratio[1] or 1,
		ratio.current or ratio[2] or 4,
		ratio.preview or ratio[3] or 3,
	}
end

---@param ratio KeepPreferencesRatio|table
---@return string
local function ratio_text(ratio)
	local r = clone_ratio(ratio)
	return string.format("[%s,%s,%s]", r[1], r[2], r[3])
end

---@param pref KeepPreferencesPref
---@return KeepPreferencesPref
local function clone_pref(pref)
	return {
		ratio = clone_ratio(pref.ratio),
		sort_by = pref.sort_by,
		sort_sensitive = pref.sort_sensitive,
		sort_reverse = pref.sort_reverse,
		sort_dir_first = pref.sort_dir_first,
		sort_translit = pref.sort_translit,
		linemode = pref.linemode,
		show_hidden = pref.show_hidden,
	}
end

---@param pref KeepPreferencesPref|KeepPreferencesPrefPatch Preference to update.
---@param patch KeepPreferencesPrefPatch Preference fields to copy.
---@return boolean changed Whether at least one supported field was copied.
local function apply_pref_patch(pref, patch)
	local changed = false
	if type(patch.ratio) == "table" then
		pref.ratio = clone_ratio(patch.ratio)
		changed = true
	end
	if type(patch.sort_by) == "string" then
		pref.sort_by = patch.sort_by
		changed = true
	end
	if type(patch.sort_sensitive) == "boolean" then
		pref.sort_sensitive = patch.sort_sensitive
		changed = true
	end
	if type(patch.sort_reverse) == "boolean" then
		pref.sort_reverse = patch.sort_reverse
		changed = true
	end
	if type(patch.sort_dir_first) == "boolean" then
		pref.sort_dir_first = patch.sort_dir_first
		changed = true
	end
	if type(patch.sort_translit) == "boolean" then
		pref.sort_translit = patch.sort_translit
		changed = true
	end
	if type(patch.linemode) == "string" then
		pref.linemode = patch.linemode
		changed = true
	end
	if type(patch.show_hidden) == "boolean" then
		pref.show_hidden = patch.show_hidden
		changed = true
	end
	return changed
end

---@param a KeepPreferencesPref
---@param b KeepPreferencesPref
---@return boolean
local function same_pref(a, b)
	local ar, br = clone_ratio(a.ratio), clone_ratio(b.ratio)
	return ar[1] == br[1]
		and ar[2] == br[2]
		and ar[3] == br[3]
		and a.sort_by == b.sort_by
		and a.sort_sensitive == b.sort_sensitive
		and a.sort_reverse == b.sort_reverse
		and a.sort_dir_first == b.sort_dir_first
		and a.sort_translit == b.sort_translit
		and a.linemode == b.linemode
		and a.show_hidden == b.show_hidden
end

---@param pref KeepPreferencesPref?
---@return string
local function pref_text(pref)
	if not pref then
		return "nil"
	end
	return string.format(
		"ratio=%s sort=%s sensitive=%s reverse=%s dir_first=%s translit=%s linemode=%s hidden=%s",
		ratio_text(pref.ratio),
		tostring(pref.sort_by),
		tostring(pref.sort_sensitive),
		tostring(pref.sort_reverse),
		tostring(pref.sort_dir_first),
		tostring(pref.sort_translit),
		tostring(pref.linemode),
		tostring(pref.show_hidden)
	)
end

---@param sticky table<string, boolean>
---@return string
local function sticky_text(sticky)
	local names = {}
	for name in pairs(sticky) do
		names[#names + 1] = name
	end
	table.sort(names)
	if #names == 0 then
		return "none"
	end
	return table.concat(names, ",")
end

---Parse `opts.sticky` into a set of preference field names.
---@param list any
---@return table<string, boolean>
local function parse_sticky(list)
	local sticky = {}
	if type(list) ~= "table" then
		return sticky
	end
	for _, name in ipairs(list) do
		if type(name) == "string" then
			sticky[name] = true
		end
	end
	return sticky
end

---Copy sticky fields from `source` into `target` so per-directory restore leaves them alone.
---@param sticky table<string, boolean>
---@param target KeepPreferencesPref
---@param source KeepPreferencesPref
local function keep_sticky_fields(sticky, target, source)
	if sticky.ratio then
		target.ratio = clone_ratio(source.ratio)
	end
	if sticky.sort_by then
		target.sort_by = source.sort_by
	end
	if sticky.sort_sensitive then
		target.sort_sensitive = source.sort_sensitive
	end
	if sticky.sort_reverse then
		target.sort_reverse = source.sort_reverse
	end
	if sticky.sort_dir_first then
		target.sort_dir_first = source.sort_dir_first
	end
	if sticky.sort_translit then
		target.sort_translit = source.sort_translit
	end
	if sticky.linemode then
		target.linemode = source.linemode
	end
	if sticky.show_hidden then
		target.show_hidden = source.show_hidden
	end
end

---Return a stable string key for the active tab.
---Newer Yazi versions expose `cx.active.id`; fall back to `cx.tabs.idx` for compatibility.
---@return string
local function tab_id()
	local id = cx.active.id
	if type(id) == "number" or type(id) == "string" then
		return tostring(id)
	end
	if id and id.value ~= nil then
		return tostring(id.value)
	end
	return tostring(cx.tabs.idx)
end

---Return the active directory key used in the per-tab cache.
---For normal filesystem URLs this uses the path; for virtual URLs it keeps the full URL string.
---@return string
local function cwd_key()
	local url = cx.active.current.cwd
	local is_virtual = Url(url).scheme and Url(url).scheme.is_virtual
	return tostring((is_virtual and url or url.path) or url)
end

---Capture the currently active manager state.
---Must run in a sync context because it reads `cx` and `rt`.
---@return KeepPreferencesPref
local function current_state()
	return {
		ratio = clone_ratio(rt.mgr.ratio),
		sort_by = cx.active.pref.sort_by,
		sort_sensitive = cx.active.pref.sort_sensitive,
		sort_reverse = cx.active.pref.sort_reverse,
		sort_dir_first = cx.active.pref.sort_dir_first,
		sort_translit = cx.active.pref.sort_translit,
		linemode = cx.active.pref.linemode,
		show_hidden = cx.active.pref.show_hidden,
	}
end

---Convert a cached preference into a Yazi `sort` action form.
---When `sticky` is set and `force_all` is false, sticky sort fields are omitted so Yazi keeps
---the current runtime values (native "do not follow directory" behavior).
---@param pref KeepPreferencesPref
---@param sticky? table<string, boolean>
---@param force_all? boolean
---@return KeepPreferencesSortForm form
---@return boolean any Whether the form includes at least one sort field.
local function sort_form(pref, sticky, force_all)
	sticky = sticky or {}
	local form = {}
	local any = false
	local function take(field)
		return force_all or not sticky[field]
	end
	if take("sort_by") then
		form[1] = pref.sort_by
		any = true
	end
	if take("sort_sensitive") then
		form.sensitive = pref.sort_sensitive
		any = true
	end
	if take("sort_reverse") then
		form.reverse = pref.sort_reverse
		any = true
	end
	if take("sort_dir_first") then
		form.dir_first = pref.sort_dir_first
		any = true
	end
	if take("sort_translit") then
		form.translit = pref.sort_translit
		any = true
	end
	return form, any
end

---Convert a cached preference into a Yazi `hidden` action form.
---@param pref KeepPreferencesPref
---@return KeepPreferencesHiddenForm
local function hidden_form(pref)
	return { pref.show_hidden and "show" or "hide" }
end

---@param state table Plugin state provided by `ya.sync`.
---@param id string Tab id.
---@return table<string, KeepPreferencesPref> tab Cache bucket for the tab.
local function ensure_tab(state, id)
	state[STATE.tabs] = state[STATE.tabs] or {}
	state[STATE.tabs][id] = state[STATE.tabs][id] or {}
	return state[STATE.tabs][id]
end

---@param state table Plugin state provided by `ya.sync`.
---@param id string Tab id.
---@param cwd string Directory key.
---@param pref KeepPreferencesPref Preference to cache.
local function cache_pref(state, id, cwd, pref)
	ensure_tab(state, id)[cwd] = pref
	state[STATE.last] = state[STATE.last] or {}
	state[STATE.last][id] = cwd
end

---@param pref KeepPreferencesPref Preference to update.
---@param opt KeepPreferencesSortForm Yazi sort action form.
---@return boolean changed Whether `opt` contained at least one concrete sort field.
local function apply_sort_form(pref, opt)
	local changed = false
	if type(opt[1]) == "string" then
		pref.sort_by = opt[1]
		changed = true
	elseif type(opt.by) == "string" then
		pref.sort_by = opt.by
		changed = true
	end
	if type(opt.sensitive) == "boolean" then
		pref.sort_sensitive = opt.sensitive
		changed = true
	end
	if type(opt.reverse) == "boolean" then
		pref.sort_reverse = opt.reverse
		changed = true
	end
	if type(opt.dir_first) == "boolean" then
		pref.sort_dir_first = opt.dir_first
		changed = true
	elseif type(opt["dir-first"]) == "boolean" then
		pref.sort_dir_first = opt["dir-first"]
		changed = true
	end
	if type(opt.translit) == "boolean" then
		pref.sort_translit = opt.translit
		changed = true
	end
	return changed
end

---@param pref KeepPreferencesPref Preference to update.
---@param opt KeepPreferencesHiddenForm Yazi hidden action form.
---@return string? mode Concrete hidden mode, if present.
local function apply_hidden_form(pref, opt)
	local mode = type(opt[1]) == "string" and opt[1] or opt.state
	if type(mode) ~= "string" then
		return nil
	end
	if mode == "show" then
		pref.show_hidden = true
	elseif mode == "hide" then
		pref.show_hidden = false
	elseif mode == "toggle" then
		pref.show_hidden = not pref.show_hidden
	else
		return nil
	end
	return mode
end

---@param path string Path pattern configured by the user.
---@param cwd string Directory key to test.
---@return boolean matched Whether the path pattern matched the cwd.
local function path_matches(path, cwd)
	local ok, matched = pcall(string.find, cwd, path)
	if not ok then
		ya.dbg(PLUGIN, "invalid path preference pattern", path, tostring(matched))
		return false
	end
	return matched ~= nil
end

---@param state table Plugin state provided by `ya.sync`.
---@param cwd string Directory key.
---@return KeepPreferencesPref pref Default preference with matching path overrides applied.
local function default_for_cwd(state, cwd)
	local pref = clone_pref(state[STATE.default])
	for _, rule in ipairs(state[STATE.path_preferences] or {}) do
		if type(rule.path) == "string" and type(rule.defaults) == "table" and path_matches(rule.path, cwd) then
			apply_pref_patch(pref, rule.defaults)
			ya.dbg(PLUGIN, "path preferences matched", "cwd", cwd, "path", rule.path, "pref", pref_text(pref))
		end
	end
	return pref
end

---Initialize default preferences and cache buckets.
---The default preference is intentionally copied from `rt.mgr`, so unvisited directories
---use the user's yazi.toml defaults instead of inheriting changes from the previous directory.
---Do not touch `cx` here: `setup()` runs while the UI context is not available yet.
---@param opts KeepPreferencesSetupOpts?
local set_defaults = ya.sync(function(state, opts)
	state[STATE.default] = {
		ratio = clone_ratio(rt.mgr.ratio),
		sort_by = rt.mgr.sort_by,
		sort_sensitive = rt.mgr.sort_sensitive,
		sort_reverse = rt.mgr.sort_reverse,
		sort_dir_first = rt.mgr.sort_dir_first,
		sort_translit = rt.mgr.sort_translit,
		linemode = rt.mgr.linemode,
		show_hidden = rt.mgr.show_hidden,
	}
	state[STATE.path_preferences] = type(opts) == "table"
			and type(opts.path_preferences) == "table"
			and opts.path_preferences
		or {}
	state[STATE.sticky] = type(opts) == "table" and parse_sticky(opts.sticky) or {}
	state[STATE.tabs] = state[STATE.tabs] or {}
	state[STATE.last] = state[STATE.last] or {}
	state[STATE.restoring] = state[STATE.restoring] or {}
	ya.dbg(
		PLUGIN,
		"setup defaults",
		pref_text(state[STATE.default]),
		"path preferences",
		tostring(#state[STATE.path_preferences]),
		"sticky",
		sticky_text(state[STATE.sticky])
	)
end)

---Save the active directory's current preference into the current tab's cache.
local remember_current = ya.sync(function(state)
	local id = tab_id()
	local cwd = cwd_key()
	local pref = current_state()
	state[STATE.restoring] = state[STATE.restoring] or {}
	local restoring = state[STATE.restoring][id]
	if restoring and restoring.cwd == cwd then
		if same_pref(pref, restoring.pref) then
			ya.dbg(PLUGIN, "restore settled", "tab", id, "cwd", cwd, pref_text(pref))
			state[STATE.restoring][id] = nil
		else
			ya.dbg(
				PLUGIN,
				"ignore stale passive state during restore",
				"tab",
				id,
				"cwd",
				cwd,
				"current",
				pref_text(pref),
				"expected",
				pref_text(restoring.pref)
			)
			return
		end
	end

	cache_pref(state, id, cwd, pref)
	ya.dbg(PLUGIN, "remember current", "tab", id, "cwd", cwd, pref_text(pref))
end)

---Return whether this tab has already gone through the plugin's restore path.
---A newly-created Yazi tab can inherit the previous tab's runtime preferences before this plugin
---sees it. Until `last[id]` is set, do not save the current values, because they may be inherited
---rather than the yazi.toml defaults expected for a fresh tab.
---@return boolean
local is_tab_initialized = ya.sync(function(state)
	state[STATE.last] = state[STATE.last] or {}
	local id = tab_id()
	local initialized = state[STATE.last][id] ~= nil
	ya.dbg(PLUGIN, "tab initialized?", "tab", id, tostring(initialized))
	return initialized
end)

---Update the cache when Yazi is about to run a `sort` action.
---This receives both key-triggered and plugin-triggered sort forms. Missing fields mean
---"keep the existing value", matching Yazi's own sort action semantics.
---@param state table Plugin state provided by `ya.sync`.
---@param opt KeepPreferencesSortForm Yazi sort action form.
---@return KeepPreferencesSortForm opt The same form, so the original action continues.
local remember_sort = ya.sync(function(state, opt)
	if state[STATE.applying] then
		ya.dbg(PLUGIN, "ignore sort while applying")
		return opt
	end

	local id = tab_id()
	local cwd = cwd_key()
	state[STATE.last] = state[STATE.last] or {}
	if not state[STATE.last][id] then
		ya.dbg(PLUGIN, "ignore sort before tab init", "tab", id, "cwd", cwd)
		return opt
	end

	local pref = current_state()
	if not apply_sort_form(pref, opt) then
		ya.dbg(PLUGIN, "ignore sort without concrete fields", "tab", id, "cwd", cwd)
		return opt
	end

	cache_pref(state, id, cwd, pref)
	ya.dbg(PLUGIN, "remember sort", "tab", id, "cwd", cwd, "form", tostring(opt[1] or opt.by), "pref", pref_text(pref))
	return opt
end)

---Update the cache when Yazi is about to run a `hidden` action.
---The action can be `show`, `hide`, or `toggle`; this function stores the resulting boolean.
---@param state table Plugin state provided by `ya.sync`.
---@param opt KeepPreferencesHiddenForm Yazi hidden action form.
---@return KeepPreferencesHiddenForm opt The same form, so the original action continues.
local remember_hidden = ya.sync(function(state, opt)
	if state[STATE.applying] then
		ya.dbg(PLUGIN, "ignore hidden while applying")
		return opt
	end

	local id = tab_id()
	local cwd = cwd_key()
	state[STATE.last] = state[STATE.last] or {}
	if not state[STATE.last][id] then
		ya.dbg(PLUGIN, "ignore hidden before tab init", "tab", id, "cwd", cwd)
		return opt
	end

	local pref = current_state()
	local mode = apply_hidden_form(pref, opt)
	if not mode then
		ya.dbg(PLUGIN, "ignore hidden without concrete mode", "tab", id, "cwd", cwd)
		return opt
	end

	cache_pref(state, id, cwd, pref)
	ya.dbg(PLUGIN, "remember hidden", "tab", id, "cwd", cwd, "mode", tostring(mode), "pref", pref_text(pref))
	return opt
end)

---Return the preference that should apply to the active directory.
---Before doing so, persist the directory that the tab just left. This is what makes
---navigation automatically record changes without requiring a manual save key.
---@param state table Plugin state provided by `ya.sync`.
---@return KeepPreferencesPref? pref Cached directory preference, or the setup-time default preference.
---@return boolean first_for_tab Whether this is the first restore for the active tab.
local pref_for_current = ya.sync(function(state)
	state[STATE.tabs] = state[STATE.tabs] or {}
	state[STATE.last] = state[STATE.last] or {}

	local id = tab_id()
	local cwd = cwd_key()
	local first_for_tab = state[STATE.last][id] == nil
	local last = state[STATE.last][id]
	if last and last ~= cwd then
		local pref = current_state()
		ensure_tab(state, id)[last] = pref
		ya.dbg(PLUGIN, "remember leaving cwd", "tab", id, "cwd", last, pref_text(pref))
	end
	state[STATE.last][id] = cwd

	local tabs = state[STATE.tabs][id]
	local pref = tabs and tabs[cwd]
	if pref then
		ya.dbg(PLUGIN, "cache hit", "tab", id, "cwd", cwd, pref_text(pref))
		return pref, first_for_tab
	end

	local default = default_for_cwd(state, cwd)
	ya.dbg(PLUGIN, "cache miss, use defaults", "tab", id, "cwd", cwd, pref_text(default))
	return default, first_for_tab
end)

---Apply a cached preference to the active tab/directory.
---`ratio` is global in Yazi, so restoring it affects the process layout; the plugin reapplies
---the active tab's recorded value whenever the tab enters a directory (unless `ratio` is sticky).
---Sticky fields keep Yazi's native behavior: they are not rewritten on directory changes.
---They are still applied once when a tab is first seen, so a new tab starts from yazi.toml defaults
---instead of inheriting the previous tab's runtime values.
---@param state table Plugin state provided by `ya.sync`.
---@param pref KeepPreferencesPref? Preference to apply; `nil` is ignored.
---@param first_for_tab? boolean Whether this is the first restore for the active tab.
local apply_pref = ya.sync(function(state, pref, first_for_tab)
	if not pref then
		ya.dbg(PLUGIN, "apply skipped", "pref=nil")
		return
	end

	local id = tab_id()
	local cwd = cwd_key()
	local sticky = state[STATE.sticky] or {}
	local force_all = first_for_tab
	local restored = clone_pref(pref)
	if not force_all then
		keep_sticky_fields(sticky, restored, current_state())
	end

	ya.dbg(PLUGIN, "apply", pref_text(restored), "force_all", tostring(force_all), "sticky", sticky_text(sticky))
	ensure_tab(state, id)[cwd] = restored
	state[STATE.restoring] = state[STATE.restoring] or {}
	state[STATE.restoring][id] = { cwd = cwd, pref = clone_pref(restored) }
	ya.dbg(PLUGIN, "protect restoring pref", "tab", id, "cwd", cwd, pref_text(restored))

	state[STATE.applying] = true
	if force_all or not sticky.ratio then
		rt.mgr.ratio = clone_ratio(restored.ratio)
	end
	local form, any_sort = sort_form(restored, sticky, force_all)
	if any_sort then
		ya.emit("sort", form)
	end
	if force_all or not sticky.show_hidden then
		ya.emit("hidden", hidden_form(restored))
	end
	if force_all or not sticky.linemode then
		ya.emit("linemode", { restored.linemode })
	end
	if force_all or not sticky.ratio then
		ya.emit("app:resize", {})
	end
	state[STATE.applying] = false
end)

---Restore the active directory from the current tab's cache, falling back to yazi.toml defaults.
local function restore_current()
	ya.dbg(PLUGIN, "restore current requested")
	local pref, first_for_tab = pref_for_current()
	apply_pref(pref, first_for_tab)
end

---On passive events, save only initialized tabs. For a fresh tab, restore first so inherited
---preferences from the previous active tab are replaced by the configured defaults.
local function remember_or_restore_current()
	if is_tab_initialized() then
		ya.dbg(PLUGIN, "passive event -> remember")
		remember_current()
	else
		ya.dbg(PLUGIN, "passive event -> restore first")
		restore_current()
	end
end

local M = {}

---@param opts KeepPreferencesSetupOpts?
function M:setup(opts)
	ya.dbg(PLUGIN, "setup")
	set_defaults(opts)

	-- Directory changes are the main restore point. `pref_for_current()` records the directory
	-- being left before returning the preference for the newly active directory.
	ps.sub("cd", function()
		ya.dbg(PLUGIN, "event", "cd")
		restore_current()
	end)

	-- Tab switches/creates can expose a tab before any directory change occurs. Restore here so
	-- a newly-created tab starts from yazi.toml defaults instead of inheriting the previous tab.
	ps.sub("tab", function()
		ya.dbg(PLUGIN, "event", "tab")
		restore_current()
	end)

	-- If a directory finishes loading after the cd event, restore again so sorting/hidden state
	-- is applied to the loaded folder contents.
	ps.sub("load", function(body)
		ya.dbg(PLUGIN, "event", "load", "url", tostring(body.url), "stage", tostring(body.stage and body.stage()))
		if body.stage and body.stage() and cwd_key() == tostring(body.url) then
			restore_current()
		else
			ya.dbg(PLUGIN, "load ignored", "cwd", cwd_key())
		end
	end)

	-- Hover is a cheap frequent event that lets us capture ratio/linemode changes because Yazi
	-- currently has no dedicated hooks for those actions.
	ps.sub("hover", function()
		ya.dbg(PLUGIN, "event", "hover")
		remember_or_restore_current()
	end)

	-- Sort and hidden have built-in preflight hooks. We update the cache before the original
	-- action runs and return the unmodified form so Yazi continues normally.
	ps.sub("key-sort", remember_sort)
	ps.sub("ind-sort", remember_sort)
	ps.sub("key-hidden", remember_hidden)
	ps.sub("ind-hidden", remember_hidden)
end

return M
