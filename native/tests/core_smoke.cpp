#include "qwen_core.hpp"
#include <chrono>
#include <iostream>
#include <string>
#include <thread>

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Usage: qwen_smoke /absolute/path/Qwen3.5-0.8B-Q4_0.gguf [prompt]\n";
        return 2;
    }
    qwen::Runner runner;
    if (!runner.load_model(argv[1])) return 3;
    bool sent = false;
    bool done = false;
    bool tokens = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(10);
    while (std::chrono::steady_clock::now() < deadline) {
        for (const auto &event : runner.poll_events()) {
            if (event.type == "error") { std::cerr << event.text << '\n'; return 4; }
            if (event.type == "state") std::cerr << "state=" << event.text << '\n';
            if (event.type == "token") { std::cout << event.text << std::flush; tokens = true; }
            if (event.type == "done") done = true;
        }
        if (!sent && runner.get_state() == "ready") {
            sent = runner.generate(argc > 2 ? argv[2] : "请用一句话介绍你自己。");
            if (!sent) return 5;
            if (runner.generate("Duplicate must be rejected")) return 6;
        }
        if (done && runner.get_state() == "ready") {
            runner.unload_model();
            while (runner.get_state() != "unloaded") std::this_thread::sleep_for(std::chrono::milliseconds(10));
            std::cout << '\n';
            std::cerr << "PASS: load, duplicate rejection, streamed generation, unload\n";
            return tokens ? 0 : 7;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    runner.cancel();
    std::cerr << "Timed out\n";
    return 8;
}
