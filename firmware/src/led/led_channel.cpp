#include "led_channel.h"

LedChannel::LedChannel(uint8_t channelId)
    : _leds(nullptr),
      _controller(nullptr),
      _animProgress(0.0f),
      _lastTickMs(0) {
    _config.channelId = channelId;

    // Load defaults based on channel ID
    switch (channelId) {
        case 1:
            _config.enabled = CH1_DEFAULT_ENABLED;
            _config.gpioPin = CH1_DEFAULT_GPIO;
            _config.ledCount = CH1_DEFAULT_LED_COUNT;
            break;
        case 2:
            _config.enabled = CH2_DEFAULT_ENABLED;
            _config.gpioPin = CH2_DEFAULT_GPIO;
            _config.ledCount = CH2_DEFAULT_LED_COUNT;
            break;
        case 3:
            _config.enabled = CH3_DEFAULT_ENABLED;
            _config.gpioPin = CH3_DEFAULT_GPIO;
            _config.ledCount = CH3_DEFAULT_LED_COUNT;
            break;
        case 4:
            _config.enabled = CH4_DEFAULT_ENABLED;
            _config.gpioPin = CH4_DEFAULT_GPIO;
            _config.ledCount = CH4_DEFAULT_LED_COUNT;
            break;
        default:
            _config.enabled = false;
            _config.ledCount = 0;
            break;
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
        _config = savedCfg;
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
    }
}

void LedChannel::_freeLeds() {
    if (_leds != nullptr) {
        delete[] _leds;
        _leds = nullptr;
    }
}

void LedChannel::_initFastLedController() {
    if (_leds == nullptr || _config.ledCount == 0) return;

    bool isRgb = (strcasecmp(_config.colorOrder, "RGB") == 0);

    // FastLED pin templates bind to known hardware channel pins
    switch (_config.channelId) {
        case 1:
            if (isRgb) {
                _controller = &FastLED.addLeds<WS2812B, CH1_DEFAULT_GPIO, RGB>(_leds, _config.ledCount);
            } else {
                _controller = &FastLED.addLeds<WS2812B, CH1_DEFAULT_GPIO, GRB>(_leds, _config.ledCount);
            }
            break;
        case 2:
            if (isRgb) {
                _controller = &FastLED.addLeds<WS2812B, CH2_DEFAULT_GPIO, RGB>(_leds, _config.ledCount);
            } else {
                _controller = &FastLED.addLeds<WS2812B, CH2_DEFAULT_GPIO, GRB>(_leds, _config.ledCount);
            }
            break;
        case 3:
            if (isRgb) {
                _controller = &FastLED.addLeds<WS2812B, CH3_DEFAULT_GPIO, RGB>(_leds, _config.ledCount);
            } else {
                _controller = &FastLED.addLeds<WS2812B, CH3_DEFAULT_GPIO, GRB>(_leds, _config.ledCount);
            }
            break;
        case 4:
            if (isRgb) {
                _controller = &FastLED.addLeds<WS2812B, CH4_DEFAULT_GPIO, RGB>(_leds, _config.ledCount);
            } else {
                _controller = &FastLED.addLeds<WS2812B, CH4_DEFAULT_GPIO, GRB>(_leds, _config.ledCount);
            }
            break;
        default:
            _controller = nullptr;
            break;
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

void LedChannel::setConfig(const ChannelConfig& config, bool save) {
    _config = config;
    if (save) NvsStorage::instance().saveChannelConfig(_config.channelId, _config);
}

void LedChannel::setState(const ChannelState& state, bool save) {
    _state = state;
    if (save) NvsStorage::instance().saveChannelState(_config.channelId, _state);
}
