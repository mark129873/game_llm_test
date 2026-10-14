extends SceneTree

var runner: Object
var failures := 0
var events: Array = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(('PASS ' if ok else 'FAIL ') + label)
	if not ok:
		failures += 1

func wait_state(wanted: String, timeout_sec: float = 120.0) -> bool:
	var until := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while str(runner.call('get_state')) != wanted and Time.get_ticks_msec() < until:
		events.append_array(runner.call('poll_events'))
		await process_frame
	events.append_array(runner.call('poll_events'))
	return str(runner.call('get_state')) == wanted

func _run() -> void:
	if not ClassDB.class_exists('QwenRunner'):
		push_error('Native extension missing')
		quit(2)
		return
	runner = ClassDB.instantiate('QwenRunner')
	check(bool(runner.call('load_model', '/missing/model.gguf')), 'accept async missing-file request')
	check(await wait_state('error'), 'missing model reports error')
	check(events.any(func(e): return e.type == 'error'), 'missing-file error event')
	events.clear()
	var path := ProjectSettings.globalize_path('res://models/Qwen3.5-0.8B-Q4_0.gguf')
	check(bool(runner.call('load_model', path)), 'load real model')
	if not await wait_state('ready'):
		print(events)
		quit(3)
		return
	events.clear()
	check(bool(runner.call('generate', '用中文回答：一加一等于几？只给答案。')), 'start Chinese generation')
	check(not bool(runner.call('generate', '重复请求')), 'reject overlapping generation')
	check(await wait_state('ready'), 'generation finishes')
	var output := ''
	for event in events:
		if event.type == 'token':
			output += str(event.text)
	print('MODEL_REPLY=' + output)
	check(not output.strip_edges().is_empty(), 'real streamed output nonempty')
	check(not output.contains('�'), 'valid UTF-8 stream')
	check(not events.any(func(e): return e.type == 'error'), 'no decode error')
	check(events.any(func(e): return e.type == 'done' and not e.cancelled), 'completion event')
	events.clear()
	check(bool(runner.call('generate', '请写一篇很长的文章。')), 'start cancellation case')
	runner.call('cancel')
	check(await wait_state('ready'), 'cancel returns to ready')
	check(events.any(func(e): return e.type == 'done' and e.cancelled), 'cancelled completion event')
	events.clear()
	check(bool(runner.call('generate', '测试'.repeat(3000))), 'accept length validation request')
	check(await wait_state('ready'), 'long prompt recovers to ready')
	check(events.any(func(e): return e.type == 'error'), 'long prompt rejected safely')
	events.clear()
	check(bool(runner.call('generate', '只回答：你好')), 'generate after cancellation and error')
	check(await wait_state('ready'), 'recovery generation finishes')
	check(events.any(func(e): return e.type == 'token'), 'recovery produces tokens')
	runner.call('unload_model')
	check(await wait_state('unloaded'), 'unload completes')
	runner = null
	print('NATIVE_INTEGRATION_FAILURES=%d' % failures)
	quit(0 if failures == 0 else 1)
