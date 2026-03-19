# Authentication API Reference

This module provides authentication mechanisms for gRPC, particularly focusing on Google Cloud authentication including Service Accounts, Compute Engine metadata, and Application Default Credentials (ADC).

## 1. Classes

### Authenticators

**BaseAuthenticator**
Abstract base class for handling gRPC authentication. It manages an underlying `auth.AccessToken` and handles caching and refreshing the token before it expires.

* **Getters:**
  * `CallOptions toCallOptions` - Returns `CallOptions` configured with this authenticator's `authenticate` method as a provider.
* **Methods:**
  * `Future<void> authenticate(Map<String, String> metadata, String uri)` - Authenticates a request by adding the `authorization` header to the metadata. Also preemptively refreshes the token if it is close to expiration.
  * `Future<void> obtainAccessCredentials(String uri)` - Abstract method to obtain access credentials. Must be implemented by subclasses.

**HttpBasedAuthenticator**
Abstract authenticator extending `BaseAuthenticator` that uses an `http.Client` to obtain credentials.

* **Methods:**
  * `Future<void> obtainAccessCredentials(String uri)` - Obtains credentials and manages the HTTP client lifecycle. Prevents concurrent requests by caching the `Future`.
  * `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Abstract method to fetch credentials using the provided HTTP client.

**ComputeEngineAuthenticator**
Authenticator for Google Compute Engine metadata service. Automatically detects and uses the service account attached to the GCE instance or App Engine Flex environment.

* **Methods:**
  * `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Obtains credentials via the metadata server.

**ServiceAccountAuthenticator**
Authenticator using a Google Service Account JSON key.

* **Constructors:**
  * `ServiceAccountAuthenticator.fromJson(Map<String, dynamic> serviceAccountJson, List<String> scopes)` - Creates an authenticator from a JSON object and a list of OAuth scopes.
  * `factory ServiceAccountAuthenticator(String serviceAccountJsonString, List<String> scopes)` - Creates an authenticator from a JSON string.
* **Getters:**
  * `String? get projectId` - Returns the project ID associated with the service account.
* **Methods:**
  * `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Obtains access credentials via the service account.

**Example Usage:**

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  final jsonString = await File('service_account.json').readAsString();
  final authenticator = ServiceAccountAuthenticator(jsonString, [
    'https://www.googleapis.com/auth/cloud-platform',
  ]);

  final channel = ClientChannel(
    'my-service.googleapis.com',
    options: ChannelOptions(credentials: ChannelCredentials.secure()),
  );
  
  // Pass the authenticator to the call options
  final options = authenticator.toCallOptions;
}
```

**JwtServiceAccountAuthenticator**
Authenticator using a JWT and a Google Service Account without requiring an intermediate HTTP request to obtain an access token.

* **Constructors:**
  * `JwtServiceAccountAuthenticator.fromJson(Map<String, dynamic> serviceAccountJson)` - Creates an authenticator from a JSON object.
  * `factory JwtServiceAccountAuthenticator(String serviceAccountJsonString)` - Creates an authenticator from a JSON string.
* **Getters:**
  * `String? get projectId` - Returns the project ID.
* **Methods:**
  * `Future<void> obtainAccessCredentials(String uri)` - Generates a JWT token for the service account credentials directly without network calls.

**Example Usage:**

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  final jsonString = await File('service_account.json').readAsString();
  // No scopes required for JWT auth
  final authenticator = JwtServiceAccountAuthenticator(jsonString);

  final channel = ClientChannel(
    'my-service.googleapis.com',
    options: ChannelOptions(credentials: ChannelCredentials.secure()),
  );
  
  final options = authenticator.toCallOptions;
}
```

### RSA and ASN1 Utilities

*(Lower-level cryptography and parsing utilities used internally by authenticators.)*

**RS256Signer**
Used for signing messages with a private RSA key. Implements EMSA-PKCS1-v1_5.

* **Constructors:**
  * `RS256Signer(RSAPrivateKey _rsaKey)`
* **Methods:**
  * `List<int> sign(List<int> bytes)` - Signs the provided bytes using SHA-256 and RSA.

**ASN1Parser**
Parser for ASN1 encoded data.

* **Methods:**
  * `static ASN1Object parse(Uint8List bytes)` - Parses an ASN1 object from the given bytes.

**RSAPrivateKey**
Represents integers obtained while creating a Public/Private key pair.

* **Constructors:**
  * `RSAPrivateKey(BigInt n, BigInt e, BigInt d, BigInt p, BigInt q, BigInt dmp1, BigInt dmq1, BigInt coeff)`
* **Getters:**
  * `int get bitLength` - The number of bits used for the modulus. Usually 1024, 2048 or 4096 bits.

**RSAAlgorithm**
Provides methods for encrypting messages with a RSAPrivateKey.

* **Methods:**
  * `static List<int> encrypt(RSAPrivateKey key, List<int> bytes, int intendedLength)` - Performs the encryption of bytes with the private key.
  * `static BigInt bytes2BigInt(List<int> bytes)` - Converts a list of bytes to a BigInt.
  * `static List<int> integer2Bytes(BigInt integer, int intendedLength)` - Converts a positive BigInt to a list of bytes.

## 2. Enums

*(No public enums defined in this module)*

## 3. Extensions

*(No public extensions defined in this module)*

## 4. Top-Level Functions

**applicationDefaultCredentialsAuthenticator**
Creates an `HttpBasedAuthenticator` using Application Default Credentials (ADC).

* **Signature:** `Future<HttpBasedAuthenticator> applicationDefaultCredentialsAuthenticator(List<String> scopes)`
* **Parameters:**
  * `List<String> scopes` - The OAuth scopes to request for the access token.
* **Returns:** A `Future` that completes with an `HttpBasedAuthenticator`.
* **Description:** Looks for credentials in the following order of preference:
  1. A JSON file specified by the `GOOGLE_APPLICATION_CREDENTIALS` environment variable.
  2. A JSON file created by `gcloud auth application-default login`.
  3. GCE metadata service (on Google Compute Engine / App Engine Flex).

**Example Usage:**

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // Automatically resolves the best available credentials
  final authenticator = await applicationDefaultCredentialsAuthenticator([
    'https://www.googleapis.com/auth/cloud-platform',
  ]);

  final channel = ClientChannel(
    'my-service.googleapis.com',
    options: ChannelOptions(credentials: ChannelCredentials.secure()),
  );
  
  final callOptions = authenticator.toCallOptions;
  
  // Use callOptions when making RPC calls
}
```
