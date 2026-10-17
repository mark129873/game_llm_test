extends Control
## A standalone, single-turn demo. All llama.cpp work happens in QwenRunner's worker.

const MODEL_FILENAME := "Qwen3.5-0.8B-Q4_0.gguf"
const MODEL_OPTIONS := [
	{"label": "Qwen3.5-0.8B · Q4_0", "files": [MODEL_FILENAME, "Qwen3.5-0.8B-Q4_0_un.gguf"]},
	{"label": "Ternary Bonsai 2 · 2B · Q2_0", "files": ["Ternary-Bonsai-2-2B-Q2_0.gguf"]},
]
const BUNDLED_MODEL_PATH := "res://models/" + MODEL_FILENAME
const CACHED_MODEL_PATH := "user://models/" + MODEL_FILENAME
const EMPTY_METRICS := "CPU 生成速度：—"
const COPY_CHUNK_BYTES := 1024 * 1024
const MAX_PROMPT_CHARACTERS := 4096
const REQUIRED_METHODS := ["load_model", "generate", "cancel", "unload_model", "poll_events", "get_state"]

# Disabled by the headless UI test; normal scene startup loads the fixed model.
@export var auto_load_model := true
@onready var _model_selector: OptionButton = %ModelSelector
@onready var _load_button: Button = %LoadModel
@onready var _metrics: Label = %Metrics
@onready var _model_info: Label = %Model
@onready var _status_label: Label = %Status
@onready var _prompt_edit: TextEdit = %Prompt
@onready var _output: RichTextLabel = %Reply
@onready var _output_hint: Label = %ReplyHint
@onready var _send_button: Button = %Send
@onready var _cancel_button: Button = %Cancel
@onready var _safe_margin: MarginContainer = %SafeMargin

var _selected_model := 0
var _switching := false
var _unload_confirmed := false
var _runner: Object
var _state := "unavailable"
var _copying := false
var _copy_cancelled := false
var _cancel_pending := false
var _request_pending := false
var _copy_progress := 0
var _last_error := ""
var _reply := ""
var _generation_started_msec := 0


func _ready() -> void:
	print("[QwenDemo] Main scene ready")
	for model: Dictionary in MODEL_OPTIONS:
		_model_selector.add_item(model.label)
	_model_selector.select(0)
	_model_selector.item_selected.connect(_on_model_selected)
	_load_button.pressed.connect(_load_selected_model)
	_update_model_info()
	_metrics.text = EMPTY_METRICS
	_send_button.pressed.connect(_on_send_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_prompt_edit.text_changed.connect(_refresh_controls)
	_prompt_edit.gui_input.connect(_on_prompt_gui_input)
	_create_native_runner()
	_refresh_controls()
	if auto_load_model and is_instance_valid(_runner):
		_load_selected_model.call_deferred()


func _create_native_runner() -> void:
	if not ClassDB.class_exists("QwenRunner"):
		_show_error("未检测到 QwenRunner 原生扩展。请按 README 编译并安装对应平台的 GDExtension。")
		return
	_runner = ClassDB.instantiate("QwenRunner")
	if not is_instance_valid(_runner):
		_show_error("QwenRunner 创建失败，请检查原生扩展与 Godot 版本。")
		return
	for method: String in REQUIRED_METHODS:
		if not _runner.has_method(method):
			_runner = null
			_show_error("原生扩展接口不完整：缺少 %s。" % method)
			return
	_state = str(_runner.call("get_state"))


func _process(_delta: float) -> void:
	if is_instance_valid(_runner):
		var events: Variant = _runner.call("poll_events")
		if events is Array:
			for event: Variant in events:
				if event is Dictionary:
					_handle_event(event)
		_state = str(_runner.call("get_state"))
	_refresh_controls()
	_update_safe_area()


func _handle_event(event: Dictionary) -> void:
	match str(event.get("type", "")):
		"state":
			_state = str(event.get("text", _state))
			print("[QwenDemo] Model state: ", _state)
			if _state == "unloaded":
				_unload_confirmed = true
			if _state in ["ready", "unloaded", "error"]:
				_request_pending = false
				if not _switching:
					_cancel_pending = false
		"token":
			var token := str(event.get("text", ""))
			_reply += token
		"done":
			var was_cancelled := _cancel_pending or bool(event.get("cancelled", false))
			_cancel_pending = false
			_request_pending = false
			var elapsed := float(Time.get_ticks_msec() - _generation_started_msec) / 1000.0
			if was_cancelled:
				_reply = ""
				_output.clear()
				_metrics.text = EMPTY_METRICS
				_output_hint.text = "已取消"
			else:
				_output.text = _reply
				_output_hint.text = "生成完成 · %.1f 秒" % elapsed
				_metrics.text = EMPTY_METRICS
				var tokens := int(event.get("decode_tokens", 0))
				var decode_ms := float(event.get("decode_ms", 0.0))
				if _last_error.is_empty() and tokens > 0 and decode_ms > 0.0 and is_finite(decode_ms):
					_metrics.text = "CPU 生成速度：%.1f token/s · 输出 %d tokens" % [tokens * 1000.0 / decode_ms, int(event.get("output_tokens", 0))]
		"error":
			_metrics.text = EMPTY_METRICS
			_reply = ""
			_output.clear()
			_last_error = str(event.get("text", "未知原生错误"))
			printerr("[QwenDemo] ", _last_error)
			_cancel_pending = false
			_request_pending = false
			_output_hint.text = "发生错误 · 请查看上方状态"


func _update_model_info() -> void:
	_model_info.text = "CPU · 单轮问答 · 最多输出 192 tokens\n手动放入 models/" + " 或 ".join(MODEL_OPTIONS[_selected_model].files)


func _on_model_selected(index: int) -> void:
	if _is_busy() or index < 0 or index >= MODEL_OPTIONS.size():
		_model_selector.select(_selected_model)
		return
	_selected_model = index
	_update_model_info()
	await _load_selected_model()


func _find_model_path(index: int, directory: String) -> String:
	for filename: String in MODEL_OPTIONS[index].files:
		var path := directory.path_join(filename)
		if FileAccess.file_exists(path):
			return path
	# Some exported Qwen copies append conversion/build suffixes around _un.
	if index == 0:
		var aliases: Array[String] = []
		for filename: String in DirAccess.get_files_at(directory):
			if filename.begins_with("Qwen3.5-0.8B-Q4_0") and filename.ends_with(".gguf") and filename.trim_prefix("Qwen3.5-0.8B-Q4_0").contains("_un"):
				aliases.append(filename)
		aliases.sort()
		if aliases.size() == 1:
			return directory.path_join(aliases[0])
		if aliases.size() > 1:
			_show_error("发现多个 Qwen _un 文件，请仅保留一个，或将所选文件命名为 %s。" % MODEL_FILENAME)
	return ""


func _load_selected_model() -> void:
	if _is_busy() or not is_instance_valid(_runner):
		return
	# Drain old events, then wait for explicit release completion before any copy/load.
	for event: Variant in _runner.call("poll_events"):
		if event is Dictionary:
			_handle_event(event)
	_metrics.text = EMPTY_METRICS
	_reply = ""
	_output.clear()
	_last_error = ""
	_cancel_pending = false
	_copy_cancelled = false
	_switching = true
	_unload_confirmed = false
	_runner.call("unload_model")
	_refresh_controls()
	while not _unload_confirmed:
		await get_tree().process_frame
	_switching = false
	if _cancel_pending:
		_cancel_pending = false
		_output_hint.text = "已取消模型加载，可点击加载重试。"
		_refresh_controls()
		return
	var source := _find_model_path(_selected_model, "res://models")
	if not _last_error.is_empty():
		return
	var model_path := _find_model_path(_selected_model, "user://models")
	if not _last_error.is_empty():
		return
	if model_path.is_empty() and not source.is_empty():
		model_path = await _copy_bundled_model(source, "user://models/" + source.get_file())
		if model_path.is_empty():
			_refresh_controls()
			return
	if model_path.is_empty():
		_show_error("未找到 %s。请放入 models/ 中列出的文件；本 Demo 不下载模型。" % MODEL_OPTIONS[_selected_model].label)
		return
	_request_pending = true
	if not bool(_runner.call("load_model", ProjectSettings.globalize_path(model_path))):
		_request_pending = false
		_show_error("无法启动模型加载，可点击加载重试。")
	else:
		_state = "loading"
		_output_hint.text = "正在加载所选模型…"
	_refresh_controls()


func _copy_bundled_model(source_path: String = BUNDLED_MODEL_PATH, target_path: String = CACHED_MODEL_PATH) -> String:
	_copying = true
	_copy_cancelled = false
	_copy_progress = 0
	var partial_path := target_path + ".part"
	var mkdir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target_path.get_base_dir()))
	if mkdir_error != OK:
		return _copy_failed("无法创建模型缓存目录：%s。" % error_string(mkdir_error), partial_path)
	var source := FileAccess.open(source_path, FileAccess.READ)
	if source == null or source.get_length() == 0:
		return _copy_failed("模型文件为空或无法读取。", partial_path)
	var destination := FileAccess.open(partial_path, FileAccess.WRITE)
	if destination == null:
		source.close()
		return _copy_failed("无法写入模型缓存，请检查存储空间。", partial_path)
	var total_bytes := source.get_length()
	var copied_bytes := 0
	while copied_bytes < total_bytes and not _copy_cancelled:
		var buffer := source.get_buffer(mini(COPY_CHUNK_BYTES, total_bytes - copied_bytes))
		if buffer.is_empty():
			source.close()
			destination.close()
			return _copy_failed("模型复制中断：读取失败。", partial_path)
		destination.store_buffer(buffer)
		if destination.get_error() != OK:
			source.close()
			destination.close()
			return _copy_failed("模型复制失败，请检查存储空间。", partial_path)
		copied_bytes += buffer.size()
		_copy_progress = int(100.0 * copied_bytes / total_bytes)
		await get_tree().process_frame
	source.close()
	destination.flush()
	var write_error := destination.get_error()
	destination.close()
	if _copy_cancelled:
		_copying = false
		_copy_cancelled = false
		DirAccess.remove_absolute(ProjectSettings.globalize_path(partial_path))
		_output_hint.text = "已取消模型复制，可点击加载重试。"
		return ""
	if write_error != OK or copied_bytes != total_bytes:
		return _copy_failed("模型未完整写入，请检查存储空间。", partial_path)
	var move_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(partial_path), ProjectSettings.globalize_path(target_path))
	if move_error != OK:
		return _copy_failed("无法保存已复制模型：%s。" % error_string(move_error), partial_path)
	_copying = false
	return target_path


func _copy_failed(message: String, partial_path: String) -> String:
	_copying = false
	if FileAccess.file_exists(partial_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(partial_path))
	_show_error(message)
	return ""


func _on_send_pressed() -> void:
	if not is_instance_valid(_runner) or _state != "ready" or _is_busy():
		return
	var prompt := _prompt_edit.text.strip_edges()
	if prompt.is_empty():
		return
	if prompt.length() > MAX_PROMPT_CHARACTERS:
		_show_error("本演示每次最多输入 %d 个字符，请缩短问题。" % MAX_PROMPT_CHARACTERS)
		return
	# Drain previous completion events before starting a new single-turn reply.
	for event: Variant in _runner.call("poll_events"):
		if event is Dictionary:
			_handle_event(event)
	_last_error = ""
	_reply = ""
	_output.clear()
	_metrics.text = EMPTY_METRICS
	_copy_cancelled = false
	_generation_started_msec = Time.get_ticks_msec()
	_request_pending = true
	if not bool(_runner.call("generate", prompt)):
		_request_pending = false
		_show_error("无法启动生成，请查看原生错误信息。")
		return
	_state = "generating"
	_output_hint.text = "正在本机生成 · 可以随时取消"
	_prompt_edit.release_focus()
	DisplayServer.virtual_keyboard_hide()
	_refresh_controls()


func _on_cancel_pressed() -> void:
	_metrics.text = EMPTY_METRICS
	if _copying:
		_copy_cancelled = true
	elif is_instance_valid(_runner) and _is_busy() and not _cancel_pending:
		_cancel_pending = true
		_runner.call("cancel")
	_refresh_controls()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		# Do not intentionally continue generation after iOS suspends the app.
		if _is_busy():
			_on_cancel_pressed()


func _exit_tree() -> void:
	_copy_cancelled = true
	if is_instance_valid(_runner):
		_runner.call("cancel")
	# Native RefCounted destruction joins its worker and releases llama.cpp memory.
	_runner = null


func _is_busy() -> bool:
	return _switching or _copying or _request_pending or _state in ["loading", "generating"]


func _show_error(message: String) -> void:
	printerr("[QwenDemo] ", message)
	if is_instance_valid(_metrics):
		_metrics.text = EMPTY_METRICS
	_last_error = message
	_refresh_controls()


func _refresh_controls() -> void:
	if not is_instance_valid(_send_button):
		return
	var available := is_instance_valid(_runner)
	var busy := _is_busy()
	_send_button.disabled = not available or busy or _state != "ready" or _prompt_edit.text.strip_edges().is_empty()
	_cancel_button.disabled = not available or not busy or _cancel_pending or _copy_cancelled
	_prompt_edit.editable = not busy
	_model_selector.disabled = not available or busy
	_load_button.disabled = not available or busy
	var state_labels := {"unavailable": "原生推理扩展未安装", "unloaded": "尚未加载模型", "loading": "正在后台加载模型…", "ready": "模型已就绪 · 可以开始对话", "generating": "正在生成…", "error": "加载或推理失败，可点击加载重试"}
	var status_text := str(state_labels.get(_state, _state))
	if _switching:
		status_text = "正在释放上一个模型…"
	if _copying:
		status_text = "首次启动：复制模型到沙盒 %d%%" % _copy_progress
	if _cancel_pending or (_copying and _copy_cancelled):
		status_text = "正在取消，请稍候…"
	_status_label.text = status_text if _last_error.is_empty() else _last_error
	_status_label.add_theme_color_override("font_color", Color("9ad9bf") if _last_error.is_empty() else Color("ffb4a2"))


func _on_prompt_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and (event.ctrl_pressed or event.meta_pressed):
			_on_send_pressed()
			_prompt_edit.accept_event()


func _update_safe_area() -> void:
	if not (OS.has_feature("ios") or OS.has_feature("android")):
		return
	var window_size := DisplayServer.window_get_size()
	var safe_area := DisplayServer.get_display_safe_area()
	if window_size.x <= 0 or window_size.y <= 0:
		return
	var scale_xy := get_viewport_rect().size / Vector2(window_size)
	_safe_margin.add_theme_constant_override("margin_left", 20 + int(safe_area.position.x * scale_xy.x))
	_safe_margin.add_theme_constant_override("margin_right", 20 + int(maxi(0, window_size.x - safe_area.end.x) * scale_xy.x))
	_safe_margin.add_theme_constant_override("margin_top", 20 + int(safe_area.position.y * scale_xy.y))
	var bottom_inset := maxi(maxi(0, window_size.y - safe_area.end.y), DisplayServer.virtual_keyboard_get_height())
	_safe_margin.add_theme_constant_override("margin_bottom", 20 + int(bottom_inset * scale_xy.y))
