#include "qwen_runner.hpp"
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>

static void initialize_qwen(godot::ModuleInitializationLevel level) {
    if (level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
        godot::ClassDB::register_class<godot::QwenRunner>();
    }
}
static void uninitialize_qwen(godot::ModuleInitializationLevel) {}
extern "C" {
GDExtensionBool GDE_EXPORT qwen_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    godot::GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_qwen);
    init.register_terminator(uninitialize_qwen);
    init.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
}
