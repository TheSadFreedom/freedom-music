import 'package:http/http.dart' as http;

/// Authenticated HTTP session for cloud sync.
class CloudAuthSession {
  const CloudAuthSession({
    required this.client,
    required this.email,
  });

  final http.Client client;
  final String email;
}
