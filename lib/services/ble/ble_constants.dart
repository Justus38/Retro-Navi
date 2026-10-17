/// Nordic UART Service (NUS): auf dem ESP32 weit verbreitet und gut dokumentiert.
/// Muss exakt zum ESP32-Sketch passen.
const kBleServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';

/// App -> ESP32 (Write / Write Without Response).
const kBleRxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

/// ESP32 -> App (Notify). Aktuell ungenutzt, fuer spaetere Rueckmeldungen.
const kBleTxUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

/// Name, unter dem sich der ESP32 meldet (Praefix reicht).
const kBleNamePrefix = 'RetroNavi';

/// Jede Nachricht endet mit einem Zeilenumbruch. Der ESP32 setzt die
/// Pakete damit wieder zusammen, auch wenn die MTU klein ist.
const kBleLineEnd = '\n';
