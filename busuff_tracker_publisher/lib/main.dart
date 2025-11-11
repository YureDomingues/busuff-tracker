import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // <-- 1. IMPORTAR PACOTE

// --- TIRAMOS AS CONSTANTES DAQUI ---
// Elas agora estão no .env
const String mqttTopic = 'busuff/tracker/location';

Future<void> main() async {
  // --- 2. CARREGAR O .ENV ANTES DE TUDO ---
  WidgetsFlutterBinding.ensureInitialized(); // Necessário para o await
  await dotenv.load(fileName: ".env");
  // --- FIM DA MODIFICAÇÃO ---

  runApp(const PublisherApp());
}

class PublisherApp extends StatelessWidget {
  const PublisherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Busuff Publisher',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const TrackingScreen(),
    );
  }
}

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({super.key});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  String _statusText = 'Desconectado';
  bool _isTracking = false;
  MqttServerClient? _mqttClient;
  
  StreamSubscription<Position>? _positionStream;
  Timer? _publishTimer;
  Position? _currentPosition;

  // --- 3. LER AS VARIÁVEIS AQUI DENTRO ---
  // Elas vêm do 'dotenv' e não são 'const'
  final String mqttHost = dotenv.env['MQTT_HOST'] ?? 'fallback_host_erro';
  final String mqttUser = dotenv.env['MQTT_USER'] ?? 'fallback_user_erro';
  final String mqttPass = dotenv.env['MQTT_PASS'] ?? 'fallback_pass_erro';
  // --- FIM DA MODIFICAÇÃO ---


  @override
  void dispose() {
    _stopTracking();
    super.dispose();
  }

  // 1. LÓGICA DE CONEXÃO MQTT
  Future<void> _connectMQTT() async {
    // Usamos as variáveis da classe (mqttHost, mqttUser, mqttPass)
    _mqttClient = MqttServerClient.withPort(mqttHost, 'busuff_publisher_client_final', 8883);
    _mqttClient!.logging(on: true);
    _mqttClient!.secure = true;
    _mqttClient!.keepAlivePeriod = 60;
    _mqttClient!.onBadCertificate = (dynamic certificate) => true;
    _mqttClient!.onConnected = _onMqttConnected; 
    _mqttClient!.onDisconnected = _onMqttDisconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('busuff_publisher_client_final')
        .startClean();
    _mqttClient!.connectionMessage = connMessage;

    try {
      setState(() {
        _statusText = 'Conectando ao MQTT...';
      });
      // Usamos as variáveis da classe
      await _mqttClient!.connect(mqttUser, mqttPass);
    } catch (e) {
      print('### Erro ao conectar MQTT: $e');
      _onMqttDisconnected();
    }
  }

  // ... (O RESTANTE DO SEU CÓDIGO (GPS, TIMERS, UI) CONTINUA EXATAMENTE O MESMO) ...
  // ...
  // 2. LÓGICA DE PERMISSÃO E STREAM DO GPS
  Future<bool> _requestGpsPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _statusText = 'Permissão de localização negada.';
        });
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _statusText = 'Permissão de localização negada permanentemente.';
      });
      return false;
    }
    return true;
  }

  // CHAMADO QUANDO O MQTT CONECTA
  void _onMqttConnected() {
    setState(() {
      _statusText = 'Conectado. Iniciando GPS e Timer...';
      _isTracking = true;
    });

    // 1. Inicia o GPS (para atualizar _currentPosition)
    _startGpsStream();

    // 2. Inicia o Timer de 5 segundos (para publicar)
    _publishTimer?.cancel(); // Cancela timer antigo (boa prática)
    _publishTimer = Timer.periodic(Duration(seconds: 5), (Timer t) {
      _publishLocation(); // Chama a função de publicar
    });
  }

  // CHAMADO QUANDO O MQTT DESCONECTA
  void _onMqttDisconnected() {
    setState(() {
      _statusText = 'MQTT Desconectado';
      _isTracking = false;
      _currentPosition = null;
    });
    // Para tudo
    _positionStream?.cancel();
    _publishTimer?.cancel();
  }

  // APENAS ATUALIZA A POSIÇÃO NA VARIÁVEL
  void _startGpsStream() {
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0, // <-- Correção: 0 para pegar TODAS as atualizações
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      
      // Apenas armazena a posição mais recente
      setState(() {
        _currentPosition = position;
        _statusText = 'Rastreando... (GPS OK)';
      });
      print('### Nova Posição GPS recebida: ${position.latitude}, ${position.longitude}');
    });
  }

  // CHAMADA PELO TIMER A CADA 5 SEGUNDOS
  void _publishLocation() {
    // Só publica se tivermos uma localização
    if (_currentPosition == null) {
      print('### Timer (5s): Sem posição GPS ainda. Pulando...');
      return;
    }

    // Só publica se o MQTT estiver conectado
    if (_mqttClient == null || _mqttClient!.connectionStatus!.state != MqttConnectionState.connected) {
      print('### Timer (5s): MQTT desconectado. Pulando...');
      return;
    }

    // Cria o payload (mensagem) COM DADOS REAIS
    final payload = {
      'lat': _currentPosition!.latitude,
      'lon': _currentPosition!.longitude,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final jsonPayload = jsonEncode(payload);

    // Publica no MQTT
    _publishMqttMessage(jsonPayload);

    setState(() {
      _statusText = 'Enviando (a cada 5s)';
    });
    print('### Publicado via Timer (5s): $jsonPayload');
  }

  // 3. LÓGICA DE PUBLICAÇÃO (Não muda, só é chamada por outra função)
  void _publishMqttMessage(String message) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    _mqttClient!.publishMessage(mqttTopic, MqttQos.atLeastOnce, builder.payload!);
  }

  // 4. FUNÇÕES DO BOTÃO (ATUALIZADAS)
  void _startTracking() async {
    // 1. Pede permissão do GPS
    final hasPermission = await _requestGpsPermission();
    if (!hasPermission) return; // Para se não tiver permissão
    
    // 2. Conecta ao MQTT (que vai ligar o GPS e o Timer)
    _connectMQTT();
  }

  void _stopTracking() {
    _positionStream?.cancel();
    _publishTimer?.cancel(); // <-- IMPORTANTE: Parar o timer
    _mqttClient?.disconnect(); // Isso vai chamar o _onMqttDisconnected
    
    setState(() {
      _isTracking = false;
      _statusText = 'Desconectado';
      _currentPosition = null;
    });
  }

  // --- UI (Não muda) ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Busuff Tracker (Motorista) - FINAL'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                'Status:',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                _statusText,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isTracking ? Colors.red : Colors.green,
                  padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 20),
                  textStyle: const TextStyle(fontSize: 20),
                ),
                onPressed: _isTracking ? _stopTracking : _startTracking,
                child: Text(_isTracking ? 'Parar Rastreamento' : 'Iniciar Rastreamento'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}