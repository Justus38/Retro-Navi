/*
  Retro Navi - ESP32 Testsketch
  Empfaengt die Navigationsdaten der App per Bluetooth (BLE) und zeigt sie
  auf einem ILI9341-Display (320x240, Querformat) im Amber-auf-Schwarz-Stil an.

  Protokoll (muss zur App passen):
    Service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E   (Nordic UART)
    RX-Char. 6E400002-...  (App schreibt, Write / Write Without Response)
    Nachricht = ein JSON-Objekt + "\n", z. B.
    {"spd":47,"turn":"L","dist":320,"street":"Hauptstr","rem":12400,"eta":18}
    turn: S, L, R, SL, SR, U, ROUND1-4, ARR
    dist/rem in Metern, eta in Minuten, spd in km/h

  Benoetigt (Arduino-IDE, Bibliotheksverwaltung):
    - Adafruit GFX Library
    - Adafruit ILI9341
    - ArduinoJson (Version 7.x)
    - Board-Paket "esp32" von Espressif (BLE ist darin enthalten)

  Arduino-IDE-Einstellungen:
    Board: "ESP32 Dev Module"
    Partition Scheme: "Huge APP (3MB No OTA/1MB SPIFFS)"
      (BLE + Display passen sonst evtl. nicht in den Standard-Speicher:
       Fehler "Sketch too big")

  Test ohne App: Im Seriellen Monitor (115200 Baud) 'd' senden. Das startet
  einen Demo-Lauf durch alle Abbiegesymbole. Nochmal 'd' beendet ihn.
*/

#include <Arduino.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ILI9341.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>

// ---------------------------------------------------------------- Hardware
// Pins wie in deinem Display-Testskript. Beim ESP32-S3 muessen sie angepasst
// werden (dort sind nicht alle dieser GPIOs frei).
#define TFT_MISO 25
#define TFT_LED 5          // in deinem Skript definiert, hier ungenutzt
#define TFT_SCK 19
#define TFT_MOSI 23
#define TFT_DC 21
#define TFT_RESET 18
#define TFT_CS 22
#define BACKLIGHT_PIN 16   // wie in deinem Skript (PWM)
#define BACKLIGHT_LEVEL 5  // 0-255, wie in deinem Skript; hoeher = heller

Adafruit_ILI9341 tft = Adafruit_ILI9341(TFT_CS, TFT_DC, TFT_MOSI, TFT_SCK, TFT_RESET, TFT_MISO);

// ------------------------------------------------------------------- BLE
#define BLE_NAME "RetroNavi"
#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_UUID "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ---------------------------------------------------------------- Farben
#define COL_BG 0x0000
#define COL_AMBER 0xFD20
#define COL_DIM 0x8280
#define COL_RED 0xF800
#define COL_GREEN 0x07E0

// ----------------------------------------------------------------- Layout
#define ICON_X 6
#define ICON_Y 6
#define ICON_SIZE 140
#define SIGNAL_TIMEOUT_MS 5000

struct NavData {
  int spd;
  char turn[8];
  int dist;
  char street[32];
  long rem;
  int eta;
};

// Punkt im Symbol-Feld (muss vor der ersten Funktion stehen, siehe Arduino-IDE 1.8)
struct Pt {
  int16_t x, y;
};

// ---------------------------------------------- Zeilenpuffer (BLE-Task)
// Der BLE-Callback laeuft in einem eigenen Task. Er sammelt nur Bytes und
// legt fertige Zeilen ab; gezeichnet wird ausschliesslich in loop().
static const size_t LINE_BUF_SIZE = 256;
static char lineBuf[LINE_BUF_SIZE];
static size_t lineLen = 0;
static bool lineOverflow = false;

static char pending[LINE_BUF_SIZE];
static volatile bool pendingReady = false;
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

static volatile bool clientConnected = false;

// ------------------------------------------------------------- Zustand
enum Screen { SCR_NONE, SCR_WAIT_CLIENT, SCR_WAIT_DATA, SCR_NAV };
static Screen screen = SCR_NONE;
static bool haveData = false;
static bool stale = false;
static unsigned long lastMsgMs = 0;
static unsigned long goodCount = 0;
static unsigned long badCount = 0;

static bool demoActive = false;
static unsigned long demoNextMs = 0;
static int demoIndex = 0;

// Zuletzt gezeichnete Texte, damit nur Geaendertes neu gezeichnet wird.
static char shownTurn[8];
static char shownDist[24];
static char shownStreet[40];
static char shownSpeed[8];
static char shownRem[24];
static char shownEta[24];
static NavData lastData;
static bool lastDataValid = false;

// ------------------------------------------------------------ Hilfsfunktionen
void feedByte(char c) {
  if (c == '\r') return;
  if (c == '\n') {
    if (!lineOverflow && lineLen > 0) {
      portENTER_CRITICAL(&mux);
      memcpy(pending, lineBuf, lineLen);
      pending[lineLen] = 0;
      pendingReady = true;
      portEXIT_CRITICAL(&mux);
    }
    lineLen = 0;
    lineOverflow = false;
    return;
  }
  if (lineLen < LINE_BUF_SIZE - 1) {
    lineBuf[lineLen++] = c;
  } else {
    lineOverflow = true;  // zu lange Zeile: bis zum naechsten Zeilenende verwerfen
  }
}

// Distanz als Text: "850 m", "12.4 km", ab 100 km "123 km" (max. 7 Zeichen bei
// Wegstrecken bis 99.9 km, sonst kuerzer).
void formatDistance(long m, char* out, size_t n) {
  if (m < 0) m = 0;
  if (m < 1000) snprintf(out, n, "%ld m", m);
  else if (m < 100000) snprintf(out, n, "%ld.%ld km", m / 1000, (m % 1000) / 100);
  else snprintf(out, n, "%ld km", m / 1000);
}

void formatEta(int minutes, char* out, size_t n) {
  if (minutes < 0) minutes = 0;
  if (minutes < 60) snprintf(out, n, "%d min", minutes);
  else snprintf(out, n, "%dh%02d", minutes / 60, minutes % 60);
}

// Zeichnet [text] links ausgerichtet, aufgefuellt auf [width] Zeichen, und nur
// dann, wenn sich der Text seit dem letzten Mal geaendert hat.
void field(int x, int y, uint8_t size, uint16_t fg, char* last, size_t lastSize,
           const char* text, uint8_t width) {
  char buf[48];
  snprintf(buf, sizeof(buf), "%-*.*s", (int)width, (int)width, text);
  if (strcmp(buf, last) == 0) return;
  tft.setTextSize(size);
  tft.setTextColor(fg, COL_BG);
  tft.setCursor(x, y);
  tft.print(buf);
  strlcpy(last, buf, lastSize);
}

// ------------------------------------------------------------- Symbole
static int mx(int x, bool mirror) { return mirror ? ICON_SIZE - x : x; }

static void thickLine(int x0, int y0, int x1, int y1, int w, uint16_t c) {
  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  if (len < 1) {
    tft.fillCircle(x0, y0, w / 2, c);
    return;
  }
  float nx = -dy / len * (w / 2.0f), ny = dx / len * (w / 2.0f);
  tft.fillTriangle((int16_t)(x0 + nx), (int16_t)(y0 + ny), (int16_t)(x0 - nx), (int16_t)(y0 - ny),
                   (int16_t)(x1 + nx), (int16_t)(y1 + ny), c);
  tft.fillTriangle((int16_t)(x0 - nx), (int16_t)(y0 - ny), (int16_t)(x1 - nx), (int16_t)(y1 - ny),
                   (int16_t)(x1 + nx), (int16_t)(y1 + ny), c);
  tft.fillCircle(x0, y0, w / 2, c);
  tft.fillCircle(x1, y1, w / 2, c);
}

static void arrowHead(int tipx, int tipy, float dx, float dy, int len, int half, uint16_t c) {
  float l = sqrtf(dx * dx + dy * dy);
  if (l < 0.001f) return;
  dx /= l;
  dy /= l;
  float bx = tipx - dx * len, by = tipy - dy * len;
  float px = -dy * half, py = dx * half;
  tft.fillTriangle(tipx, tipy, (int16_t)(bx + px), (int16_t)(by + py), (int16_t)(bx - px),
                   (int16_t)(by - py), c);
}

// Linienzug mit Pfeilspitze am letzten Punkt (Koordinaten im 140x140-Feld).
static void drawArrow(const Pt* p, uint8_t n, bool mirror) {
  const int W = 22, HEAD_LEN = 38, HEAD_HALF = 28;
  float dx = mx(p[n - 1].x, mirror) - mx(p[n - 2].x, mirror);
  float dy = p[n - 1].y - p[n - 2].y;
  float l = sqrtf(dx * dx + dy * dy);
  float ux = dx / l, uy = dy / l;
  for (uint8_t i = 0; i + 1 < n; i++) {
    int x0 = ICON_X + mx(p[i].x, mirror), y0 = ICON_Y + p[i].y;
    int x1 = ICON_X + mx(p[i + 1].x, mirror), y1 = ICON_Y + p[i + 1].y;
    if (i + 2 == n) {  // letztes Stueck endet mitten in der Spitze
      x1 -= (int)(ux * HEAD_LEN * 0.5f);
      y1 -= (int)(uy * HEAD_LEN * 0.5f);
    }
    thickLine(x0, y0, x1, y1, W, COL_AMBER);
  }
  arrowHead(ICON_X + mx(p[n - 1].x, mirror), ICON_Y + p[n - 1].y, ux, uy, HEAD_LEN, HEAD_HALF, COL_AMBER);
}

static void drawRoundabout(int exitNo) {
  const int cx = ICON_X + 70, cy = ICON_Y + 64, r = 30;
  tft.fillCircle(cx, cy, r, COL_AMBER);
  tft.fillCircle(cx, cy, r - 11, COL_BG);
  thickLine(cx, ICON_Y + 134, cx, cy + r - 2, 12, COL_AMBER);  // Einfahrt von unten
  // Ausfahrt: 1 = rechts, 2 = geradeaus, 3 = links, 4 = zurueck (schraeg unten links)
  int sx, sy, ex, ey;
  switch (exitNo) {
    case 1: sx = cx + r; sy = cy; ex = cx + r + 34; ey = cy; break;
    case 2: sx = cx; sy = cy - r; ex = cx; ey = cy - r - 34; break;
    case 3: sx = cx - r; sy = cy; ex = cx - r - 34; ey = cy; break;
    default: sx = cx - 21; sy = cy + 21; ex = cx - 21 - 26; ey = cy + 21 + 26; break;
  }
  float dx = ex - sx, dy = ey - sy;
  float l = sqrtf(dx * dx + dy * dy);
  thickLine(sx, sy, ex - (int)(dx / l * 10), ey - (int)(dy / l * 10), 14, COL_AMBER);
  arrowHead(ex, ey, dx, dy, 22, 16, COL_AMBER);
  tft.setTextSize(2);
  tft.setTextColor(COL_AMBER, COL_BG);
  tft.setCursor(cx - 5, cy - 7);
  tft.print(exitNo);
}

static void drawFlag() {
  tft.fillRect(ICON_X + 34, ICON_Y + 8, 8, 124, COL_AMBER);
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 4; col++) {
      uint16_t c = ((row + col) % 2 == 0) ? COL_AMBER : COL_DIM;
      tft.fillRect(ICON_X + 42 + col * 22, ICON_Y + 8 + row * 22, 22, 22, c);
    }
  }
}

static void drawTurnIcon(const char* code) {
  tft.fillRect(ICON_X, ICON_Y, ICON_SIZE, ICON_SIZE, COL_BG);
  static const Pt P_STRAIGHT[] = {{70, 134}, {70, 30}};
  static const Pt P_LEFT[] = {{98, 134}, {98, 72}, {26, 72}};
  static const Pt P_SLIGHT[] = {{86, 134}, {86, 92}, {40, 46}};
  static const Pt P_UTURN[] = {{104, 134}, {104, 52}, {88, 30}, {52, 30}, {36, 52}, {36, 112}};

  if (!strcmp(code, "S")) drawArrow(P_STRAIGHT, 2, false);
  else if (!strcmp(code, "L")) drawArrow(P_LEFT, 3, false);
  else if (!strcmp(code, "R")) drawArrow(P_LEFT, 3, true);
  else if (!strcmp(code, "SL")) drawArrow(P_SLIGHT, 3, false);
  else if (!strcmp(code, "SR")) drawArrow(P_SLIGHT, 3, true);
  else if (!strcmp(code, "U")) drawArrow(P_UTURN, 6, false);
  else if (!strncmp(code, "ROUND", 5)) drawRoundabout(constrain(atoi(code + 5), 1, 4));
  else if (!strcmp(code, "ARR")) drawFlag();
  else {
    tft.setTextSize(8);
    tft.setTextColor(COL_AMBER, COL_BG);
    tft.setCursor(ICON_X + 40, ICON_Y + 40);
    tft.print("?");
  }
}

// --------------------------------------------------------------- Bildschirme
static void resetShown() {
  shownTurn[0] = 0;
  shownDist[0] = 0;
  shownStreet[0] = 0;
  shownSpeed[0] = 0;
  shownRem[0] = 0;
  shownEta[0] = 0;
}

static void centerText(const char* text, int y, uint8_t size, uint16_t color) {
  int16_t w = strlen(text) * 6 * size;
  tft.setTextSize(size);
  tft.setTextColor(color, COL_BG);
  tft.setCursor((tft.width() - w) / 2, y);
  tft.print(text);
}

static void switchScreen(Screen next) {
  screen = next;
  tft.fillScreen(COL_BG);
  resetShown();
  stale = false;
  switch (next) {
    case SCR_WAIT_CLIENT:
      centerText("RETRO NAVI", 70, 4, COL_AMBER);
      centerText("Warte auf App ...", 130, 2, COL_DIM);
      centerText(BLE_NAME, 170, 2, COL_DIM);
      break;
    case SCR_WAIT_DATA:
      centerText("VERBUNDEN", 70, 4, COL_GREEN);
      centerText("Warte auf Navigation ...", 130, 2, COL_DIM);
      break;
    case SCR_NAV:
      tft.drawFastHLine(0, 188, 320, COL_DIM);
      tft.setTextSize(2);
      tft.setTextColor(COL_DIM, COL_BG);
      tft.setCursor(92, 212);
      tft.print("km/h");
      break;
    default:
      break;
  }
}

static void drawNav(const NavData& d) {
  if (screen != SCR_NAV) switchScreen(SCR_NAV);

  if (strcmp(d.turn, shownTurn) != 0) {
    drawTurnIcon(d.turn);
    strlcpy(shownTurn, d.turn, sizeof(shownTurn));
  }

  char buf[32];
  formatDistance(d.dist, buf, sizeof(buf));
  field(150, 52, 4, COL_AMBER, shownDist, sizeof(shownDist), buf, 7);

  if (stale) field(8, 156, 3, COL_RED, shownStreet, sizeof(shownStreet), "KEIN SIGNAL", 17);
  else field(8, 156, 3, COL_AMBER, shownStreet, sizeof(shownStreet), d.street, 17);

  snprintf(buf, sizeof(buf), "%d", d.spd);
  field(8, 198, 4, COL_AMBER, shownSpeed, sizeof(shownSpeed), buf, 3);

  formatDistance(d.rem, buf, sizeof(buf));
  field(176, 196, 2, COL_AMBER, shownRem, sizeof(shownRem), buf, 9);

  formatEta(d.eta, buf, sizeof(buf));
  field(176, 218, 2, COL_AMBER, shownEta, sizeof(shownEta), buf, 9);
}

// -------------------------------------------------------------- Auswertung
static void handleLine(const char* line) {
  Serial.printf("RX: %s\n", line);
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, line);
  if (err) {
    badCount++;
    Serial.printf("JSON-Fehler: %s\n", err.c_str());
    return;
  }
  NavData d;
  d.spd = doc["spd"] | 0;
  strlcpy(d.turn, doc["turn"] | "S", sizeof(d.turn));
  d.dist = doc["dist"] | 0;
  strlcpy(d.street, doc["street"] | "", sizeof(d.street));
  d.rem = doc["rem"] | 0L;
  d.eta = doc["eta"] | 0;

  goodCount++;
  haveData = true;
  lastMsgMs = millis();
  lastData = d;
  lastDataValid = true;
  stale = false;
  drawNav(d);
}

// ------------------------------------------------------------------- BLE
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    lineLen = 0;
    lineOverflow = false;
    clientConnected = true;
  }
  void onDisconnect(BLEServer* server) override {
    clientConnected = false;
    lineLen = 0;
    lineOverflow = false;
    BLEDevice::startAdvertising();  // wieder sichtbar fuer die App
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    auto v = c->getValue();  // je nach Board-Paket std::string oder String
    for (size_t i = 0; i < v.length(); i++) feedByte((char)v[i]);
  }
};

static void startBle() {
  BLEDevice::init(BLE_NAME);
  BLEDevice::setMTU(247);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);
  BLECharacteristic* rx = service->createCharacteristic(
      RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCallbacks());
  BLECharacteristic* tx = service->createCharacteristic(TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  tx->addDescriptor(new BLE2902());
  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.printf("BLE bereit. Name: %s  Adresse: %s\n", BLE_NAME,
                BLEDevice::getAddress().toString().c_str());
}

// ------------------------------------------------------------------- Demo
static const char* const DEMO[] = {
  "{\"spd\":0,\"turn\":\"S\",\"dist\":850,\"street\":\"Hauptstr\",\"rem\":12400,\"eta\":18}",
  "{\"spd\":47,\"turn\":\"L\",\"dist\":320,\"street\":\"Bahnhofstr\",\"rem\":12080,\"eta\":17}",
  "{\"spd\":52,\"turn\":\"R\",\"dist\":150,\"street\":\"Am Markt\",\"rem\":11200,\"eta\":16}",
  "{\"spd\":60,\"turn\":\"SL\",\"dist\":900,\"street\":\"Landstr\",\"rem\":9800,\"eta\":14}",
  "{\"spd\":60,\"turn\":\"SR\",\"dist\":1200,\"street\":\"Ringstr\",\"rem\":8600,\"eta\":12}",
  "{\"spd\":35,\"turn\":\"U\",\"dist\":80,\"street\":\"Waldweg\",\"rem\":7000,\"eta\":10}",
  "{\"spd\":40,\"turn\":\"ROUND1\",\"dist\":200,\"street\":\"Kreisel\",\"rem\":6000,\"eta\":9}",
  "{\"spd\":40,\"turn\":\"ROUND2\",\"dist\":120,\"street\":\"Kreisel\",\"rem\":5800,\"eta\":8}",
  "{\"spd\":40,\"turn\":\"ROUND3\",\"dist\":60,\"street\":\"Kreisel\",\"rem\":5600,\"eta\":8}",
  "{\"spd\":40,\"turn\":\"ROUND4\",\"dist\":30,\"street\":\"Kreisel\",\"rem\":5400,\"eta\":7}",
  "{\"spd\":120,\"turn\":\"S\",\"dist\":45300,\"street\":\"A 8\",\"rem\":182000,\"eta\":95}",
  "{\"spd\":30,\"turn\":\"ARR\",\"dist\":0,\"street\":\"Ziel\",\"rem\":0,\"eta\":0}"
};
static const int DEMO_COUNT = sizeof(DEMO) / sizeof(DEMO[0]);

static void handleSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == 'd' || c == 'D') {
      demoActive = !demoActive;
      demoIndex = 0;
      demoNextMs = 0;
      screen = SCR_NONE;  // Bildschirm neu aufbauen
      Serial.println(demoActive ? "Demo AN" : "Demo AUS");
    }
  }
}

// Helligkeit per PWM. analogWrite() gibt es erst ab Board-Paket 3.x; fuer 2.x
// (z. B. 2.0.14) wird der LEDC-Timer direkt benutzt.
static void setBacklight(uint8_t level) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  pinMode(BACKLIGHT_PIN, OUTPUT);
  analogWrite(BACKLIGHT_PIN, level);
#else
  ledcSetup(0, 5000, 8);
  ledcAttachPin(BACKLIGHT_PIN, 0);
  ledcWrite(0, level);
#endif
}

// ------------------------------------------------------------------ Arduino
void setup() {
  Serial.begin(115200);
  tft.begin();
  tft.setRotation(3);
  tft.fillScreen(COL_BG);
  setBacklight(BACKLIGHT_LEVEL);

  resetShown();
  startBle();
  switchScreen(SCR_WAIT_CLIENT);
}

void loop() {
  handleSerial();

  if (demoActive && millis() >= demoNextMs) {
    handleLine(DEMO[demoIndex]);
    demoIndex = (demoIndex + 1) % DEMO_COUNT;
    demoNextMs = millis() + 2500;
  }

  if (pendingReady) {
    char tmp[LINE_BUF_SIZE];
    portENTER_CRITICAL(&mux);
    memcpy(tmp, pending, LINE_BUF_SIZE);
    pendingReady = false;
    portEXIT_CRITICAL(&mux);
    handleLine(tmp);
  }

  const bool connected = clientConnected || demoActive;

  if (!connected) {
    haveData = false;
    lastDataValid = false;
    if (screen != SCR_WAIT_CLIENT) switchScreen(SCR_WAIT_CLIENT);
  } else if (!haveData) {
    if (screen != SCR_WAIT_DATA) switchScreen(SCR_WAIT_DATA);
  } else if (screen == SCR_NAV && lastDataValid) {
    bool nowStale = (millis() - lastMsgMs) > SIGNAL_TIMEOUT_MS;
    if (nowStale != stale) {
      stale = nowStale;
      drawNav(lastData);
    }
  }
  delay(5);
}
