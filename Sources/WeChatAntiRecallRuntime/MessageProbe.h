#pragma once
#include <cstdint>
#include <string>

// Read-only view of WeChat's receive Message, implemented in RedPacket.mm because that
// module owns the per-build profile (message vtable and layout checks) that makes these
// offsets safe to read. Other features reuse it instead of repeating the offsets.
namespace message_probe {

// Verified older Message layout, independent of the newer payment-service ABI.
bool initializeNative268602(uintptr_t slide);

struct Received {
    uint32_t type = 0;      // Message +0x0C: 1 text, 3 image, 49 appmsg, ...
    uint32_t created = 0;   // Message +0x114: Unix seconds
    uint64_t serverId = 0;  // Message +0xF8
    std::string from;       // Message +0x18: sender, or the chat room id for group chats
    std::string to;         // Message +0x30: the receiving account
    std::string content;    // Message +0x130: raw content; group chats prefix "sender:\n"
};

// True only for a network-received Message with a verified per-build layout
// (the vtable is compared against that build's Message vtable). `mode` is the second
// argument of the Message finalizer; 1 means a freshly received message.
bool readReceived(void *message, int mode, Received &out);

// The signed-in account id. This calls into WeChat, so use the main queue only.
// Empty when unavailable.
std::string currentAccount();

}  // namespace message_probe
