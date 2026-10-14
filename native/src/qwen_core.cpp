#include "qwen_core.hpp"
#include "llama.h"
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <utility>

namespace qwen {
namespace {
std::once_flag backend_once;
bool abort_inference(void *data) { return static_cast<std::atomic<bool> *>(data)->load(); }
bool load_progress(float, void *data) { return !abort_inference(data); }
using Batch = std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)>;
using Sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>;
}

Runner::Runner() : worker_(&Runner::run, this) {}
Runner::~Runner() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        cancelled_ = true;
    }
    wake_.notify_one();
    if (worker_.joinable()) worker_.join();
}
bool Runner::load_model(const std::string &path) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (path.empty() || busy_ || unload_requested_ || stopping_) return false;
    busy_ = true;
    cancelled_ = false;
    command_ = Command::load;
    argument_ = path;
    set_state_locked("loading");
    wake_.notify_one();
    return true;
}
bool Runner::generate(const std::string &prompt) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ != "ready" || busy_ || unload_requested_ || stopping_) return false;
    busy_ = true;
    cancelled_ = false;
    command_ = Command::generate;
    argument_ = prompt;
    set_state_locked("generating");
    wake_.notify_one();
    return true;
}
void Runner::cancel() { cancelled_ = true; }
void Runner::unload_model() {
    std::lock_guard<std::mutex> lock(mutex_);
    unload_requested_ = true;
    cancelled_ = true;
    wake_.notify_one();
}
std::string Runner::get_state() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return state_;
}
std::vector<Event> Runner::poll_events() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<Event> result;
    result.reserve(events_.size());
    while (!events_.empty()) {
        result.push_back(std::move(events_.front()));
        events_.pop_front();
    }
    return result;
}
void Runner::emit_locked(Event event) {
    // Bound unpolled memory even if a caller never drains its event queue.
    if (event.type == "token" && !events_.empty() && events_.back().type == "token" &&
        events_.back().text.size() + event.text.size() <= 16384) {
        events_.back().text += event.text;
        return;
    }
    if (events_.size() >= 256) events_.pop_front();
    events_.push_back(std::move(event));
}
void Runner::emit(Event event) {
    std::lock_guard<std::mutex> lock(mutex_);
    emit_locked(std::move(event));
}
void Runner::set_state_locked(const std::string &state) {
    state_ = state;
    emit_locked({"state", state, false});
}
void Runner::finish(const std::string &state) {
    std::lock_guard<std::mutex> lock(mutex_);
    busy_ = false;
    if (!unload_requested_ && !stopping_) set_state_locked(state);
}
void Runner::release_model() {
    if (context_) { llama_free(context_); context_ = nullptr; }
    if (model_) { llama_model_free(model_); model_ = nullptr; }
}
void Runner::run() {
    for (;;) {
        Command command;
        std::string argument;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return stopping_ || unload_requested_ || command_ != Command::none; });
            if (stopping_) break;
            if (unload_requested_) {
                // Cancel can arrive before the queued operation starts.
                command_ = Command::none;
                argument_.clear();
                lock.unlock();
                release_model();
                lock.lock();
                busy_ = false;
                unload_requested_ = false;
                set_state_locked("unloaded");
                continue;
            }
            command = command_;
            argument = std::move(argument_);
            command_ = Command::none;
        }
        try {
            if (command == Command::load) do_load(argument);
            else if (command == Command::generate) do_generate(argument);
        } catch (const std::exception &error) {
            emit({"error", error.what(), false});
            if (command == Command::load) release_model();
            finish(command == Command::generate && model_ && context_ ? "ready" : "error");
        } catch (...) {
            emit({"error", "Unexpected native inference failure.", false});
            release_model();
            finish("error");
        }
    }
    release_model();
}
void Runner::do_load(const std::string &path) {
    release_model();
    // Backend lifetime is process-wide: no instance may free it while another uses it.
    std::call_once(backend_once, [] { llama_backend_init(); });
    auto params = llama_model_default_params();
    params.n_gpu_layers = 0;
    params.progress_callback = load_progress;
    params.progress_callback_user_data = &cancelled_;
    model_ = llama_model_load_from_file(path.c_str(), params);
    if (cancelled_) {
        release_model();
        emit({"done", "", true});
        finish("unloaded");
        return;
    }
    if (!model_) throw std::runtime_error("Could not load GGUF. Check the file, free memory, and native log.");
    char architecture[64] = {};
    llama_model_meta_val_str(model_, "general.architecture", architecture, sizeof(architecture));
    if (std::string(architecture) != "qwen35") {
        throw std::runtime_error("This demo requires Qwen3.5-0.8B-Q4_0.gguf (qwen35 architecture).");
    }
    const auto count = llama_model_n_params(model_);
    if (count < 600000000ULL || count > 1100000000ULL) {
        throw std::runtime_error("The model size is not Qwen3.5-0.8B; use the specified 0.8B GGUF.");
    }
    auto context_params = llama_context_default_params();
    context_params.n_ctx = context_size;
    context_params.n_batch = batch_size;
    context_params.n_ubatch = batch_size;
    context_params.n_seq_max = 1;
    const int threads = static_cast<int>(std::max(1u, std::min(4u, std::thread::hardware_concurrency())));
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    context_params.offload_kqv = false;
    context_params.op_offload = false;
    context_params.abort_callback = abort_inference;
    context_params.abort_callback_data = &cancelled_;
    context_ = llama_init_from_model(model_, context_params);
    if (cancelled_) {
        release_model();
        emit({"done", "", true});
        finish("unloaded");
        return;
    }
    if (!context_) throw std::runtime_error("Could not allocate inference context. Close other apps and retry.");
    finish("ready");
}
void Runner::do_generate(const std::string &prompt) {
    const std::string formatted = format_prompt(prompt);
    const auto *vocab = llama_model_get_vocab(model_);
    const int required = -llama_tokenize(vocab, formatted.data(), static_cast<int32_t>(formatted.size()), nullptr, 0, false, true);
    if (required <= 0) throw std::runtime_error("Prompt tokenization failed.");
    if (required + output_limit > static_cast<int>(llama_n_ctx(context_))) {
        throw std::runtime_error("Prompt is too long for the 1024-token demo context. Shorten it and retry.");
    }
    std::vector<llama_token> tokens(required);
    const int actual = llama_tokenize(vocab, formatted.data(), static_cast<int32_t>(formatted.size()), tokens.data(), required, false, true);
    if (actual != required) throw std::runtime_error("Prompt tokenization returned an unexpected length.");
    llama_memory_clear(llama_get_memory(context_), true);
    Batch batch(llama_batch_ext_init(context_), &llama_batch_ext_free);
    Sampler sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()), &llama_sampler_free);
    if (!batch || !sampler) throw std::runtime_error("Could not allocate the inference batch or sampler.");
    // Qwen recommends sampling for non-thinking mode; deterministic seed aids demo tests.
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.8f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
    auto decode = [&](const llama_token *input, int count, int position, bool logits) {
        llama_batch_ext_clear(batch.get());
        for (int i = 0; i < count; ++i) {
            const int idx = llama_batch_ext_add_token(batch.get(), 0, input[i]);
            const llama_pos pos = position + i;
            if (idx < 0 || !llama_batch_ext_set_pos(batch.get(), idx, &pos)) {
                throw std::runtime_error("Could not prepare inference batch.");
            }
        }
        llama_batch_ext_set_output_logits(batch.get(), count - 1, logits);
        const int result = llama_process(context_, LLAMA_PROCESS_TYPE_DECODE, batch.get());
        if (result && !cancelled_) throw std::runtime_error("Native model decode failed (code " + std::to_string(result) + ").");
        return result == 0 && !cancelled_;
    };
    int position = 0;
    while (position < required && !cancelled_) {
        const int count = std::min(batch_size, required - position);
        if (!decode(tokens.data() + position, count, position, position + count == required)) break;
        position += count;
    }
    std::string pending;
    int generated = 0;
    for (; generated < output_limit && !cancelled_; ++generated) {
        const auto token = llama_sampler_sample(sampler.get(), context_, -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        char buffer[256];
        int length = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, false);
        if (length < 0) {
            std::vector<char> large(static_cast<std::size_t>(-length));
            length = llama_token_to_piece(vocab, token, large.data(), static_cast<int32_t>(large.size()), 0, false);
            if (length < 0) throw std::runtime_error("Could not decode generated text.");
            pending.append(large.data(), length);
        } else pending.append(buffer, length);
        auto piece = take_utf8(pending);
        if (!piece.empty()) emit({"token", std::move(piece), false});
        if (generated + 1 == output_limit) break;
        if (!decode(&token, 1, position, true)) break;
        ++position;
    }
    auto tail = take_utf8(pending, true);
    if (!tail.empty()) emit({"token", std::move(tail), false});
    emit({"done", "", cancelled_.load()});
    finish("ready");
}
} // namespace qwen
