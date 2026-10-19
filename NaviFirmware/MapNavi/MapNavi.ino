/*
  Retro Navi - ESP32 Sketch (Stufe 1: Kartenansicht)
  Empfaengt die Navigationsdaten der App per Bluetooth (BLE) und zeigt sie
  auf einem ILI9341-Display (320x240, Querformat) im Amber-auf-Schwarz-Stil an:

    - MIT Kartendaten: Kartenausschnitt (Fahrtrichtung nach oben) mit dick
      gezeichneter Route, Fahrzeugsymbol, kleinem Abbiegesymbol samt Distanz
      oben links, Strassenname oben, Tempo / Restweg / Restzeit unten.
    - OHNE Kartendaten (aeltere App, Kartenansicht in der App aus, Chunk
      verloren): wie bisher grosser Abbiegepfeil.

  Protokoll (muss zur App passen):
    Service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E   (Nordic UART)
    RX-Char. 6E400002-...  (App schreibt, Write / Write Without Response)
    Nachricht = ein JSON-Objekt + "\n"

    1) Navigation (jede Sekunde)
       {"spd":47,"turn":"L","dist":320,"street":"Hauptstr","rem":12400,"eta":18,
        "m":3,"x":12.3,"y":-45,"h":87,"z":240,"i":14}
       turn: S, L, R, SL, SR, U, ROUND1-4, ARR
       dist/rem in Metern, eta in Minuten, spd in km/h
       Kartenfelder (optional): m = Chunk-Kennung, x/y = Fahrzeugposition in
       Metern (x Ost, y Nord, im System des Chunks), h = Fahrtrichtung in Grad
       (0 = Nord), z = Sichtweite nach vorn in Metern, i = Index des ersten
       Streckenpunkts vor dem Fahrzeug.

    2) Kartenstueck (alle paar Sekunden / bei Bedarf)
       {"t":"map","id":3,"e":0,"r":[x0,y0,x1,y1,...]}
       r = Streckenpunkte in ganzen Metern, e = 1 wenn der letzte Punkt das
       Ziel ist.

  Benoetigt (Arduino-IDE, Bibliotheksverwaltung):
    - Adafruit GFX Library
    - Adafruit ILI9341
    - ArduinoJson (Version 7.x)
    - Board-Paket "esp32" von Espressif (BLE ist darin enthalten)

  Arduino-IDE-Einstellungen:
    ESP32 klassisch:  Board "ESP32 Dev Module",
                      Partition Scheme "Huge APP (3MB No OTA/1MB SPIFFS)"
    XIAO ESP32S3:     Board "XIAO_ESP32S3",
                      USB CDC On Boot: "Enabled" (sonst kein Serieller Monitor),
                      PSRAM: "Disabled" (der Kartenpuffer soll im schnellen internen RAM liegen),
                      Partition Scheme: eines mit mindestens 3 MB App, z. B. "8M with spiffs (3MB APP/1.5MB SPIFFS)"

  Speicher: Die Karte wird in einem Puffer im RAM (320x240, 1 Byte/Pixel =
  ca. 77 kB) gezeichnet und auf einmal an das Display geschickt (kein
  Flackern). Der Puffer wird VOR dem Bluetooth-Start angelegt. Klappt das
  nicht, steht es im Seriellen Monitor und es bleibt beim Pfeil.

  Display: laeuft jetzt ueber Hardware-SPI (deine Pins, 27 MHz). Wenn das Bild
  Fehler zeigt (Rauschen, falsche Farben), TFT_SPI_HZ verkleinern, z. B. auf
  16000000. Geht es stabil, kann man auf 40000000 erhoehen.

  Test ohne App (Seriellen Monitor, 115200 Baud):
    'd'  Demo durch alle Abbiegesymbole (Pfeil-Ansicht). Nochmal 'd' beendet.
    'm'  Demo-Fahrt auf einer eingebauten Strecke mit Kartenansicht.
         Nochmal 'm' beendet.
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
// Pins: automatisch passend zum gewaehlten Board.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
// Seeed XIAO ESP32S3 (Beschriftung auf der Platine in Klammern):
#define TFT_SCK 7          // D8
#define TFT_MISO 8         // D9  (nur angeschlossen, der Sketch liest nichts vom Display)
#define TFT_MOSI 9         // D10
#define TFT_DC 4           // D3
#define TFT_CS 5           // D4
#define TFT_RESET 6        // D5
#define TFT_LED 1          // D0 - Hintergrundbeleuchtung (PWM)
#define BACKLIGHT_PIN TFT_LED
#else
// Klassischer ESP32 (Pins wie in deinem Display-Testskript):
#define TFT_MISO 25
#define TFT_LED 5          // in deinem Skript definiert, hier ungenutzt
#define TFT_SCK 19
#define TFT_MOSI 23
#define TFT_DC 21
#define TFT_RESET 18
#define TFT_CS 22
#define BACKLIGHT_PIN 16   // wie in deinem Skript (PWM)
#endif
#define BACKLIGHT_LEVEL 5  // 0-255, wie in deinem Skript; hoeher = heller
#define TFT_SPI_HZ 27000000

#define SCREEN_W 320
#define SCREEN_H 240

// Hardware-SPI auf frei gewaehlten Pins (ESP32 legt sie ueber die GPIO-Matrix).
Adafruit_ILI9341 tft = Adafruit_ILI9341(&SPI, TFT_DC, TFT_CS, TFT_RESET);

// ------------------------------------------------------------------- BLE
#define BLE_NAME "RetroNavi"
#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define TX_UUID "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ---------------------------------------------------------------- Farben
// Direkte RGB565-Farben (Pfeil-Ansicht, Textbildschirme):
#define COL_BG 0x0000
#define COL_AMBER 0xFD20
#define COL_DIM 0x8280
#define COL_RED 0xF800
#define COL_GREEN 0x07E0

// Palette des Kartenpuffers (1 Byte pro Pixel = Index in diese Tabelle):
#define PAL_BG 0
#define PAL_SIDE 1     // Nebenstrassen (Stufe 2)
#define PAL_MAIN 2     // Hauptstrassen (Stufe 2)
#define PAL_PASSED 3   // schon gefahrener Teil der Route
#define PAL_ROUTE 4    // Route voraus
#define PAL_CAR 5      // Fahrzeug
#define PAL_TEXT 6
#define PAL_DIM 7
#define PAL_RED 8
#define PAL_GREEN 9

static const uint16_t PALETTE[16] = {
  0x0000,  // PAL_BG
  0x2945,  // PAL_SIDE
  0x6B6D,  // PAL_MAIN
  0x5200,  // PAL_PASSED
  0xFD20,  // PAL_ROUTE
  0xFFFF,  // PAL_CAR
  0xFD20,  // PAL_TEXT
  0x8280,  // PAL_DIM
  0xF800,  // PAL_RED
  0x07E0,  // PAL_GREEN
  0, 0, 0, 0, 0, 0
};

// ----------------------------------------------------------------- Layout
#define ICON_X 6
#define ICON_Y 6
#define ICON_SIZE 140
#define SIGNAL_TIMEOUT_MS 5000

// Kartenansicht
#define MAP_MX 160          // Fahrzeug auf dem Display
#define MAP_MY 176
#define MAP_TOP 22          // hier endet die "Sichtweite nach vorn"
#define PANEL_W 94          // Abbiege-Feld oben links
#define PANEL_H 76
#define BAR_H 20            // Strassenname oben
#define STRIP_Y 214         // Statusleiste unten
#define ROUTE_W 7
#define CASING_W 11
#define PASSED_W 3
#define MAX_ROUTE_PTS 128
#define MAX_RD_PTS 2600    // Punkte aller Nebenstrassen-Abschnitte
#define MAX_RD_RUNS 400    // Abschnitte

// ------------------------------------------------------------------ Typen
// Alle Typen stehen VOR der ersten Funktion (Arduino-IDE 1.8 erzeugt die
// Funktions-Prototypen automatisch vor der ersten Funktion).
struct NavData {
  int spd;
  char turn[8];
  int dist;
  char street[32];
  long rem;
  int eta;
};

// Punkt im Symbol-Feld
struct Pt {
  int16_t x, y;
};

// Fahrzeugzustand im Koordinatensystem des Chunks
struct PoseData {
  bool valid;
  int id;
  float x, y;
  int h;
  int z;
  int idx;
};

// Zeichenziel fuer Abbiegesymbole: Display oder Kartenpuffer, mit Massstab.
// Alle Symbolkoordinaten sind fuer ein 140x140-Feld definiert (s = size/140).
struct IconCtx {
  Adafruit_GFX* g;
  int ox, oy;
  float s;
  uint16_t fg, bg, dim;
};

// Nebenstrassen: viele kurze Linienzuege. Zwei Saetze (einer wird gezeichnet,
// im anderen wird die naechste Ausgabe zusammengesetzt; Umschalten erst, wenn
// alles da ist).
struct RoadSet {
  int16_t x[MAX_RD_PTS];
  int16_t y[MAX_RD_PTS];
  uint16_t start[MAX_RD_RUNS + 1];  // erster Punkt jedes Abschnitts
  uint8_t cls[MAX_RD_RUNS];         // 1 Neben-, 2 Hauptstrasse
  int runs;
  int pts;
};

// Sicht auf die Karte (Drehung + Massstab)
struct View {
  float sinH, cosH, sc, cx, cy;
};

// ---------------------------------------------- Zeilenpuffer (BLE-Task)
// Der BLE-Callback laeuft in einem eigenen Task. Er sammelt Bytes direkt in
// einem Ringpuffer aus mehreren Zeilen-Plaetzen; gezeichnet wird nur in loop().
// Mehrere Plaetze, weil Kartenstueck und Navigation kurz nacheinander kommen.
#define LINE_BUF_SIZE 1536
#define RING_SLOTS 4
static char ring[RING_SLOTS][LINE_BUF_SIZE];
static volatile uint8_t ringHead = 0;  // hier schreibt der BLE-Task
static volatile uint8_t ringTail = 0;  // hier liest loop()
static size_t lineLen = 0;
static bool lineOverflow = false;
static unsigned long droppedLines = 0;
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

static volatile bool clientConnected = false;

// ------------------------------------------------------------- Zustand
enum Screen { SCR_NONE, SCR_WAIT_CLIENT, SCR_WAIT_DATA, SCR_NAV, SCR_MAP };
static Screen screen = SCR_NONE;
static bool haveData = false;
static bool stale = false;
static unsigned long lastMsgMs = 0;
static unsigned long goodCount = 0;
static unsigned long badCount = 0;

static bool demoActive = false;
static unsigned long demoNextMs = 0;
static int demoIndex = 0;

// Zuletzt gezeichnete Texte der Pfeil-Ansicht (nur Geaendertes neu zeichnen).
static char shownTurn[8];
static char shownDist[24];
static char shownStreet[40];
static char shownSpeed[8];
static char shownRem[24];
static char shownEta[24];
static NavData lastData;
static PoseData lastPose;
static bool lastDataValid = false;

// Kartenpuffer und aktuelles Kartenstueck
static GFXcanvas8* canvas = nullptr;
static uint16_t flushBuf[SCREEN_W * 8];
static int16_t routeX[MAX_ROUTE_PTS];
static int16_t routeY[MAX_ROUTE_PTS];
static int routeN = 0;
static int chunkId = -1;
static bool chunkEnd = false;
static bool chunkValid = false;
static int chunkFrame = 0;  // Koordinatensystem des Chunks (0 = unbekannt)

// Nebenstrassen
static RoadSet roadSetA, roadSetB;
static RoadSet* rdActive = &roadSetA;
static RoadSet* rdStage = &roadSetB;
static bool rdStageValid = false;
static int rdStageGen = 0;
static int rdStageNext = 0;
static bool rdShow = false;  // aktiver Satz gehoert zum aktuellen Koordinatensystem

// Demo-Fahrt
static bool mapDemoActive = false;
static unsigned long mapDemoLastMs = 0;
static float mapDemoAlong = 0;

// ------------------------------------------------------------ Hilfsfunktionen
void feedByte(char c) {
  if (c == '\r') return;
  if (c == '\n') {
    if (!lineOverflow && lineLen > 0) {
      uint8_t next = (ringHead + 1) % RING_SLOTS;
      if (next != ringTail) {
        ring[ringHead][lineLen] = 0;
        portENTER_CRITICAL(&mux);
        ringHead = next;
        portEXIT_CRITICAL(&mux);
      } else {
        droppedLines++;  // loop() kommt nicht hinterher
      }
    }
    lineLen = 0;
    lineOverflow = false;
    return;
  }
  if (lineLen < LINE_BUF_SIZE - 1) {
    ring[ringHead][lineLen++] = c;
  } else {
    lineOverflow = true;  // zu lange Zeile: bis zum naechsten Zeilenende verwerfen
  }
}

// Distanz als Text: "850 m", "12.4 km", ab 100 km "123 km".
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

// ------------------------------------------------------- Zeichenwerkzeuge
// Alles laeuft ueber Adafruit_GFX&, damit es auf dem Display UND im
// Kartenpuffer funktioniert.
static void thickLineG(Adafruit_GFX& g, float fx0, float fy0, float fx1, float fy1, int w,
                       uint16_t c) {
  int x0 = (int)lroundf(fx0), y0 = (int)lroundf(fy0);
  int x1 = (int)lroundf(fx1), y1 = (int)lroundf(fy1);
  if (w < 1) w = 1;
  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  if (len < 1 || w == 1) {
    if (w == 1) g.drawLine(x0, y0, x1, y1, c);
    else g.fillCircle(x0, y0, w / 2, c);
    return;
  }
  float nx = -dy / len * (w / 2.0f), ny = dx / len * (w / 2.0f);
  g.fillTriangle((int16_t)(x0 + nx), (int16_t)(y0 + ny), (int16_t)(x0 - nx), (int16_t)(y0 - ny),
                 (int16_t)(x1 + nx), (int16_t)(y1 + ny), c);
  g.fillTriangle((int16_t)(x0 - nx), (int16_t)(y0 - ny), (int16_t)(x1 - nx), (int16_t)(y1 - ny),
                 (int16_t)(x1 + nx), (int16_t)(y1 + ny), c);
  g.fillCircle(x0, y0, w / 2, c);
  g.fillCircle(x1, y1, w / 2, c);
}

static void arrowHeadG(Adafruit_GFX& g, float tipx, float tipy, float dx, float dy, float len,
                       float half, uint16_t c) {
  float l = sqrtf(dx * dx + dy * dy);
  if (l < 0.001f) return;
  dx /= l;
  dy /= l;
  float bx = tipx - dx * len, by = tipy - dy * len;
  float px = -dy * half, py = dx * half;
  g.fillTriangle((int16_t)lroundf(tipx), (int16_t)lroundf(tipy), (int16_t)lroundf(bx + px),
                 (int16_t)lroundf(by + py), (int16_t)lroundf(bx - px), (int16_t)lroundf(by - py), c);
}

// ------------------------------------------------------------- Symbole
// Symbolkoordinaten (u, v) liegen im 140x140-Feld; IconCtx rechnet in Pixel um.
static float icx(const IconCtx& c, float u) { return c.ox + u * c.s; }
static float icy(const IconCtx& c, float v) { return c.oy + v * c.s; }

static void iconLine(const IconCtx& c, float u0, float v0, float u1, float v1, float w) {
  int pw = (int)lroundf(w * c.s);
  thickLineG(*c.g, icx(c, u0), icy(c, v0), icx(c, u1), icy(c, v1), pw < 1 ? 1 : pw, c.fg);
}

static void iconHead(const IconCtx& c, float u, float v, float du, float dv, float len, float half) {
  arrowHeadG(*c.g, icx(c, u), icy(c, v), du, dv, len * c.s, half * c.s, c.fg);
}

static void iconRect(const IconCtx& c, float u, float v, float w, float h, uint16_t col) {
  int x0 = (int)lroundf(icx(c, u)), x1 = (int)lroundf(icx(c, u + w));
  int y0 = (int)lroundf(icy(c, v)), y1 = (int)lroundf(icy(c, v + h));
  c.g->fillRect(x0, y0, x1 - x0, y1 - y0, col);
}

static float mirrorU(float u, bool mirror) { return mirror ? ICON_SIZE - u : u; }

// Linienzug mit Pfeilspitze am letzten Punkt.
static void drawArrowIcon(const IconCtx& c, const Pt* p, uint8_t n, bool mirror) {
  const float W = 22, HEAD_LEN = 38, HEAD_HALF = 28;
  float dx = mirrorU(p[n - 1].x, mirror) - mirrorU(p[n - 2].x, mirror);
  float dy = p[n - 1].y - p[n - 2].y;
  float l = sqrtf(dx * dx + dy * dy);
  float ux = dx / l, uy = dy / l;
  for (uint8_t i = 0; i + 1 < n; i++) {
    float x0 = mirrorU(p[i].x, mirror), y0 = p[i].y;
    float x1 = mirrorU(p[i + 1].x, mirror), y1 = p[i + 1].y;
    if (i + 2 == n) {  // letztes Stueck endet mitten in der Spitze
      x1 -= ux * HEAD_LEN * 0.5f;
      y1 -= uy * HEAD_LEN * 0.5f;
    }
    iconLine(c, x0, y0, x1, y1, W);
  }
  iconHead(c, mirrorU(p[n - 1].x, mirror), p[n - 1].y, ux, uy, HEAD_LEN, HEAD_HALF);
}

static void drawRoundaboutIcon(const IconCtx& c, int exitNo) {
  const float cx = 70, cy = 64, r = 30;
  c.g->fillCircle((int16_t)lroundf(icx(c, cx)), (int16_t)lroundf(icy(c, cy)),
                  (int16_t)lroundf(r * c.s), c.fg);
  c.g->fillCircle((int16_t)lroundf(icx(c, cx)), (int16_t)lroundf(icy(c, cy)),
                  (int16_t)lroundf((r - 11) * c.s), c.bg);
  iconLine(c, cx, 134, cx, cy + r - 2, 12);  // Einfahrt von unten
  // Ausfahrt: 1 = rechts, 2 = geradeaus, 3 = links, 4 = zurueck (schraeg unten links)
  float sx, sy, ex, ey;
  switch (exitNo) {
    case 1: sx = cx + r; sy = cy; ex = cx + r + 34; ey = cy; break;
    case 2: sx = cx; sy = cy - r; ex = cx; ey = cy - r - 34; break;
    case 3: sx = cx - r; sy = cy; ex = cx - r - 34; ey = cy; break;
    default: sx = cx - 21; sy = cy + 21; ex = cx - 21 - 26; ey = cy + 21 + 26; break;
  }
  float dx = ex - sx, dy = ey - sy;
  float l = sqrtf(dx * dx + dy * dy);
  iconLine(c, sx, sy, ex - dx / l * 10, ey - dy / l * 10, 14);
  iconHead(c, ex, ey, dx, dy, 22, 16);
  int ts = c.s >= 0.6f ? 2 : 1;
  c.g->setTextSize(ts);
  c.g->setTextColor(c.fg, c.bg);
  c.g->setCursor((int16_t)lroundf(icx(c, cx)) - 3 * ts + 1, (int16_t)lroundf(icy(c, cy)) - 4 * ts + 1);
  c.g->print(exitNo);
}

static void drawFlagIcon(const IconCtx& c) {
  iconRect(c, 34, 8, 8, 124, c.fg);
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 4; col++) {
      uint16_t color = ((row + col) % 2 == 0) ? c.fg : c.dim;
      iconRect(c, 42 + col * 22, 8 + row * 22, 22, 22, color);
    }
  }
}

// Zeichnet das Symbol fuer [code] in das Ziel von [c]. Das Feld wird vorher
// vom Aufrufer geleert.
static void drawTurnIcon(const IconCtx& c, const char* code) {
  static const Pt P_STRAIGHT[] = {{70, 134}, {70, 30}};
  static const Pt P_LEFT[] = {{98, 134}, {98, 72}, {26, 72}};
  static const Pt P_SLIGHT[] = {{86, 134}, {86, 92}, {40, 46}};
  static const Pt P_UTURN[] = {{104, 134}, {104, 52}, {88, 30}, {52, 30}, {36, 52}, {36, 112}};

  if (!strcmp(code, "S")) drawArrowIcon(c, P_STRAIGHT, 2, false);
  else if (!strcmp(code, "L")) drawArrowIcon(c, P_LEFT, 3, false);
  else if (!strcmp(code, "R")) drawArrowIcon(c, P_LEFT, 3, true);
  else if (!strcmp(code, "SL")) drawArrowIcon(c, P_SLIGHT, 3, false);
  else if (!strcmp(code, "SR")) drawArrowIcon(c, P_SLIGHT, 3, true);
  else if (!strcmp(code, "U")) drawArrowIcon(c, P_UTURN, 6, false);
  else if (!strncmp(code, "ROUND", 5)) drawRoundaboutIcon(c, constrain(atoi(code + 5), 1, 4));
  else if (!strcmp(code, "ARR")) drawFlagIcon(c);
  else {
    int ts = (int)lroundf(8 * c.s);
    if (ts < 1) ts = 1;
    c.g->setTextSize(ts);
    c.g->setTextColor(c.fg, c.bg);
    c.g->setCursor((int16_t)lroundf(icx(c, 40)), (int16_t)lroundf(icy(c, 40)));
    c.g->print("?");
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

// Pfeil-Ansicht (ohne Kartendaten).
static void drawNav(const NavData& d) {
  if (screen != SCR_NAV) switchScreen(SCR_NAV);

  if (strcmp(d.turn, shownTurn) != 0) {
    tft.fillRect(ICON_X, ICON_Y, ICON_SIZE, ICON_SIZE, COL_BG);
    IconCtx ic = {&tft, ICON_X, ICON_Y, 1.0f, COL_AMBER, COL_BG, COL_DIM};
    drawTurnIcon(ic, d.turn);
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

// ------------------------------------------------------------- Kartenansicht
// Liang-Barsky: schneidet die Strecke auf das Rechteck zu. false = ganz ausserhalb.
// Noetig, weil Dreiecke mit riesigen Koordinaten sonst sehr lange zum Fuellen brauchen.
static bool clipSegment(float& x0, float& y0, float& x1, float& y1, float xmin, float ymin,
                        float xmax, float ymax) {
  float dx = x1 - x0, dy = y1 - y0, t0 = 0, t1 = 1;
  float p[4] = {-dx, dx, -dy, dy};
  float q[4] = {x0 - xmin, xmax - x0, y0 - ymin, ymax - y0};
  for (int i = 0; i < 4; i++) {
    if (p[i] == 0) {
      if (q[i] < 0) return false;
    } else {
      float r = q[i] / p[i];
      if (p[i] < 0) {
        if (r > t1) return false;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return false;
        if (r < t1) t1 = r;
      }
    }
  }
  float nx0 = x0 + t0 * dx, ny0 = y0 + t0 * dy;
  float nx1 = x0 + t1 * dx, ny1 = y0 + t1 * dy;
  x0 = nx0; y0 = ny0; x1 = nx1; y1 = ny1;
  return true;
}

// Weltpunkt (Meter, Chunk-System) -> Bildschirmpixel (Fahrtrichtung nach oben).
static void worldToScreen(const View& v, float wx, float wy, float& sx, float& sy) {
  float dx = wx - v.cx, dy = wy - v.cy;
  float fwd = dx * v.sinH + dy * v.cosH;     // Meter nach vorn
  float right = dx * v.cosH - dy * v.sinH;   // Meter nach rechts
  sx = MAP_MX + right * v.sc;
  sy = MAP_MY - fwd * v.sc;
}

// Strecke in Weltkoordinaten zeichnen (mit Beschnitt).
static void strokeWorld(const View& v, float wx0, float wy0, float wx1, float wy1, int w,
                        uint8_t color) {
  float x0, y0, x1, y1;
  worldToScreen(v, wx0, wy0, x0, y0);
  worldToScreen(v, wx1, wy1, x1, y1);
  if (!clipSegment(x0, y0, x1, y1, -16, -16, SCREEN_W + 16, SCREEN_H + 16)) return;
  thickLineG(*canvas, x0, y0, x1, y1, w, color);
}

// Zeichnet einen Streckenzug: [from, to) aus dem Chunk, optional mit Startpunkt
// (sx, sy) vor dem ersten Chunk-Punkt bzw. Endpunkt (ex, ey) nach dem letzten.
static void strokeRoute(const View& v, int from, int to, bool hasStart, float sx, float sy,
                        bool hasEnd, float ex, float ey, int w, uint8_t color) {
  float px = sx, py = sy;
  bool havePrev = hasStart;
  for (int i = from; i < to; i++) {
    float cx = routeX[i], cy = routeY[i];
    if (havePrev) strokeWorld(v, px, py, cx, cy, w, color);
    px = cx;
    py = cy;
    havePrev = true;
  }
  if (hasEnd && havePrev) strokeWorld(v, px, py, ex, ey, w, color);
}

static void flushCanvas() {
  const uint8_t* src = canvas->getBuffer();
  tft.startWrite();
  tft.setAddrWindow(0, 0, SCREEN_W, SCREEN_H);
  for (int y = 0; y < SCREEN_H; y += 8) {
    const uint8_t* row = src + (size_t)y * SCREEN_W;
    for (int i = 0; i < SCREEN_W * 8; i++) flushBuf[i] = PALETTE[row[i] & 15];
    tft.writePixels(flushBuf, SCREEN_W * 8);
  }
  tft.endWrite();
}

static void canvasText(int x, int y, uint8_t size, uint8_t color, const char* text) {
  canvas->setTextSize(size);
  canvas->setTextColor(color);
  canvas->setCursor(x, y);
  canvas->print(text);
}

// Alle Abschnitte einer Klasse zeichnen.
static void drawRoads(const View& v, uint8_t cls, int w, uint8_t color) {
  const RoadSet& r = *rdActive;
  for (int k = 0; k < r.runs; k++) {
    if (r.cls[k] != cls) continue;
    int a = r.start[k], b = r.start[k + 1];
    for (int i = a + 1; i < b; i++) strokeWorld(v, r.x[i - 1], r.y[i - 1], r.x[i], r.y[i], w, color);
  }
}

static void drawMap(const NavData& d, const PoseData& p) {
  screen = SCR_MAP;
  canvas->fillScreen(PAL_BG);

  // ---- Karte
  float z = p.z > 20 ? (float)p.z : 300.0f;
  View v;
  float hr = p.h * (float)M_PI / 180.0f;
  v.sinH = sinf(hr);
  v.cosH = cosf(hr);
  v.sc = (MAP_MY - MAP_TOP) / z;
  v.cx = p.x;
  v.cy = p.y;

  // Nebenstrassen unter der Route: erst die kleinen, dann die Hauptstrassen.
  if (rdShow && rdActive->runs > 0) {
    bool near = z <= 320.0f;
    drawRoads(v, 1, near ? 3 : 2, PAL_SIDE);
    drawRoads(v, 2, near ? 5 : 3, PAL_MAIN);
  }

  int idx = constrain(p.idx, 0, routeN);
  // Schon gefahren: Punkte 0..idx-1, dann bis zum Fahrzeug.
  if (idx > 0) strokeRoute(v, 0, idx, false, 0, 0, true, p.x, p.y, PASSED_W, PAL_PASSED);
  // Voraus: Fahrzeug, dann Punkte idx..n-1. Erst schwarzer Rand, dann Farbe.
  if (idx < routeN) {
    strokeRoute(v, idx, routeN, true, p.x, p.y, false, 0, 0, CASING_W, PAL_BG);
    strokeRoute(v, idx, routeN, true, p.x, p.y, false, 0, 0, ROUTE_W, PAL_ROUTE);
  }

  // Ziel: Zielscheibe am letzten Punkt
  if (chunkEnd && routeN > 0) {
    float gx, gy;
    worldToScreen(v, routeX[routeN - 1], routeY[routeN - 1], gx, gy);
    if (gx > -10 && gx < SCREEN_W + 10 && gy > -10 && gy < SCREEN_H + 10) {
      canvas->fillCircle((int16_t)lroundf(gx), (int16_t)lroundf(gy), 9, PAL_CAR);
      canvas->fillCircle((int16_t)lroundf(gx), (int16_t)lroundf(gy), 6, PAL_BG);
      canvas->fillCircle((int16_t)lroundf(gx), (int16_t)lroundf(gy), 3, PAL_CAR);
    }
  }

  // Fahrzeug: weisser Pfeil mit schwarzem Rand
  canvas->fillTriangle(MAP_MX, MAP_MY - 16, MAP_MX - 13, MAP_MY + 12, MAP_MX, MAP_MY + 5, PAL_BG);
  canvas->fillTriangle(MAP_MX, MAP_MY - 16, MAP_MX, MAP_MY + 5, MAP_MX + 13, MAP_MY + 12, PAL_BG);
  canvas->fillTriangle(MAP_MX, MAP_MY - 12, MAP_MX - 9, MAP_MY + 9, MAP_MX, MAP_MY + 4, PAL_CAR);
  canvas->fillTriangle(MAP_MX, MAP_MY - 12, MAP_MX, MAP_MY + 4, MAP_MX + 9, MAP_MY + 9, PAL_CAR);

  // ---- Abbiege-Feld oben links
  char buf[32];
  canvas->fillRect(0, 0, PANEL_W, PANEL_H, PAL_BG);
  canvas->drawRect(0, 0, PANEL_W, PANEL_H, PAL_DIM);
  IconCtx ic = {canvas, (PANEL_W - 50) / 2, 4, 50.0f / ICON_SIZE, PAL_ROUTE, PAL_BG, PAL_DIM};
  drawTurnIcon(ic, d.turn);
  formatDistance(d.dist, buf, sizeof(buf));
  int tw = strlen(buf) * 12;
  canvasText((PANEL_W - tw) / 2, 57, 2, PAL_TEXT, buf);

  // ---- Strassenname oben
  if (stale || d.street[0]) {
    canvas->fillRect(PANEL_W, 0, SCREEN_W - PANEL_W, BAR_H, PAL_BG);
    canvas->drawFastHLine(PANEL_W, BAR_H, SCREEN_W - PANEL_W, PAL_DIM);
    if (stale) canvasText(PANEL_W + 6, 3, 2, PAL_RED, "KEIN SIGNAL");
    else canvasText(PANEL_W + 6, 3, 2, PAL_TEXT, d.street);
  }

  // ---- Statusleiste unten
  canvas->fillRect(0, STRIP_Y, SCREEN_W, SCREEN_H - STRIP_Y, PAL_BG);
  canvas->drawFastHLine(0, STRIP_Y, SCREEN_W, PAL_DIM);
  snprintf(buf, sizeof(buf), "%d", d.spd);
  canvasText(6, STRIP_Y + 2, 3, PAL_TEXT, buf);
  canvasText(66, STRIP_Y + 18, 1, PAL_DIM, "km/h");
  formatDistance(d.rem, buf, sizeof(buf));
  canvasText(112, STRIP_Y + 6, 2, PAL_TEXT, buf);
  formatEta(d.eta, buf, sizeof(buf));
  canvasText(222, STRIP_Y + 6, 2, PAL_TEXT, buf);

  flushCanvas();
}

// Entscheidet, was gezeichnet wird: Karte, wenn Pose und passendes Kartenstueck
// da sind, sonst der Pfeil.
static void renderCurrent() {
  if (!lastDataValid) return;
  bool useMap = canvas != nullptr && lastPose.valid && chunkValid && lastPose.id == chunkId &&
                routeN >= 2;
  if (useMap) drawMap(lastData, lastPose);
  else drawNav(lastData);
}

// -------------------------------------------------------------- Auswertung
static void handleMapChunk(JsonDocument& doc) {
  JsonArray r = doc["r"].as<JsonArray>();
  int k = 0;
  for (JsonVariant v : r) {
    int val = v.as<int>();
    int n = k / 2;
    if (n < MAX_ROUTE_PTS) {
      if ((k & 1) == 0) routeX[n] = (int16_t)val;
      else routeY[n] = (int16_t)val;
    }
    k++;
  }
  routeN = min(k / 2, (int)MAX_ROUTE_PTS);
  chunkId = doc["id"] | -1;
  chunkEnd = (doc["e"] | 0) != 0;
  chunkValid = true;
  int fr = doc["fr"] | 0;
  if (fr != chunkFrame) {  // neues Koordinatensystem: alte Strassen passen nicht mehr
    chunkFrame = fr;
    rdShow = false;
    rdActive->runs = 0;
    rdStageValid = false;
  }
  goodCount++;
  Serial.printf("Chunk %d: %d Punkte%s\n", chunkId, routeN, chunkEnd ? ", Ziel" : "");
}

// Nebenstrassen-Teil. Teile einer Ausgabe kommen der Reihe nach (n = 0, 1, ...);
// fehlt einer, wird die halbe Ausgabe verworfen und die alte bleibt stehen.
// Erst der letzte Teil (f = 1) schaltet um.
static void handleRoads(JsonDocument& doc) {
  int fr = doc["fr"] | 0;
  if (!chunkValid || fr == 0 || fr != chunkFrame) return;
  int g = doc["g"] | 0;
  int n = doc["n"] | 0;
  bool fin = (doc["f"] | 0) != 0;

  if (n == 0) {
    rdStageValid = true;
    rdStageGen = g;
    rdStageNext = 0;
    rdStage->runs = 0;
    rdStage->pts = 0;
    rdStage->start[0] = 0;
  }
  if (!rdStageValid || g != rdStageGen || n != rdStageNext) {
    rdStageValid = false;
    return;
  }

  RoadSet& r = *rdStage;
  for (JsonVariant rv : doc["l"].as<JsonArray>()) {
    JsonArray a = rv.as<JsonArray>();
    int cnt = a.size();
    int np = (cnt - 1) / 2;
    if (np < 2) continue;
    if (r.runs >= MAX_RD_RUNS || r.pts + np > MAX_RD_PTS) {
      rdStageValid = false;  // zu gross: alte Ausgabe behalten
      return;
    }
    int cls = a[0].as<int>();
    int x = 0, y = 0;
    for (int i = 0; i < np; i++) {
      int dx = a[1 + 2 * i].as<int>();
      int dy = a[2 + 2 * i].as<int>();
      x = (i == 0) ? dx : x + dx;
      y = (i == 0) ? dy : y + dy;
      r.x[r.pts + i] = (int16_t)x;
      r.y[r.pts + i] = (int16_t)y;
    }
    r.cls[r.runs] = (uint8_t)cls;
    r.runs++;
    r.pts += np;
    r.start[r.runs] = r.pts;
  }
  rdStageNext++;

  if (fin) {
    RoadSet* t = rdActive;
    rdActive = rdStage;
    rdStage = t;
    rdShow = true;
    rdStageValid = false;
    goodCount++;
    Serial.printf("Strassen g=%d: %d Abschnitte, %d Punkte\n", g, rdActive->runs, rdActive->pts);
    renderCurrent();
  }
}

static void handleLine(const char* line) {
  Serial.printf("RX: %.100s%s\n", line, strlen(line) > 100 ? " ..." : "");
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, line);
  if (err) {
    badCount++;
    Serial.printf("JSON-Fehler: %s\n", err.c_str());
    return;
  }

  const char* type = doc["t"] | "";
  if (!strcmp(type, "map")) {
    handleMapChunk(doc);
    return;
  }
  if (!strcmp(type, "rd")) {
    handleRoads(doc);
    return;
  }

  NavData d;
  d.spd = doc["spd"] | 0;
  strlcpy(d.turn, doc["turn"] | "S", sizeof(d.turn));
  d.dist = doc["dist"] | 0;
  strlcpy(d.street, doc["street"] | "", sizeof(d.street));
  d.rem = doc["rem"] | 0L;
  d.eta = doc["eta"] | 0;

  PoseData p;
  p.valid = !doc["m"].isNull();
  p.id = doc["m"] | -1;
  p.x = doc["x"] | 0.0f;
  p.y = doc["y"] | 0.0f;
  p.h = doc["h"] | 0;
  p.z = doc["z"] | 300;
  p.idx = doc["i"] | 0;

  goodCount++;
  haveData = true;
  lastMsgMs = millis();
  lastData = d;
  lastPose = p;
  lastDataValid = true;
  stale = false;
  renderCurrent();
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

// Eingebaute Demo-Strecke (Meter): Start 150 m hinter dem Nullpunkt, mehrere
// Kurven, eine Haarnadel, ein Bogen.
static const int16_t DEMO_ROUTE[][2] = {
  {0, -150}, {0, 300}, {350, 300}, {350, 650}, {600, 900}, {900, 900},
  {1000, 1100}, {1000, 1500}, {700, 1500}, {700, 1100}, {400, 1100}, {400, 1700}
};
static const int DEMO_ROUTE_N = sizeof(DEMO_ROUTE) / sizeof(DEMO_ROUTE[0]);

// Strassenraster rund um die Demo-Strecke: Nebenstrassen alle 90 m, jede
// vierte als Hauptstrasse, dazu zwei schraege Wege.
static void addDemoRun(RoadSet& r, uint8_t cls, int x0, int y0, int x1, int y1) {
  if (r.runs >= MAX_RD_RUNS || r.pts + 2 > MAX_RD_PTS) return;
  r.x[r.pts] = x0; r.y[r.pts] = y0;
  r.x[r.pts + 1] = x1; r.y[r.pts + 1] = y1;
  r.cls[r.runs] = cls;
  r.runs++;
  r.pts += 2;
  r.start[r.runs] = r.pts;
}

static void buildDemoRoads() {
  RoadSet& r = *rdActive;
  r.runs = 0;
  r.pts = 0;
  r.start[0] = 0;
  for (int gx = -450, k = 0; gx <= 1350; gx += 90, k++)
    addDemoRun(r, (k % 4 == 0) ? 2 : 1, gx, -300, gx, 2000);
  for (int gy = -270, k = 0; gy <= 2000; gy += 90, k++)
    addDemoRun(r, (k % 4 == 0) ? 2 : 1, -450, gy, 1350, gy);
  addDemoRun(r, 1, -300, -300, 1200, 1500);
  addDemoRun(r, 2, 1300, -200, 200, 1900);
  rdShow = true;
}

static void startMapDemo() {
  routeN = DEMO_ROUTE_N;
  for (int i = 0; i < routeN; i++) {
    routeX[i] = DEMO_ROUTE[i][0];
    routeY[i] = DEMO_ROUTE[i][1];
  }
  chunkId = 900;
  chunkEnd = true;
  chunkValid = true;
  chunkFrame = 1;
  buildDemoRoads();
  mapDemoAlong = 0;
  mapDemoLastMs = millis();
  haveData = true;
}

// Position / Richtung auf der Demo-Strecke bei Streckenmeter s.
static void demoPoint(float s, float& x, float& y, int& segment) {
  for (int i = 0; i + 1 < routeN; i++) {
    float dx = routeX[i + 1] - routeX[i], dy = routeY[i + 1] - routeY[i];
    float len = sqrtf(dx * dx + dy * dy);
    if (s <= len || i + 2 == routeN) {
      float t = len > 0 ? constrain(s / len, 0.0f, 1.0f) : 0;
      x = routeX[i] + dx * t;
      y = routeY[i] + dy * t;
      segment = i;
      return;
    }
    s -= len;
  }
}

static float demoTotal() {
  float t = 0;
  for (int i = 0; i + 1 < routeN; i++) {
    float dx = routeX[i + 1] - routeX[i], dy = routeY[i + 1] - routeY[i];
    t += sqrtf(dx * dx + dy * dy);
  }
  return t;
}

static void stepMapDemo() {
  unsigned long now = millis();
  float dt = (now - mapDemoLastMs) / 1000.0f;
  mapDemoLastMs = now;
  const float speedMps = 14.0f;  // ca. 50 km/h
  float total = demoTotal();
  mapDemoAlong += speedMps * dt;
  if (mapDemoAlong > total + 40) mapDemoAlong = 0;  // von vorn
  float along = min(mapDemoAlong, total);

  float x, y, x2, y2;
  int seg, seg2;
  demoPoint(along, x, y, seg);
  demoPoint(min(total, along + 20.0f), x2, y2, seg2);
  float hd = atan2f(x2 - x, y2 - y) * 180.0f / (float)M_PI;  // 0 = Nord
  if (hd < 0) hd += 360;

  // Naechste Ecke und Abstand dazu
  float distToCorner = 0;
  {
    float s = along, acc = 0;
    for (int i = 0; i + 1 < routeN; i++) {
      float dx = routeX[i + 1] - routeX[i], dy = routeY[i + 1] - routeY[i];
      float len = sqrtf(dx * dx + dy * dy);
      if (acc + len > s + 0.5f) {
        distToCorner = acc + len - s;
        break;
      }
      acc += len;
    }
  }
  char turn[8] = "ARR";
  if (seg + 2 < routeN) {
    float ax = routeX[seg + 1] - routeX[seg], ay = routeY[seg + 1] - routeY[seg];
    float bx = routeX[seg + 2] - routeX[seg + 1], by = routeY[seg + 2] - routeY[seg + 1];
    float ang = atan2f(ax * by - ay * bx, ax * bx + ay * by) * 180.0f / (float)M_PI;  // + = links
    bool left = ang > 0;
    float a = fabsf(ang);
    if (a < 20) strlcpy(turn, "S", sizeof(turn));
    else if (a < 55) strlcpy(turn, left ? "SL" : "SR", sizeof(turn));
    else strlcpy(turn, left ? "L" : "R", sizeof(turn));
  }

  // Sichtweite: wie in der App (Naeherung) - heranzoomen vor Ecken.
  float zoom = 230;
  if (distToCorner < zoom) zoom = constrain(distToCorner * 1.5f + 80, 160.0f, zoom);

  NavData d;
  d.spd = 50;
  strlcpy(d.turn, turn, sizeof(d.turn));
  d.dist = (int)distToCorner;
  strlcpy(d.street, "Demo-Weg", sizeof(d.street));
  d.rem = (long)(total - along);
  d.eta = (int)ceilf((total - along) / speedMps / 60.0f);

  PoseData p;
  p.valid = true;
  p.id = chunkId;
  p.x = x;
  p.y = y;
  p.h = (int)lroundf(hd) % 360;
  p.z = (int)zoom;
  p.idx = min(seg + 1, routeN);

  haveData = true;
  lastMsgMs = now;
  lastData = d;
  lastPose = p;
  lastDataValid = true;
  stale = false;
  renderCurrent();
}

static void handleSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == 'd' || c == 'D') {
      demoActive = !demoActive;
      mapDemoActive = false;
      demoIndex = 0;
      demoNextMs = 0;
      haveData = false;
      lastPose.valid = false;
      screen = SCR_NONE;  // Bildschirm neu aufbauen
      Serial.println(demoActive ? "Demo (Pfeile) AN" : "Demo AUS");
    } else if (c == 'm' || c == 'M') {
      mapDemoActive = !mapDemoActive;
      demoActive = false;
      screen = SCR_NONE;
      lastDataValid = false;
      haveData = false;
      if (mapDemoActive) startMapDemo();
      else {
        chunkValid = false;
        chunkFrame = 0;
        rdShow = false;
        rdActive->runs = 0;
      }
      Serial.println(mapDemoActive ? "Demo (Karte) AN" : "Demo AUS");
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

  // Hardware-SPI auf den eigenen Pins starten, BEVOR das Display initialisiert
  // wird. Kein SS-Pin: den schaltet die Adafruit-Bibliothek selbst.
  SPI.begin(TFT_SCK, TFT_MISO, TFT_MOSI, -1);
  tft.begin(TFT_SPI_HZ);
  tft.setRotation(3);
  tft.fillScreen(COL_BG);
  setBacklight(BACKLIGHT_LEVEL);

  // Kartenpuffer VOR Bluetooth anlegen, solange der Speicher noch am Stueck frei ist.
  canvas = new GFXcanvas8(SCREEN_W, SCREEN_H);
  if (canvas == nullptr || canvas->getBuffer() == nullptr) {
    Serial.println("WARNUNG: Kein Speicher fuer den Kartenpuffer - es bleibt beim Pfeil.");
    canvas = nullptr;
  } else {
    Serial.printf("Kartenpuffer ok. Freier Speicher: %u Byte\n", (unsigned)ESP.getFreeHeap());
  }

  lastPose.valid = false;
  resetShown();
  startBle();
  Serial.printf("Nach BLE-Start freier Speicher: %u Byte\n", (unsigned)ESP.getFreeHeap());
  switchScreen(SCR_WAIT_CLIENT);
}

void loop() {
  handleSerial();

  if (demoActive && millis() >= demoNextMs) {
    handleLine(DEMO[demoIndex]);
    demoIndex = (demoIndex + 1) % DEMO_COUNT;
    demoNextMs = millis() + 2500;
  }

  if (mapDemoActive && millis() >= demoNextMs) {
    stepMapDemo();
    demoNextMs = millis() + 250;
  }

  // Alle fertigen Zeilen abarbeiten (nur dieser Task liest).
  while (ringTail != ringHead) {
    handleLine(ring[ringTail]);
    portENTER_CRITICAL(&mux);
    ringTail = (ringTail + 1) % RING_SLOTS;
    portEXIT_CRITICAL(&mux);
  }

  const bool connected = clientConnected || demoActive || mapDemoActive;

  if (!connected) {
    haveData = false;
    lastDataValid = false;
    chunkValid = false;
    chunkFrame = 0;
    rdShow = false;
    lastPose.valid = false;
    if (screen != SCR_WAIT_CLIENT) switchScreen(SCR_WAIT_CLIENT);
  } else if (!haveData) {
    if (screen != SCR_WAIT_DATA) switchScreen(SCR_WAIT_DATA);
  } else if ((screen == SCR_NAV || screen == SCR_MAP) && lastDataValid) {
    bool nowStale = (millis() - lastMsgMs) > SIGNAL_TIMEOUT_MS;
    if (nowStale != stale) {
      stale = nowStale;
      renderCurrent();
    }
  }
  delay(5);
}
