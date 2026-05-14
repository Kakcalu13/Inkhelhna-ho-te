extends Node

# Autoload — at game start, scans narrative/conversations/conversation_*.json
# files and groups them by GENDER PAIR + LANGUAGE.
#
# Filename convention: conversation_<gender_a>_<gender_b>[_<tag>].json
#   conversation_female_male.json           -> language "english" (default)
#   conversation_female_male_mz.json        -> language "mizo"
#   conversation_female_male_mixed.json     -> language "mixed"   (regular + golden)
#   conversation_female_male_wedding.json   -> language "english" (unknown tag falls back)
#
# Each JSON has:
#   { "lines": { "1": [ {speaker, text}, ... ], "2": [ ... ], ... } }
# We flatten each numbered key into one selectable conversation in the pool.

const CONV_DIR: String = "res://narrative/conversations/"

const LANG_ENGLISH: String = "english"
const LANG_MIZO: String = "mizo"
const LANG_MIXED: String = "mixed"

# Catch-all key used when a JSON's filename starts with "conversation_human_"
# — those files are gender-agnostic Human↔Golden cross-language scripts and
# get returned for any gender pair when language == "mixed".
const KEY_MIXED_ANY: String = "mixed__any"

# "<language>__<sorted_gender_pair>" -> Array of conversation arrays
var _pools: Dictionary = {}


func _ready() -> void:
	_load_all()


func _pair_key(g1: String, g2: String) -> String:
	if g1 <= g2:
		return "%s_%s" % [g1, g2]
	return "%s_%s" % [g2, g1]


func _pool_key(language: String, g1: String, g2: String) -> String:
	return "%s__%s" % [language, _pair_key(g1, g2)]


func _detect_language(parts: PackedStringArray) -> String:
	# parts is the filename split, after stripping "conversation_". The first
	# two are the gender pair; if any LATER token is "mz" we route to mizo,
	# "mixed" routes to the cross-language pool, anything else stays english.
	for i in range(2, parts.size()):
		var token: String = parts[i].to_lower()
		if token == "mz":
			return LANG_MIZO
		if token == "mixed":
			return LANG_MIXED
	return LANG_ENGLISH


func _load_all() -> void:
	var dir: DirAccess = DirAccess.open(CONV_DIR)
	if dir == null:
		push_warning("ConversationManager: cannot open %s" % CONV_DIR)
		return
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if not dir.current_is_dir() \
				and f.to_lower().ends_with(".json") \
				and f.begins_with("conversation_"):
			_load_file(CONV_DIR + f)
		f = dir.get_next()
	dir.list_dir_end()

	var summary: PackedStringArray = []
	for k in _pools.keys():
		summary.append("%s(%d)" % [k, _pools[k].size()])
	print("ConversationManager: pools = ", summary)


func _load_file(path: String) -> void:
	var raw: String = FileAccess.get_file_as_string(path)
	if raw == "":
		push_warning("ConversationManager: empty %s" % path)
		return

	var data: Variant = JSON.parse_string(raw)
	if not (data is Dictionary) or not data.has("lines"):
		push_warning("ConversationManager: bad JSON %s" % path)
		return

	var fname: String = path.get_file().get_basename()
	var rest: String = fname.replace("conversation_", "")
	var parts: PackedStringArray = rest.split("_", false)
	if parts.size() < 2:
		return

	# Special case: conversation_human_<anything>.json is a gender-agnostic
	# cross-language Human↔Golden pool. The trailing tag (mz / mixed / etc)
	# is informational — we always route to the catch-all "mixed__any" key.
	var key: String
	if parts[0].to_lower() == "human":
		key = KEY_MIXED_ANY
	else:
		var language: String = _detect_language(parts)
		key = _pool_key(language, parts[0], parts[1])

	if not _pools.has(key):
		_pools[key] = []

	var lines: Variant = data["lines"]
	if lines is Dictionary:
		var sorted_keys: Array = lines.keys()
		sorted_keys.sort()
		for k in sorted_keys:
			var arr: Variant = lines[k]
			if arr is Array and not arr.is_empty():
				_pools[key].append(arr)


# pick_random(gender_a, gender_b, language)
# Returns a randomly chosen conversation (Array of {speaker, text} dicts) for
# the given gender pair + language pool, or [] if none are registered.
# When language == "mixed" and there's no gender-specific pool, falls back to
# the gender-agnostic "mixed__any" pool (conversation_human_*.json files).
func pick_random(gender_a: String, gender_b: String, language: String = LANG_ENGLISH) -> Array:
	var key: String = _pool_key(language, gender_a, gender_b)
	var pool: Array = _pools.get(key, [])
	if pool.is_empty() and language == LANG_MIXED:
		pool = _pools.get(KEY_MIXED_ANY, [])
	if pool.is_empty():
		return []
	return pool[randi() % pool.size()]


func has_pool(gender_a: String, gender_b: String, language: String = LANG_ENGLISH) -> bool:
	return _pools.has(_pool_key(language, gender_a, gender_b))
