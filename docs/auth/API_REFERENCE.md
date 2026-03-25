# Authentication API Reference

The **Authentication** module provides classes and functions for handling gRPC call authentication, including support for Google Application Default Credentials (ADC), Service Accounts, and custom JWT-based authentication.

## 1. Authenticators

These classes handle the lifecycle of obtaining and refreshing access tokens for gRPC calls.

### **BaseAuthenticator** (Abstract)
Base class for all authenticators. It manages token caching and proactive refresh.

*   **Properties:**
    *   `CallOptions toCallOptions` - Returns `CallOptions` containing the `authenticate` provider, ready to be passed to a client stub.
*   **Methods:**
    *   `Future<void> authenticate(Map<String, String> metadata, String uri)` - Adds the `authorization` header to the metadata. Automatically refreshes the token if it has expired or is about to expire (within 30 seconds).
    *   `Future<void> obtainAccessCredentials(String uri)` - Abstract method to be implemented by subclasses to fetch the actual credentials.

---

### **HttpBasedAuthenticator** (Abstract)
An authenticator that performs HTTP requests to obtain credentials.

*   **Methods:**
    *   `Future<void> obtainAccessCredentials(String uri)` - Implementation that uses an internal HTTP client to fetch tokens.
    *   `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Abstract method to be implemented by subclasses to perform the specific credential fetch using the provided client.

---

### **ComputeEngineAuthenticator**
Authenticates using the Google Compute Engine (GCE) metadata service. Useful for applications running on GCE, GKE, or App Engine Flexible.

*   **Methods:**
    *   `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Fetches credentials from the metadata server.

---

### **ServiceAccountAuthenticator**
Authenticates using a Google Service Account JSON key, requiring specific OAuth2 scopes.

*   **Constructors:**
    *   `factory ServiceAccountAuthenticator(String serviceAccountJsonString, List<String> scopes)` - Creates an authenticator from a JSON string.
    *   `ServiceAccountAuthenticator.fromJson(Map<String, dynamic> serviceAccountJson, List<String> scopes)` - Creates an authenticator from a JSON map.
*   **Properties:**
    *   `String? projectId` - The Google Cloud project ID extracted from the service account JSON.
*   **Methods:**
    *   `Future<auth.AccessCredentials> obtainCredentialsWithClient(http.Client client, String uri)` - Exchanges the service account key for an access token with the requested scopes.

---

### **JwtServiceAccountAuthenticator**
Authenticates using a JSON Web Token (JWT) signed with a Service Account's private key. This is often used for Google Cloud APIs that support JWT-based authorization without an intermediate OAuth2 token exchange.

*   **Constructors:**
    *   `factory JwtServiceAccountAuthenticator(String serviceAccountJsonString)` - Creates an authenticator from a JSON string.
    *   `JwtServiceAccountAuthenticator.fromJson(Map<String, dynamic> serviceAccountJson)` - Creates an authenticator from a JSON map.
*   **Properties:**
    *   `String? projectId` - The Google Cloud project ID.
*   **Methods:**
    *   `Future<void> obtainAccessCredentials(String uri)` - Generates and signs a JWT for the target URI.

---

## 2. Top-Level Functions

### **applicationDefaultCredentialsAuthenticator**
Creates an `HttpBasedAuthenticator` using **Application Default Credentials (ADC)**.

*   **Signature:** `Future<HttpBasedAuthenticator> applicationDefaultCredentialsAuthenticator(List<String> scopes)`
*   **Parameters:**
    *   `List<String> scopes` - The OAuth2 scopes to request.
*   **Search Order:**
    1.  **Environment Variable:** A JSON file at the path specified by `GOOGLE_APPLICATION_CREDENTIALS`.
    2.  **GCloud Config:** A JSON file created by `gcloud auth application-default login`.
        *   Windows: `%APPDATA%/gcloud/application_default_credentials.json`
        *   Linux/macOS: `$HOME/.config/gcloud/application_default_credentials.json`
    3.  **Metadata Server:** If running on Google Cloud (GCE, GKE, etc.), it fetches credentials from the metadata service.

---

## 3. Security Primitives (RSA & ASN.1)

These classes provide the underlying cryptographic support for signing JWTs.

### **RS256Signer**
Signs messages using a private RSA key with the SHA-256 algorithm (RS256).

*   **Constructors:**
    *   `RS256Signer(RSAPrivateKey rsaKey)`
*   **Methods:**
    *   `List<int> sign(List<int> bytes)` - Signs the bytes according to RFC 3447 (PKCS#1 v1.5).

---

### **RSAPrivateKey**
Represents the components of an RSA private key.

*   **Fields:**
    *   `BigInt n` - Modulus.
    *   `BigInt e` - Public exponent.
    *   `BigInt d` - Private exponent.
    *   `BigInt p`, `BigInt q` - Prime factors.
    *   `BigInt dmp1`, `BigInt dmq1`, `BigInt coeff` - CRT components for efficient signing.
*   **Properties:**
    *   `int bitLength` - The bit length of the modulus `n`.

---

### **RSAAlgorithm**
Utility class for RSA operations.

*   **Methods:**
    *   `static List<int> encrypt(RSAPrivateKey key, List<int> bytes, int intendedLength)` - Encrypts (signs) bytes using the private key.
    *   `static BigInt bytes2BigInt(List<int> bytes)`
    *   `static List<int> integer2Bytes(BigInt integer, int intendedLength)`

---

### **ASN1Parser**
Parses DER-encoded ASN.1 data.

*   **Methods:**
    *   `static ASN1Object parse(Uint8List bytes)` - Returns an `ASN1Object` tree.

---

### **ASN1Object** (and Subclasses)
Abstract base class for nodes in an ASN.1 tree.

*   **ASN1Integer**
    *   `BigInt integer` - The integer value.
*   **ASN1OctetString**
    *   `List<int> bytes` - The raw octet bytes.
*   **ASN1ObjectIdentifier**
    *   `List<int> bytes` - The encoded OID bytes.
*   **ASN1Sequence**
    *   `List<ASN1Object> objects` - The sequence of child ASN.1 objects.
*   **ASN1Null**
    *   Represents a null ASN.1 value.

---

## 4. Usage Examples

### Using Application Default Credentials

This is the recommended way to authenticate when running on Google Cloud or for local development using `gcloud`.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // 1. Create the authenticator with required scopes
  final authenticator = await applicationDefaultCredentialsAuthenticator([
    'https://www.googleapis.com/auth/cloud-platform',
  ]);

  // 2. Create a channel
  final channel = ClientChannel('pubsub.googleapis.com');

  // 3. Pass the authenticator to the client stub via call options
  final stub = PublisherClient(channel, options: authenticator.toCallOptions);

  // 4. Construct a request using the builder pattern and camelCase fields
  final request = Topic()
    ..name = 'projects/my-project/topics/my-topic'
    ..labels.addAll({'env': 'production'});

  await stub.createTopic(request);
}
```

### Using a Service Account Key File

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

void main() async {
  final jsonKey = File('path/to/service-account.json').readAsStringSync();
  
  // Use ServiceAccountAuthenticator for standard OAuth2 flow
  final authenticator = ServiceAccountAuthenticator(jsonKey, [
    'https://www.googleapis.com/auth/cloud-platform',
  ]);

  final channel = ClientChannel('my-service.com');
  final stub = MyServiceClient(channel, options: authenticator.toCallOptions);
}
```

### Naming Conventions in Generated Messages

When constructing messages for gRPC calls, always use **camelCase** for field access, even if the `.proto` file uses `snake_case`.

```dart
import 'package:grpc/grpc.dart';
// import 'src/generated/mail.pbgrpc.dart';

void example(MailServiceClient stub) async {
  // Proto fields like batch_id, send_at, mail_settings become camelCase in Dart
  final request = SendMailRequest()
    ..batchId = 'batch_123'
    ..sendAt = Int64(1672531200)
    ..mailSettings = (MailSettings()
      ..sandboxMode = true
      ..enableText = true)
    ..trackingSettings = (TrackingSettings()
      ..clickTracking = (ClickTracking()..enable = true)
      ..openTracking = (OpenTracking()..substitutionTag = '[open]'));

  await stub.sendMail(request);
}
```
