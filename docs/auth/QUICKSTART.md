# Authentication Module Quickstart

## 1. Overview
The Authentication module provides utilities for authenticating gRPC client calls, specifically for Google Cloud environment. It allows you to inject authorization metadata (like OAuth 2.0 access tokens or self-signed JWTs) into your gRPC calls.

This module simplifies the process of using **Application Default Credentials (ADC)**, **Service Accounts**, and **Compute Engine Metadata** by providing `BaseAuthenticator` implementations that automatically manage token acquisition and refresh.

## 2. Import
The primary authenticators are available via the main `grpc.dart` entry point. For the JWT-specific authenticator, you may need to import from the internal auth source.

```dart
import 'package:grpc/grpc.dart';
// Required for JwtServiceAccountAuthenticator:
import 'package:grpc/src/auth/auth.dart';
```

## 3. Basic Setup (Application Default Credentials)
The most common way to authenticate in a Google Cloud environment or locally via the gcloud CLI is using `applicationDefaultCredentialsAuthenticator`. It returns an `HttpBasedAuthenticator` which can be converted to `CallOptions`.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // 1. Define required OAuth 2.0 scopes
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];

  // 2. Create the authenticator using ADC
  // This automatically checks environment variables, gcloud config, and metadata servers.
  final authenticator = await applicationDefaultCredentialsAuthenticator(scopes);

  // 3. Convert to CallOptions to be used in client calls
  final options = authenticator.toCallOptions;

  // Use 'options' when calling your gRPC client methods
}
```

## 4. Advanced Authentication

### Using a Service Account JSON
If you have a Service Account JSON key string, use `ServiceAccountAuthenticator`.

```dart
import 'package:grpc/grpc.dart';

void setupServiceAccount(String jsonKeyString) {
  final scopes = ['https://www.googleapis.com/auth/cloud-platform'];
  
  // Creates an authenticator that exchanges the service account key for OAuth 2.0 tokens
  final authenticator = ServiceAccountAuthenticator(jsonKeyString, scopes);
  
  final options = authenticator.toCallOptions;
}
```

### Using a JWT Service Account (Self-Signed)
For improved performance, you can use a self-signed JWT. This avoids the extra network hop to the OAuth 2.0 token server.

```dart
import 'package:grpc/src/auth/auth.dart';

void setupJwtAuth(String jsonKeyString) {
  // Creates an authenticator that signs its own JWTs for authentication
  final authenticator = JwtServiceAccountAuthenticator(jsonKeyString);
  
  final options = authenticator.toCallOptions;
}
```

### Using Compute Engine Metadata
When running on GCE, GAE, or GKE, you can fetch tokens directly from the local metadata server.

```dart
import 'package:grpc/grpc.dart';

void setupComputeEngineAuth() {
  // Fetches credentials from the GCE metadata service
  final authenticator = ComputeEngineAuthenticator();
  
  final options = authenticator.toCallOptions;
}
```

## 5. Comprehensive Example (SendMail Service)

This example demonstrates using an authenticator with a generated gRPC client (`MailServiceClient`). Note how all `snake_case` proto fields are accessed using `camelCase` in Dart.

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
// Assuming mail.pbgrpc.dart is generated from your proto definitions
// import 'src/generated/mail.pbgrpc.dart';

Future<void> sendSecureMail(String jsonKey) async {
  final channel = ClientChannel('mail.googleapis.com');
  final stub = MailServiceClient(channel);
  
  // Setup JWT authentication
  final authenticator = JwtServiceAccountAuthenticator(jsonKey);
  final authOptions = authenticator.toCallOptions;

  // Combine auth options with call-specific options (like timeout)
  final callOptions = authOptions.mergedWith(
    CallOptions(timeout: Duration(seconds: 10)),
  );

  final request = SendMailRequest()
    ..batchId = 'batch-123' // Unique batch identifier
    ..sendAt = Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000) // Timestamp to send at
    ..mailSettings = (MailSettings()
      ..sandboxMode = false // Whether to run in sandbox mode
      ..enableText = true // Whether to enable text format
    )
    ..trackingSettings = (TrackingSettings()
      ..clickTracking = (ClickTracking()
        ..enable = true // Whether to enable click tracking
        ..enableText = true // Whether to enable text format for click tracking
        ..substitutionTag = '[click_track]' // The substitution tag for tracking
      )
      ..openTracking = (OpenTracking()
        ..enable = true // Whether to enable open tracking
        ..substitutionTag = '[open_track]' // The substitution tag for tracking
      )
    )
    ..dynamicTemplateData['user'] = 'John Doe' // Dynamic data for templates
    ..contentId = 'welcome-email-001' // Content identifier
    ..customArgs['campaign'] = 'spring_sale' // Custom arguments for tracking
    ..ipPoolName = 'transactional-pool' // IP pool name to use
    ..replyTo = 'support@example.com' // Reply-to address
    ..replyToList.addAll(['backup@example.com', 'logs@example.com']) // Multiple reply-to addresses
    ..templateId = 'tmpl_456' // ID of the template to use
    ..groupId = 789 // Target group ID
    ..groupsToDisplay.addAll([1, 2, 3]) // List of group IDs to display
    ..mailFrom = MailFrom.MAIL_FROM_SUPPORT; // Enum representing the mail sender

  try {
    final response = await stub.sendMail(request, options: callOptions);
    print('Mail sent: ${response.messageId}');
  } catch (e) {
    print('Error sending mail: $e');
  } finally {
    await channel.shutdown();
  }
}
```

## 6. Configuration Details

### Authenticator Inheritance
- **`BaseAuthenticator`**: The base class for all authenticators. Provides `toCallOptions`.
- **`HttpBasedAuthenticator`**: Subclass that handles asynchronous token fetching via HTTP clients.

### ADC Discovery Order
The `applicationDefaultCredentialsAuthenticator` function searches for credentials in the following order:
1. **`GOOGLE_APPLICATION_CREDENTIALS`**: Environment variable pointing to a service account JSON file.
2. **Local GCloud Config**: JSON file created by `gcloud auth application-default login`.
   - Windows: `%APPDATA%/gcloud/application_default_credentials.json`
   - Linux/macOS: `$HOME/.config/gcloud/application_default_credentials.json`
3. **Metadata Server**: Fetches from the Google Compute Engine (GCE) metadata service.

### Metadata Injection
Authenticators inject the `authorization` header into the metadata of every RPC call. If a `quota_project_id` is found in the credentials, the `X-Goog-User-Project` header is also automatically added.

## 7. Related Modules
- **Client (`lib/src/client/`)**: Uses `CallOptions` to attach the authentication metadata to HTTP/2 streams.
- **Shared (`lib/src/shared/`)**: Defines the `CallOptions` and `ClientMethod` classes used by the authenticators.
- **Google APIs Auth (`googleapis_auth`)**: The underlying library used for OAuth 2.0 credential management.
