#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct llama_model;
struct llama_context;

namespace qwen {
struct Event {
    std::string type;
    std::string text;
    bool cancelled = false;
};

// Public calls are non-blocking, except destruction, which cancels and joins.
// The worker alone owns every llama object. No Godot API is used on that thread.
class Runner {
public:
    static constexpr int context_size = 1024;
    static constexpr int output_limit = 192;
    static constexpr int batch_size = 128;
    Runner();
    ~Runner();
    Runner(const Runner &) = delete;
    Runner &operator=(const Runner &) = delete;
    bool load_model(const std::string &path);
    bool generate(const std::string &prompt);
    void cancel();
    void unload_model();
    std::string get_state() const;
    std::vector<Event> poll_events();

private:
    enum class Command { none, load, generate };
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Event> events_;
    std::string state_ = "unloaded";
    Command command_ = Command::none;
    std::string argument_;
    bool busy_ = false;
    bool unload_requested_ = false;
    bool stopping_ = false;
    std::atomic<bool> cancelled_{false};
    llama_model *model_ = nullptr;
    llama_context *context_ = nullptr;
    std::thread worker_;

    void run();
    void do_load(const std::string &path);
    void do_generate(const std::string &prompt);
    void release_model();
    void finish(const std::string &state);
    void emit(Event event);
    void emit_locked(Event event);
    void set_state_locked(const std::string &state);
};

// Text-only, single-turn specialization of Qwen's official non-thinking template.
std::string format_prompt(const std::string &prompt);
// Produces only complete valid UTF-8. Incomplete trailing bytes stay in pending.
std::string take_utf8(std::string &pending, bool final = false);
} // namespace qwen
