#include "qwen_runner.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {
void QwenRunner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_model", "path"), &QwenRunner::load_model);
    ClassDB::bind_method(D_METHOD("generate", "prompt"), &QwenRunner::generate);
    ClassDB::bind_method(D_METHOD("cancel"), &QwenRunner::cancel);
    ClassDB::bind_method(D_METHOD("unload_model"), &QwenRunner::unload_model);
    ClassDB::bind_method(D_METHOD("poll_events"), &QwenRunner::poll_events);
    ClassDB::bind_method(D_METHOD("get_state"), &QwenRunner::get_state);
}
bool QwenRunner::load_model(const String &path) {
    const auto utf8 = path.utf8();
    return runner_.load_model(std::string(utf8.get_data(), utf8.length()));
}
bool QwenRunner::generate(const String &prompt) {
    const auto utf8 = prompt.utf8();
    return runner_.generate(std::string(utf8.get_data(), utf8.length()));
}
void QwenRunner::cancel() { runner_.cancel(); }
void QwenRunner::unload_model() { runner_.unload_model(); }
String QwenRunner::get_state() const { return String::utf8(runner_.get_state().c_str()); }
Array QwenRunner::poll_events() {
    Array result;
    for (const auto &event : runner_.poll_events()) {
        Dictionary item;
        item["type"] = String::utf8(event.type.c_str());
        item["text"] = String::utf8(event.text.c_str(), static_cast<int64_t>(event.text.size()));
        item["cancelled"] = event.cancelled;
        item["decode_tokens"] = event.decode_tokens;
        item["decode_ms"] = event.decode_ms;
        item["output_tokens"] = event.output_tokens;
        result.append(item);
    }
    return result;
}
} // namespace godot
