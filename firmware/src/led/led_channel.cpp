#include "led_channel.h"
#include "animation_engine.h"
#include <new>

LedChannel::LedChannel(uint8_t channelId)
    : _leds(nullptr),
      _controller(nullptr),
      _animProgress(0.0f),
      _lastTickMs(0) {
    _config.channelId = channelId;

    // Varsayılanlar ve SABİT pin: config.h LED_CHANNEL_HW (tek merkez)
    if (channelId >= 1 && channelId <= MAX_CHANNELS) {
        const LedChannelHw& hw = LED_CHANNEL_HW[channelId - 1];
        _config.enabled = hw.defaultEnabled;
        _config.gpioPin = hw.gpio;
        _config.ledCount = hw.defaultLedCount;
    } else {
        _config.enabled = false;
        _config.ledCount = 0;
    }

    _config.maxBrightness = 255;
    strncpy(_config.ledType, "WS2812B", sizeof(_config.ledType) - 1);
    _config.ledType[sizeof(_config.ledType) - 1] = '\0';
    strncpy(_config.colorOrder, "GRB", sizeof(_config.colorOrder) - 1);
    _config.colorOrder[sizeof(_config.colorOrder) - 1] = '\0';
}

LedChannel::~LedChannel() {
    _freeLeds();
}

bool LedChannel::begin() {
    // Attempt loading saved config & state from NVS
    ChannelConfig savedCfg;
    if (NvsStorage::instance().loadChannelConfig(_config.channelId, savedCfg)) {
        // GPIO sabittir (config.h LED_CHANNEL_HW): NVS'teki eski pin değeri (ör. v0.3.1'de CH3=21, CH4=22) yok sayılır.
        uint8_t fixedPin = _config.gpioPin;
        if (savedCfg.gpioPin != fixedPin) {
            Serial.printf("[LedChannel %d] Fixed GPIO %d (saved value %d ignored)\n",
                          _config.channelId, fixedPin, savedCfg.gpioPin);
        }
        _config = savedCfg;
        _config.gpioPin = fixedPin;
    }

    ChannelState savedState;
    if (NvsStorage::instance().loadChannelState(_config.channelId, savedState)) {
        _state = savedState;
    }

    _lastTickMs = millis();

    if (_config.enabled && _config.ledCount > 0) {
        _allocateLeds();
        _initFastLedController();
        Serial.printf("[LedChannel %d] Initialized on GPIO %d with %d LED(s) [%s, %s]\n",
                      _config.channelId, _config.gpioPin, _config.ledCount,
                      _config.ledType, _config.colorOrder);
        return true;
    } else {
        Serial.printf("[LedChannel %d] Channel disabled or 0 LEDs (dormant mode).\n", _config.channelId);
        return false;
    }
}

void LedChannel::_allocateLeds() {
    _freeLeds();
    if (_config.ledCount > 0) {
        _leds = new CRGB[_config.ledCount];
        for (uint16_t i = 0; i < _config.ledCount; i++) {
            _leds[i] = CRGB::Black;
        }
        _bufCount = _config.ledCount;
    }
}

void LedChannel::_freeLeds() {
    if (_leds != nullptr) {
        delete[] _leds;
        _leds = nullptr;
    }
    _bufCount = 0;
}

void LedChannel::_initFastLedController() {
    if (_leds == nullptr || _config.ledCount == 0) return;
    _addController(_leds, _config.ledCount);
}

// FastLED pini derleme zamanı şablon parametresi ister: pinler config.h LED_CHANNEL_HW'dan derleme zamanında alınır
// (pin değiştirmek için bu dosya DÜZENLENMEZ).
template <uint8_t PIN>
static CLEDController* addFor(bool isRgb, CRGB* buf, uint16_t count) {
    if (isRgb) return &FastLED.addLeds<WS2812B, PIN, RGB>(buf, count);
    return &FastLED.addLeds<WS2812B, PIN, GRB>(buf, count);
}
static_assert(MAX_CHANNELS == 4, "_addController 4 kanal için yazıldı");

void LedChannel::_addController(CRGB* buf, uint16_t count) {
    if (buf == nullptr || count == 0) return;

    bool isRgb = (strcasecmp(_config.colorOrder, "RGB") == 0);
    switch (_config.channelId) {
        case 1: _controller = addFor<LED_CHANNEL_HW[0].gpio>(isRgb, buf, count); break;
        case 2: _controller = addFor<LED_CHANNEL_HW[1].gpio>(isRgb, buf, count); break;
        case 3: _controller = addFor<LED_CHANNEL_HW[2].gpio>(isRgb, buf, count); break;
        case 4: _controller = addFor<LED_CHANNEL_HW[3].gpio>(isRgb, buf, count); break;
        default: _controller = nullptr; break;
    }
}

uint8_t LedChannel::getEffectiveBrightness() const {
    if (!_state.isOn) return 0;
    return static_cast<uint8_t>((static_cast<uint16_t>(_state.brightness) * _config.maxBrightness) / 255);
}

void LedChannel::show() {
    if (_controller != nullptr && _leds != nullptr && _config.enabled) {
        _controller->showLeds(getEffectiveBrightness());
    }
}

void LedChannel::setPower(bool on, bool save) {
    if (_state.isOn != on) {
        _state.isOn = on;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setColor(const RgbColor& color, bool save) {
    // CRITICAL: Updates color WITHOUT resetting _animProgress, timers, or effectType!
    if (_state.primaryColor != color) {
        _state.primaryColor = color;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setSecondaryColor(const RgbColor& color, bool save) {
    if (_state.secondaryColor != color) {
        _state.secondaryColor = color;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setBrightness(uint8_t brightness, bool save) {
    // CRITICAL: Updates brightness scaling without resetting animation phase!
    if (_state.brightness != brightness) {
        _state.brightness = brightness;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setEffect(EffectType effect, bool save) {
    if (_state.effectType != effect) {
        _state.effectType = effect;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setSpeed(uint8_t speed, bool save) {
    if (_state.speed != speed) {
        _state.speed = constrain(speed, 1, 100);
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

void LedChannel::setDirection(int8_t direction, bool save) {
    _state.direction = direction >= 0 ? 1 : -1;
    if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
}

void LedChannel::setIntensity(uint8_t intensity, bool save) {
    _state.intensity = constrain(intensity, 0, 100);
    if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
}

void LedChannel::setPalette(const Palette& palette, bool save) {
    if (_state.palette != palette) {
        _state.palette = palette;
        if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
    }
}

// LED tamponunu yeniden boyutlandırır. Tek yazar: loop çekirdeği (komut kuyruğu). Hata durumunda hiçbir şey değişmez.
bool LedChannel::_resizeLeds(uint16_t newCount) {
    if (_controller == nullptr) return false;
    if (newCount > MAX_LEDS_PER_CHANNEL) return false;
    if (newCount == _bufCount) return true;

    // 1) yeni tamponu önce ayır (bellek yetersizse eski şerit olduğu gibi kalır)
    CRGB* nl = nullptr;
    if (newCount > 0) {
        if (ESP.getFreeHeap() < 24000u + static_cast<uint32_t>(newCount) * 3u) return false;
        nl = new (std::nothrow) CRGB[newCount];
        if (nl == nullptr) return false;
        for (uint16_t i = 0; i < newCount; i++) nl[i] = CRGB::Black;
    }

    // 2) eski şeridi OLDUĞU UZUNLUKTA siyaha çek: küçülürken artık sürülmeyen LED'ler sönük kalsın
    if (_leds != nullptr && _bufCount > 0) {
        for (uint16_t i = 0; i < _bufCount; i++) _leds[i] = CRGB::Black;
        _controller->showLeds(255);
    }

    // 3) denetleyiciyi yeni tampona bağla, eskiyi serbest bırak
    if (nl != nullptr) _controller->setLeds(nl, newCount);
    else               _controller->setLeds(_dummy, 1);
    CRGB* old = _leds;
    _leds = nl;
    _bufCount = newCount;
    delete[] old;

    AnimationEngine::instance().resetChannel(_config.channelId);   // efekt tamponları yeni uzunluğa göre yeniden kurulur
    return true;
}

LedChannel::ApplyResult LedChannel::applyLiveConfig(const ChannelConfig& next) {
#if LIVE_LED_RESIZE
    if (_controller == nullptr) return ApplyResult::NeedsReboot;
    if (strcmp(next.colorOrder, _config.colorOrder) != 0) return ApplyResult::NeedsReboot;
    uint16_t target = next.enabled ? next.ledCount : 0;
    if (!_resizeLeds(target)) return ApplyResult::NoMemory;
    uint8_t keepId = _config.channelId;
    uint8_t keepPin = _config.gpioPin;
    _config = next;
    _config.channelId = keepId;
    _config.gpioPin = keepPin;
    return ApplyResult::Applied;
#else
    (void)next;
    return ApplyResult::NeedsReboot;
#endif
}

void LedChannel::setConfig(const ChannelConfig& config, bool save) {
    _config = config;
    if (save) NvsStorage::instance().saveChannelConfig(_config.channelId, _config);
}

void LedChannel::setState(const ChannelState& state, bool save) {
    _state = state;
    if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
}
