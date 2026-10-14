#pragma once
#include "qwen_core.hpp"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {
class QwenRunner : public RefCounted {
    GDCLASS(QwenRunner, RefCounted)
    qwen::Runner runner_;
protected:
    static void _bind_methods();
public:
    bool load_model(const String &path);
    bool generate(const String &prompt);
    void cancel();
    void unload_model();
    Array poll_events();
    String get_state() const;
};
} // namespace godot
