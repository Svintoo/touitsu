#pragma once
#include "tx_api.h"
namespace txbridge {
void configure(void*, tx_process_cb, tx_process_cb, tx_thread_cb, tx_thread_cb, tx_output_cb);
void foundCallback(void*, tx_found_cb);
bool owns(uint32_t);
bool is32(uint32_t);
bool attach(uint32_t);
bool detach(uint32_t);
bool insert(uint32_t, const wchar_t*);
bool remove(uint32_t, uint64_t);
bool find(uint32_t, uint32_t, const wchar_t*);
uint32_t shutdown(uint32_t);
bool probe();
}
