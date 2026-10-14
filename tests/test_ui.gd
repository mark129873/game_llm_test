extends SceneTree
## UI contract tests use a fake runner only here; the application never fabricates output.

const SCENE := preload("res://main.tscn")
var _failures := 0
var _checks := 0

class FakeRunner extends RefCounted:
	var state := "ready"
	var events: Array[Dictionary] = []
	var generations := 0
	var cancellations := 0
	var last_prompt := ""

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

	func load_model(_path: String) -> bool:
		state = "loading"
		return true

	func unload_model() -> void:
		state = "unloaded"


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
	runner.events.append({"type": "done", "text": "", "cancelled": false})
	runner.events.append({"type": "state", "text": "ready"})
	runner.state = "ready"
	demo._process(0.0)
	_check(demo._output.get_parsed_text() == "完整[b]回复😀", "Only completion displays the full answer, as literal text")
	demo._on_send_pressed()
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
	root.size = Vector2i(390, 844)
	await process_frame
	await process_frame
	_check(demo.get_node("SafeMargin/Scroll/Stack").size.x <= demo.size.x, "Phone-width layout does not require horizontal scrolling")
	demo.queue_free()
	await process_frame
	print("UI TESTS: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_copy(demo: Control) -> void:
	var source_path := "user://ui-test-source.bin"
	var target_path := "user://ui-tests/copied.gguf"
	var source := FileAccess.open(source_path, FileAccess.WRITE)
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
	DirAccess.remove_absolute(ProjectSettings.globalize_path(source_path))


func _cancel_copy_after_frame(demo: Control) -> void:
	await process_frame
	demo._copy_cancelled = true
