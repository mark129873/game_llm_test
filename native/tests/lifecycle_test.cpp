#include "qwen_core.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
void wait(qwen::Runner &runner, const char *state) {
    const auto until = std::chrono::steady_clock::now() + std::chrono::minutes(3);
    while (runner.get_state() != state) {
        if (std::chrono::steady_clock::now() > until) throw std::runtime_error("State transition timed out");
        for (const auto &event : runner.poll_events()) {
            if (event.type == "error") throw std::runtime_error(event.text);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
        qwen::Runner runner;
        // Unload can race both a queued and an active load.
        require(runner.load_model(argv[1]), "Load rejected");
        runner.unload_model();
        wait(runner, "unloaded");
        require(runner.load_model(argv[1]), "Reload rejected");
        wait(runner, "ready");
        require(runner.generate("Write a very long story about a sailor."), "Generate rejected");
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        runner.unload_model();
        wait(runner, "unloaded");
        require(runner.load_model(argv[1]), "Reload after active unload rejected");
        wait(runner, "ready");
        require(runner.generate("Say hello."), "Generate after unload rejected");
        wait(runner, "ready");
        for (int i = 0; i < 20; ++i) {
            require(runner.generate("Count from one to one hundred."), "Repeated generation rejected");
            runner.cancel();
            wait(runner, "ready");
        }
        { // Destruction while loading must join before freeing members.
            qwen::Runner loading;
            require(loading.load_model(argv[1]), "Destructor load rejected");
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        { // Destruction during inference must cancel, join, then free.
            qwen::Runner generating;
            require(generating.load_model(argv[1]), "Destructor generation load rejected");
            wait(generating, "ready");
            require(generating.generate("Write a long story."), "Destructor generation rejected");
            std::this_thread::sleep_for(std::chrono::milliseconds(30));
        }
        std::cout << "PASS: unload during load/generation, reload, 20 cancel cycles, destruction during load/generation\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
