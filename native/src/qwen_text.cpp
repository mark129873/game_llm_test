#include "qwen_core.hpp"
#include <cstdint>
#include <stdexcept>

namespace qwen {
std::string format_prompt(const std::string &prompt) {
    const auto first = prompt.find_first_not_of(" \t\n\r\f\v");
    if (first == std::string::npos) throw std::invalid_argument("Enter a non-empty prompt.");
    if (prompt.size() > 16384) throw std::invalid_argument("Prompt exceeds the 16 KiB input limit.");
    if (prompt.find("<|") != std::string::npos) {
        throw std::invalid_argument("Prompt must not contain model control-token delimiters (<|).");
    }
    const auto last = prompt.find_last_not_of(" \t\n\r\f\v");
    // https://huggingface.co/Qwen/Qwen3.5-0.8B/blob/main/chat_template.jinja
    // messages=[{role: user, content: prompt}], enable_thinking=false,
    // add_generation_prompt=true. There is deliberately no conversation history.
    return "<|im_start|>user\n" + prompt.substr(first, last - first + 1) +
           "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
}

std::string take_utf8(std::string &pending, bool final) {
    std::string result;
    std::size_t i = 0;
    constexpr const char *replacement = "\xEF\xBF\xBD";
    while (i < pending.size()) {
        const auto lead = static_cast<unsigned char>(pending[i]);
        unsigned length = 0;
        std::uint32_t code = 0;
        if (lead <= 0x7f) { length = 1; code = lead; }
        else if (lead >= 0xc2 && lead <= 0xdf) { length = 2; code = lead & 0x1f; }
        else if (lead >= 0xe0 && lead <= 0xef) { length = 3; code = lead & 0x0f; }
        else if (lead >= 0xf0 && lead <= 0xf4) { length = 4; code = lead & 0x07; }
        else { result += replacement; ++i; continue; }
        if (i + length > pending.size()) {
            if (!final) break;
            result += replacement;
            i = pending.size();
            break;
        }
        bool valid = true;
        for (unsigned j = 1; j < length; ++j) {
            const auto c = static_cast<unsigned char>(pending[i + j]);
            if ((c & 0xc0) != 0x80) { valid = false; break; }
            code = (code << 6) | (c & 0x3f);
        }
        if (!valid || (length == 2 && code < 0x80) ||
            (length == 3 && code < 0x800) || (length == 4 && code < 0x10000) ||
            code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
            result += replacement;
            ++i;
            continue;
        }
        // Godot strings cannot use an embedded NUL as visible output.
        if (code == 0) result += replacement;
        else result.append(pending, i, length);
        i += length;
    }
    pending.erase(0, i);
    return result;
}
} // namespace qwen
