extends SceneTree
## UI contract tests use a fake runner only here; the application never fabricates output.

const SCENE := preload("res://main.tscn")
var _failures := 0
var _checks := 0
var _copy_tests_completed := false
var _model_tests_completed := false

class FakeRunner extends RefCounted:
	var state := "ready"
	var events: Array[Dictionary] = []
	var generations := 0
	var cancellations := 0
	var last_prompt := ""
	var operations: Array[String] = []
	var last_path := ""

	func get_state() -> String:
		return state

	func poll_events() -> Array[Dictionary]:
		var result := events.duplicate()
		events.clear()
		return result

	func generate(prompt: String) -> bool:
		if state != "ready":
			return false
		generations += 1
		last_prompt = prompt
		state = "generating"
		events.append({"type": "state", "text": state})
		return true

	func cancel() -> void:
		cancellations += 1

	func load_model(path: String) -> bool:
		operations.append("load")
		last_path = path
		state = "loading"
		return true

	func unload_model() -> void:
		operations.append("unload")
		state = "unloaded"
		events.append({"type": "state", "text": "unloaded"})


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS: " + description)
	else:
		_failures += 1
		push_error("FAIL: " + description)


func _run() -> void:
	var demo := SCENE.instantiate()
	demo.auto_load_model = false
	root.add_child(demo)
	await process_frame
	_check(demo._selected_model == 0 and demo._model_selector.item_count == 2, "Qwen is default with a distinct Bonsai option")
	_check(demo._output.text.is_empty(), "No fabricated model reply at startup")
	if not ClassDB.class_exists("QwenRunner"):
		_check(demo._status_label.text.contains("未检测到"), "Missing extension is explained honestly")
		_check(demo._send_button.disabled, "Send is disabled without a native runner")
	var runner := FakeRunner.new()
	demo._runner = runner
	demo._state = "ready"
	demo._last_error = ""
	demo._refresh_controls()
	_check(demo._send_button.disabled, "Empty prompt is disabled")
	demo._prompt_edit.text = "  你好  "
	demo._refresh_controls()
	_check(not demo._send_button.disabled, "Ready model enables a nonempty prompt")
	demo._on_send_pressed()
	demo._on_send_pressed()
	_check(demo._model_selector.disabled and demo._load_button.disabled, "Selector and retry are disabled during generation")
	demo._on_model_selected(1)
	_check(demo._selected_model == 0, "Programmatic switch is rejected while busy")
	_check(runner.generations == 1, "Repeated send starts exactly one generation")
	_check(runner.last_prompt == "你好", "Prompt is trimmed before native dispatch")
	_check(demo._send_button.disabled and not demo._cancel_button.disabled, "Generating enables cancel and disables send")
	runner.events.append({"type": "token", "text": "你好[b]"})
	runner.events.append({"type": "token", "text": "世界😀"})
	demo._process(0.0)
	_check(demo._reply == "你好[b]世界😀", "Native chunks are buffered in order with Unicode")
	_check(demo._output.text.is_empty(), "Partial output stays invisible while generating")
	demo._on_cancel_pressed()
	demo._on_cancel_pressed()
	_check(runner.cancellations == 1, "Repeated cancel dispatches once")
	_check(demo._cancel_button.disabled, "Cancel button disables while cancellation is pending")
	runner.events.append({"type": "done", "text": "", "cancelled": true})
	runner.events.append({"type": "state", "text": "ready"})
	runner.state = "ready"
	demo._process(0.0)
	_check(demo._output_hint.text == "已取消" and demo._reply.is_empty() and demo._output.text.is_empty(), "Cancellation discards all partial output")
	_check(not demo._send_button.disabled, "A cancelled generation can be followed by another prompt")
	demo._on_send_pressed()
	_check(runner.generations == 2 and demo._reply.is_empty() and demo._output.text.is_empty(), "Next single-turn reply clears the previous output")
	runner.events.append({"type": "token", "text": "完整[b]回复😀"})
	runner.events.append({"type": "done", "text": "", "cancelled": false, "decode_tokens": 10, "decode_ms": 250.0, "output_tokens": 11})
	runner.events.append({"type": "state", "text": "ready"})
	runner.state = "ready"
	demo._process(0.0)
	_check(demo._output.get_parsed_text() == "完整[b]回复😀", "Only completion displays the full answer, as literal text")
	_check(demo._metrics.text == "CPU 生成速度：40.0 token/s · 输出 11 tokens", "Rate uses native decode token count and milliseconds only")
	demo._on_send_pressed()
	_check(demo._metrics.text == demo.EMPTY_METRICS, "Starting generation clears old throughput")
	runner.events.append({"type": "error", "text": "测试：上下文长度超限"})
	runner.events.append({"type": "state", "text": "ready"})
	runner.state = "ready"
	demo._process(0.0)
	_check(demo._status_label.text.contains("上下文长度超限"), "Native errors are surfaced verbatim")
	_check(not demo._send_button.disabled, "Recoverable native errors do not lock the UI")
	demo._prompt_edit.text = "a".repeat(4097)
	demo._on_send_pressed()
	_check(runner.generations == 3, "Oversized input is rejected before native dispatch")
	demo._prompt_edit.text = "你好"
	demo._last_error = ""
	await _test_copy(demo)
	await _test_models(demo, runner)
	root.size = Vector2i(390, 844)
	await process_frame
	await process_frame
	_check(demo.get_node("SafeMargin/Scroll/Stack").size.x <= demo.size.x, "Phone-width layout does not require horizontal scrolling")
	demo.queue_free()
	await process_frame
	_check(_copy_tests_completed and _model_tests_completed, "All async fixture suites reached completion")
	_check(_checks + 1 >= 54, "Full required UI coverage executed")
	print("UI TESTS: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_copy(demo: Control) -> void:
	var source_path := "user://ui-test-source.bin"
	var target_path := "user://ui-tests/copied.gguf"
	var source := FileAccess.open(source_path, FileAccess.WRITE)
	if source == null:
		_check(false, "Cannot create copy fixture; set writable HOME and XDG_DATA_HOME")
		return
	var bytes := PackedByteArray()
	bytes.resize(2 * 1024 * 1024 + 31)
	bytes.fill(123)
	bytes[bytes.size() - 1] = 42
	source.store_buffer(bytes)
	source.close()
	var copied_path: String = await demo._copy_bundled_model(source_path, target_path)
	_check(copied_path == target_path, "Chunked resource copy returns a real sandbox path")
	_check(FileAccess.get_file_as_bytes(target_path) == bytes, "Chunked copy preserves bytes across buffer boundaries")
	_check(not FileAccess.file_exists(target_path + ".part"), "Successful copy atomically removes the partial path")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(target_path))
	_cancel_copy_after_frame(demo)
	var cancelled_path: String = await demo._copy_bundled_model(source_path, target_path)
	_check(cancelled_path.is_empty(), "Copy can be cancelled between chunks")
	_check(not FileAccess.file_exists(target_path) and not FileAccess.file_exists(target_path + ".part"), "Cancelled copy leaves no partial model")
	_check(not demo._copying, "Cancellation releases the UI copy-busy state")
	copied_path = await demo._copy_bundled_model(source_path, target_path)
	_check(copied_path == target_path, "Cancelled copy can be retried without restarting")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(target_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(source_path))
	_copy_tests_completed = true


func _cancel_copy_after_frame(demo: Control) -> void:
	await process_frame
	demo._copy_cancelled = true


func _test_models(demo: Control, runner: FakeRunner) -> void:
	var directory := "user://ui-model-aliases"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var alias_path := directory + "/Qwen3.5-0.8B-Q4_0_un.gguf"
	var alias_file := FileAccess.open(alias_path, FileAccess.WRITE)
	if alias_file == null:
		_check(false, "Cannot create alias fixture; set writable HOME and XDG_DATA_HOME")
		return
	alias_file.store_string("fixture")
	alias_file.close()
	_check(demo._find_model_path(0, directory) == alias_path, "Qwen _un alias is resolved only when present")
	_check(demo._find_model_path(1, directory).is_empty(), "Missing Bonsai is never fabricated from a Qwen file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(alias_path))
	_check(demo._find_model_path(0, directory).is_empty(), "Absent aliases yield no model path")
	var unknown_alias := directory + "/Qwen3.5-0.8B-Q4_0_build_un_v2.gguf"
	alias_file = FileAccess.open(unknown_alias, FileAccess.WRITE)
	if alias_file == null:
		_check(false, "Cannot create model discovery fixture")
		return
	alias_file.store_string("fixture")
	alias_file.close()
	_check(demo._find_model_path(0, directory) == unknown_alias, "Qwen discovery accepts _un within a conversion suffix")
	var second_alias := directory + "/Qwen3.5-0.8B-Q4_0_other_un.gguf"
	alias_file = FileAccess.open(second_alias, FileAccess.WRITE)
	if alias_file == null:
		_check(false, "Cannot create model discovery fixture")
		return
	alias_file.store_string("fixture")
	alias_file.close()
	_check(demo._find_model_path(0, directory).is_empty() and demo._last_error.contains("多个"), "Ambiguous unknown aliases require explicit resolution")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(unknown_alias))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(second_alias))
	demo._last_error = ""
	# Use a real sandbox fixture for each distinct cache; fake runner never infers from it.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://models"))
	var paths: Array[String] = []
	for option: Dictionary in demo.MODEL_OPTIONS:
		var path: String = "user://models/" + option.files[0]
		# Do not overwrite an actual pre-existing user's model cache.
		if FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_check(false, "Cannot create model cache fixture")
			return
		file.store_string("fixture")
		file.close()
		paths.append(path)
	demo._metrics.text = "stale rate"
	await demo._on_model_selected(1)
	_check(runner.operations == ["unload", "load"], "Switch waits for unload completion before loading")
	_check(runner.last_path.ends_with("Ternary-Bonsai-2-2B-Q2_0.gguf"), "Bonsai loads its own cached filename")
	_check(demo._metrics.text == demo.EMPTY_METRICS, "Model switch clears stale throughput")
	_check(demo._model_selector.disabled, "Selector disabled during native loading")
	runner.state = "ready"
	runner.events.append({"type": "state", "text": "ready"})
	demo._process(0.0)
	await demo._on_model_selected(0)
	_check(runner.operations == ["unload", "load", "unload", "load"], "Switching back releases Bonsai before loading Qwen")
	_check(runner.last_path.ends_with("Qwen3.5-0.8B-Q4_0.gguf"), "Qwen retains an independent cache")
	runner.state = "ready"
	runner.events.append({"type": "state", "text": "ready"})
	demo._process(0.0)
	demo._handle_event({"type": "done", "decode_tokens": 191, "decode_ms": 1000.0, "output_tokens": 192})
	_check(demo._metrics.text == "CPU 生成速度：191.0 token/s · 输出 192 tokens", "Output cap count remains distinct from decoded-token rate")
	for invalid_ms: float in [0.0, -1.0, INF, NAN]:
		demo._handle_event({"type": "done", "decode_tokens": 10, "decode_ms": invalid_ms})
		_check(demo._metrics.text == demo.EMPTY_METRICS, "Invalid native duration never displays throughput")
	demo._handle_event({"type": "done", "decode_tokens": 0, "decode_ms": 10.0})
	_check(demo._metrics.text == demo.EMPTY_METRICS, "Zero decode tokens never displays throughput")
	demo._handle_event({"type": "done", "cancelled": true, "decode_tokens": 10, "decode_ms": 250.0})
	_check(demo._metrics.text == demo.EMPTY_METRICS, "Cancellation never displays successful throughput")
	runner.state = "error"
	runner.events.append({"type": "error", "text": "测试加载失败"})
	runner.events.append({"type": "state", "text": "error"})
	demo._process(0.0)
	_check(not demo._load_button.disabled and not demo._model_selector.disabled, "Load failure re-enables retry and model selection")
	await demo._load_selected_model()
	_check(runner.operations.slice(-2) == ["unload", "load"], "Retry releases prior native resources and starts a fresh load")
	demo._on_cancel_pressed()
	runner.state = "unloaded"
	runner.events.append({"type": "state", "text": "unloaded"})
	demo._process(0.0)
	_check(not demo._cancel_pending and not demo._load_button.disabled, "Cancelled native load releases cancellation lock for retry")
	await demo._load_selected_model()
	_check(runner.operations.slice(-2) == ["unload", "load"], "Cancelled native load is retryable")
	runner.state = "ready"
	runner.events.append({"type": "state", "text": "ready"})
	demo._process(0.0)
	for path: String in paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_model_tests_completed = true
