#include "snapshot.h"

SnapshotStore& SnapshotStore::instance() {
    static SnapshotStore store;
    return store;
}

void SnapshotStore::begin() {
    if (_mutex == nullptr) _mutex = xSemaphoreCreateMutex();
    _scan.status = ScanStatus::Idle;
    _scan.failed = false;
    _scan.count = 0;
}

void SnapshotStore::setState(const Snapshot& s) {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    _state = s;
    xSemaphoreGive(_mutex);
}

void SnapshotStore::getState(Snapshot& out) {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    out = _state;
    xSemaphoreGive(_mutex);
}

void SnapshotStore::setScan(const ScanSnapshot& s) {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    _scan = s;
    xSemaphoreGive(_mutex);
}

void SnapshotStore::getScan(ScanSnapshot& out) {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    out = _scan;
    xSemaphoreGive(_mutex);
}

ScanStatus SnapshotStore::getScanStatus() {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    ScanStatus s = _scan.status;
    xSemaphoreGive(_mutex);
    return s;
}
