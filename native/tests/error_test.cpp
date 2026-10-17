#include "qwen_core.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

int main() {
    qwen::Runner runner;
    if (runner.generate("No model") || runner.load_model("")) return 1;
    for (int trial = 0; trial < 2; ++trial) {
        if (!runner.load_model("/definitely-absent-dual-model-test.gguf")) return 2;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (runner.get_state() == "loading" && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (runner.get_state() != "error") return 3;
        bool error = false;
        for (const auto &event : runner.poll_events()) {
            error |= event.type == "error";
            if (event.decode_tokens || event.decode_ms || event.output_tokens) return 4;
        }
        if (!error) return 5;
    }
    runner.unload_model();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (runner.get_state() != "unloaded" && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (runner.get_state() != "unloaded") return 6;
    std::cout << "PASS: invalid calls, failed-load retry, zero error metrics, unload\n";
}
