// =============================================================================
// DePIN Edge Cluster — ESP32 Environmental Monitor
// Publishes temperature, heartbeat, and power status via MQTT.
// All traffic is LAN-only (to zpin-pi3-mon).
// =============================================================================

#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>

// ─── Configuration ──────────────────────────────────────────────────────────

// WiFi (your dorm network)
const char* WIFI_SSID     = "YOUR_WIFI_SSID";       // <-- CHANGE
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";    // <-- CHANGE

// MQTT Broker (zpin-pi3-mon LAN IP or Tailscale IP)
const char* MQTT_SERVER   = "192.168.1.100";         // <-- CHANGE to monitoring node IP
const int   MQTT_PORT     = 1883;
const char* MQTT_CLIENT   = "esp32-monitor-01";
// const char* MQTT_USER  = "";                      // Uncomment if auth needed
// const char* MQTT_PASS  = "";                      // Uncomment if auth needed

// Sensor pin (DHT22 or DHT11)
#define DHT_PIN   4
#define DHT_TYPE  DHT22     // Change to DHT11 if using that sensor

// Power monitoring pin (optional — connect to voltage divider on 5V rail)
#define POWER_PIN 34        // ADC pin

// LED for status
#define LED_PIN   2         // Built-in LED on most ESP32 boards

// Intervals (milliseconds)
const unsigned long HEARTBEAT_INTERVAL  = 30000;   // 30 seconds
const unsigned long SENSOR_INTERVAL     = 60000;   // 60 seconds
const unsigned long RECONNECT_INTERVAL  = 5000;    // 5 seconds

// MQTT Topics
const char* TOPIC_HEARTBEAT   = "depin/esp32/heartbeat";
const char* TOPIC_TEMPERATURE = "depin/esp32/temperature";
const char* TOPIC_HUMIDITY    = "depin/esp32/humidity";
const char* TOPIC_POWER       = "depin/esp32/power";
const char* TOPIC_RSSI        = "depin/esp32/rssi";
const char* TOPIC_UPTIME      = "depin/esp32/uptime";
const char* TOPIC_STATUS      = "depin/esp32/status";

// ─── Globals ────────────────────────────────────────────────────────────────

WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
DHT dht(DHT_PIN, DHT_TYPE);

unsigned long lastHeartbeat = 0;
unsigned long lastSensor    = 0;
unsigned long lastReconnect = 0;
unsigned long bootTime      = 0;
unsigned long heartbeatCount = 0;

// ─── WiFi Connection ────────────────────────────────────────────────────────

void setupWiFi() {
  Serial.print("Connecting to WiFi: ");
  Serial.println(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 60) {
    delay(500);
    Serial.print(".");
    attempts++;
    digitalWrite(LED_PIN, !digitalRead(LED_PIN));
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println();
    Serial.print("Connected! IP: ");
    Serial.println(WiFi.localIP());
    digitalWrite(LED_PIN, HIGH);
  } else {
    Serial.println();
    Serial.println("WiFi connection FAILED. Restarting...");
    delay(5000);
    ESP.restart();
  }
}

// ─── MQTT Connection ────────────────────────────────────────────────────────

void connectMQTT() {
  if (mqtt.connected()) return;

  unsigned long now = millis();
  if (now - lastReconnect < RECONNECT_INTERVAL) return;
  lastReconnect = now;

  Serial.print("Connecting to MQTT...");

  // Use client ID with random suffix to avoid conflicts
  String clientId = String(MQTT_CLIENT) + "-" + String(random(0xffff), HEX);

  bool connected = mqtt.connect(clientId.c_str());
  // If using auth:
  // bool connected = mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASS);

  if (connected) {
    Serial.println("connected!");

    // Publish online status (retained)
    mqtt.publish(TOPIC_STATUS, "online", true);

    // Set last will (offline when disconnected)
    // Note: Last will is set in connect(), not after
  } else {
    Serial.print("failed, rc=");
    Serial.println(mqtt.state());
  }
}

// ─── Sensor Reading ─────────────────────────────────────────────────────────

void readAndPublishSensors() {
  float temperature = dht.readTemperature();
  float humidity    = dht.readHumidity();

  if (!isnan(temperature)) {
    char tempStr[10];
    dtostrf(temperature, 4, 1, tempStr);
    mqtt.publish(TOPIC_TEMPERATURE, tempStr);
    Serial.print("Temp: ");
    Serial.print(tempStr);
    Serial.print("°C  ");
  } else {
    Serial.print("Temp: ERR  ");
  }

  if (!isnan(humidity)) {
    char humStr[10];
    dtostrf(humidity, 4, 1, humStr);
    mqtt.publish(TOPIC_HUMIDITY, humStr);
    Serial.print("Hum: ");
    Serial.print(humStr);
    Serial.println("%");
  } else {
    Serial.println("Hum: ERR");
  }

  // Power monitoring (optional — requires voltage divider circuit)
  int rawADC = analogRead(POWER_PIN);
  float voltage = (rawADC / 4095.0) * 3.3 * 2.0;  // Adjust multiplier for your divider
  char voltStr[10];
  dtostrf(voltage, 4, 2, voltStr);
  mqtt.publish(TOPIC_POWER, voltStr);

  // WiFi signal strength
  int rssi = WiFi.RSSI();
  char rssiStr[10];
  itoa(rssi, rssiStr, 10);
  mqtt.publish(TOPIC_RSSI, rssiStr);
}

// ─── Heartbeat ──────────────────────────────────────────────────────────────

void publishHeartbeat() {
  heartbeatCount++;
  unsigned long uptimeSeconds = (millis() - bootTime) / 1000;

  // Heartbeat with uptime
  char uptimeStr[20];
  snprintf(uptimeStr, sizeof(uptimeStr), "%lu", uptimeSeconds);
  mqtt.publish(TOPIC_UPTIME, uptimeStr);

  // Simple heartbeat counter
  char hbStr[20];
  snprintf(hbStr, sizeof(hbStr), "%lu", heartbeatCount);
  mqtt.publish(TOPIC_HEARTBEAT, hbStr);

  // Blink LED
  digitalWrite(LED_PIN, LOW);
  delay(50);
  digitalWrite(LED_PIN, HIGH);

  Serial.print("Heartbeat #");
  Serial.print(heartbeatCount);
  Serial.print(" | Uptime: ");
  Serial.print(uptimeSeconds);
  Serial.println("s");
}

// ─── Setup ──────────────────────────────────────────────────────────────────

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println();
  Serial.println("================================");
  Serial.println("DePIN ESP32 Environmental Monitor");
  Serial.println("================================");

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  // Initialize sensor
  dht.begin();

  // Connect WiFi
  setupWiFi();

  // Configure MQTT
  mqtt.setServer(MQTT_SERVER, MQTT_PORT);
  mqtt.setKeepAlive(60);
  mqtt.setBufferSize(256);

  // Set last will testament
  // mqtt.setWill(TOPIC_STATUS, "offline", true, 0);

  bootTime = millis();

  Serial.println("Setup complete. Starting monitoring loop...");
}

// ─── Main Loop ──────────────────────────────────────────────────────────────

void loop() {
  // Maintain WiFi
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("WiFi lost. Reconnecting...");
    setupWiFi();
  }

  // Maintain MQTT
  if (!mqtt.connected()) {
    connectMQTT();
  }
  mqtt.loop();

  unsigned long now = millis();

  // Heartbeat
  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL) {
    lastHeartbeat = now;
    if (mqtt.connected()) {
      publishHeartbeat();
    }
  }

  // Sensor reading
  if (now - lastSensor >= SENSOR_INTERVAL) {
    lastSensor = now;
    if (mqtt.connected()) {
      readAndPublishSensors();
    }
  }

  delay(100);  // Small delay to prevent watchdog issues
}
