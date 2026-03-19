# Authentication Module Quickstart

## 1. Overview
The `auth` module provides comprehensive, production-ready authentication mechanisms for gRPC clients, primarily focusing on Google Cloud Platform (GCP) credential flows. It includes robust APIs for token management, automatic refreshing, JSON Web Token (JWT) generation, Application Default Credentials (ADC) resolution, and underlying utilities for RSA signing and ASN1 parsing.

## 2. Import
Import the libraries based on your application's environment:

```dart
// For core authentication interfaces and JWT logic (Platform agnostic)
import 'package:grpc/src/auth/auth.dart';

// For IO-dependent authenticators like ADC, Service Accounts, and GCE
import 'package:grpc/src/auth/auth_io.dart';

// For low-level cryptography and ASN.1 structure parsing
import 'package:grpc/src/auth/rsa.dart';
```

## 3. Core Authenticator Classes

### `BaseAuthenticator`
The foundational abstract class for all authenticators.
- `Future<void> authenticate(Map<String, String> metadata, String uri)`: Attaches the authorization header.
- `CallOptions get toCallOptions`: Generates the interceptor.
- `Future<void> obtainAccessCredentials(String uri)`: Abstract method to fetch credentials.

### `HttpBasedAuthenticator`
Inherits from `BaseAuthenticator` and provides HTTP client caching.
- `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)`: Abstract method to fetch credentials using a provided HTTP client.

## 4. Common Operations

### Using Application Default Credentials (ADC)
This is the recommended approach for GCP environments. It seamlessly handles local `gcloud` credentials, environment variables, or Compute Engine metadata.

```dart
import 'package:grpc/src/auth/auth_io.dart';

Future<void> main() async {
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  
  // Resolves the correct HttpBasedAuthenticator internally 
  // (ComputeEngineAuthenticator, ServiceAccountAuthenticator, or a refreshing ADC)
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);
  
  final callOptions = authenticator.toCallOptions;
  // Use callOptions in your generated gRPC Client calls
}
```

### Authenticating with a JWT Service Account
Use `JwtServiceAccountAuthenticator` when you want to avoid network-based token fetches and rely directly on locally-signed JWTs using `RS256Signer`.

```dart
import 'package:grpc/src/auth/auth.dart';
import 'dart:io';

Future<void> main() async {
  final serviceAccountJsonString = await File('service_account.json').readAsString();
  
  // Instantiates the BaseAuthenticator with JWT capabilities
  final authenticator = JwtServiceAccountAuthenticator(serviceAccountJsonString);
  
  // Alternatively, from parsed JSON:
  // final authenticator = JwtServiceAccountAuthenticator.fromJson(jsonMap);
  
  final callOptions = authenticator.toCallOptions;
  // Optional: access project info
  print('Project ID: ${authenticator.projectId}');
}
```

### Standard Service Account Authenticator
Use `ServiceAccountAuthenticator` for HTTP-based token resolution and refresh for a defined service account scope.

```dart
import 'package:grpc/src/auth/auth_io.dart';
import 'dart:io';

Future<void> main() async {
  final serviceAccountJsonString = await File('service_account.json').readAsString();
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  
  final authenticator = ServiceAccountAuthenticator(serviceAccountJsonString, scopes);
  
  // Alternatively, from parsed JSON:
  // final authenticator = ServiceAccountAuthenticator.fromJson(jsonMap, scopes);
  
  final callOptions = authenticator.toCallOptions;
  print('Project ID: ${authenticator.projectId}');
}
```

### Compute Engine Metadata Auth
For code strictly running on Google Compute Engine or App Engine Flex.

```dart
import 'package:grpc/src/auth/auth_io.dart';

void main() {
  final authenticator = ComputeEngineAuthenticator();
  final callOptions = authenticator.toCallOptions;
}
```

## 5. Low-Level RSA and Cryptography Utilities

The `rsa.dart` module provides classes for raw RSA signing and parsing `ASN1Object` streams (`ASN1Sequence`, `ASN1Integer`, `ASN1OctetString`, `ASN1ObjectIdentifier`, `ASN1Null`).

### Working with `RSAPrivateKey`
The `RSAPrivateKey` class encapsulates the components of an RSA key:
- `p` (BigInt): First prime number.
- `q` (BigInt): Second prime number.
- `n` (BigInt): Modulus.
- `e` (BigInt): Public exponent.
- `d` (BigInt): Private exponent.
- `dmp1` (BigInt): `d mod (p-1)`.
- `dmq1` (BigInt): `d mod (q-1)`.
- `coeff` (BigInt): `q^-1 mod p`.
- `bitLength` (int): Bit length of the modulus.

### Crypto Operations Examples

```dart
import 'package:grpc/src/auth/rsa.dart';
import 'dart:typed_data';

void encryptAndSign(RSAPrivateKey rsaKey, List<int> data) {
  // Encrypt directly using RSAAlgorithm
  final encryptedBytes = RSAAlgorithm.encrypt(rsaKey, data, 256);
  
  // Sign using EMSA-PKCS1-v1_5 SHA-256
  final signer = RS256Signer(rsaKey);
  final signature = signer.sign(data);
  
  // Convert BigInt to Bytes and vice versa
  final number = RSAAlgorithm.bytes2BigInt(data);
  final bytes = RSAAlgorithm.integer2Bytes(number, 256);
  
  // Parse ASN1
  final asn1Object = ASN1Parser.parse(Uint8List.fromList(data));
  
  if (asn1Object is ASN1Sequence) {
    print('Parsed a sequence with ${asn1Object.objects.length} elements');
  } else if (asn1Object is ASN1Integer) {
    print('Parsed integer: ${asn1Object.integer}');
  }
}
```

## 6. Configuration

The `applicationDefaultCredentialsAuthenticator()` flow automatically evaluates the following configurations in order:

1. **`GOOGLE_APPLICATION_CREDENTIALS`**: Environment variable pointing to a service account JSON file.
2. **gcloud Local Defaults**: Uses `%APPDATA%/gcloud/application_default_credentials.json` on Windows or `$HOME/.config/gcloud/application_default_credentials.json` on Linux/Mac.
3. **Metadata Service**: Fallback to Google Compute Engine (GCE) metadata service headers if no files are found.
4. **Quota Projects**: When using ADC user files, the system automatically checks for `quota_project_id` and attaches the `X-Goog-User-Project` header via the internal `_CredentialsRefreshingAuthenticator`.

## 7. Related Modules

*   `package:googleapis_auth/googleapis_auth.dart`: Used internally for HTTP-based authentication workflows and underlying credentials mapping.
*   `client/call.dart`: Exposes the `CallOptions` class which authenticators instantiate using the `toCallOptions` method.
*   `shared/logging/logging.dart`: Internal gRPC library utility utilized for logging failed `token_refresh` routines in the `authenticate` pipeline.
