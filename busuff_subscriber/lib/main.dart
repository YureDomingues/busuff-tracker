import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // Teste do .env
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Teste da API Key
import 'package:mqtt_client/mqtt_client.dart'; // Teste da Conexão
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:async';
import 'dart:convert';

// --- TÓPICO QUE VAMOS OUVIR ---
const String mqttTopic = 'busuff/tracker/location';

Future<void> main() async {
  // 1. Carrega o .env ANTES de rodar o app
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  runApp(const SubscriberApp());
}

class SubscriberApp extends StatelessWidget {
  const SubscriberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Busuff Tracker (Aluno)',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // 2. Carrega as credenciais do .env
  final String mqttHost = dotenv.env['MQTT_HOST'] ?? 'ERRO_HOST';
  final String mqttUser = dotenv.env['MQTT_USER'] ?? 'ERRO_USER';
  final String mqttPass = dotenv.env['MQTT_PASS'] ?? 'ERRO_PASS';

  MqttServerClient? _mqttClient;
  String _statusText = 'Desconectado';

  // --- GOOGLE MAPS ---
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  
  // Posição inicial (ex: Centro do Rio)
  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(-22.9068, -43.1729),
    zoom: 12,
  );

  @override
  void initState() {
    super.initState();
    // 3. Tenta conectar ao MQTT assim que a tela abre
    _connectMQTT();
  }

  @override
  void dispose() {
    _mqttClient?.disconnect();
    super.dispose();
  }

  // --- LÓGICA MQTT (Quase idêntica à do Publisher) ---

  Future<void> _connectMQTT() async {
    _mqttClient = MqttServerClient.withPort(mqttHost, 'busuff_subscriber_client', 8883);
    _mqttClient!.logging(on: true);
    _mqttClient!.secure = true;
    _mqttClient!.keepAlivePeriod = 60;
    _mqttClient!.onBadCertificate = (dynamic certificate) => true; // A MÁGICA!

    _mqttClient!.onConnected = _onMqttConnected; // Diferente!
    _mqttClient!.onDisconnected = _onMqttDisconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('busuff_subscriber_client')
        .startClean();
    _mqttClient!.connectionMessage = connMessage;

    try {
      setState(() {
        _statusText = 'Conectando ao MQTT...';
      });
      await _mqttClient!.connect(mqttUser, mqttPass);
    } catch (e) {
      print('### Erro ao conectar MQTT: $e');
      _onMqttDisconnected();
    }
  }

  void _onMqttDisconnected() {
    setState(() {
      _statusText = 'MQTT Desconectado';
    });
  }

  // --- A MÁGICA DO SUBSCRIBER ---

  void _onMqttConnected() {
    setState(() {
      _statusText = 'MQTT Conectado! Aguardando ônibus...';
    });

    // 1. INSCREVE no tópico
    _mqttClient!.subscribe(mqttTopic, MqttQos.atLeastOnce);

    // 2. ESCUTA por mensagens
    _mqttClient!.updates!.listen(_onMqttMessage);
  }

  // CHAMADO A CADA NOVA MENSAGEM DO ÔNIBUS
  void _onMqttMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    final MqttPublishMessage receivedMessage = messages[0].payload as MqttPublishMessage;
    final String payload = MqttPublishPayload.bytesToStringAsString(receivedMessage.payload.message);

    print('### MENSAGEM RECEBIDA: $payload');

    // Faz o parse do JSON
    try {
      final Map<String, dynamic> data = jsonDecode(payload);
      final double lat = data['lat'];
      final double lon = data['lon'];
      final LatLng busPosition = LatLng(lat, lon);

      // ATUALIZA O MAPA!
      setState(() {
        _statusText = 'Ônibus localizado!';
        
        // Remove o marcador antigo e adiciona o novo
        _markers.clear();
        _markers.add(
          Marker(
            markerId: const MarkerId('busuff_onibus'),
            position: busPosition,
            infoWindow: const InfoWindow(title: 'Ônibus da UFF'),
            // TODO: Adicionar um ícone de ônibus customizado
            // icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure), 
          ),
        );
      });

      // (Opcional) Move a câmera para focar no ônibus
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(busPosition, 16),
      );

    } catch (e) {
      print('### Erro ao processar JSON: $e');
    }
  }

  // --- INTERFACE (UI) ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Busuff Tracker (Aluno)'),
      ),
      // O Stack permite colocar o texto de status EM CIMA do mapa
      body: Stack(
        children: [
          // 4. Se o mapa aparecer, sua Chave de API funcionou!
          GoogleMap(
            initialCameraPosition: _initialPosition,
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller; // Salva o controlador do mapa
            },
            markers: _markers, // Mostra os marcadores (o ônibus)
            zoomControlsEnabled: false,
          ),

          // Um banner simples para mostrar o status da conexão
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 5),
                ],
              ),
              child: Text(
                'Status: $_statusText',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}