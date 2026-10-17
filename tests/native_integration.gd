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
	if '--no-model' in OS.get_cmdline_user_args():
		check(events.all(func(e): return e.has('decode_tokens') and e.has('decode_ms') and e.has('output_tokens')), 'native events expose benchmark fields')
		check(events.all(func(e): return typeof(e.decode_tokens) == TYPE_INT and typeof(e.decode_ms) == TYPE_FLOAT and typeof(e.output_tokens) == TYPE_INT), 'benchmark fields have numeric types')
		events.clear()
		check(bool(runner.call('load_model', '/missing/retry.gguf')), 'retry after load error is accepted')
		check(await wait_state('error'), 'retry reports missing model honestly')
		check(events.any(func(e): return e.type == 'error'), 'retry emits actionable error')
		runner.call('unload_model')
		check(await wait_state('unloaded'), 'failed model resources unload cleanly')
		runner = null
		print('NATIVE_NO_MODEL_FAILURES=%d' % failures)
		quit(0 if failures == 0 else 1)
		return
	events.clear()
	var ui_script = load('res://scripts/main.gd')
	var resolver = ui_script.new()
	# Resolve the same real on-disk aliases as the application.
	var qwen_path: String = resolver._find_model_path(0, 'res://models')
	resolver.free()
	check(not qwen_path.is_empty(), 'real Qwen fixture exists')
	if qwen_path.is_empty():
		quit(3)
		return
	var path := ProjectSettings.globalize_path(qwen_path)
	check(bool(runner.call('load_model', path)), 'load real model')
	if not await wait_state('ready'):
		print(events)
		quit(3)
		return
	events.clear()
	check(bool(runner.call('generate', 'What is 2 + 2? Reply with a single digit only.')), 'start controlled Qwen arithmetic generation')
	check(not bool(runner.call('generate', '重复请求')), 'reject overlapping generation')
	check(await wait_state('ready'), 'generation finishes')
	var output := ''
	for event in events:
		if event.type == 'token':
			output += str(event.text)
	print('MODEL_REPLY=' + output)
	check(not output.strip_edges().is_empty(), 'real streamed output nonempty')
	check(not output.contains('�'), 'valid UTF-8 stream')
	check_semantics(output, 'Qwen')
	check(not events.any(func(e): return e.type == 'error'), 'no decode error')
	check(events.any(func(e): return e.type == 'done' and not e.cancelled), 'completion event')
	check_metrics()
	events.clear()
	check(bool(runner.call('generate', '请写一篇很长的文章。')), 'start cancellation case')
	runner.call('cancel')
	check(await wait_state('ready'), 'cancel returns to ready')
	check(events.any(func(e): return e.type == 'done' and e.cancelled), 'cancelled completion event')
	check(events.any(func(e): return e.type == 'done' and e.cancelled and e.decode_tokens == 0 and e.decode_ms == 0.0), 'cancelled run exposes no successful decode rate')
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
	events.clear()
	var bonsai_path := ProjectSettings.globalize_path('res://models/Ternary-Bonsai-2-2B-Q2_0.gguf')
	check(FileAccess.file_exists(bonsai_path), 'real Bonsai fixture exists')
	if FileAccess.file_exists(bonsai_path):
		check(bool(runner.call('load_model', bonsai_path)), 'load Bonsai after releasing Qwen')
		if await wait_state('ready'):
			events.clear()
			check(bool(runner.call('generate', 'What is 2 + 2? Reply with a single digit only.')), 'start Bonsai generation')
			check(await wait_state('ready'), 'Bonsai generation finishes')
			check(not events.any(func(e): return e.type == 'error'), 'Bonsai has no decode error')
			check_metrics()
			var bonsai_output := ''
			for event: Dictionary in events:
				if event.type == 'token':
					bonsai_output += str(event.text)
			print('BONSAI_REPLY=' + bonsai_output)
			check_semantics(bonsai_output, 'Bonsai')
		else:
			check(false, 'Bonsai loads successfully')
		runner.call('unload_model')
		check(await wait_state('unloaded'), 'release Bonsai')
	runner = null
	print('NATIVE_INTEGRATION_FAILURES=%d' % failures)
	quit(0 if failures == 0 else 1)


func check_metrics() -> void:
	var completions := events.filter(func(e): return e.type == 'done' and not e.cancelled)
	check(completions.size() == 1, 'one successful completion contains benchmark stats')
	if completions.size() != 1:
		return
	var done: Dictionary = completions[0]
	var decoded := int(done.get('decode_tokens', -1))
	var output := int(done.get('output_tokens', -1))
	var elapsed := float(done.get('decode_ms', -1.0))
	check(output > 0 and output <= 192, 'sampled output obeys 192-token cap')
	check(decoded >= 0 and decoded <= output and output - decoded <= 1, 'decode count excludes an undecoded final capped token')
	check(is_finite(elapsed) and elapsed >= 0.0, 'native decode duration is finite and nonnegative')
	if decoded > 0:
		check(elapsed > 0.0, 'decoded tokens have a measurable native duration')
		print('DECODE_TOKENS=%d DECODE_MS=%.3f OUTPUT_TOKENS=%d TOKEN_PER_SEC=%.3f' % [decoded, elapsed, output, decoded * 1000.0 / elapsed])


func check_semantics(output: String, model_name: String) -> void:
	var answer := output.strip_edges()
	check(answer in ['4', '4.'], model_name + ' answers controlled arithmetic correctly')
	check(not output.contains('<think>') and not output.contains('</think>') and not output.contains('<|'), model_name + ' reply contains no internal/template markers')
