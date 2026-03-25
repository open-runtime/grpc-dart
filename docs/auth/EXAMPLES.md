# Authentication Examples

This guide provides practical, copy-paste-ready examples for using the Authentication module in `grpc-dart`.

## 1. Primary Authentication Workflows

### Using Application Default Credentials (ADC)
This is the recommended way to authenticate when running on Google Cloud or using the `gcloud` CLI. It automatically handles discovery of credentials.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // 1. Define required OAuth 2.0 scopes
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];

  // 2. Create the authenticator using ADC
  // This searches GOOGLE_APPLICATION_CREDENTIALS, gcloud config, and metadata servers.
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);

  // 3. Convert to CallOptions to be used in stub methods
  final options = authenticator.toCallOptions;

  print('ADC Authenticator ready. Managed Project: ${authenticator.projectId ?? "Default"}');
}
```

### Using a Service Account Key (JSON String)
When you have a service account JSON file, you can load it directly.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  const jsonKeyString = '''
  {
    "type": "service_account",
    "project_id": "your-project-id",
    "private_key_id": "your-key-id",
    "private_key": "-----BEGIN PRIVATE KEY-----\\nMIIE...\\n-----END PRIVATE KEY-----\\n",
    "client_email": "your-service-account@your-project-id.iam.gserviceaccount.com"
  }
  ''';

  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];

  // Instantiate the ServiceAccountAuthenticator
  final authenticator = ServiceAccountAuthenticator(jsonKeyString, scopes);

  // Use the authenticator's options in your gRPC calls
  final options = authenticator.toCallOptions;

  print('Service Account Authenticator initialized for project: ${authenticator.projectId}');
}
```

### Self-Signed JWT Authentication
For improved performance in server-to-server scenarios, use self-signed JWTs to avoid an extra network round-trip to an OAuth token server.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  const jsonKeyString = '{...}'; // Your Service Account JSON string

  // Instantiate the JwtServiceAccountAuthenticator
  // It handles JWT signing locally using the provided private key.
  final jwtAuthenticator = JwtServiceAccountAuthenticator(jsonKeyString);

  final options = jwtAuthenticator.toCallOptions;

  print('JWT Authenticator configured for project: ${jwtAuthenticator.projectId}');
}
```

## 2. Real-World Integration Example

This example demonstrates how to use `CallOptions` from an authenticator with a generated gRPC stub, highlighting the **camelCase** naming conventions for protobuf fields.

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
// import 'generated/mail.pbgrpc.dart'; // Example generated file

Future<void> sendSecureMail(String jsonKey) async {
  final channel = ClientChannel('mail.googleapis.com');
  final stub = MailServiceClient(channel);
  
  // 1. Setup the authenticator
  final authenticator = JwtServiceAccountAuthenticator(jsonKey);
  final authOptions = authenticator.toCallOptions;

  // 2. Combine authentication with other call options (e.g., timeout)
  final callOptions = authOptions.mergedWith(
    CallOptions(timeout: Duration(seconds: 15)),
  );

  // 3. Construct the request using the builder pattern (cascade notation)
  // Note: snake_case fields from .proto are converted to camelCase in Dart.
  final request = SendMailRequest()
    ..batchId = 'TXN-98765'              // batch_id
    ..sendAt = Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000) // send_at
    ..mailSettings = (MailSettings()
      ..sandboxMode = false              // sandbox_mode
    )
    ..trackingSettings = (TrackingSettings()
      ..clickTracking = (ClickTracking()
        ..enable = true                  // enable
        ..enableText = true              // enable_text
        ..substitutionTag = '[click_id]' // substitution_tag
      )
      ..openTracking = (OpenTracking()
        ..enable = true                  // open_tracking
      )
    )
    ..dynamicTemplateData['user'] = 'Alice' // dynamic_template_data
    ..contentId = 'newsletter_01'        // content_id
    ..customArgs['source'] = 'organic'   // custom_args
    ..ipPoolName = 'marketing-pool'      // ip_pool_name
    ..replyTo = 'no-reply@example.com'   // reply_to
    ..replyToList.addAll(['logs@example.com']) // reply_to_list
    ..templateId = 'tmpl_abc'            // template_id
    ..groupId = 101                      // group_id
    ..groupsToDisplay.addAll([10, 20]);  // groups_to_display

  try {
    // 4. Pass the combined callOptions to the stub method
    final response = await stub.sendMail(request, options: callOptions);
    print('Successfully sent mail: ${response.messageId}');
  } catch (e) {
    print('Failed to send mail: $e');
  } finally {
    await channel.shutdown();
  }
}
```

## 3. Advanced Configuration

### Manual Header Injection
You can manually inject the authorization headers into a metadata map if you are not using `toCallOptions` directly.

```dart
import 'package:grpc/grpc.dart';

Future<void> manualInjection() async {
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);

  final metadata = <String, String>{};
  const targetUri = 'https://example.googleapis.com/Service/Method';

  // Injects 'authorization': 'Bearer <token>' into the map
  // Also injects 'X-Goog-User-Project' if a quota_project_id is detected
  await authenticator.authenticate(metadata, targetUri);

  print('Generated Headers: $metadata');
}
```

### Custom HTTP-based Authenticators
Extend `HttpBasedAuthenticator` to implement your own credential retrieval logic (e.g., from a custom internal service).

```dart
import 'package:grpc/grpc.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;

class InternalTokenAuthenticator extends HttpBasedAuthenticator {
  final Uri tokenUrl;

  InternalTokenAuthenticator(String url) : tokenUrl = Uri.parse(url);

  @override
  Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri) async {
    final response = await client.get(tokenUrl);
    
    if (response.statusCode != 200) {
      throw Exception('Internal token service error: ${response.statusCode}');
    }

    // Wrap the fetched token into AccessCredentials
    final token = auth.AccessToken(
      'Bearer', 
      response.body.trim(), 
      DateTime.now().toUtc().add(const Duration(minutes: 30))
    );
    
    return auth.AccessCredentials(token, null, []);
  }
}
```

### Low-Level RSA Utilities
The module provides cryptographic primitives for manual JWT signing or other RSA-based operations.

```dart
import 'dart:convert';
import 'dart:typed_data';
// Required for direct RSA access:
import 'package:grpc/src/auth/rsa.dart'; 

void manualSigningExample(BigInt n, BigInt e, BigInt d, BigInt p, BigInt q, BigInt dmp1, BigInt dmq1, BigInt coeff) {
  // 1. Define the private key
  final privateKey = RSAPrivateKey(n, e, d, p, q, dmp1, dmq1, coeff);

  // 2. Initialize the signer
  final signer = RS256Signer(privateKey);

  // 3. Sign a payload
  final payload = utf8.encode('{"iss":"service-account","aud":"https://example.com"}');
  final signature = signer.sign(payload);

  print('Raw signature bytes: ${signature.take(8).toList()}...');
}
```

## 4. Error Handling and Debugging

Authenticators may throw exceptions during credential acquisition. Use specific error types to handle different failure modes.

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> robustAuth() async {
  try {
    final auth = await applicationDefaultCredentialsAuthenticator([]);
    final options = auth.toCallOptions;
  } on IOException catch (e) {
    print('Network error fetching credentials: $e');
  } on FormatException catch (e) {
    print('Invalid JSON in credentials file: $e');
  } catch (e) {
    // Other errors like file not found or invalid scopes
    print('Authentication setup failed: $e');
  }
}
```