/*
 * ESP32 A2DP-Sink fürs Oldtimer-Radio
 * -----------------------------------
 * Hardware: klassischer ESP32 (z. B. ESP32-WROOM-32 DevKit)
 *           -> ESP32-S3 / C3 / C6 / P4 können KEIN A2DP (kein Bluetooth Classic)
 *
 * Audio:    I2S -> PCM5102A (Stereo-DAC, Line-Out ca. 2,1 Vrms)
 *           Der PCM5102A liefert nur Line-Pegel – für Lautsprecher brauchst du
 *           dahinter einen Verstärker (z. B. PAM8403 klein, TPA3116 kräftiger).
 *
 * Metadaten: Titel/Interpret/Album per AVRCP -> UART an den Navi-ESP32-S3
 *            Protokoll (muss zum Navi-Sketch passen): eine JSON-Zeile,
 *            alle 2 s und sofort bei jeder Änderung:
 *              {"t":"media","title":"..","artist":"..","album":"..","play":1,"con":1,"vol":60}
 *              play = 1 spielt / 0 Pause, con = 1 wenn ein Handy verbunden ist,
 *              vol = Lautstärke in Prozent (0 bei Stumm)
 *
 * Bibliotheken (Arduino Library Manager oder GitHub):
 *   - ESP32-A2DP        https://github.com/pschatzmann/ESP32-A2DP
 *   - arduino-audio-tools https://github.com/pschatzmann/arduino-audio-tools
 *
 * Arduino IDE: Board "ESP32 Dev Module",
 *              Partition Scheme "Huge APP (3MB No OTA)" – der BT-Stack ist groß!
 *
 * Verdrahtung PCM5102A-Modul (das übliche lila/blaue Board):
 *   BCK  -> GPIO 26
 *   LCK  -> GPIO 25   (auch LRCK / WS genannt)
 *   DIN  -> GPIO 22
 *   SCK  -> GND       (keine Master-Clock nötig, der PCM5102A erzeugt sie intern)
 *   VIN  -> 3,3 V oder 5 V (Modul hat Regler), GND -> GND
 *
 *   Konfig-Pins (auf vielen Modulen per Lötbrücken H1L–H4L auf der Rückseite):
 *   FLT  -> GND   (normaler Filter)
 *   DEMP -> GND   (De-Emphasis aus)
 *   XSMT -> 3,3 V (Soft-Mute AUS – liegt der auf GND, bleibt alles stumm!)
 *   FMT  -> GND   (I2S-Format)
 *
 *   Ausgang: 3,5-mm-Klinke bzw. L/R/GND-Pads -> Eingang des Verstärkers
 *
 * Lautstärke: Drehgeber (EC11 mit 3 Pins auf einer Seite) steuert die Lautstärke
 *   in der Software (a2dp_sink.set_volume, 0..127) - kein digitales Poti nötig.
 *   Mittelpin (C / gemeinsam) -> GND
 *   Außenpin A               -> GPIO 32
 *   Außenpin B               -> GPIO 27
 *   (interne Pull-ups, keine Widerstände nötig)
 *   Optional Taster (2 Pins auf der anderen Seite) -> ENC_SW_GPIO und GND:
 *   Druck = Stumm an/aus. Drehrichtung falsch? ENC_REVERSE auf true.
 *   Die Handy-Lautstärke einmal auf Maximum stellen, geregelt wird am Drehgeber.
 *
 * Verdrahtung UART zum Navi-ESP32-S3:
 *   ESP32 GPIO 17 (TX) -> S3 D7 (GPIO44, RX)
 *   ESP32 GPIO 16 (RX) -> S3 D6 (GPIO43, TX)  (optional, für Rückkanal)
 *   GND gemeinsam!
 */

#include "AudioTools.h"
#include "BluetoothA2DPSink.h"
#include <Preferences.h>

// ---------- Konfiguration ----------
static const char* BT_NAME   = "Oldtimer-Radio";

static const int I2S_BCK_GPIO  = 26;
static const int I2S_WS_GPIO   = 25;
static const int I2S_DATA_GPIO = 22;

static const int NAVI_RX_GPIO  = 16;
static const int NAVI_TX_GPIO  = 17;
static const uint32_t UART_BAUD = 115200;

// Drehgeber / Lautstärke
static const int ENC_A_GPIO = 32;
static const int ENC_B_GPIO = 27;
static const int ENC_SW_GPIO = -1;     // Taster (Stumm); -1 = nicht angeschlossen
static const bool ENC_REVERSE = false; // Drehrichtung tauschen
static const int ENC_STEPS_PER_DETENT = 4;  // 4 bei den meisten EC11, 2 bei manchen
static const int VOLUME_STEP = 4;      // Lautstärke (0..127) pro Rastung
static const int VOLUME_DEFAULT = 60;

// Titel, Interpret und Album kommen einzeln vom Handy. Nach der letzten
// Änderung so lange warten, dann alles zusammen senden (kein Flackern).
static const uint32_t SETTLE_MS = 300;
static const uint32_t RESEND_MS = 2000;

// ---------- Objekte ----------
I2SStream i2s;
BluetoothA2DPSink a2dp_sink(i2s);
HardwareSerial NaviSerial(2);

// ---------- Zustand ----------
static char title[80], artist[80], album[80];
static bool connected = false;
static bool playing = false;
static bool dirty = true;
static unsigned long lastChangeMs = 0;
static unsigned long lastSendMs = 0;

static Preferences prefs;
static int volume = VOLUME_DEFAULT;    // 0..127
static bool muted = false;
static bool volumeSavePending = false;
static unsigned long volumeChangedMs = 0;

// Drehgeber: Zustandstabelle, wird in der Unterbrechung ausgewertet (kein Prellen-Ärger).
static volatile int32_t encCount = 0;
static volatile uint8_t encState = 0;
static const int8_t ENC_TABLE[16] = {0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0};

void IRAM_ATTR encoderISR() {
  uint8_t s = (digitalRead(ENC_A_GPIO) << 1) | digitalRead(ENC_B_GPIO);
  encCount += ENC_TABLE[(encState << 2) | s];
  encState = s;
}

static void applyVolume() {
  a2dp_sink.set_volume(muted ? 0 : (uint8_t)volume);
}

// Kopiert Text und entfernt Zeichen, die das JSON stören würden.
// (Umlaute bleiben UTF-8, der Navi-Sketch schreibt sie in ASCII um.)
static void copyClean(char* dst, const char* src, size_t n) {
  size_t o = 0;
  for (; *src && o < n - 1; ++src) {
    char c = *src;
    if (c == '"') c = '\'';
    else if (c == '\\') c = '/';
    else if ((uint8_t)c < 0x20) continue;
    dst[o++] = c;
  }
  dst[o] = 0;
}

static void markChanged() {
  dirty = true;
  lastChangeMs = millis();
}

// Eine JSON-Zeile an den Navi-ESP32.
static void sendMediaLine() {
  NaviSerial.printf(
      "{\"t\":\"media\",\"title\":\"%s\",\"artist\":\"%s\",\"album\":\"%s\",\"play\":%d,\"con\":%d,\"vol\":%d}\n",
      title, artist, album, playing ? 1 : 0, connected ? 1 : 0, muted ? 0 : (volume * 100 + 63) / 127);
  dirty = false;
  lastSendMs = millis();
}

// AVRCP-Metadaten vom Handy (Titel, Interpret, Album)
void avrcMetadataCallback(uint8_t id, const uint8_t* text) {
  const char* t = reinterpret_cast<const char*>(text);
  Serial.printf("Metadaten 0x%02X: %s\n", id, t);

  switch (id) {
    case ESP_AVRC_MD_ATTR_TITLE:  copyClean(title, t, sizeof(title)); break;
    case ESP_AVRC_MD_ATTR_ARTIST: copyClean(artist, t, sizeof(artist)); break;
    case ESP_AVRC_MD_ATTR_ALBUM:  copyClean(album, t, sizeof(album)); break;
    default: return;
  }
  markChanged();
}

// Verbindungsstatus (verbunden / getrennt)
void connectionStateChanged(esp_a2d_connection_state_t state, void* /*obj*/) {
  Serial.printf("A2DP-Status: %s\n", a2dp_sink.to_str(state));
  if (state == ESP_A2D_CONNECTION_STATE_CONNECTED) {
    connected = true;
  } else if (state == ESP_A2D_CONNECTION_STATE_DISCONNECTED) {
    connected = false;
    playing = false;
    title[0] = artist[0] = album[0] = 0;  // Display leeren
  }
  markChanged();
}

void setup() {
  Serial.begin(115200);
  NaviSerial.begin(UART_BAUD, SERIAL_8N1, NAVI_RX_GPIO, NAVI_TX_GPIO);

  // I2S-Ausgang konfigurieren
  auto cfg = i2s.defaultConfig(TX_MODE);
  cfg.pin_bck  = I2S_BCK_GPIO;
  cfg.pin_ws   = I2S_WS_GPIO;
  cfg.pin_data = I2S_DATA_GPIO;
  i2s.begin(cfg);

  // Welche Metadaten wir haben wollen
  a2dp_sink.set_avrc_metadata_attribute_mask(
      ESP_AVRC_MD_ATTR_TITLE | ESP_AVRC_MD_ATTR_ARTIST | ESP_AVRC_MD_ATTR_ALBUM);
  a2dp_sink.set_avrc_metadata_callback(avrcMetadataCallback);
  a2dp_sink.set_on_connection_state_changed(connectionStateChanged);

  // Beim Einschalten automatisch mit dem zuletzt gekoppelten Handy verbinden
  a2dp_sink.set_auto_reconnect(true);

  // Gespeicherte Lautstärke laden
  prefs.begin("radio", false);
  volume = constrain(prefs.getInt("vol", VOLUME_DEFAULT), 0, 127);

  // Drehgeber
  pinMode(ENC_A_GPIO, INPUT_PULLUP);
  pinMode(ENC_B_GPIO, INPUT_PULLUP);
  if (ENC_SW_GPIO >= 0) pinMode(ENC_SW_GPIO, INPUT_PULLUP);
  encState = (digitalRead(ENC_A_GPIO) << 1) | digitalRead(ENC_B_GPIO);
  attachInterrupt(digitalPinToInterrupt(ENC_A_GPIO), encoderISR, CHANGE);
  attachInterrupt(digitalPinToInterrupt(ENC_B_GPIO), encoderISR, CHANGE);

  a2dp_sink.start(BT_NAME);
  applyVolume();
  Serial.printf("A2DP-Sink \"%s\" gestartet\n", BT_NAME);
}

void loop() {
  // Optional: Befehle vom Navi zurück ans Handy, z. B. per Lenkrad-/Radiotaste
  // "N" = nächster Titel, "P" = vorheriger, "X" = Play/Pause-Toggle
  if (NaviSerial.available()) {
    char c = NaviSerial.read();
    switch (c) {
      case 'N': a2dp_sink.next();     break;
      case 'P': a2dp_sink.previous(); break;
      case 'X':
        if (a2dp_sink.get_audio_state() == ESP_A2D_AUDIO_STATE_STARTED)
          a2dp_sink.pause();
        else
          a2dp_sink.play();
        break;
      default: break;
    }
  }

  // Drehgeber -> Lautstärke
  noInterrupts();
  int32_t c = encCount;
  int32_t steps = c / ENC_STEPS_PER_DETENT;
  encCount = c - steps * ENC_STEPS_PER_DETENT;
  interrupts();
  if (steps != 0) {
    if (ENC_REVERSE) steps = -steps;
    volume = constrain(volume + (int)steps * VOLUME_STEP, 0, 127);
    muted = false;
    applyVolume();
    volumeSavePending = true;
    volumeChangedMs = millis();
    Serial.printf("Lautstaerke: %d/127\n", volume);
    markChanged();
  }

  // Taster: Stumm an/aus (entprellt)
  if (ENC_SW_GPIO >= 0) {
    static bool lastDown = false;
    static unsigned long downMs = 0;
    bool down = digitalRead(ENC_SW_GPIO) == LOW;
    if (down && !lastDown && millis() - downMs > 200) {
      downMs = millis();
      muted = !muted;
      applyVolume();
      Serial.println(muted ? "Stumm" : "Ton an");
      markChanged();
    }
    lastDown = down;
  }

  // Lautstärke erst speichern, wenn eine Weile nicht gedreht wurde (schont den Flash)
  if (volumeSavePending && millis() - volumeChangedMs > 3000) {
    prefs.putInt("vol", volume);
    volumeSavePending = false;
  }

  // Spielt es gerade? (Audio-Zustand des A2DP-Streams)
  bool nowPlaying = connected && a2dp_sink.get_audio_state() == ESP_A2D_AUDIO_STATE_STARTED;
  if (nowPlaying != playing) {
    playing = nowPlaying;
    markChanged();
  }

  // Änderungen gesammelt senden, sonst alle RESEND_MS wiederholen
  unsigned long now = millis();
  if (dirty && now - lastChangeMs > SETTLE_MS) sendMediaLine();
  else if (now - lastSendMs > RESEND_MS) sendMediaLine();

  delay(10);
}
