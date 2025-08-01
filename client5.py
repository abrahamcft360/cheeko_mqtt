import json
import time
import uuid
import threading
import socket
import struct
import logging
import pyaudio
import keyboard

from typing import Dict, Optional, Tuple
import requests
import paho.mqtt.client as mqtt_client
from paho.mqtt.enums import CallbackAPIVersion
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
from queue import Queue, Empty
import opuslib
CURRETT_VERSION = "1.7.1"
# --- Configuration ---
SERVER_IP = "64.227.170.31" # !!! UPDATE with your server's local IP address !!!
OTA_PORT = 8003
# DEVICE_MAC is now dynamically generated for uniqueness
PLAYBACK_BUFFER_MIN_FRAMES = 3  # Minimum frames to have in buffer to continue playback
PLAYBACK_BUFFER_START_FRAMES = 16 # Number of frames to buffer before starting playback

# --- NEW: Sequence tracking configuration ---
ENABLE_SEQUENCE_LOGGING = True  # Set to False to disable sequence loggingdocker-compose logs -f appserver
LOG_SEQUENCE_EVERY_N_PACKETS = 16  # Log every N packets instead of every packet

# --- NEW: Timeout configurations ---
TTS_TIMEOUT_SECONDS = 30  # Maximum time to wait for TTS audio
BUFFER_TIMEOUT_SECONDS = 10  # Maximum time to wait for initial buffering
KEEP_ALIVE_INTERVAL = 5  # Send keep-alive every N seconds

# --- Logging ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(name)s: %(message)s')
logger = logging.getLogger("TestClient")

# --- Global variables ---
mqtt_message_queue = Queue()
udp_session_details = {}
stop_threads = threading.Event()
start_recording_event = threading.Event() # Event to signal recording thread to start
stop_recording_event = threading.Event()  # Event to signal recording thread to stop

def generate_unique_mac() -> str:
    """Generates a unique MAC address for the client."""
    # Generate 6 random bytes for the MAC address
    # Using a common OUI prefix (00:16:3E) for locally administered addresses
    # and then random bytes to ensure uniqueness for each client instance.
    mac_bytes = [0x00, 0x16, 0x3E, # OUI prefix
                 uuid.uuid4().bytes[0], uuid.uuid4().bytes[1], uuid.uuid4().bytes[2]]
    return '_'.join(f'{b:02x}' for b in mac_bytes)
def download_firmware(url: str, dest_path: str) -> bool:
    """Download firmware from the given URL to the destination path."""
    try:
        logger.info(f"⬇️ Downloading firmware from {url} ...")
        response = requests.get(url, stream=True, timeout=10)
        response.raise_for_status()
        with open(dest_path, "wb") as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
        logger.info(f"✅ Firmware downloaded to {dest_path}")
        return True
    except Exception as e:
        logger.error(f"❌ Firmware download failed: {e}")
        return False
class TestClient:
    def __init__(self):
        self.mqtt_client = None
        # Generate a unique MAC address for this client instance
        self.device_mac_formatted = "00_16_3e_fa_3d_de"
        # generate_unique_mac()
        print(f"Generated unique MAC address: {self.device_mac_formatted}"  )
        # The P2P topic will now be unique to this client's MAC address
        self.p2p_topic = f"devices/p2p/{self.device_mac_formatted}"
        self.ota_config = {}
        self.udp_socket = None
        self.udp_listener_thread = None
        self.playback_thread = None
        self.audio_recording_thread = None
        self.udp_local_sequence = 0
        self.audio_playback_queue = Queue()
        
        # --- NEW: Sequence tracking variables ---
        self.expected_sequence = 1  # Expected next sequence number
        self.last_received_sequence = 0  # Last sequence number received
        self.total_packets_received = 0  # Total packets received
        self.out_of_order_packets = 0  # Count of out-of-order packets
        self.duplicate_packets = 0  # Count of duplicate packets
        self.missing_packets = 0  # Count of missing packets
        self.sequence_gaps = []  # List of detected gaps in sequence
        
        # --- NEW: State tracking ---
        self.tts_active = False
        self.last_audio_received = 0
        self.session_active = True
        self.conversation_count = 0
        
        # --- NEW: UDP Stream Speed Tracking ---
        self.stream_start_time = 0
        self.stream_end_time = 0
        self.total_bytes_received = 0
        self.speed_samples = []  # List to store speed samples for averaging
        self.last_speed_calculation = 0
        self.speed_calculation_interval = 1.0  # Calculate speed every second
        
        logger.info(f"Client initialized with unique MAC: {self.device_mac_formatted}")

    def on_mqtt_connect(self, client, userdata, flags, rc, properties=None):
        """Callback for MQTT connection."""
        if rc == 0:
            logger.info(f"✅ MQTT Connected! Subscribing to P2P topic: {self.p2p_topic}")
            client.subscribe(self.p2p_topic)
        else:
            logger.error(f"❌ MQTT Connection failed with code {rc}")

    def on_mqtt_message(self, client, userdata, msg):
        """Callback for MQTT message reception."""
        try:
            payload_str = msg.payload.decode()
            payload = json.loads(payload_str)
            logger.info(f"📨 MQTT Message received on topic '{msg.topic}':\n{json.dumps(payload, indent=2)}")
            
            # Handle TTS start signal (reset sequence tracking)
            if payload.get("type") == "tts" and payload.get("state") == "start":
                logger.info("🎵 TTS started. Resetting sequence tracking.")
                self.tts_active = True
                self.reset_sequence_tracking()
            
            # Handle TTS stop signal (start recording for next user input)
            elif payload.get("type") == "tts" and payload.get("state") == "stop":
                logger.info("🎤 TTS finished. Received 'stop' signal. Preparing for microphone capture...")
                self.tts_active = False
                self.print_sequence_summary()  # Print summary when TTS ends
                
                # Only proceed with recording if we actually received audio
                if self.total_packets_received > 0:
                    # Clear the stop event to allow the recording thread to continue or start
                    stop_recording_event.clear() 
                    # Set the start event to signal the recording thread to begin (if it was waiting)
                    start_recording_event.set()
                    logger.info("🎤 Cleared stop_recording_event and set start_recording_event for next recording.")
                else:
                    logger.warning("⚠️ No audio packets received during TTS. Server may have an issue.")
                    # Try to trigger another conversation after a short delay
                    threading.Timer(2.0, self.retry_conversation).start()
            
            # Handle STT message (server processed our speech)
            elif payload.get("type") == "stt":
                transcription = payload.get("text", "")
                logger.info(f"🗣️ Server transcribed: '{transcription}'")
            
            # Handle record stop signal (stop recording)
            elif payload.get("type") == "record_stop":
                logger.info("🛑 Received 'record_stop' signal from server. Stopping current audio recording...")
                stop_recording_event.set() # This will cause the recording thread loop to exit
            
            # Handle abort acknowledgment from server
            elif payload.get("type") == "abort_ack":
                logger.info("✅ Server acknowledged abort request")
                stop_recording_event.set()
                # Clear any buffered audio
                while not self.audio_playback_queue.empty():
                    try:
                        self.audio_playback_queue.get_nowait()
                    except:
                        break
                logger.info("🧹 Cleared audio playback buffer after abort")
            
            else:
                mqtt_message_queue.put(payload)
        except (json.JSONDecodeError, Exception) as e:
            logger.error(f"Error processing MQTT message: {e}")

    def retry_conversation(self):
        """Retry triggering a conversation if no audio was received."""
        if self.session_active and not self.tts_active:
            self.conversation_count += 1
            logger.info(f"🔄 Retry attempt #{self.conversation_count}: Sending listen message again...")
            
            if self.conversation_count < 3:  # Limit retries
                listen_payload = {
                    "type": "listen", 
                    "session_id": udp_session_details["session_id"], 
                    "state": "detect", 
                    "text": f"retry attempt {self.conversation_count}"
                }
                if self.mqtt_client:
                    # Send to both topics
                    self.mqtt_client.publish("device-server", json.dumps(listen_payload))
                    
                    # Also send wrapped format
                    wrapped_listen = {
                        "orginal_payload": listen_payload,  # Note: keeping original typo for compatibility
                        "sender_client_id": self.device_mac_formatted
                    }
                    self.mqtt_client.publish("internal/server-ingest", json.dumps(wrapped_listen))
                    logger.info(f"📤 Sent retry listen message (attempt {self.conversation_count})")
            else:
                logger.error("❌ Too many retry attempts. There may be a server issue.")
                self.session_active = False

    def reset_sequence_tracking(self):
        """Reset sequence tracking statistics for a new TTS stream."""
        self.expected_sequence = 1
        self.last_received_sequence = 0
        self.total_packets_received = 0
        self.out_of_order_packets = 0
        self.duplicate_packets = 0
        self.missing_packets = 0
        self.sequence_gaps = []
        self.last_audio_received = time.time()
        
        # Reset speed tracking for new stream
        self.stream_start_time = time.time()
        self.stream_end_time = 0
        self.total_bytes_received = 0
        self.speed_samples = []
        self.last_speed_calculation = time.time()
        
        if ENABLE_SEQUENCE_LOGGING:
            logger.info("🔄 Reset sequence tracking and speed tracking for new TTS stream")

    def calculate_stream_speed(self, bytes_received: int):
        """Calculate and track UDP stream speed from server to client."""
        current_time = time.time()
        
        # Update total bytes received
        self.total_bytes_received += bytes_received
        
        # Calculate instantaneous speed every second
        if current_time - self.last_speed_calculation >= self.speed_calculation_interval:
            if self.stream_start_time > 0:
                elapsed_time = current_time - self.stream_start_time
                if elapsed_time > 0:
                    # Calculate current speed in bytes per second
                    current_speed_bps = self.total_bytes_received / elapsed_time
                    current_speed_kbps = current_speed_bps / 1024
                    current_speed_mbps = current_speed_kbps / 1024
                    
                    # Store speed sample
                    self.speed_samples.append({
                        'timestamp': current_time,
                        'speed_bps': current_speed_bps,
                        'speed_kbps': current_speed_kbps,
                        'speed_mbps': current_speed_mbps,
                        'total_bytes': self.total_bytes_received,
                        'elapsed_time': elapsed_time
                    })
                    
                    # Log current speed
                    if ENABLE_SEQUENCE_LOGGING and len(self.speed_samples) % 5 == 0:  # Log every 5 samples
                        logger.info(f"🚀 Current UDP speed: {current_speed_kbps:.2f} KB/s ({current_speed_mbps:.3f} MB/s)")
                        logger.info(f"📊 Total received: {self.total_bytes_received:,} bytes in {elapsed_time:.2f}s")
            
            self.last_speed_calculation = current_time

    def get_average_stream_speed(self) -> dict:
        """Calculate average UDP stream speed statistics."""
        if not self.speed_samples:
            return {
                'average_speed_bps': 0,
                'average_speed_kbps': 0,
                'average_speed_mbps': 0,
                'peak_speed_bps': 0,
                'peak_speed_kbps': 0,
                'peak_speed_mbps': 0,
                'total_bytes': self.total_bytes_received,
                'total_duration': 0,
                'sample_count': 0
            }
        
        # Calculate averages
        total_speed_bps = sum(sample['speed_bps'] for sample in self.speed_samples)
        avg_speed_bps = total_speed_bps / len(self.speed_samples)
        avg_speed_kbps = avg_speed_bps / 1024
        avg_speed_mbps = avg_speed_kbps / 1024
        
        # Find peak speeds
        peak_sample = max(self.speed_samples, key=lambda x: x['speed_bps'])
        peak_speed_bps = peak_sample['speed_bps']
        peak_speed_kbps = peak_sample['speed_kbps']
        peak_speed_mbps = peak_sample['speed_mbps']
        
        # Calculate total duration
        if self.stream_start_time > 0:
            total_duration = (self.stream_end_time or time.time()) - self.stream_start_time
        else:
            total_duration = 0
        
        return {
            'average_speed_bps': avg_speed_bps,
            'average_speed_kbps': avg_speed_kbps,
            'average_speed_mbps': avg_speed_mbps,
            'peak_speed_bps': peak_speed_bps,
            'peak_speed_kbps': peak_speed_kbps,
            'peak_speed_mbps': peak_speed_mbps,
            'total_bytes': self.total_bytes_received,
            'total_duration': total_duration,
            'sample_count': len(self.speed_samples)
        }

    def print_sequence_summary(self):
        """Print a summary of sequence statistics and UDP stream speed."""
        if not ENABLE_SEQUENCE_LOGGING:
            return
        
        # Mark stream end time for final calculations
        self.stream_end_time = time.time()
        
        logger.info("=" * 60)
        logger.info("📊 SEQUENCE TRACKING SUMMARY")
        logger.info("=" * 60)
        logger.info(f"📦 Total packets received: {self.total_packets_received}")
        logger.info(f"🔢 Last sequence number: {self.last_received_sequence}")
        logger.info(f"❌ Missing packets: {self.missing_packets}")
        logger.info(f"🔄 Out-of-order packets: {self.out_of_order_packets}")
        logger.info(f"🔁 Duplicate packets: {self.duplicate_packets}")
        
        if self.sequence_gaps:
            logger.info(f"🕳️  Sequence gaps detected: {len(self.sequence_gaps)}")
            for gap in self.sequence_gaps[-5:]:  # Show last 5 gaps
                logger.info(f"   Gap: expected {gap['expected']}, got {gap['received']}")
        else:
            logger.info("✅ No sequence gaps detected")
        
        # Calculate packet loss percentage
        if self.last_received_sequence > 0:
            expected_total = self.last_received_sequence
            loss_rate = (self.missing_packets / expected_total) * 100
            logger.info(f"📈 Packet loss rate: {loss_rate:.2f}%")
        
        # Print UDP stream speed statistics
        logger.info("=" * 60)
        logger.info("🚀 UDP STREAM SPEED SUMMARY")
        logger.info("=" * 60)
        
        speed_stats = self.get_average_stream_speed()
        logger.info(f"📊 Total bytes received: {speed_stats['total_bytes']:,} bytes")
        logger.info(f"⏱️  Total stream duration: {speed_stats['total_duration']:.2f} seconds")
        logger.info(f"📈 Average speed: {speed_stats['average_speed_kbps']:.2f} KB/s ({speed_stats['average_speed_mbps']:.3f} MB/s)")
        logger.info(f"🔥 Peak speed: {speed_stats['peak_speed_kbps']:.2f} KB/s ({speed_stats['peak_speed_mbps']:.3f} MB/s)")
        logger.info(f"📊 Speed samples collected: {speed_stats['sample_count']}")
        
        # Calculate overall average speed for entire stream
        if speed_stats['total_duration'] > 0:
            overall_speed_bps = speed_stats['total_bytes'] / speed_stats['total_duration']
            overall_speed_kbps = overall_speed_bps / 1024
            overall_speed_mbps = overall_speed_kbps / 1024
            logger.info(f"🎯 Overall average speed: {overall_speed_kbps:.2f} KB/s ({overall_speed_mbps:.3f} MB/s)")
        
        logger.info("=" * 60)

    def get_current_speed_info(self) -> dict:
        """Get current UDP stream speed information in real-time."""
        current_time = time.time()
        
        if self.stream_start_time > 0:
            elapsed_time = current_time - self.stream_start_time
            if elapsed_time > 0:
                current_speed_bps = self.total_bytes_received / elapsed_time
                current_speed_kbps = current_speed_bps / 1024
                current_speed_mbps = current_speed_kbps / 1024
                
                return {
                    'current_speed_bps': current_speed_bps,
                    'current_speed_kbps': current_speed_kbps,
                    'current_speed_mbps': current_speed_mbps,
                    'total_bytes_received': self.total_bytes_received,
                    'elapsed_time': elapsed_time,
                    'packets_received': self.total_packets_received,
                    'is_active': self.tts_active
                }
        
        return {
            'current_speed_bps': 0,
            'current_speed_kbps': 0,
            'current_speed_mbps': 0,
            'total_bytes_received': self.total_bytes_received,
            'elapsed_time': 0,
            'packets_received': self.total_packets_received,
            'is_active': self.tts_active
        }

    def parse_packet_header(self, header: bytes) -> Dict:
        """Parse the packet header to extract sequence and other info."""
        if len(header) < 16:
            return {}
        
        try:
            # Unpack header: packet_type, flags, payload_len, ssrc, timestamp, sequence
            packet_type, flags, payload_len, ssrc, timestamp, sequence = struct.unpack('>BBHIII', header)
            return {
                'packet_type': packet_type,
                'flags': flags,
                'payload_len': payload_len,
                'ssrc': ssrc,
                'timestamp': timestamp,
                'sequence': sequence
            }
        except struct.error:
            return {}

    def track_sequence(self, sequence: int):
        """Track and analyze packet sequence numbers."""
        if not ENABLE_SEQUENCE_LOGGING:
            return
            
        self.total_packets_received += 1
        self.last_audio_received = time.time()
        
        # Check for out-of-order packets
        if sequence < self.expected_sequence:
            if sequence <= self.last_received_sequence:
                self.duplicate_packets += 1
                if self.total_packets_received % LOG_SEQUENCE_EVERY_N_PACKETS == 0:
                    logger.warning(f"🔁 Duplicate packet: seq={sequence} (expected={self.expected_sequence})")
            else:
                self.out_of_order_packets += 1
                if self.total_packets_received % LOG_SEQUENCE_EVERY_N_PACKETS == 0:
                    logger.warning(f"🔄 Out-of-order packet: seq={sequence} (expected={self.expected_sequence})")
        
        # Check for missing packets (gaps in sequence)
        elif sequence > self.expected_sequence:
            gap_size = sequence - self.expected_sequence
            self.missing_packets += gap_size
            self.sequence_gaps.append({
                'expected': self.expected_sequence,
                'received': sequence,
                'gap_size': gap_size,
                'timestamp': time.time()
            })
            logger.warning(f"🕳️  Sequence gap detected: expected {self.expected_sequence}, got {sequence} (missing {gap_size} packets)")
        
        # Update tracking variables
        if sequence > self.last_received_sequence:
            self.last_received_sequence = sequence
            self.expected_sequence = sequence + 1
        
        # Log sequence info periodically
        if self.total_packets_received % LOG_SEQUENCE_EVERY_N_PACKETS == 0:
            logger.info(f"🔢 Packet #{self.total_packets_received}: seq={sequence}, expected={self.expected_sequence}")

    def encrypt_packet(self, payload: bytes) -> bytes:
        """Encrypts the audio payload using AES-CTR with header as nonce."""
        global udp_session_details
        if "udp" not in udp_session_details: 
            logger.error("UDP session details not available for encryption.")
            return b''
        
        aes_key = bytes.fromhex(udp_session_details["udp"]["key"])
        packet_type, flags, ssrc = 0x01, 0x00, 0
        payload_len, timestamp, sequence = len(payload), int(time.time()), self.udp_local_sequence
        
        # Header is used as the nonce for AES-CTR
        header = struct.pack('>BBHIII', packet_type, flags, payload_len, ssrc, timestamp, sequence)
        
        cipher = Cipher(algorithms.AES(aes_key), modes.CTR(header), backend=default_backend())
        encryptor = cipher.encryptor()
        encrypted_payload = encryptor.update(payload) + encryptor.finalize()
        self.udp_local_sequence += 1
        return header + encrypted_payload

    def get_ota_config(self) -> bool:
        """Requests OTA configuration from the server."""
        logger.info(f"▶️ STEP 1: Requesting OTA config from http://{SERVER_IP}:{OTA_PORT}")
        try:
            response = requests.post(f"http://{SERVER_IP}:{OTA_PORT}", json={"mac_address": self.device_mac_formatted}, timeout=5)
            response.raise_for_status()
            self.ota_config = response.json()
            print(f"OTA Config received: {json.dumps(self.ota_config, indent=5)}")
            logger.info("✅ OTA config received successfully.")


             # --- Firmware version check and update ---
            firmware_info = self.ota_config.get("firmware", {})
            ota_version = firmware_info.get("version")
            ota_url = firmware_info.get("url")
            if ota_version and ota_url:
                def version_tuple(v):
                    return tuple(map(int, (v.split("."))))
                try:
                    if version_tuple(CURRETT_VERSION) < version_tuple(ota_version):
                        logger.info(f"🆕 New firmware available: {ota_version} (current: {CURRETT_VERSION})")
                        firmware_path = f"firmware_{ota_version}.bin"
                        if download_firmware(ota_url, firmware_path):
                            logger.info("🔦 Firmware flashing is success!")
                        else:
                            logger.error("❌ Firmware flashing failed.")
                    else:
                        logger.info(f"Firmware is up to date (current: {CURRETT_VERSION}, OTA: {ota_version})")
                except Exception as e:
                    logger.error(f"❌ Firmware version comparison failed: {e}")

            # --- Handle activation logic ---
            activation = self.ota_config.get("activation")
            if activation:
                code = activation.get("code")
                if code:
                    print(f"🔐 Activation Required. Code: {code}")
                    activated = False
                    for attempt in range(10):
                        logger.info(f"🕒 Checking activation status... Attempt {attempt + 1}/10")
                        try:
                            status_response = requests.get(f"http://{SERVER_IP}:{OTA_PORT}/ota/active", params={"mac": self.device_mac_formatted}, timeout=3)
                            print(f"Activation status response: {status_response.text}")
                            if status_response.ok and status_response.json().get("activated"):
                                logger.info("✅ Device activated!")
                                activated = True
                                break
                            else:
                                logger.warning("❌ Device not activated yet. Retrying...")

                        except Exception as e:
                            logger.warning(f"Activation check failed: {e}")
                        time.sleep(5)
                    if not activated:
                        logger.error("❌ Activation failed after 10 attempts. Exiting client.")
                        return False
            return True
        except requests.exceptions.RequestException as e:
            logger.error(f"❌ Failed to get OTA config: {e}")
            return False

    def connect_mqtt(self) -> bool:
        """Connects to the MQTT Broker."""
        logger.info("▶️ STEP 2: Connecting to MQTT Broker...")
        mqtt_cfg = self.ota_config["mqtt"]
        self.mqtt_client = mqtt_client.Client(callback_api_version=CallbackAPIVersion.VERSION2, client_id=mqtt_cfg["client_id"])
        self.mqtt_client.on_connect, self.mqtt_client.on_message = self.on_mqtt_connect, self.on_mqtt_message
        self.mqtt_client.username_pw_set(mqtt_cfg["username"], mqtt_cfg["password"])
        try:
            self.mqtt_client.connect(mqtt_cfg["endpoint"].split(":")[0], int(mqtt_cfg["endpoint"].split(":")[1]), 60)
            self.mqtt_client.loop_start()
            return True
        except Exception as e:
            logger.error(f"❌ Failed to connect to MQTT: {e}")
            return False

    def send_hello_and_get_session(self) -> bool:
        """Sends 'hello' message and waits for session details."""
        logger.info("▶️ STEP 3: Sending 'hello' and pinging UDP...")
        
        # Create hello message
        hello_payload = {
            "type": "hello", 
            "client_id": self.ota_config["mqtt"]["client_id"]
        }
        
        # Send to both topics for compatibility
        self.mqtt_client.publish("device-server", json.dumps(hello_payload))
        
        # Also send to internal/server-ingest with wrapped format
        wrapped_hello = {
            "orginal_payload": hello_payload,  # Note: keeping original typo for compatibility
            "sender_client_id": self.device_mac_formatted
        }
        self.mqtt_client.publish("internal/server-ingest", json.dumps(wrapped_hello))
        logger.info("📤 Sent hello message to both topics")
        
        try:
            response = mqtt_message_queue.get(timeout=10)
            if response.get("type") == "hello" and "udp" in response:
                global udp_session_details
                udp_session_details = response
                self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.udp_socket.settimeout(1.0)
                ping_payload = f"ping:{udp_session_details['session_id']}".encode()
                encrypted_ping = self.encrypt_packet(ping_payload)
                server_udp_addr = (SERVER_IP, udp_session_details['udp']['port'])
                logger.info(f"🔄 Sending UDP Ping to {server_udp_addr} with session ID {udp_session_details['session_id']}"
                             f" and key {udp_session_details['udp']['key']}"
                             f" (local sequence: {self.udp_local_sequence})"
                             )
                if encrypted_ping:
                    self.udp_socket.sendto(encrypted_ping, server_udp_addr)
                    logger.info(f"✅ UDP Ping sent. Session configured.")
                    return True
            logger.error(f"❌ Received unexpected message: {response}")
            return False
        except Empty:
            logger.error("❌ Timed out waiting for 'hello' response.")
            return False

    def _playback_thread(self):
        """Thread to play back incoming audio from the server with a robust jitter buffer."""
        p = pyaudio.PyAudio()
        audio_params = udp_session_details["audio_params"]
        stream = p.open(format=p.get_format_from_width(2),
                        channels=audio_params["channels"],
                        rate=audio_params["sample_rate"],
                        output=True)
        
        logger.info("🔊 Playback thread started.")
        is_playing = False
        buffer_timeout_start = time.time()

        while not stop_threads.is_set() and self.session_active:
            try:
                # --- JITTER BUFFER LOGIC ---
                if not is_playing:
                    # Wait until we have enough frames to start playback smoothly
                    if self.audio_playback_queue.qsize() < PLAYBACK_BUFFER_START_FRAMES:
                        # Check for timeout
                        if time.time() - buffer_timeout_start > BUFFER_TIMEOUT_SECONDS:
                            logger.warning(f"⏰ Buffer timeout after {BUFFER_TIMEOUT_SECONDS}s. Queue size: {self.audio_playback_queue.qsize()}")
                            if self.tts_active:
                                logger.warning("🔊 TTS is active but no audio received. Possible server issue.")
                            buffer_timeout_start = time.time()  # Reset timeout
                        
                        logger.info(f"🎧 Buffering audio... {self.audio_playback_queue.qsize()}/{PLAYBACK_BUFFER_START_FRAMES}")
                        time.sleep(0.05)
                        continue
                    else:
                        logger.info("✅ Buffer ready. Starting playback.")
                        is_playing = True

                # --- If buffer runs low, stop playing and re-buffer ---
                if self.audio_playback_queue.qsize() < PLAYBACK_BUFFER_MIN_FRAMES:
                    is_playing = False
                    buffer_timeout_start = time.time()  # Reset timeout when buffering starts
                    logger.warning(f"‼️ Playback buffer low ({self.audio_playback_queue.qsize()}). Re-buffering...")
                    continue
                
                # Get audio chunk from the queue and play it
                stream.write(self.audio_playback_queue.get(timeout=1))

            except Empty:
                is_playing = False
                buffer_timeout_start = time.time()  # Reset timeout
                continue
            except Exception as e:
                logger.error(f"Playback error: {e}")
                break

        stream.stop_stream()
        stream.close()
        p.terminate()
        logger.info("🔊 Playback thread finished.")

    def listen_for_udp_audio(self):
        """Thread to listen for incoming UDP audio from the server with sequence tracking."""
        logger.info(f"🎧 UDP Listener started on local socket {self.udp_socket.getsockname()}")
        aes_key = bytes.fromhex(udp_session_details["udp"]["key"])
        audio_params = udp_session_details["audio_params"]
        
        # Initialize the decoder with the sample rate provided by the server
        decoder = opuslib.Decoder(audio_params["sample_rate"], audio_params["channels"])
        frame_size_samples = int(audio_params["sample_rate"] * audio_params["frame_duration"] / 1000)
        
        # Create a larger buffer for decoding to handle variable Opus frame sizes
        # Opus can produce frames of different sizes, so we need a buffer that can handle the maximum
        max_frame_size_samples = frame_size_samples * 2  # Double the expected size as safety buffer
        logger.info(f"🎧 Decoder initialized: {audio_params['sample_rate']}Hz, {audio_params['channels']}ch, {audio_params['frame_duration']}ms")
        logger.info(f"🎧 Expected frame size: {frame_size_samples} samples ({frame_size_samples * 2} bytes PCM)")
        logger.info(f"🎧 Max buffer size: {max_frame_size_samples} samples ({max_frame_size_samples * 2} bytes PCM)")
        
        while not stop_threads.is_set() and self.session_active:
            try:
                data, addr = self.udp_socket.recvfrom(4096)
                if data and len(data) > 16:
                    header, encrypted = data[:16], data[16:]
                    
                    # --- Calculate UDP stream speed ---
                    self.calculate_stream_speed(len(data))
                    
                    # --- Parse header to extract sequence number ---
                    header_info = self.parse_packet_header(header)
                    if header_info and ENABLE_SEQUENCE_LOGGING:
                        sequence = header_info.get('sequence', 0)
                        timestamp = header_info.get('timestamp', 0)
                        payload_len = header_info.get('payload_len', 0)
                        
                        # Track sequence for analysis
                        self.track_sequence(sequence)
                        
                        # Detailed logging for first few packets or periodically
                        if self.total_packets_received <= 5 or self.total_packets_received % (LOG_SEQUENCE_EVERY_N_PACKETS * 2) == 0:
                            logger.info(f"📦 Packet details: seq={sequence}, payload={payload_len}B, ts={timestamp}, from={addr}")
                    
                    # Decrypt and decode as usual
                    cipher = Cipher(algorithms.AES(aes_key), modes.CTR(header), backend=default_backend())
                    decryptor = cipher.decryptor()
                    opus_payload = decryptor.update(encrypted) + decryptor.finalize()
                    
                    # Decode the Opus payload to PCM with proper buffer size handling
                    try:
                        # For Opus decoding, we need to provide a buffer that's large enough
                        # The actual frame size can vary, so we use a generous buffer size
                        # For 24kHz, 60ms frames: 24000 * 0.06 = 1440 samples
                        # But Opus can produce variable sizes, so we use 2x as safety margin
                        safe_frame_size = max_frame_size_samples
                        pcm_payload = decoder.decode(opus_payload, safe_frame_size)
                        self.audio_playback_queue.put(pcm_payload)
                        
                    except opuslib.exceptions.OpusError as e:
                        if b'buffer too small' in str(e).encode():
                            # Try with an even larger buffer - some Opus frames can be larger
                            try:
                                # Use 4x the expected frame size as maximum buffer
                                max_buffer_size = frame_size_samples * 4
                                pcm_payload = decoder.decode(opus_payload, max_buffer_size)
                                self.audio_playback_queue.put(pcm_payload)
                                logger.debug(f"🔧 Used maximum buffer for Opus decoding: {len(opus_payload)} bytes -> {len(pcm_payload)} bytes PCM")
                            except Exception as e2:
                                logger.error(f"❌ Failed to decode Opus with maximum buffer: {e2}")
                                # Skip this frame to avoid blocking the audio stream
                                logger.warning(f"⚠️ Skipping corrupted Opus frame: {len(opus_payload)} bytes")
                        else:
                            logger.error(f"❌ Opus decoding error: {e}")
                            # Skip this frame
                            logger.warning(f"⚠️ Skipping problematic Opus frame: {len(opus_payload)} bytes")
                    except Exception as e:
                        logger.error(f"❌ Unexpected Opus decoding error: {e}")
                        # Skip this frame
                        logger.warning(f"⚠️ Skipping frame due to unexpected error: {len(opus_payload)} bytes")
                    
            except socket.timeout:
                continue
            except Exception as e:
                logger.error(f"UDP Listen Error: {e}", exc_info=True)
        
        logger.info("👋 UDP Listener shutting down.")

    def _record_and_send_audio_thread(self):
        """Thread to record microphone audio and send it to the server."""
        # Main loop to keep the thread alive for multiple recording sessions
        while not stop_threads.is_set() and self.session_active:
            # Wait here until the start event is set (e.g., after TTS stop)
            if not start_recording_event.wait(timeout=1):
                continue
            
            # If the main stop signal was set while waiting, exit the thread
            if stop_threads.is_set():
                break

            logger.info("🔴 Recording thread activated. Capturing audio.")
            p = pyaudio.PyAudio()
            audio_params = udp_session_details["audio_params"]
            FORMAT, CHANNELS, RATE, FRAME_DURATION_MS = pyaudio.paInt16, audio_params["channels"], audio_params["sample_rate"], audio_params["frame_duration"]
            SAMPLES_PER_FRAME = int(RATE * FRAME_DURATION_MS / 1000)
            
            try:
                encoder = opuslib.Encoder(RATE, CHANNELS, opuslib.APPLICATION_VOIP)
            except Exception as e:
                logger.error(f"❌ Failed to create Opus encoder: {e}")
                return # Exit thread if encoder fails
            
            stream = p.open(format=FORMAT, channels=CHANNELS, rate=RATE, input=True, frames_per_buffer=SAMPLES_PER_FRAME)
            logger.info("🎙️ Microphone stream opened. Sending audio to server...")
            server_udp_addr = (SERVER_IP, udp_session_details['udp']['port'])
            
            packets_sent = 0
            last_log_time = time.time()

            # Inner loop for the active recording session
            while not stop_threads.is_set() and not stop_recording_event.is_set() and self.session_active:
                try:
                    pcm_data = stream.read(SAMPLES_PER_FRAME, exception_on_overflow=False)
                    opus_data = encoder.encode(pcm_data, SAMPLES_PER_FRAME)
                    encrypted_packet = self.encrypt_packet(opus_data)
                    
                    if encrypted_packet:
                        self.udp_socket.sendto(encrypted_packet, server_udp_addr)
                        packets_sent += 1
                        
                        if time.time() - last_log_time >= 1.0:
                            logger.info(f"⬆️  Sent {packets_sent} audio packets in the last second.")
                            packets_sent = 0
                            last_log_time = time.time()
                            
                except Exception as e:
                    logger.error(f"An error occurred in the recording loop: {e}")
                    break # Exit inner loop on error
            
            # Cleanup for the current recording session
            logger.info("🎙️ Stopping microphone stream for this session.")
            stream.stop_stream()
            stream.close()
            p.terminate()

            # Clear the start event so it has to be triggered again for the next session
            start_recording_event.clear()
            
            if stop_recording_event.is_set():
                logger.info("🛑 Recording stopped by server signal. Waiting for next turn.")
            
        logger.info("🔴 Recording thread finished completely.")

    def trigger_conversation(self):
        """Starts the audio streaming threads and sends initial listen message."""
        if not self.udp_socket: return False
        logger.info("▶️ STEP 4: Starting all streaming audio threads...")
        global stop_threads, start_recording_event, stop_recording_event
        stop_threads.clear()
        # Initially, clear both events. The server's initial TTS will set start_recording_event.
        start_recording_event.clear() 
        stop_recording_event.clear() 

        self.playback_thread = threading.Thread(target=self._playback_thread, daemon=True)
        self.udp_listener_thread = threading.Thread(target=self.listen_for_udp_audio, daemon=True)
        self.audio_recording_thread = threading.Thread(target=self._record_and_send_audio_thread, daemon=True)
        self.playback_thread.start(), self.udp_listener_thread.start(), self.audio_recording_thread.start()

        logger.info("▶️ STEP 5: Sending 'listen' message to trigger initial TTS from server...")
        # The server's initial TTS will then trigger the client's recording.
        listen_payload = {"type": "listen", "session_id": udp_session_details["session_id"], "state": "detect", "text": "hello baby"}
        
        # Send to both topics for compatibility
        self.mqtt_client.publish("device-server", json.dumps(listen_payload))
        
        # Also send wrapped format to internal/server-ingest
        wrapped_listen = {
            "orginal_payload": listen_payload,  # Note: keeping original typo for compatibility
            "sender_client_id": self.device_mac_formatted
        }
        self.mqtt_client.publish("internal/server-ingest", json.dumps(wrapped_listen))
        logger.info("📤 Sent listen message to trigger initial conversation")
        logger.info("⏳ Test running. Press Spacebar to abort TTS, 'S' key for speed info, or Ctrl+C to stop.")

        # Start a thread to monitor keyboard input
        def monitor_keyboard():
            spacebar_pressed = False
            s_key_pressed = False
            while not stop_threads.is_set() and self.session_active:
                try:
                    # Monitor spacebar for abort
                    if keyboard.is_pressed('space') and not spacebar_pressed:
                        spacebar_pressed = True
                        logger.info("🚫 Spacebar pressed. Sending abort message to server...")
                        
                        # Send abort message via MQTT
                        abort_payload = {
                            "type": "abort",
                            "session_id": udp_session_details["session_id"]
                        }
                        
                        # Publish to the correct topic that the server is listening to
                        self.mqtt_client.publish("device-server", json.dumps(abort_payload))
                        logger.info(f"📤 Sent abort message: {abort_payload}")
                        
                        # Also send internal/server-ingest topic (wrapped format)
                        wrapped_payload = {
                            "orginal_payload": abort_payload,  # Note: keeping original typo for compatibility
                            "sender_client_id": self.device_mac_formatted
                        }
                        self.mqtt_client.publish("internal/server-ingest", json.dumps(wrapped_payload))
                        logger.info(f"📤 Sent wrapped abort message to internal/server-ingest")
                        
                        # Stop current recording immediately
                        stop_recording_event.set()
                        logger.info("🛑 Stopped current recording due to abort")
                        
                    elif not keyboard.is_pressed('space'):
                        spacebar_pressed = False
                    
                    # Monitor 'S' key for speed information
                    if keyboard.is_pressed('s') and not s_key_pressed:
                        s_key_pressed = True
                        speed_info = self.get_current_speed_info()
                        logger.info("=" * 50)
                        logger.info("🚀 CURRENT UDP STREAM SPEED INFO")
                        logger.info("=" * 50)
                        logger.info(f"📊 Current speed: {speed_info['current_speed_kbps']:.2f} KB/s ({speed_info['current_speed_mbps']:.3f} MB/s)")
                        logger.info(f"📦 Total bytes received: {speed_info['total_bytes_received']:,} bytes")
                        logger.info(f"📈 Total packets received: {speed_info['packets_received']:,}")
                        logger.info(f"⏱️  Stream duration: {speed_info['elapsed_time']:.2f} seconds")
                        logger.info(f"🎵 TTS active: {'Yes' if speed_info['is_active'] else 'No'}")
                        
                        # Show average speed if we have samples
                        avg_stats = self.get_average_stream_speed()
                        if avg_stats['sample_count'] > 0:
                            logger.info(f"📊 Average speed: {avg_stats['average_speed_kbps']:.2f} KB/s ({avg_stats['average_speed_mbps']:.3f} MB/s)")
                            logger.info(f"🔥 Peak speed: {avg_stats['peak_speed_kbps']:.2f} KB/s ({avg_stats['peak_speed_mbps']:.3f} MB/s)")
                        logger.info("=" * 50)
                        
                    elif not keyboard.is_pressed('s'):
                        s_key_pressed = False
                        
                except Exception as e:
                    logger.error(f"❌ Error in keyboard monitoring: {e}")
                    
                time.sleep(0.01)

        keyboard_thread = threading.Thread(target=monitor_keyboard, daemon=True)
        keyboard_thread.start()

        try:
            # Keep running with better timeout handling
            timeout_count = 0
            while not stop_threads.is_set() and self.session_active:
                time.sleep(1)
                
                # Check if we've been inactive for too long
                if self.tts_active and time.time() - self.last_audio_received > TTS_TIMEOUT_SECONDS:
                    logger.warning(f"⏰ No audio received for {TTS_TIMEOUT_SECONDS}s during TTS. Possible server issue.")
                    timeout_count += 1
                    if timeout_count >= 3:
                        logger.error("❌ Too many timeouts. Stopping session.")
                        self.session_active = False
                        break
                    else:
                        logger.info("🔄 Attempting to recover by sending new listen message...")
                        self.retry_conversation()
                        
        except KeyboardInterrupt:
            logger.info("Manual interruption detected. Cleaning up...")
            stop_threads.set()
            self.session_active = False
        return True

    def cleanup(self):
        """Cleans up resources and disconnects."""
        logger.info("▶️ STEP 6: Cleaning up and disconnecting...")
        global stop_threads, start_recording_event, stop_recording_event
        stop_threads.set()
        self.session_active = False
        start_recording_event.set() # Unblock if waiting
        stop_recording_event.set()  # Unblock if running
        
        # Print final sequence summary
        if ENABLE_SEQUENCE_LOGGING and self.total_packets_received > 0:
            logger.info("📊 FINAL SEQUENCE SUMMARY")
            self.print_sequence_summary()
        
        if self.audio_recording_thread:
            logger.info("Attempting to join audio_recording_thread...")
            self.audio_recording_thread.join(timeout=2)
            if self.audio_recording_thread.is_alive():
                logger.warning("Audio recording thread did not terminate gracefully.")
        
        if self.playback_thread: self.playback_thread.join(timeout=2)
        if self.udp_listener_thread: self.udp_listener_thread.join(timeout=2)
        if self.udp_socket: self.udp_socket.close()
        
        if self.mqtt_client and udp_session_details:
            goodbye_payload = { "type": "goodbye", "session_id": udp_session_details.get("session_id") }
            
            # Send to both topics
            self.mqtt_client.publish("device-server", json.dumps(goodbye_payload))
            
            # Also send wrapped format
            wrapped_goodbye = {
                "orginal_payload": goodbye_payload,  # Note: keeping original typo for compatibility
                "sender_client_id": self.device_mac_formatted
            }
            self.mqtt_client.publish("internal/server-ingest", json.dumps(wrapped_goodbye))
            logger.info("👋 Sent 'goodbye' message to both topics.")
        
        if self.mqtt_client:
            self.mqtt_client.loop_stop()
            self.mqtt_client.disconnect()
            logger.info("🔌 MQTT Disconnected.")
        logger.info("✅ Test finished.")

    def run_test(self):
        """Runs the full test sequence."""
        if ENABLE_SEQUENCE_LOGGING:
            logger.info("🔢 Sequence tracking is ENABLED")
            logger.info(f"📊 Will log sequence info every {LOG_SEQUENCE_EVERY_N_PACKETS} packets")
        else:
            logger.info("🔢 Sequence tracking is DISABLED")
            
        if not self.get_ota_config(): return
        if not self.connect_mqtt(): return
        time.sleep(1) # Give MQTT a moment to connect and subscribe
        if not self.send_hello_and_get_session():
            self.cleanup()
            return
        self.trigger_conversation()
        self.cleanup()

if __name__ == "__main__":
    # You can control sequence logging from here
    print(f"🔢 Sequence logging: {'ENABLED' if ENABLE_SEQUENCE_LOGGING else 'DISABLED'}")
    print(f"📊 Log frequency: Every {LOG_SEQUENCE_EVERY_N_PACKETS} packets")
    
    client = TestClient()
    try:
        client.run_test()
    except KeyboardInterrupt:
        logger.info("Manual interruption detected. Cleaning up...")
        client.cleanup()