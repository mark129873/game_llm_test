#include "qwen_core.hpp"
#include <chrono>
#include <iostream>
#include <cmath>
#include <algorithm>
#include <cctype>
#include <string>
#include <thread>

int main(int argc, char **argv) {
    if (argc < 2 || argc == 3) {
        std::cerr << "Usage: qwen_smoke /absolute/path/Qwen3.5-0.8B-Q4_0.gguf [prompt] [required-answer-substring]\n";
        return 2;
    }
    qwen::Runner runner;
    if (!runner.load_model(argv[1])) return 3;
    bool sent = false;
    bool done = false;
    std::string answer;
    qwen::Event completion;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(10);
    while (std::chrono::steady_clock::now() < deadline) {
        for (const auto &event : runner.poll_events()) {
            if (event.type == "error") { std::cerr << event.text << '\n'; return 4; }
            if (event.type == "state") std::cerr << "state=" << event.text << '\n';
            if (event.type == "token") { std::cout << event.text << std::flush; answer += event.text; }
            if (event.type == "done") { done = true; completion = event; }
        }
        if (!sent && runner.get_state() == "ready") {
            sent = runner.generate(argc > 2 ? argv[2] : "What is 2 + 2? Reply with only the single digit.");
            if (!sent) return 5;
            if (runner.generate("Duplicate must be rejected")) return 6;
        }
        if (done && runner.get_state() == "ready") {
            runner.unload_model();
            while (runner.get_state() != "unloaded") std::this_thread::sleep_for(std::chrono::milliseconds(10));
            std::cout << '\n';
            const std::string expected = argc > 3 ? argv[3] : "4";
            std::string compact = answer;
            compact.erase(std::remove_if(compact.begin(), compact.end(), [](unsigned char c) { return std::isspace(c); }), compact.end());
            const bool correct = argc > 2 ? (argc > 3 && answer.find(expected) != std::string::npos)
                                         : (compact == "4" || compact == "4.");
            const bool semantic = correct &&
                answer.find("<think>") == std::string::npos && answer.find("<|im_") == std::string::npos;
            const bool stats = !completion.cancelled && completion.decode_tokens > 0 &&
                completion.decode_ms > 0 && std::isfinite(completion.decode_ms) &&
                completion.output_tokens >= completion.decode_tokens &&
                completion.output_tokens <= qwen::Runner::output_limit &&
                completion.output_tokens - completion.decode_tokens <= 1;
            std::cerr << "output_tokens=" << completion.output_tokens
                      << " decode_tokens=" << completion.decode_tokens
                      << " decode_ms=" << completion.decode_ms << '\n';
            if (!semantic || !stats) {
                std::cerr << "FAIL: expected answer substring / non-thinking / decode metrics\n";
                return 7;
            }
            std::cerr << "PASS: load, duplicate rejection, semantic answer, decode metrics, unload\n";
            return 0;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    runner.cancel();
    std::cerr << "Timed out\n";
    return 8;
}
