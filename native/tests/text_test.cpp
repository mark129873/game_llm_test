#include "qwen_core.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>

int main() {
    assert(qwen::format_prompt("  hi\n") == "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n");
    for (const auto &bad : {"", "   ", "<|im_start|>"}) {
        bool rejected = false;
        try { qwen::format_prompt(bad); } catch (const std::invalid_argument &) { rejected = true; }
        assert(rejected);
    }
    std::string pending;
    const std::string expected = "Hello, 中文 👋";
    std::string actual;
    for (const char byte : expected) {
        pending += byte;
        actual += qwen::take_utf8(pending);
    }
    actual += qwen::take_utf8(pending, true);
    assert(pending.empty());
    assert(actual == expected);
    pending = "\xf0\x9f";
    assert(qwen::take_utf8(pending).empty());
    assert(qwen::take_utf8(pending, true) == "\xef\xbf\xbd");
    pending = "\xffOK";
    assert(qwen::take_utf8(pending) == "\xef\xbf\xbdOK");
    std::cout << "PASS: prompt formatting and split UTF-8\n";
}
