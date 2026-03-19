# gRPC Dart Authentication Examples

This document provides practical, copy-paste-ready examples for using the authentication mechanisms provided in `package:grpc/src/auth/`.

## 1. Basic Usage

### Using Application Default Credentials (ADC)

The most common and recommended way to authenticate is using Application Default Credentials, which automatically discovers credentials from the environment (`GOOGLE_APPLICATION_CREDENTIALS`), the gcloud CLI, or the Google Compute Engine metadata server.

```dart
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  // 1. Define the OAuth 2.0 scopes required for your API
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  
  // 2. Instantiate the authenticator
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);
  
  // 3. Obtain CallOptions which can be passed to your gRPC client stub
  final callOptions = authenticator.toCallOptions;
  
  print('Successfully loaded ADC credentials.');
  // Example usage with a mock stub:
  // final stub = MyServiceClient(channel, options: callOptions);
}
```

### Using a Service Account JSON String or Map

If you have a service account JSON file, you can explicitly load it using `ServiceAccountAuthenticator` or `JwtServiceAccountAuthenticator`. You can initialize these authenticators using a JSON string or a parsed JSON `Map`.

```dart
import 'dart:convert';
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth.dart';
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  // 1. Read the service account JSON file
  final serviceAccountJsonString = await File('service_account.json').readAsString();
  final serviceAccountJsonMap = jsonDecode(serviceAccountJsonString) as Map<String, dynamic>;
  
  // 2. Instantiate the JwtServiceAccountAuthenticator
  // JwtServiceAccountAuthenticator is useful when you don't need to specify scopes
  // and prefer JWT-based auth over OAuth2 access tokens.
  
  // From String:
  final jwtAuthenticator = JwtServiceAccountAuthenticator(serviceAccountJsonString);
  // From JSON Map:
  final jwtAuthenticatorFromJson = JwtServiceAccountAuthenticator.fromJson(serviceAccountJsonMap);
  
  print('Loaded JWT Authenticator for project: ${jwtAuthenticator.projectId}');
  
  // Alternatively, use ServiceAccountAuthenticator for OAuth2 access tokens
  final scopes = ['https://www.googleapis.com/auth/datastore'];
  
  // From String:
  final oauthAuthenticator = ServiceAccountAuthenticator(serviceAccountJsonString, scopes);
  // From JSON Map:
  final oauthAuthenticatorFromJson = ServiceAccountAuthenticator.fromJson(serviceAccountJsonMap, scopes);
  
  print('Loaded OAuth2 Authenticator for project: ${oauthAuthenticator.projectId}');
  
  // 3. Get CallOptions for gRPC requests
  final jwtOptions = jwtAuthenticator.toCallOptions;
  final oauthOptions = oauthAuthenticator.toCallOptions;
}
```

## 2. Common Workflows

### Authenticating on Google Compute Engine

If your code runs on Google Compute Engine (GCE), you can use the `ComputeEngineAuthenticator` to fetch credentials from the local metadata server.

```dart
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  // 1. Instantiate the Compute Engine authenticator directly
  final authenticator = ComputeEngineAuthenticator();
  
  // 2. Get the Call Options
  final callOptions = authenticator.toCallOptions;
  
  // 3. The authenticator will lazily fetch and cache the token 
  // when a gRPC call is made. Tokens are automatically refreshed.
}
```

### Manual Authentication Injection (BaseAuthenticator)

Sometimes you may want to manually trigger the authentication process to pre-warm the token before making any gRPC calls, using the `authenticate` method on `BaseAuthenticator`.

```dart
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);
  
  // The URI of the service you are communicating with
  final serviceUri = 'https://example.googleapis.com/';
  
  // Manually authenticate and obtain access credentials
  final metadata = <String, String>{};
  await authenticator.authenticate(metadata, serviceUri);
  
  // The authorization header is now populated in the metadata map
  print('Authorization Header: ${metadata['authorization']}');
}
```

## 3. Error Handling

When working with authentication, errors typically occur during the reading of the credentials file or when fetching tokens from the network.

```dart
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  try {
    final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
    
    // This will throw an exception if GOOGLE_APPLICATION_CREDENTIALS points
    // to a non-existent file, or if the JSON is malformed.
    final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);
    
    final callOptions = authenticator.toCallOptions;
    
  } catch (e) {
    if (e.toString().contains('Failed to read credentials file')) {
      print('Ensure GOOGLE_APPLICATION_CREDENTIALS is set to a valid file path.');
    } else if (e.toString().contains('Failed to parse JSON')) {
      print('The credentials file contains invalid JSON.');
    } else {
      print('An unexpected authentication error occurred: $e');
    }
  }
}
```

## 4. Advanced Usage

### Custom HTTP-based Authenticator

If you need to fetch OAuth2 tokens from a custom metadata server or an internal auth provider, you can extend `HttpBasedAuthenticator`.

```dart
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:grpc/grpc.dart';
import 'package:grpc/src/auth/auth.dart';

class CustomHttpAuthenticator extends HttpBasedAuthenticator {
  final String tokenEndpoint;

  CustomHttpAuthenticator(this.tokenEndpoint);

  @override
  Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri) async {
    // 1. Fetch a token from your custom endpoint
    final response = await client.get(Uri.parse(tokenEndpoint));
    
    if (response.statusCode != 200) {
      throw Exception('Failed to obtain token: ${response.body}');
    }
    
    // 2. Parse the custom response (example structure)
    // final json = jsonDecode(response.body);
    // final accessTokenStr = json['access_token'];
    
    // 3. Create the AccessToken object
    final token = auth.AccessToken(
      'Bearer', 
      'mockTokenData', // Use accessTokenStr in reality
      DateTime.now().toUtc().add(Duration(hours: 1))
    );
    
    // 4. Return the standard AccessCredentials object
    return auth.AccessCredentials(token, null, []);
  }
}

Future<void> main() async {
  final customAuth = CustomHttpAuthenticator('https://internal-auth.example.com/token');
  final callOptions = customAuth.toCallOptions;
  
  // Use callOptions in your gRPC requests
}
```

### Manual RSA Signing and Encryption

The authentication library includes utilities for RSA signing (`RS256Signer`), encryption (`RSAAlgorithm`), and parsing ASN.1 structures (`ASN1Parser`, `ASN1Object`, `ASN1Sequence`, `ASN1Integer`, `ASN1OctetString`, `ASN1ObjectIdentifier`, `ASN1Null`).

```dart
import 'dart:convert';
import 'package:grpc/src/auth/rsa.dart';

void main() {
  // 1. Define the components of your RSA private key.
  // In a real application, you would parse these from a PEM/DER file or ASN.1 structure.
  final n = BigInt.parse('123456789');
  final e = BigInt.parse('65537');
  final d = BigInt.parse('987654321');
  final p = BigInt.parse('11111');
  final q = BigInt.parse('22222');
  final dmp1 = BigInt.parse('33333');
  final dmq1 = BigInt.parse('44444');
  final coeff = BigInt.parse('55555');

  // 2. Instantiate the RSAPrivateKey
  final privateKey = RSAPrivateKey(n, e, d, p, q, dmp1, dmq1, coeff);
  
  // 3. Create the RS256Signer and sign a message
  final signer = RS256Signer(privateKey);
  final dataToSign = ascii.encode('mySecretData');
  final signature = signer.sign(dataToSign);
  
  print('Generated signature with length: ${signature.length}');
  
  // 4. Using RSAAlgorithm for manual encryption
  // Encrypt bytes and specify the intended length.
  final intendedLength = (privateKey.bitLength + 7) ~/ 8;
  final encryptedBytes = RSAAlgorithm.encrypt(privateKey, dataToSign, intendedLength);
  
  print('Encrypted bytes length: ${encryptedBytes.length}');
}
```

### Parsing ASN.1 Structures

You can use `ASN1Parser` to parse DER-encoded bytes into `ASN1Object`s. This is useful when loading keys manually.

```dart
import 'dart:typed_data';
import 'package:grpc/src/auth/rsa.dart';

void main() {
  // Example DER-encoded ASN.1 sequence containing an integer and a null.
  // Sequence tag (0x30), length 5, Integer tag (0x02), length 1, value 42, Null tag (0x05), length 0.
  final bytes = Uint8List.fromList([0x30, 0x05, 0x02, 0x01, 42, 0x05, 0x00]);
  
  // Parse the bytes into an ASN1Object
  final asn1Object = ASN1Parser.parse(bytes);
  
  if (asn1Object is ASN1Sequence) {
    print('Parsed an ASN1Sequence with ${asn1Object.objects.length} elements.');
    
    final firstElement = asn1Object.objects[0];
    if (firstElement is ASN1Integer) {
      print('First element is an integer: ${firstElement.integer}');
    }
    
    final secondElement = asn1Object.objects[1];
    if (secondElement is ASN1Null) {
      print('Second element is a null value.');
    }
  }
}
```
